local ADDON, ns = ...

-- Records module (spec §4.4): personal records, lifetime material totals
-- (warband and per character) and the session history list.
--
-- Messages sent: HB_RECORD_BROKEN(name, value) when a record that already
-- existed is beaten (never for the very first value), with name one of
-- "bestGph", "biggestNode", "longest", "mostNodes"; HB_RECORDS_CHANGED()
-- after a session is deleted (BestSpot listens to it).
--
-- Records are NOT recomputed when a session is deleted: they are personal
-- bests and stay even if the session that set them is gone.

local HB = ns.HB
local SessionMath = ns.SessionMath
local Format = ns.Format
local Theme = ns.Theme
local W = ns.Widgets

local Records = HB:NewModule("Records", "AceEvent-3.0")

local MIN_GPH_SECONDS = 600
local DASH = "\226\128\148"

local charKey
local pageBody
local viewMode = "warband"   -- "warband" | "char"
local detailID               -- session id shown in the detail view

local function g() return HB.db.global end
local function money(copper) return Format.Money(copper, HB.db.profile.goldStyle) end

local function itemName(itemID)
  local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
  return name or ("Item " .. tostring(itemID))
end

local function itemIcon(itemID)
  return C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID) or nil
end

local function mapName(mapID)
  local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
  return info and info.name or ("Map " .. tostring(mapID))
end

---------------------------------------------------------------------------
-- Record comparison (pure)
---------------------------------------------------------------------------

-- A new value beats a record when there is none yet (first value) or it is
-- strictly larger. Returns beats, hadPrevious.
local function beats(old, value)
  if not old or old.value == nil then return value > 0, false end
  return value > old.value, true
end

-- Stores the record and fires HB_RECORD_BROKEN only when it replaced one.
local function setRecord(name, value, fields)
  local recs = g().records
  local ok, had = beats(recs[name], value)
  if not ok then return end
  fields.value = value
  recs[name] = fields
  if had then HB:SendMessage("HB_RECORD_BROKEN", name, value) end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- Newest first; filter = { mapID? } keeps sessions that visited that zone.
function Records:GetSessions(filter)
  local out = {}
  local mapID = filter and filter.mapID
  for _, s in ipairs(g().sessions) do
    if not mapID or (s.zones and s.zones[mapID]) then out[#out + 1] = s end
  end
  table.sort(out, function(a, b)
    if (a.started or 0) ~= (b.started or 0) then return (a.started or 0) > (b.started or 0) end
    return (a.id or 0) > (b.id or 0)
  end)
  return out
end

function Records:DeleteSession(id)
  local list = g().sessions
  for i, s in ipairs(list) do
    if s.id == id then
      table.remove(list, i)
      HB:SendMessage("HB_RECORDS_CHANGED")
      return true
    end
  end
  return false
end

---------------------------------------------------------------------------
-- Event handlers
---------------------------------------------------------------------------

function Records:OnGather(gather)
  if type(gather) ~= "table" then return end
  local life = g().lifetime
  local byChar = g().lifetimeByChar
  local mine = byChar[charKey]
  if not mine then
    mine = {}
    byChar[charKey] = mine
  end
  local priceFn = HB.Pricing:Fn()
  local bestItem, bestValue, total = nil, -1, 0
  for _, it in ipairs(gather.items or {}) do
    local id, n = it.itemID, it.count or 0
    if id and n > 0 then
      life[id] = (life[id] or 0) + n
      mine[id] = (mine[id] or 0) + n
      local v = (priceFn(id, it.quality, it.link) or 0) * n
      total = total + v
      if v > bestValue then bestValue, bestItem = v, id end
    end
  end
  setRecord("biggestNode", total, { time = time(), itemID = bestItem })
end

function Records:OnSession(state, s)
  if state ~= "stopped" or not s then return end
  local priceFn = HB.Pricing:Fn()
  local active = s.activeSeconds or 0
  if active >= MIN_GPH_SECONDS then
    local gph = SessionMath.GoldPerHour(s, 0, priceFn)
    if gph then setRecord("bestGph", gph, { sessionID = s.id }) end
  end
  setRecord("longest", active, { sessionID = s.id })
  local nodes = 0
  for _, n in pairs(s.nodes or {}) do nodes = nodes + n end
  setRecord("mostNodes", nodes, { sessionID = s.id })
end

---------------------------------------------------------------------------
-- Page
---------------------------------------------------------------------------

local LIFE_COLUMNS = {
  { key = "name", title = "Item", width = 260, align = "LEFT" },
  { key = "count", title = "Count", width = 90, align = "RIGHT" },
}

local HISTORY_COLUMNS = {
  { key = "date", title = "Date", width = 110, align = "LEFT" },
  { key = "duration", title = "Duration", width = 64, align = "RIGHT" },
  { key = "zones", title = "Zones", width = 150, align = "LEFT" },
  { key = "gold", title = "Gold", width = 74, align = "RIGHT" },
  { key = "gph", title = "Gold/hr", width = 74, align = "RIGHT" },
}

local DETAIL_COLUMNS = {
  { key = "name", title = "Item", width = 220, align = "LEFT" },
  { key = "count", title = "Count", width = 64, align = "RIGHT" },
  { key = "price", title = "Price", width = 90, align = "RIGHT" },
  { key = "value", title = "Value", width = 90, align = "RIGHT" },
}

local function zonesText(s)
  local ids = {}
  for mapID in pairs(s.zones or {}) do ids[#ids + 1] = mapID end
  table.sort(ids, function(a, b)
    local ca, cb = s.zones[a], s.zones[b]
    if ca ~= cb then return ca > cb end
    return a < b
  end)
  if #ids == 0 then return DASH end
  local parts = {}
  for i = 1, math.min(2, #ids) do parts[i] = mapName(ids[i]) end
  local text = table.concat(parts, ", ")
  if #ids > 2 then text = text .. " +" .. (#ids - 2) end
  return text
end

local function lifeCell(row, key)
  if key == "name" then return itemName(row.itemID), itemIcon(row.itemID) end
  if key == "count" then return Format.Thousands(row.count) end
end

local function historyCell(s, key)
  local priceFn = HB.Pricing:Fn()
  if key == "date" then
    return date("%Y-%m-%d %H:%M", s.started)
  elseif key == "duration" then
    return Format.Duration(s.activeSeconds)
  elseif key == "zones" then
    return zonesText(s)
  elseif key == "gold" then
    return money(SessionMath.Value(s, priceFn))
  elseif key == "gph" then
    local gph = SessionMath.GoldPerHour(s, 0, priceFn)
    return gph and money(gph) or DASH
  end
end

local function detailCell(row, key)
  if key == "name" then
    local name = itemName(row.itemID)
    if row.quality and row.quality > 0 then name = name .. " (Q" .. row.quality .. ")" end
    return name, itemIcon(row.itemID)
  elseif key == "count" then
    return Format.Thousands(row.count)
  elseif key == "price" then
    return money(row.unit)
  elseif key == "value" then
    return money(row.value)
  end
end

local function findSession(id)
  for _, s in ipairs(g().sessions) do
    if s.id == id then return s end
  end
end

local function recordLines()
  local r = g().records
  local function line(name, rec, fmt, extra)
    return { label = name, value = rec and rec.value and (fmt(rec.value) .. (extra or "")) or DASH }
  end
  local nodeExtra = r.biggestNode and r.biggestNode.itemID and (" (" .. itemName(r.biggestNode.itemID) .. ")") or ""
  return {
    line("Best gold/hr (10+ min)", r.bestGph, function(v) return money(v) .. "/hr" end),
    line("Biggest single node", r.biggestNode, money, nodeExtra),
    line("Longest session", r.longest, Format.Duration),
    line("Most nodes in a session", r.mostNodes, Format.Thousands),
  }
end

local function lifetimeRows()
  local src = viewMode == "char" and g().lifetimeByChar[charKey] or g().lifetime
  local rows = {}
  for itemID, count in pairs(src or {}) do
    rows[#rows + 1] = { itemID = itemID, count = count }
  end
  table.sort(rows, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.itemID < b.itemID
  end)
  return rows
end

local function refreshPage(body)
  local ui = body.records
  if not ui then return end

  local s = detailID and findSession(detailID)
  if detailID and not s then detailID = nil end

  ui.main:SetShown(not s)
  ui.detail:SetShown(s ~= nil)

  if s then
    ui.detailTitle:SetText(date("%Y-%m-%d %H:%M", s.started) .. "  " .. DASH .. "  "
      .. Format.Duration(s.activeSeconds) .. "  " .. DASH .. "  "
      .. money(SessionMath.Value(s, HB.Pricing:Fn())))
    ui.detailList:SetRows(SessionMath.Rows(s, 0, HB.Pricing:Fn()), detailCell)
    return
  end

  for i, l in ipairs(recordLines()) do
    ui.labels[i]:SetText(l.label)
    ui.values[i]:SetText(l.value)
  end
  ui.mode:Refresh()
  ui.life:SetRows(lifetimeRows(), lifeCell)
  ui.history:SetRows(Records:GetSessions(), historyCell)
end

local function buildPage(body)
  pageBody = body
  local ui = {}
  body.records = ui

  -- Main view ---------------------------------------------------------
  ui.main = CreateFrame("Frame", nil, body)
  ui.main:SetAllPoints(body)

  ui.labels, ui.values = {}, {}
  for i = 1, 4 do
    local y = -(i - 1) * 16
    local label = ui.main:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
    label:SetPoint("TOPLEFT", ui.main, "TOPLEFT", 4, y)
    label:SetWidth(190)
    label:SetJustifyH("LEFT")
    label:SetTextColor(Theme:Color("gold"))
    local value = ui.main:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
    value:SetPoint("LEFT", label, "RIGHT", 8, 0)
    value:SetPoint("RIGHT", ui.main, "RIGHT", 0, 0)
    value:SetJustifyH("LEFT")
    value:SetWordWrap(false)
    value:SetTextColor(1, 1, 1)
    ui.labels[i], ui.values[i] = label, value
  end

  ui.mode = W.Dropdown(ui.main, 160, {
    { value = "warband", text = "Warband" },
    { value = "char", text = "This character" },
  }, function() return viewMode end, function(v)
    viewMode = v
    refreshPage(body)
  end)
  ui.mode:SetPoint("TOPLEFT", ui.main, "TOPLEFT", 0, -72)

  local lifeTitle = ui.main:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
  lifeTitle:SetPoint("LEFT", ui.mode, "RIGHT", 10, 0)
  lifeTitle:SetText("Lifetime materials")
  lifeTitle:SetTextColor(Theme:Color("grey"))

  ui.life = W.ColumnList(ui.main, LIFE_COLUMNS)
  ui.life:SetPoint("TOPLEFT", ui.mode, "BOTTOMLEFT", 0, -4)
  ui.life:SetPoint("TOPRIGHT", ui.main, "TOPRIGHT", 0, -100)
  ui.life:SetHeight(120)

  local histTitle = ui.main:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
  histTitle:SetPoint("TOPLEFT", ui.life, "BOTTOMLEFT", 4, -8)
  histTitle:SetText("Session history (click a session for its materials)")
  histTitle:SetTextColor(Theme:Color("grey"))

  ui.history = W.ColumnList(ui.main, HISTORY_COLUMNS)
  ui.history:SetPoint("TOPLEFT", histTitle, "BOTTOMLEFT", -4, -4)
  ui.history:SetPoint("BOTTOMRIGHT", ui.main, "BOTTOMRIGHT", 0, 0)
  ui.history.onRowClick = function(s)
    detailID = s.id
    refreshPage(body)
  end

  -- Detail view -------------------------------------------------------
  ui.detail = CreateFrame("Frame", nil, body)
  ui.detail:SetAllPoints(body)
  ui.detail:Hide()

  ui.back = W.RedButton(ui.detail, "< Back", function()
    detailID = nil
    refreshPage(body)
  end)
  ui.back:SetPoint("TOPLEFT", ui.detail, "TOPLEFT", 0, 0)

  ui.detailTitle = ui.detail:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  ui.detailTitle:SetPoint("LEFT", ui.back, "RIGHT", 12, 0)
  ui.detailTitle:SetTextColor(Theme:Color("gold"))

  ui.detailList = W.ColumnList(ui.detail, DETAIL_COLUMNS)
  ui.detailList:SetPoint("TOPLEFT", ui.detail, "TOPLEFT", 0, -30)
  ui.detailList:SetPoint("BOTTOMRIGHT", ui.detail, "BOTTOMRIGHT", 0, 32)

  ui.delete = W.RedButton(ui.detail, "Delete session", function()
    if detailID then
      StaticPopup_Show("HARVESTBOOK_DELETE_SESSION", nil, nil, detailID)
    end
  end)
  ui.delete:SetPoint("BOTTOMLEFT", ui.detail, "BOTTOMLEFT", 0, 0)
end

StaticPopupDialogs["HARVESTBOOK_DELETE_SESSION"] = {
  text = "Delete this session from your history? This cannot be undone.",
  button1 = YES, button2 = CANCEL,
  OnAccept = function(_, id)
    HB:SafeCall("Records", Records.DeleteSession, Records, id)
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local PAGE = { id = "records", title = "Records", order = 40, build = buildPage, refresh = refreshPage }

local function onChanged() HB.UI:RefreshPage("records") end

function Records:OnEnable()
  charKey = UnitName("player") .. "-" .. GetRealmName()
  -- One handler per message (AceEvent keeps a single callback per object).
  HB:Listen(self, "HB_NODE_GATHERED", function(mod, gather)
    mod:OnGather(gather)
    onChanged()
  end)
  HB:Listen(self, "HB_SESSION_CHANGED", function(mod, state, s)
    mod:OnSession(state, s)
    onChanged()
  end)
  HB:Listen(self, "HB_RECORDS_CHANGED", onChanged)
  HB:Listen(self, "HB_PRICES_UPDATED", onChanged)
  PAGE.icon = Theme.ICONS and Theme.ICONS.records
  HB.UI:RegisterPage(PAGE)
end

function Records:OnDisable()
  self:UnregisterAllMessages()
  HB.UI:UnregisterPage("records")
end
