local ADDON, ns = ...

-- Gear comparison module: snapshots the equipped profession gear onto a
-- session when it starts (s.gear, see Logic/GearCompare.BuildGear) and compares
-- the gold/hr of the gear sets over saved sessions.
--
-- Listens to HB_SESSION_CHANGED and HB_RECORDS_CHANGED. Owns no data of its
-- own; turning it off stops new snapshots and keeps the old ones.

local HB = ns.HB
local Compare = ns.GearCompare
local Format = ns.Format
local Theme = ns.Theme
local W = ns.Widgets

local GearCompare = HB:NewModule("GearCompare", "AceEvent-3.0")

local ALL_ZONES = 0
local zoneFilter = ALL_ZONES -- this login only: a mapID or ALL_ZONES

-- Fallback numbers are the slots the constants have had since Dragonflight.
local SLOTS = {
  { id = INVSLOT_PROF1TOOL or 20, tool = true },
  { id = INVSLOT_PROF1GEAR0 or 21 },
  { id = INVSLOT_PROF1GEAR1 or 22 },
  { id = INVSLOT_PROF2TOOL or 23, tool = true },
  { id = INVSLOT_PROF2GEAR0 or 24 },
  { id = INVSLOT_PROF2GEAR1 or 25 },
}

local function mapName(mapID)
  local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
  return info and info.name or ("Map " .. tostring(mapID))
end

local function sessions() return HB.db.global.sessions end

local function itemName(itemID, link) return HB:ItemName(itemID, link) end

---------------------------------------------------------------------------
-- Snapshot
---------------------------------------------------------------------------

-- nil when the inventory can't be read: the session then counts as "no gear
-- data" rather than as a set with no gear.
local function snapshot()
  if not (GetInventoryItemID and GetInventoryItemLink) then return nil end
  local items = {}
  for _, slot in ipairs(SLOTS) do
    local ok, itemID = pcall(GetInventoryItemID, "player", slot.id)
    if not ok then return nil end
    if itemID then
      local okLink, link = pcall(GetInventoryItemLink, "player", slot.id)
      items[#items + 1] = { itemID = itemID, link = okLink and link or nil, tool = slot.tool }
    end
  end
  return Compare.BuildGear(items)
end

---------------------------------------------------------------------------
-- Page
---------------------------------------------------------------------------

-- Columns + 4 px pad + 16 px scrollbar must be <= 440: 420.
local COLUMNS = {
  { key = "set", title = "Gear set", width = 125, align = "LEFT" },
  { key = "sessions", title = "Sessions", width = 50, align = "RIGHT" },
  { key = "time", title = "Time", width = 50, align = "RIGHT" },
  { key = "gph", title = "Gold/hr", width = 75, align = "RIGHT" },
  { key = "nph", title = "Nodes/hr", width = 60, align = "RIGHT" },
  { key = "pct", title = "vs best", width = 60, align = "RIGHT" },
}

local function cell(row, key)
  if key == "set" then
    return Compare.Label(row.items, itemName)
  elseif key == "sessions" then
    return Format.Thousands(row.sessions)
  elseif key == "time" then
    return Format.Duration(row.seconds)
  elseif key == "gph" then
    return Format.Money(row.gph, HB.db.profile.goldStyle)
  elseif key == "nph" then
    return string.format("%.1f", row.nodesPerHour)
  elseif key == "pct" then
    if row.pct == 0 then return "Best" end
    return string.format("%.1f%%", row.pct)
  end
end

local function zoneOptions()
  local ids = Compare.Zones(sessions())
  table.sort(ids, function(a, b)
    local na, nb = mapName(a), mapName(b)
    if na ~= nb then return na < nb end
    return a < b
  end)
  local options = { { value = ALL_ZONES, text = "All zones" } }
  for _, mapID in ipairs(ids) do
    options[#options + 1] = { value = mapID, text = mapName(mapID) }
  end
  return options
end

local function showTooltip(row, rowFrame)
  GameTooltip:SetOwner(rowFrame, "ANCHOR_RIGHT")
  GameTooltip:AddLine("Gear set", Theme:Color("gold"))
  if #row.items == 0 then
    GameTooltip:AddLine("No profession gear", 1, 1, 1)
  end
  for _, it in ipairs(row.items) do
    GameTooltip:AddLine(itemName(it.itemID, it.link), 1, 1, 1)
  end
  GameTooltip:Show()
end

local function refreshPage(body)
  local ui = body.gearcompare
  if not ui then return end

  -- The chosen zone can leave the data when sessions are deleted.
  if zoneFilter ~= ALL_ZONES then
    local found = false
    for _, mapID in ipairs(Compare.Zones(sessions())) do
      if mapID == zoneFilter then found = true break end
    end
    if not found then zoneFilter = ALL_ZONES end
  end
  ui.zone:Refresh()

  local result = Compare.Compare(sessions(), HB.Pricing:Fn(),
    zoneFilter ~= ALL_ZONES and zoneFilter or nil)
  ui.list:SetRows(result.sets, cell)
  ui.empty:SetShown(#result.sets == 0)
  if result.noGear > 0 then
    ui.noGear:SetText(result.noGear == 1 and "1 session: no gear data"
      or (Format.Thousands(result.noGear) .. " sessions: no gear data"))
  else
    ui.noGear:SetText("")
  end
end

local function buildPage(body)
  local ui = {}
  body.gearcompare = ui

  ui.zone = W.Dropdown(body, 200, zoneOptions, function() return zoneFilter end, function(v)
    zoneFilter = v
    refreshPage(body)
  end)
  ui.zone:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)

  ui.noGear = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
  ui.noGear:SetPoint("LEFT", ui.zone, "RIGHT", 8, 0)
  ui.noGear:SetPoint("RIGHT", body, "RIGHT", 0, 0)
  ui.noGear:SetJustifyH("LEFT")
  ui.noGear:SetWordWrap(false)
  ui.noGear:SetTextColor(Theme:Color("grey"))

  ui.note = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
  ui.note:SetPoint("TOPLEFT", ui.zone, "BOTTOMLEFT", 0, -6)
  ui.note:SetPoint("RIGHT", body, "RIGHT", 0, 0)
  ui.note:SetHeight(28) -- two lines at the smallest window
  ui.note:SetJustifyH("LEFT")
  ui.note:SetJustifyV("TOP")
  ui.note:SetTextColor(Theme:Color("grey"))
  ui.note:SetText("Different zones and prices affect these numbers, so compare within one zone and over several sessions.")

  ui.list = W.ColumnList(body, COLUMNS)
  ui.list:SetPoint("TOPLEFT", ui.note, "BOTTOMLEFT", 0, -4)
  ui.list:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
  ui.list:SetSort("gph", true)
  ui.list.onRowEnter = showTooltip
  ui.list.onRowLeave = function() GameTooltip:Hide() end

  ui.empty = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  ui.empty:SetPoint("TOPLEFT", ui.list, "TOPLEFT", 4, -30)
  ui.empty:SetPoint("RIGHT", body, "RIGHT", -4, 0)
  ui.empty:SetJustifyH("LEFT")
  ui.empty:SetTextColor(Theme:Color("grey"))
  ui.empty:SetText("No gear sets to compare yet. Your profession gear is recorded when a session starts; "
    .. "finish a session of at least a minute and its gear set appears here.")
  ui.empty:Hide()
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local PAGE = { id = "gear", title = "Gear", order = 47, build = buildPage, refresh = refreshPage }

local function onChanged() HB.UI:RefreshPage("gear") end

function GearCompare:OnEnable()
  -- One handler per message (AceEvent keeps a single callback per object).
  HB:Listen(self, "HB_SESSION_CHANGED", function(_, state, s)
    if state == "running" and s and not s.gear then
      s.gear = snapshot()
    elseif state == "stopped" and s ~= nil then
      onChanged()
    end
  end)
  HB:Listen(self, "HB_RECORDS_CHANGED", onChanged)
  PAGE.icon = Theme.ICONS and Theme.ICONS.gear
  HB.UI:RegisterPage(PAGE)
end

function GearCompare:OnDisable()
  self:UnregisterAllMessages()
  HB.UI:UnregisterPage("gear")
end
