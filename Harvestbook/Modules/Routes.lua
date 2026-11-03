local ADDON, ns = ...

-- Routes module: builds a farming loop from the player's node log
-- (Logic/RouteBuilder) and shows it on the world map as numbered stops with
-- dots along the legs. "Next stop" sets a map waypoint and advances.
--
-- The active route is a snapshot in HB.char.route (see RouteBuilder.Sanitize);
-- later gathers or forgotten spots don't change it until the next Build.
-- Filters live in HB.db.profile.routes. Pins use HBD-Pins the way MapPins
-- does, under this module's own ref, and take no mouse so they never get in
-- the way of Map Pins' tooltips and clicks.

local HB = ns.HB
local Format = ns.Format
local NodeGrid = ns.NodeGrid
local RouteBuilder = ns.RouteBuilder
local Theme = ns.Theme
local W = ns.Widgets

local Routes = HB:NewModule("Routes", "AceEvent-3.0")

local HBDPins = LibStub("HereBeDragons-Pins-2.0", true)

local CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local STOP_SIZE = 18
local DOT_SIZE = 5
local KIND_LABEL = { herb = "Herb", ore = "Ore", skin = "Skin" }

local active    -- sanitised copy of HB.char.route, or nil
local curMap    -- mapID shown by the pager
local paged     -- the player chose curMap; don't follow zone changes
local pageBody

local function cfg() return HB.db.profile.routes end

local function mapName(mapID)
  local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
  return info and info.name or ("Map " .. tostring(mapID))
end

local function refresh() HB.UI:RefreshPage("routes") end

---------------------------------------------------------------------------
-- World map pins
---------------------------------------------------------------------------

local pools = { stop = {}, dot = {} } -- free frames per pin type
local shown = {}                      -- frames currently added to HBD

local function newFrame(strata)
  local pin = CreateFrame("Frame", nil, UIParent)
  pin:SetFrameStrata(strata)
  if pin.SetFixedFrameStrata then pin:SetFixedFrameStrata(true) end
  pin:EnableMouse(false)
  pin:Hide() -- HBD shows it while the map displays it
  return pin
end

local function newCircle(pin, layer, size, r, g, b, a)
  local tex = pin:CreateTexture(nil, layer)
  tex:SetTexture(CIRCLE)
  tex:SetVertexColor(r, g, b, a)
  tex:SetSize(size, size)
  tex:SetPoint("CENTER")
end

local CREATE = {
  -- Above Map Pins, which can sit at exactly the same position.
  stop = function()
    local pin = newFrame("DIALOG")
    pin:SetSize(STOP_SIZE, STOP_SIZE)
    local r, g, b = Theme:Color("gold")
    newCircle(pin, "BACKGROUND", STOP_SIZE, r, g, b, 1)
    newCircle(pin, "BORDER", STOP_SIZE - 3, 0.03, 0.06, 0.05, 1)
    pin.text = pin:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
    pin.text:SetPoint("CENTER")
    pin.text:SetTextColor(r, g, b)
    return pin
  end,
  dot = function()
    local pin = newFrame("HIGH")
    pin:SetSize(DOT_SIZE, DOT_SIZE)
    local r, g, b = Theme:Color("gold")
    newCircle(pin, "ARTWORK", DOT_SIZE, r, g, b, 0.85)
    return pin
  end,
}

local function addPin(pinType, mapID, x, y)
  local pin = table.remove(pools[pinType]) or CREATE[pinType]()
  pin.pinType = pinType
  if HBDPins:AddWorldMapIconMap(Routes, pin, mapID, x, y, HBD_PINS_WORLDMAP_SHOW_PARENT) then
    shown[#shown + 1] = pin
    return pin
  end
  local pool = pools[pinType]
  pool[#pool + 1] = pin
  return nil
end

local function releasePins()
  if not HBDPins then return end
  HBDPins:RemoveAllWorldMapIcons(Routes)
  for i = #shown, 1, -1 do
    local pin = shown[i]
    shown[i] = nil
    pin:Hide()
    pin:ClearAllPoints()
    local pool = pools[pin.pinType]
    pool[#pool + 1] = pin
  end
end

local function drawPins()
  releasePins()
  if not HBDPins or not active then return end
  for _, dot in ipairs(RouteBuilder.LegDots(active.stops)) do
    addPin("dot", active.mapID, dot.x, dot.y)
  end
  for i, stop in ipairs(active.stops) do
    local pin = addPin("stop", active.mapID, stop.x, stop.y)
    if pin then pin.text:SetText(i) end
  end
end

---------------------------------------------------------------------------
-- Route state
---------------------------------------------------------------------------

local function setRoute(route)
  active = route
  HB.char.route = route
  drawPins()
  refresh()
end

-- Saved data that can't be read is dropped: no route rather than an error.
local function loadRoute()
  setRoute(RouteBuilder.Sanitize(HB.char.route))
end

local function buildRoute()
  local zone = curMap and Routes.nodelog and Routes.nodelog:GetZone(curMap)
  if not zone then return end
  local c = cfg()
  local built = RouteBuilder.Build(RouteBuilder.Spots(zone, c.kinds, c.minGathers))
  if #built.stops == 0 then
    HB:Msg("No spots in %s match these filters.", mapName(curMap))
    return
  end
  local stops = {}
  for i, s in ipairs(built.stops) do
    local spot = zone[s.key]
    stops[i] = { x = s.x, y = s.y, gathers = s.weight, nodeID = NodeGrid.Dominant(spot), kind = spot.kind }
  end
  setRoute({ mapID = curMap, target = 0, stops = stops })
end

-- The loop is closed: after the last stop comes the first again.
local function nextStop()
  if not active then return end
  local target = active.target % #active.stops + 1
  local stop = active.stops[target]
  if HB:SetWaypoint(active.mapID, stop.x, stop.y) then
    active.target = target
    refresh()
  end
end

---------------------------------------------------------------------------
-- Page
---------------------------------------------------------------------------

-- Columns + 4 px pad + 16 px scrollbar must be <= 440.
local STOP_COLUMNS = {
  { key = "number", title = "Stop", width = 50, align = "RIGHT" },
  { key = "name", title = "Node", width = 290, align = "LEFT" },
  { key = "gathers", title = "Gathers", width = 80, align = "RIGHT" },
}

local function stopName(stop)
  local name = stop.nodeID and HB.db.global.nodeNames[stop.nodeID]
  return name or KIND_LABEL[stop.kind] or "Node"
end

local function stopCell(row, key)
  if key == "number" then
    return row.number
  elseif key == "name" then
    return stopName(row.stop), Theme.ICONS and Theme.ICONS[row.stop.kind] or nil
  elseif key == "gathers" then
    return Format.Thousands(row.stop.gathers)
  end
end

-- Keeps curMap valid; defaults to the player's zone when it has data.
local function resolveCurrent(zones)
  for _, id in ipairs(zones) do
    if id == curMap then return end
  end
  curMap, paged = nil, false
  local here = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  for _, id in ipairs(zones) do
    if id == here then curMap = id end
  end
  curMap = curMap or zones[1]
end

local function refreshPage(body)
  local ui = body.routes
  if not ui then return end
  local zones = Routes.nodelog and Routes.nodelog:GetZones() or {}
  resolveCurrent(zones)

  local index
  for i, id in ipairs(zones) do
    if id == curMap then index = i end
  end
  if index then
    ui.pager:SetText(string.format("%s (%d/%d)", mapName(curMap), index, #zones))
    ui.pager:SetButtonsEnabled(index > 1, index < #zones)
  else
    ui.pager:SetText("No zones recorded")
    ui.pager:SetButtonsEnabled(false, false)
  end

  for _, toggle in ipairs(ui.toggles) do toggle:Refresh() end
  ui.minGathers:Refresh()
  ui.build:SetEnabled(index ~= nil)
  ui.nextStop:SetEnabled(active ~= nil)
  ui.clear:SetEnabled(active ~= nil)

  local rows = {}
  if active then
    for i, stop in ipairs(active.stops) do rows[i] = { number = i, stop = stop } end
    local text = string.format("%s: %d %s", mapName(active.mapID), #rows, #rows == 1 and "stop" or "stops")
    if active.target > 0 then text = text .. string.format(", waypoint on stop %d", active.target) end
    ui.status:SetText(text)
  else
    ui.status:SetText("")
  end
  ui.stops:SetRows(rows, stopCell)
  ui.empty:SetShown(not active)
end

local function step(delta)
  local zones = Routes.nodelog and Routes.nodelog:GetZones() or {}
  for i, id in ipairs(zones) do
    if id == curMap and zones[i + delta] then
      curMap, paged = zones[i + delta], true
      break
    end
  end
  if pageBody then refreshPage(pageBody) end
end

local function safely(fn)
  return function() HB:SafeCall("Routes", fn) end
end

local function kindToggle(parent, kind, label)
  return W.Toggle(parent, label,
    function() return cfg().kinds[kind] end,
    function(on) cfg().kinds[kind] = on end)
end

local MIN_GATHERS = {}
for _, n in ipairs({ 1, 2, 3, 5, 10 }) do
  MIN_GATHERS[#MIN_GATHERS + 1] = { value = n, text = "Minimum gathers: " .. n }
end

local function buildPage(body)
  pageBody = body
  local ui = {}
  body.routes = ui

  ui.pager = W.Pager(body, function() step(-1) end, function() step(1) end)
  ui.pager:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
  ui.pager:SetWidth(420)

  local herb = kindToggle(body, "herb", "Herbs")
  herb:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -28)
  local ore = kindToggle(body, "ore", "Ore")
  ore:SetPoint("LEFT", herb, "LEFT", 75, 0)
  local skin = kindToggle(body, "skin", "Skinning")
  skin:SetPoint("LEFT", ore, "LEFT", 60, 0)
  ui.toggles = { herb, ore, skin }

  ui.minGathers = W.Dropdown(body, 165, MIN_GATHERS,
    function() return cfg().minGathers end,
    function(v) cfg().minGathers = v end)
  ui.minGathers:SetPoint("LEFT", skin, "LEFT", 95, 0)

  ui.build = W.RedButton(body, "Build", safely(buildRoute))
  ui.build:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -58)
  ui.nextStop = W.RedButton(body, "Next stop", safely(nextStop))
  ui.nextStop:SetPoint("LEFT", ui.build, "RIGHT", 8, 0)
  ui.clear = W.RedButton(body, "Clear route", safely(function() setRoute(nil) end))
  ui.clear:SetPoint("LEFT", ui.nextStop, "RIGHT", 8, 0)

  ui.status = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  ui.status:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -88)
  ui.status:SetPoint("RIGHT", body, "RIGHT", 0, 0)
  ui.status:SetJustifyH("LEFT")
  ui.status:SetWordWrap(false)

  ui.stops = W.ColumnList(body, STOP_COLUMNS)
  ui.stops:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -106)
  ui.stops:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)

  ui.empty = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  ui.empty:SetPoint("TOPLEFT", ui.stops, "TOPLEFT", 4, -30)
  ui.empty:SetText("No active route. Choose filters and press Build.")
  ui.empty:SetTextColor(Theme:Color("grey"))
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local PAGE = { id = "routes", title = "Routes", order = 35, build = buildPage, refresh = refreshPage }

local profileOwner = {} -- unique AceDB callback owner (see MapPins)

-- "Reset all data" clears HB.char.route just before resetting the profile.
local function onProfileChanged()
  if Routes:IsEnabled() then HB:SafeCall("Routes", loadRoute) end
end

function Routes:OnEnable()
  self.nodelog = HB:GetModule("NodeLog", true)
  if not profileOwner.registered then
    profileOwner.registered = true
    HB.db.RegisterCallback(profileOwner, "OnProfileChanged", onProfileChanged)
    HB.db.RegisterCallback(profileOwner, "OnProfileCopied", onProfileChanged)
    HB.db.RegisterCallback(profileOwner, "OnProfileReset", onProfileChanged)
  end
  HB:Listen(self, "HB_NODELOG_CHANGED", refresh)
  self:RegisterEvent("ZONE_CHANGED_NEW_AREA", safely(function()
    if not paged then curMap = nil end
    refresh()
  end))
  PAGE.icon = Theme.ICONS and Theme.ICONS.routes
  HB.UI:RegisterPage(PAGE)
  loadRoute()
end

function Routes:OnDisable()
  self:UnregisterAllMessages()
  self:UnregisterAllEvents()
  releasePins()
  HB.UI:UnregisterPage("routes")
end
