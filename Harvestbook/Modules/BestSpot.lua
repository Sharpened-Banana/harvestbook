local ADDON, ns = ...

-- BestSpot module (spec §4.5): ranks zones across saved sessions and spots
-- within the current zone. Clicking a spot sets a map waypoint.
--
-- Listens to HB_SESSION_CHANGED("stopped"), HB_RECORDS_CHANGED,
-- HB_NODELOG_CHANGED and ZONE_CHANGED_NEW_AREA (spots scope only).
-- Owns no data; scope/metric live in HB.db.profile.bestspot.

local HB = ns.HB
local Format = ns.Format
local Rankings = ns.Rankings
local Theme = ns.Theme
local W = ns.Widgets

local BestSpot = HB:NewModule("BestSpot", "AceEvent-3.0")

local MIN_ZONE_SECONDS = 900   -- 15 active minutes
local MIN_SPOT_GATHERS = 5
local DASH = "\226\128\148"
local GREY = "|cff9d9d9d"

local function cfg()
  local c = HB.db.profile.bestspot
  if not c then
    c = { scope = "zones", metric = "gph" }
    HB.db.profile.bestspot = c
  end
  return c
end

local function money(copper) return Format.Money(copper, HB.db.profile.goldStyle) end

local function mapName(mapID)
  local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
  return info and info.name or ("Map " .. tostring(mapID))
end

local function currentMapID()
  return C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player") or nil
end

local function grey(text) return GREY .. text .. "|r" end

---------------------------------------------------------------------------
-- Cells
---------------------------------------------------------------------------

-- Columns + 4 px pad + 16 px scrollbar must be <= 440: zones 420, spots 420.
local ZONE_COLUMNS = {
  { key = "zone", title = "Zone", width = 125, align = "LEFT" },
  { key = "time", title = "Time", width = 50, align = "RIGHT" },
  { key = "nodes", title = "Nodes", width = 40, align = "RIGHT" },
  { key = "gph", title = "Gold/hr", width = 75, align = "RIGHT" },
  { key = "perNode", title = "Value/node", width = 70, align = "RIGHT" },
  { key = "nph", title = "Nodes/hr", width = 60, align = "RIGHT" },
}

local SPOT_COLUMNS = {
  { key = "spot", title = "Spot", width = 150, align = "LEFT" },
  { key = "kind", title = "Kind", width = 60, align = "LEFT" },
  { key = "gathers", title = "Gathers", width = 70, align = "RIGHT" },
  { key = "perNode", title = "Value/node", width = 140, align = "RIGHT" },
}

local function zoneCell(row, key)
  local text
  if key == "zone" then
    text = mapName(row.mapID)
    if row.lowData then text = text .. " (low data)" end
    return row.lowData and grey(text) or text
  elseif key == "time" then
    text = Format.Duration(row.seconds)
  elseif key == "nodes" then
    text = Format.Thousands(row.nodes)
  elseif key == "gph" then
    text = row.gph and money(row.gph) or DASH
  elseif key == "perNode" then
    text = row.perNode and money(row.perNode) or DASH
  elseif key == "nph" then
    text = row.nodesPerHour and string.format("%.1f", row.nodesPerHour) or DASH
  end
  if text and row.lowData then text = grey(text) end
  return text
end

local function spotLabel(row)
  return string.format("%.1f, %.1f", (row.x or 0) * 100, (row.y or 0) * 100)
end

local function spotCell(row, key)
  local text, icon
  if key == "spot" then
    text = spotLabel(row)
    if row.lowData then text = text .. " (low data)" end
  elseif key == "kind" then
    text = ""
    icon = Theme.ICONS and Theme.ICONS[row.kind] or nil
  elseif key == "gathers" then
    text = Format.Thousands(row.gathers)
  elseif key == "perNode" then
    text = row.perNode and money(row.perNode) or DASH
  end
  if text and text ~= "" and row.lowData then text = grey(text) end
  return text, icon
end

---------------------------------------------------------------------------
-- Waypoint
---------------------------------------------------------------------------

local function openMap(mapID)
  if OpenWorldMap then
    OpenWorldMap(mapID)
  elseif WorldMapFrame then
    if WorldMapFrame.Show then WorldMapFrame:Show() end
    if WorldMapFrame.SetMapID then WorldMapFrame:SetMapID(mapID) end
  end
end

local function setWaypoint(mapID, x, y)
  if not (mapID and x and y and C_Map and C_Map.SetUserWaypoint and UiMapPoint) then return end
  if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(mapID) then
    HB:Msg("Can't place a waypoint on this map.")
    return
  end
  C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
  if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)
  end
  openMap(mapID)
end

---------------------------------------------------------------------------
-- Page
---------------------------------------------------------------------------

local function spotRows(mapID)
  local zone = mapID and BestSpot.nodelog and BestSpot.nodelog:GetZone(mapID)
  if not zone then return {} end
  return Rankings.Spots(zone, MIN_SPOT_GATHERS)
end

local function refreshPage(body)
  local ui = body.bestspot
  if not ui then return end
  local c = cfg()
  local spots = c.scope == "spots"

  ui.scope:Refresh()
  ui.metric:Refresh()
  ui.metric:SetShown(not spots)
  ui.zones:SetShown(not spots)
  ui.spots:SetShown(spots)

  if spots then
    local mapID = currentMapID()
    ui.mapID = mapID
    local rows = spotRows(mapID)
    ui.spots:SetRows(rows, spotCell)
    ui.empty:SetShown(#rows == 0)
    ui.hint:SetText(mapID and (mapName(mapID) .. " " .. DASH .. " click a spot to set a waypoint") or "")
  else
    ui.empty:Hide()
    ui.hint:SetText("")
    local sessions = BestSpot.records and BestSpot.records:GetSessions() or {}
    local rows = Rankings.Zones(sessions, c.metric or "gph", MIN_ZONE_SECONDS)
    ui.zones:SetRows(rows, zoneCell)
    ui.zones:SetSort(c.metric == "perNode" and "perNode" or c.metric == "nodesPerHour" and "nph" or "gph", true)
  end
end

local function buildPage(body)
  local ui = {}
  body.bestspot = ui

  ui.scope = W.Dropdown(body, 170, {
    { value = "zones", text = "Zones" },
    { value = "spots", text = "Spots in current zone" },
  }, function() return cfg().scope end, function(v)
    cfg().scope = v
    refreshPage(body)
  end)
  ui.scope:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)

  ui.metric = W.Dropdown(body, 150, {
    { value = "gph", text = "Gold per hour" },
    { value = "perNode", text = "Value per node" },
    { value = "nodesPerHour", text = "Nodes per hour" },
  }, function() return cfg().metric end, function(v)
    cfg().metric = v
    refreshPage(body)
  end)
  ui.metric:SetPoint("LEFT", ui.scope, "RIGHT", 8, 0)

  ui.hint = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
  ui.hint:SetPoint("LEFT", ui.scope, "RIGHT", 8, 0)
  ui.hint:SetTextColor(Theme:Color("grey"))

  ui.zones = W.ColumnList(body, ZONE_COLUMNS)
  ui.zones:SetPoint("TOPLEFT", ui.scope, "BOTTOMLEFT", 0, -6)
  ui.zones:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)

  ui.spots = W.ColumnList(body, SPOT_COLUMNS)
  ui.spots:SetPoint("TOPLEFT", ui.scope, "BOTTOMLEFT", 0, -6)
  ui.spots:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
  ui.spots.onRowClick = function(row)
    setWaypoint(ui.mapID, row.x, row.y)
  end

  ui.empty = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  ui.empty:SetPoint("TOPLEFT", ui.spots, "TOPLEFT", 4, -30)
  ui.empty:SetText("No spots recorded in this zone yet.")
  ui.empty:SetTextColor(Theme:Color("grey"))
  ui.empty:Hide()
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local PAGE = { id = "bestspot", title = "Best Spot", order = 30, build = buildPage, refresh = refreshPage }

local function onChanged() HB.UI:RefreshPage("bestspot") end

function BestSpot:OnEnable()
  self.records = HB:GetModule("Records", true)
  self.nodelog = HB:GetModule("NodeLog", true)
  -- One handler per message (AceEvent keeps a single callback per object).
  HB:Listen(self, "HB_SESSION_CHANGED", function(_, state, s)
    if state == "stopped" and s ~= nil then onChanged() end
  end)
  HB:Listen(self, "HB_RECORDS_CHANGED", onChanged)
  HB:Listen(self, "HB_NODELOG_CHANGED", onChanged)
  self:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
    if cfg().scope == "spots" then onChanged() end
  end)
  PAGE.icon = Theme.ICONS and Theme.ICONS.bestspot
  HB.UI:RegisterPage(PAGE)
end

function BestSpot:OnDisable()
  self:UnregisterAllMessages()
  self:UnregisterAllEvents()
  HB.UI:UnregisterPage("bestspot")
end
