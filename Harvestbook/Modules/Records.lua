local ADDON, ns = ...
local L = ns.L

-- Records module (spec §4.4): personal records, lifetime material totals
-- (warband and per character) and the session history list.
--
-- Messages sent: HB_RECORD_BROKEN(name, value) when a record that already
-- existed is beaten (never for the very first value), with name one of
-- "bestGph", "longest", "mostNodes"; HB_RECORDS_CHANGED()
-- after a session is deleted (BestSpot listens to it).
--
-- Deleting the session that holds a record recomputes that record from the
-- remaining history; other records are left alone (their session may have aged
-- out of the 500-session history).
--
-- The Gold page: an all-time total, gold per day / daily reset / weekly reset
-- and the all-time goal (global.gold, Logic/GoldLedger.lua). A gather adds its
-- value at the prices of that moment, on every character. HB_GOAL_REACHED fires
-- when a gather crosses the goal.
--
-- CSV export: a copy box over Logic/Export.lua, opened from the Records page or
-- /hb export. WoW has no file access, so the player copies the text out.

local HB = ns.HB
local SessionMath = ns.SessionMath
local GoldLedger = ns.GoldLedger
local GoalEval = ns.GoalEval
local Export = ns.Export
local Format = ns.Format
local Theme = ns.Theme
local W = ns.Widgets

local Records = HB:NewModule("Records", "AceEvent-3.0")

local RECORD_NAMES = { "bestGph", "longest", "mostNodes" }
local DASH = "\226\128\148"

local charKey
local viewMode = "warband"   -- "warband" | "char"
local detailID               -- session id shown in the detail view

local function g() return HB.db.global end
local function money(copper) return Format.Money(copper, HB.db.profile.goldStyle) end

local function itemName(itemID) return HB:ItemName(itemID) end

local function itemIcon(itemID)
  return C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID) or nil
end

local function mapName(mapID)
  local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
  return info and info.name or L["Map %s"]:format(tostring(mapID))
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
      local recs, fn = g().records, HB.Pricing:Fn()
      for _, name in ipairs(RECORD_NAMES) do
        if recs[name] and recs[name].sessionID == id then
          local value, sessionID = SessionMath.BestRecord(name, list, fn)
          recs[name] = value and { value = value, sessionID = sessionID } or nil
        end
      end
      HB:SendMessage("HB_RECORDS_CHANGED")
      return true
    end
  end
  return false
end

---------------------------------------------------------------------------
-- Event handlers
---------------------------------------------------------------------------

-- The ledger keys for a moment in time. Resets come from the server clock; a
-- client without the call just skips that bucket.
local function goldKeys(t)
  local keys = { day = date("%Y-%m-%d", t) }
  local api, now = C_DateAndTime, time()
  if api and api.GetSecondsUntilDailyReset then
    local secs = api.GetSecondsUntilDailyReset()
    if type(secs) == "number" then
      keys.daily = GoldLedger.ResetKey(t, now + secs, GoldLedger.PERIOD_SECONDS.daily)
    end
  end
  if api and api.GetSecondsUntilWeeklyReset then
    local secs = api.GetSecondsUntilWeeklyReset()
    if type(secs) == "number" then
      keys.weekly = GoldLedger.ResetKey(t, now + secs, GoldLedger.PERIOD_SECONDS.weekly)
    end
  end
  return keys
end

local function addGold(gather)
  local fn, copper = HB.Pricing:Fn(), 0
  for _, it in ipairs(gather.items or {}) do
    if it.itemID then copper = copper + (fn(it.itemID, it.quality, it.link) or 0) * (it.count or 0) end
  end
  local ledger = g().gold
  local before = ledger.total or 0
  GoldLedger.Add(ledger, copper, goldKeys(time()))
  if GoldLedger.GoalCrossed(before, ledger.total or 0, ledger.goal) then
    HB:SendMessage("HB_GOAL_REACHED", { id = "alltime", type = "gold", target = ledger.goal })
  end
end

-- First run with the Gold page: count the sessions already in history.
local function backfillGold()
  local ledger = g().gold
  if ledger.backfilled then return end
  ledger.backfilled = true
  local fn = HB.Pricing:Fn()
  local function value(s) return SessionMath.Value(s, fn) end
  GoldLedger.Backfill(ledger, g().sessions, value, goldKeys)
  if HB.char.current then GoldLedger.Backfill(ledger, { HB.char.current }, value, goldKeys) end
end

function Records:OnGather(gather)
  if type(gather) ~= "table" then return end
  addGold(gather)
  local life = g().lifetime
  local byChar = g().lifetimeByChar
  local mine = byChar[charKey]
  if not mine then
    mine = {}
    byChar[charKey] = mine
  end
  for _, it in ipairs(gather.items or {}) do
    local id, n = it.itemID, it.count or 0
    if id and n > 0 then
      life[id] = (life[id] or 0) + n
      mine[id] = (mine[id] or 0) + n
    end
  end
end

function Records:OnSession(state, s)
  if state ~= "stopped" or not s then return end
  local priceFn = HB.Pricing:Fn()
  for _, name in ipairs(RECORD_NAMES) do
    local value = SessionMath.RecordValue(name, s, priceFn)
    if value then setRecord(name, value, { sessionID = s.id }) end
  end
end

---------------------------------------------------------------------------
-- Page
---------------------------------------------------------------------------

local LIFE_COLUMNS = {
  { key = "name", title = L["Item"], width = 260, align = "LEFT" },
  { key = "count", title = L["Count"], width = 90, align = "RIGHT" },
}

local HISTORY_COLUMNS = {
  { key = "date", title = L["Date"], width = 100, align = "LEFT" },
  { key = "duration", title = L["Duration"], width = 60, align = "RIGHT" },
  { key = "zones", title = L["Zones"], width = 100, align = "LEFT" },
  { key = "gold", title = L["Gold"], width = 80, align = "RIGHT" },
  { key = "gph", title = L["Gold/hr"], width = 80, align = "RIGHT" },
}

local DETAIL_COLUMNS = {
  { key = "name", title = L["Item"], width = 170, align = "LEFT" },
  { key = "count", title = L["Count"], width = 60, align = "RIGHT" },
  { key = "price", title = L["Price"], width = 80, align = "RIGHT" },
  { key = "value", title = L["Value"], width = 90, align = "RIGHT" },
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
  return {
    line(L["Best gold/hr (10+ min)"], r.bestGph, function(v) return L["%s/hr"]:format(money(v)) end),
    line(L["Longest session"], r.longest, Format.Duration),
    line(L["Most nodes in a session"], r.mostNodes, Format.Thousands),
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
    { value = "warband", text = L["Warband"] },
    { value = "char", text = L["This character"] },
  }, function() return viewMode end, function(v)
    viewMode = v
    refreshPage(body)
  end)
  ui.mode:SetPoint("TOPLEFT", ui.main, "TOPLEFT", 0, -72)

  local lifeTitle = ui.main:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
  lifeTitle:SetPoint("LEFT", ui.mode, "RIGHT", 10, 0)
  lifeTitle:SetText(L["Lifetime materials"])
  lifeTitle:SetTextColor(Theme:Color("grey"))

  ui.export = W.RedButton(ui.main, L["Export"], function()
    HB:SafeCall("Records", Records.OpenExport, Records)
  end)
  ui.export:SetPoint("TOPRIGHT", ui.main, "TOPRIGHT", 0, -74)

  ui.life = W.ColumnList(ui.main, LIFE_COLUMNS)
  ui.life:SetPoint("TOPLEFT", ui.mode, "BOTTOMLEFT", 0, -4)
  ui.life:SetPoint("TOPRIGHT", ui.main, "TOPRIGHT", 0, -100)
  ui.life:SetHeight(120)

  local histTitle = ui.main:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
  histTitle:SetPoint("TOPLEFT", ui.life, "BOTTOMLEFT", 4, -8)
  histTitle:SetText(L["Session history (click a session for its materials)"])
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

  ui.back = W.RedButton(ui.detail, L["< Back"], function()
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

  ui.delete = W.RedButton(ui.detail, L["Delete session"], function()
    if detailID then
      StaticPopup_Show("HARVESTBOOK_DELETE_SESSION", nil, nil, detailID)
    end
  end)
  ui.delete:SetPoint("BOTTOMLEFT", ui.detail, "BOTTOMLEFT", 0, 0)
end

StaticPopupDialogs["HARVESTBOOK_DELETE_SESSION"] = {
  text = L["Delete this session from your history? This cannot be undone."],
  button1 = YES, button2 = CANCEL,
  OnAccept = function(_, id)
    HB:SafeCall("Records", Records.DeleteSession, Records, id)
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Gold page
---------------------------------------------------------------------------

local PERIOD_OPTIONS = {
  { value = "day", text = L["Per day"] },
  { value = "daily", text = L["Per daily reset"] },
  { value = "weekly", text = L["Per weekly reset"] },
}
-- Current, average and best lines for each period.
local PERIOD_LINES = {
  day = { L["This day"], L["Average per active day"], L["Best day"] },
  daily = { L["This reset"], L["Average per active reset"], L["Best reset"] },
  weekly = { L["This week"], L["Average per active week"], L["Best week"] },
}

local GOLD_COLUMNS = {
  { key = "period", title = L["Period"], width = 200, align = "LEFT" },
  { key = "gold", title = L["Gold"], width = 150, align = "RIGHT" },
}

local function goldPeriod()
  local p = HB.db.profile.goldPeriod
  return PERIOD_LINES[p] and p or "day"
end

-- Reset keys are the epoch a period ends at; rows show the date it began.
-- weekFormat differs because the CSV export keeps its English label in every locale.
local function periodLabel(period, key, weekFormat)
  if period == "day" then return key end
  local start = date("%Y-%m-%d", key - GoldLedger.PERIOD_SECONDS[period])
  return period == "weekly" and (weekFormat or L["Week of %s"]):format(start) or start
end

local function refreshGold(body)
  local ui = body.gold
  if not ui then return end
  local ledger, period = g().gold, goldPeriod()
  local total, goal = ledger.total or 0, ledger.goal

  ui.total:SetText(money(total))
  if goal then
    local pct = math.min(100, total / goal * 100)
    ui.bar:SetProgress(total, goal, L["Goal: %.1f%%"]:format(pct), money)
    ui.bar:Show()
    ui.noGoal:Hide()
  else
    ui.bar:Hide()
    ui.noGoal:Show()
  end
  ui.clear:SetEnabled(goal ~= nil)

  local sum = GoldLedger.Summary(ledger[period], goldKeys(time())[period])
  local lines = PERIOD_LINES[period]
  ui.lines[1].label:SetText(lines[1])
  ui.lines[1].value:SetText(money(sum.current))
  ui.lines[2].label:SetText(lines[2])
  ui.lines[2].value:SetText(sum.periods > 0 and money(sum.average) or DASH)
  ui.lines[3].label:SetText(lines[3])
  ui.lines[3].value:SetText(sum.periods > 0 and money(sum.best) or DASH)
  ui.period:Refresh()
  ui.list:SetRows(GoldLedger.Rows(ledger[period]), function(row, key)
    if key == "period" then return periodLabel(period, row.key) end
    return money(row.copper)
  end)
end

local function buildGold(body)
  local ui = {}
  body.gold = ui

  local function line(y, width)
    local label = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
    label:SetPoint("TOPLEFT", body, "TOPLEFT", 4, y)
    label:SetWidth(width)
    label:SetJustifyH("LEFT")
    label:SetTextColor(Theme:Color("gold"))
    local value = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
    value:SetPoint("LEFT", label, "RIGHT", 8, 0)
    value:SetPoint("RIGHT", body, "RIGHT", 0, 0)
    value:SetJustifyH("LEFT")
    value:SetWordWrap(false)
    value:SetTextColor(1, 1, 1)
    return label, value
  end

  local totalLabel
  totalLabel, ui.total = line(0, 190)
  totalLabel:SetText(L["All-time gold earned"])

  ui.bar = W.ProgressBar(body)
  ui.bar:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -22)
  ui.bar:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -22)
  ui.noGoal = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
  ui.noGoal:SetPoint("TOPLEFT", body, "TOPLEFT", 4, -25)
  ui.noGoal:SetText(L["No goal set. Try 5m for 5 million gold."])
  ui.noGoal:SetTextColor(Theme:Color("grey"))

  local goalLabel = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  goalLabel:SetPoint("TOPLEFT", body, "TOPLEFT", 4, -50)
  goalLabel:SetText(L["Gold goal"])
  goalLabel:SetTextColor(Theme:Color("gold"))

  local input = CreateFrame("EditBox", nil, body, "InputBoxTemplate")
  input:SetSize(110, 20)
  input:SetAutoFocus(false)
  input:SetMaxLetters(16)
  input:SetTextInsets(2, 2, 0, 0)
  input:SetPoint("LEFT", goalLabel, "RIGHT", 12, 0)
  input:SetScript("OnEscapePressed", input.ClearFocus)

  local function setGoal()
    local target = GoalEval.ParseTarget(input:GetText(), true)
    if not target then
      HB:Msg(L["enter a whole number of gold, like 5000000, 250k or 5m."])
      return
    end
    g().gold.goal = target * 10000
    input:SetText("")
    input:ClearFocus()
    refreshGold(body)
  end
  input:SetScript("OnEnterPressed", setGoal)

  ui.set = W.RedButton(body, L["Set goal"], setGoal)
  ui.set:SetPoint("LEFT", input, "RIGHT", 8, 0)
  ui.clear = W.RedButton(body, L["Clear"], function()
    g().gold.goal = nil
    refreshGold(body)
  end)
  ui.clear:SetPoint("LEFT", ui.set, "RIGHT", 6, 0)

  ui.period = W.Dropdown(body, 160, PERIOD_OPTIONS, goldPeriod, function(v)
    HB.db.profile.goldPeriod = v
    refreshGold(body)
  end)
  ui.period:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -78)

  ui.lines = {}
  for i = 1, 3 do
    local label, value = line(-108 - (i - 1) * 16, 190)
    ui.lines[i] = { label = label, value = value }
  end

  ui.list = W.ColumnList(body, GOLD_COLUMNS)
  ui.list:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -164)
  ui.list:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 20)

  local note = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
  note:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 4, 2)
  note:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 2)
  note:SetJustifyH("LEFT")
  note:SetWordWrap(false)
  note:SetText(L["Estimated value of what you gathered on all characters, at the price when gathered."])
  note:SetTextColor(Theme:Color("grey"))
end

---------------------------------------------------------------------------
-- CSV export window
---------------------------------------------------------------------------

local EXPORT_OPTIONS = {
  { value = "sessions", text = L["Sessions"] },
  { value = "materials", text = L["Materials"] },
  { value = "gold", text = L["Gold"] },
}
local EXPORT_HINT = L["Press Ctrl+C (Cmd+C on Mac) to copy, then paste into a spreadsheet"]
local EXPORT_W, EXPORT_H = 560, 380
local NAME_RETRIES = 5 -- seconds to wait for item names the client has not loaded

local exportKind = "sessions"
local exportWin

-- Returns the CSV and whether an item name is still a placeholder. Gold uses
-- the period chosen on the Gold page.
local function exportText()
  if exportKind == "materials" then
    local pending = false
    local text = Export.Materials(g().lifetime, function(itemID)
      if not (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)) then pending = true end
      return itemName(itemID)
    end)
    return text, pending
  elseif exportKind == "gold" then
    local period = goldPeriod()
    return Export.Gold(g().gold, period, function(key) return periodLabel(period, key, "Week of %s") end)
  end
  return Export.Sessions(g().sessions, {
    date = function(t) return date("%Y-%m-%d %H:%M", t) end,
    zoneName = mapName,
    price = HB.Pricing:Fn(),
  })
end

local function showExportText(win, text)
  win.text = text
  win.edit:SetText(text)
  win.edit:SetCursorPosition(0)
  win.scroll:SetVerticalScroll(0)
  win.edit:SetFocus()
  win.edit:HighlightText()
end

-- Without retries: always redraw. A retry only redraws when a name has arrived.
local function fillExport(win, retries)
  local text, pending = exportText()
  if not retries or text ~= win.text then showExportText(win, text) end
  retries = retries or NAME_RETRIES
  if pending and retries > 0 and C_Timer then
    C_Timer.After(1, function()
      if win:IsShown() then HB:SafeCall("Records", fillExport, win, retries - 1) end
    end)
  end
end

local function buildExportWindow()
  local win = CreateFrame("Frame", "HarvestbookExport", UIParent, "BackdropTemplate")
  win:Hide()
  win:SetSize(EXPORT_W, EXPORT_H)
  win:SetPoint("CENTER")
  win:SetFrameStrata("DIALOG")
  win:SetToplevel(true)
  win:SetClampedToScreen(true)
  win:SetMovable(true)
  win:EnableMouse(true)
  win:RegisterForDrag("LeftButton")
  win:SetScript("OnDragStart", function(self) self:StartMoving() end)
  win:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  HB.UI._NoLayoutCache(win)
  Theme:Backdrop(win, "frame", "border")
  tinsert(UISpecialFrames, "HarvestbookExport")

  local title = win:CreateFontString(nil, "OVERLAY", "HarvestbookFontHeading")
  title:SetPoint("TOPLEFT", win, "TOPLEFT", 12, -10)
  title:SetText(L["Export to spreadsheet"])

  win.kind = W.Dropdown(win, 160, EXPORT_OPTIONS, function() return exportKind end, function(v)
    exportKind = v
    HB:SafeCall("Records", fillExport, win)
  end)
  win.kind:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -34)

  local bg = CreateFrame("Frame", nil, win, "BackdropTemplate")
  bg:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -66)
  bg:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -10, 40)
  Theme:Backdrop(bg, "content", "contentBorder")

  local ok, scroll = pcall(CreateFrame, "ScrollFrame", nil, win, "UIPanelScrollFrameTemplate")
  if not (ok and scroll) then
    scroll = CreateFrame("ScrollFrame", nil, win)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
      local y = self:GetVerticalScroll() - delta * 40
      self:SetVerticalScroll(math.max(0, math.min(self:GetVerticalScrollRange(), y)))
    end)
  end
  scroll:SetPoint("TOPLEFT", bg, "TOPLEFT", 6, -6)
  scroll:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", -26, 6)
  win.scroll = scroll

  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetAutoFocus(false)
  edit:SetMaxLetters(0)
  if edit.SetMaxBytes then edit:SetMaxBytes(0) end
  edit:SetFontObject("HarvestbookFontSmall")
  edit:SetSize(EXPORT_W - 52, 1) -- the box grows with its text
  scroll:SetScrollChild(edit)
  win.edit = edit

  -- The box is for copying: any edit puts the data back.
  edit:SetScript("OnTextChanged", function(self, userInput)
    if userInput and self:GetText() ~= win.text then showExportText(win, win.text) end
  end)
  edit:SetScript("OnEscapePressed", function() win:Hide() end)
  edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
  edit:SetScript("OnMouseUp", function(self) self:HighlightText() end)
  edit:SetScript("OnEditFocusLost", function(self) self:HighlightText(0, 0) end)
  edit:SetScript("OnCursorChanged", function(_, _, y, _, h)
    local top, view = scroll:GetVerticalScroll(), scroll:GetHeight()
    if -y < top then
      scroll:SetVerticalScroll(-y)
    elseif -y + h > top + view then
      scroll:SetVerticalScroll(-y + h - view)
    end
  end)
  scroll:EnableMouse(true)
  scroll:SetScript("OnMouseDown", function() edit:SetFocus() end)

  local close = W.RedButton(win, L["Close"], function() win:Hide() end)
  close:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -10, 10)

  local hint = win:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
  hint:SetPoint("LEFT", win, "BOTTOMLEFT", 12, 21)
  hint:SetPoint("RIGHT", close, "LEFT", -8, 0)
  hint:SetJustifyH("LEFT")
  hint:SetText(EXPORT_HINT)
  hint:SetTextColor(Theme:Color("grey"))

  win:SetScript("OnHide", function() edit:ClearFocus() end)
  return win
end

function Records:OpenExport()
  exportWin = exportWin or buildExportWindow()
  exportWin:Show()
  exportWin.kind:Refresh()
  fillExport(exportWin)
end

local PAGE = { id = "records", title = L["Records"], order = 40, build = buildPage, refresh = refreshPage }
local GOLD_PAGE = { id = "gold", title = L["Gold"], order = 45, build = buildGold, refresh = refreshGold }

local function onChanged()
  HB.UI:RefreshPage("records")
  HB.UI:RefreshPage("gold")
end

function Records:OnEnable()
  charKey = UnitName("player") .. "-" .. GetRealmName()
  -- One handler per message (AceEvent keeps a single callback per object).
  HB:Listen(self, "HB_NODE_GATHERED", function(mod, gather)
    mod:OnGather(gather)
    onChanged()
  end)
  HB:Listen(self, "HB_BONUS_LOOT", function(mod, gather) -- lifetime totals only
    mod:OnGather(gather)
    onChanged()
  end)
  HB:Listen(self, "HB_SESSION_CHANGED", function(mod, state, s)
    mod:OnSession(state, s)
    onChanged()
  end)
  HB:Listen(self, "HB_RECORDS_CHANGED", onChanged)
  HB:Listen(self, "HB_PRICES_UPDATED", onChanged)
  backfillGold()
  PAGE.icon = Theme.ICONS and Theme.ICONS.records
  HB.UI:RegisterPage(PAGE)
  GOLD_PAGE.icon = Theme.ICONS and Theme.ICONS.gold
  HB.UI:RegisterPage(GOLD_PAGE)
end

function Records:OnDisable()
  self:UnregisterAllMessages()
  if exportWin then exportWin:Hide() end
  HB.UI:UnregisterPage("records")
  HB.UI:UnregisterPage("gold")
end
