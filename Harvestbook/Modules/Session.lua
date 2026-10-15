local ADDON, ns = ...

-- Session module (spec §4.1): start/pause/resume/stop, auto-start on the first
-- gather, auto-pause (instance, mailbox, auction house, AFK) with optional
-- auto-resume, the Session page (materials list, totals, footer, chat post)
-- and the companion Session / Materials / Log tabs.
--
-- The in-progress session lives in HB.char.current (written after every
-- gather and state change); stopped sessions move to HB.db.global.sessions.
-- All timestamps are time() (seconds since epoch).

local HB = ns.HB
local SessionMath = ns.SessionMath
local Format = ns.Format
local Theme = ns.Theme
local W = ns.Widgets

local Session = HB:NewModule("Session", "AceEvent-3.0", "AceTimer-3.0")

local MAX_HISTORY = 500
local LOG_SIZE = 10
local TOP_MATERIALS = 8
local MAX_GOAL_BARS = 3
local DASH = "\226\128\148"
local DOT = " \194\183 "
local KIND_LABELS = { herb = "Herbalism", ore = "Mining", skin = "Skinning" }
local SORT_KEYS = { name = true, count = true, perHour = true, unit = true, value = true }

local ticker
local active = {}      -- [reason] = true while that auto-pause condition holds
local gatherLog = {}   -- last LOG_SIZE gathers, newest first (memory only)
local lastRare         -- itemID from HB_RARE_FOUND
local sortDesc         -- current sort direction (key persisted in profile)
local pageBody         -- Session page body once built

local function profile() return HB.db.profile end
local function cur() return HB.char.current end
local function priceFn() return HB.Pricing:Fn() end
local function money(copper) return Format.Money(copper, profile().goldStyle) end

local function safe(fn)
  return function(...) return HB:SafeCall("Session", fn, ...) end
end

---------------------------------------------------------------------------
-- Item helpers
---------------------------------------------------------------------------

local function itemName(itemID, link)
  local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
  if not name and link then
    -- Reagent links embed the quality atlas inside the brackets.
    name = link:match("%[(.-)%]")
    if name then name = name:gsub("|A.-|a", ""):gsub("%s+$", "") end
  end
  return name or ("Item " .. tostring(itemID))
end

local function itemIcon(itemID)
  return C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID) or nil
end

local function qualityAtlas(quality)
  if type(quality) == "number" then
    return "Professions-Icon-Quality-Tier" .. quality .. "-Small"
  end
  return nil
end

local function ago(seconds)
  seconds = math.max(0, seconds or 0)
  if seconds < 60 then return string.format("%ds", seconds) end
  if seconds < 3600 then return string.format("%dm", math.floor(seconds / 60)) end
  if seconds < 86400 then return string.format("%dh", math.floor(seconds / 3600)) end
  return string.format("%dd", math.floor(seconds / 86400))
end

---------------------------------------------------------------------------
-- State text
---------------------------------------------------------------------------

local function companionState(s)
  if not s then return "" end
  if s.state == "paused" then return "Paused" end
  local found, n = nil, 0
  for kind, label in pairs(KIND_LABELS) do
    if (s.nodes[kind] or 0) > 0 then found, n = label, n + 1 end
  end
  if n > 1 then return "Mixed" end
  return found or ""
end

local function updateStatus()
  local s = cur()
  if not s then
    HB.UI:SetStatus("No session", "grey")
  elseif s.state == "running" then
    HB.UI:SetStatus("Session running" .. DOT .. Format.Duration(SessionMath.ActiveSeconds(s, time())), "green")
  else
    HB.UI:SetStatus("Paused", "grey")
  end
  HB.UI:SetCompanionState(companionState(s))
end

local refreshTotals -- page totals strip (defined with the page)

local function onTick()
  updateStatus()
  if pageBody and pageBody:IsVisible() then refreshTotals(pageBody) end
  HB.UI:RefreshCompanion()
end

local function updateTicker()
  local s = cur()
  local running = s ~= nil and s.state == "running"
  if running and not ticker then
    ticker = Session:ScheduleRepeatingTimer(safe(onTick), 1)
  elseif not running and ticker then
    Session:CancelTimer(ticker)
    ticker = nil
  end
end

local function refreshAll()
  HB.UI:RefreshPage("session")
  HB.UI:RefreshCompanion()
  HB.UI:SetCompanionState(companionState(cur()))
end

---------------------------------------------------------------------------
-- Session state
---------------------------------------------------------------------------

local function nodeTotal(s)
  local n = 0
  for _, c in pairs(s.nodes or {}) do n = n + c end
  return n
end

local function save()
  local s = cur()
  if s then SessionMath.Checkpoint(s, time()) end
end

local function clearAuto(s)
  s.autoPaused, s.autoReasons = nil, nil
end

local function changed(state, s)
  save()
  updateTicker()
  updateStatus()
  HB:SendMessage("HB_SESSION_CHANGED", state, s)
  refreshAll()
end

-- Appends a stopped session to history; a session with no gathers is
-- discarded instead. Returns true when archived.
local function archive(s)
  clearAuto(s)
  if next(s.items) == nil and nodeTotal(s) == 0 then return false end
  local list = HB.db.global.sessions
  list[#list + 1] = s
  while #list > MAX_HISTORY do table.remove(list, 1) end
  return true
end

local function startNew()
  local s = SessionMath.New(time())
  HB.char.current = s
  wipe(gatherLog)
  changed("running", s)
  return s
end

function Session:GetCurrent()
  return HB.char.current
end

function Session:GetValue(s)
  if not s then return 0 end
  return SessionMath.Value(s, priceFn())
end

function Session:Start()
  local s = cur()
  if not s then
    startNew()
  elseif s.state == "paused" then
    self:Resume()
  else
    HB:Msg("a session is already running.")
  end
end

function Session:Pause()
  local s = cur()
  if not s or s.state ~= "running" then
    HB:Msg("no running session to pause.")
    return
  end
  SessionMath.Pause(s, time())
  clearAuto(s) -- a manual pause is never auto-resumed
  changed("paused", s)
end

function Session:Resume()
  local s = cur()
  if not s or s.state ~= "paused" then
    HB:Msg("no paused session to resume.")
    return
  end
  SessionMath.Resume(s, time())
  clearAuto(s)
  changed("running", s)
end

function Session:Stop()
  local s = cur()
  if not s then
    HB:Msg("no session to stop.")
    return
  end
  SessionMath.Stop(s, time(), priceFn())
  local kept = archive(s)
  HB.char.current = nil
  changed("stopped", kept and s or nil) -- empty sessions are discarded
end

function Session:Reset()
  HB.char.current = nil
  wipe(gatherLog)
  changed("stopped", nil)
end

-- Asks before Reset (page button and /hb reset).
function Session:ConfirmReset()
  if not cur() then
    HB:Msg("no session to reset.")
    return
  end
  StaticPopup_Show("HARVESTBOOK_SESSION_RESET")
end

---------------------------------------------------------------------------
-- Auto-pause / auto-resume
---------------------------------------------------------------------------

-- Edge-triggered: a reason pauses a running session when it begins; a session
-- paused this way resumes (if autoResume) once every reason has ended.
local function setCondition(reason, on)
  on = on and true or false
  local was = active[reason] or false
  active[reason] = on or nil
  if on == was then return end
  local s = cur()
  if not s then return end
  if on then
    if not profile().session.pause[reason] then return end
    if s.state == "running" then
      SessionMath.Pause(s, time())
      s.autoPaused, s.autoReasons = reason, { [reason] = true }
      changed("paused", s)
    elseif s.state == "paused" and s.autoPaused then
      s.autoReasons = s.autoReasons or {}
      s.autoReasons[reason] = true
    end
  elseif s.state == "paused" and s.autoPaused then
    if s.autoReasons then s.autoReasons[reason] = nil end
    if s.autoReasons and next(s.autoReasons) then return end
    clearAuto(s)
    if profile().session.autoResume then
      SessionMath.Resume(s, time())
      changed("running", s)
    end
  end
end

local function isAFK()
  local afk = UnitIsAFK("player")
  if issecretvalue and issecretvalue(afk) then return active.afk end
  return afk
end

-- After a load: drop remembered reasons that no longer hold (mail/AH frames
-- are closed after /reload), then apply the conditions that do.
local function reconcileConditions()
  local s = cur()
  local now = { instance = IsInInstance() and true or false, afk = isAFK() and true or false }
  if s and s.state == "paused" and s.autoPaused and s.autoReasons then
    for reason in pairs(s.autoReasons) do
      if not now[reason] then active[reason] = true; setCondition(reason, false) end
    end
  end
  setCondition("instance", now.instance)
  setCondition("afk", now.afk)
end

---------------------------------------------------------------------------
-- Gathers
---------------------------------------------------------------------------

local function logGather(payload, fn)
  local best, bestValue
  for _, it in ipairs(payload.items or {}) do
    local v = (fn(it.itemID, it.quality, it.link) or 0) * (it.count or 0)
    if not best or v > bestValue or (v == bestValue and (it.count or 0) > (best.count or 0)) then
      best, bestValue = it, v
    end
  end
  table.insert(gatherLog, 1, { time = payload.time or time(), kind = payload.kind, item = best })
  while #gatherLog > LOG_SIZE do table.remove(gatherLog) end
end

function Session:OnGather(payload)
  if type(payload) ~= "table" then return end
  local s = cur()
  if not s then
    if not profile().session.autoStart then return end
    s = startNew()
  end
  local fn = priceFn()
  if not SessionMath.AddGather(s, payload, time(), fn) then return end -- paused
  logGather(payload, fn)
  save()
  refreshAll()
end

function Session:OnRareFound(itemID)
  lastRare = itemID
  HB.UI:RefreshCompanion()
end

---------------------------------------------------------------------------
-- Session page
---------------------------------------------------------------------------

local COLUMNS = {
  { key = "name", title = "Material", width = 220, align = "LEFT", sortable = true },
  { key = "count", title = "Count", width = 64, align = "RIGHT", sortable = true },
  { key = "perHour", title = "Per hour", width = 76, align = "RIGHT", sortable = true },
  { key = "unit", title = "Price", width = 100, align = "RIGHT", sortable = true },
  { key = "value", title = "Value", width = 110, align = "RIGHT", sortable = true },
}

local TOTALS = {
  { key = "time", label = "Time" },
  { key = "nodes", label = "Nodes herb/ore/skin" },
  { key = "materials", label = "Materials" },
  { key = "gold", label = "Gold" },
  { key = "gph", label = "Gold/hr" },
  { key = "nph", label = "Nodes/hr" },
}

local function sortKey()
  local key = profile().session.sortKey
  if not SORT_KEYS[key] then key = "value" end
  if sortDesc == nil then sortDesc = key ~= "name" end
  return key
end

local function sessionRows(s)
  local key = sortKey()
  local rows = SessionMath.Rows(s, time(), priceFn(), key, sortDesc)
  for _, r in ipairs(rows) do r.name = itemName(r.itemID, r.link) end
  if key == "name" then
    table.sort(rows, function(a, b)
      if a.name ~= b.name then
        if sortDesc then return a.name > b.name end
        return a.name < b.name
      end
      return a.itemKey < b.itemKey
    end)
  end
  return rows
end

local function cellText(row, key)
  if key == "name" then
    return row.name, itemIcon(row.itemID), qualityAtlas(row.quality)
  elseif key == "count" then
    return Format.Thousands(row.count)
  elseif key == "perHour" then
    return row.perHour and Format.Thousands(row.perHour) or DASH
  elseif key == "unit" then
    return row.source == "none" and DASH or money(row.unit)
  elseif key == "value" then
    return money(row.value)
  end
end

local function showRowTooltip(row, rowFrame, cellKey)
  GameTooltip:SetOwner(rowFrame, "ANCHOR_RIGHT")
  if cellKey == "unit" then
    GameTooltip:AddLine(row.name, 1, 1, 1)
    if row.source == "none" then
      GameTooltip:AddLine("no price found", Theme:Color("grey"))
    else
      local label = HB.Pricing.SOURCE_LABELS[row.source] or tostring(row.source)
      GameTooltip:AddDoubleLine("Source", label, 1, 0.82, 0, 1, 1, 1)
      local cached = HB.db.global.prices[row.itemKey]
      if cached and cached.time then
        GameTooltip:AddLine("cached " .. ago(time() - cached.time) .. " ago", Theme:Color("grey"))
      end
    end
  elseif row.link then
    GameTooltip:SetHyperlink(row.link)
  else
    GameTooltip:SetItemByID(row.itemID)
  end
  GameTooltip:Show()
end

refreshTotals = function(body)
  local ui = body.session
  local s = cur()
  local v = {}
  if s then
    local now = time()
    local secs = SessionMath.ActiveSeconds(s, now)
    local sum = SessionMath.Summary(s, now, priceFn())
    local nodes = nodeTotal(s)
    v.time = Format.Duration(secs)
    v.nodes = string.format("%d / %d / %d", s.nodes.herb or 0, s.nodes.ore or 0, s.nodes.skin or 0)
    v.materials = Format.Thousands(sum.materials)
    v.gold = money(sum.copper)
    v.gph = sum.gph and money(sum.gph) or DASH
    v.nph = secs >= 60 and Format.Thousands(nodes / secs * 3600) or DASH
    ui.footer:SetText(string.format("This session: %d materials of %d kinds, worth %s" .. DOT .. "%s/hr",
      sum.materials, sum.kinds, money(sum.copper), sum.gph and money(sum.gph) or DASH))
    ui.footer:SetTextColor(1, 1, 1)
  else
    ui.footer:SetText("No session " .. DASH .. " gather a node or press Start.")
    ui.footer:SetTextColor(Theme:Color("grey"))
  end
  for _, t in ipairs(TOTALS) do ui.totals[t.key]:SetText(v[t.key] or DASH) end
end

local postToChat -- defined below

local function refreshPage(body)
  local ui = body.session
  local s = cur()
  local state = s and s.state
  ui.start:SetEnabled(state == nil)
  ui.pause:SetEnabled(state == "running")
  ui.resume:SetEnabled(state == "paused")
  ui.stop:SetEnabled(s ~= nil)
  ui.reset:SetEnabled(s ~= nil)
  ui.post:SetEnabled(s ~= nil)
  ui.prices:SetEnabled(s ~= nil)
  local key = sortKey()
  ui.list:SetSort(key, sortDesc)
  ui.list:SetRows(s and sessionRows(s) or {}, cellText)
  refreshTotals(body)
end

local function buildPage(body)
  pageBody = body
  local ui = {}
  body.session = ui

  local function action(method)
    return function() HB:SafeCall("Session", Session[method], Session) end
  end
  ui.start = W.RedButton(body, "Start", action("Start"))
  ui.start:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
  ui.pause = W.RedButton(body, "Pause", action("Pause"))
  ui.pause:SetPoint("LEFT", ui.start, "RIGHT", 6, 0)
  ui.resume = W.RedButton(body, "Resume", action("Resume"))
  ui.resume:SetPoint("LEFT", ui.pause, "RIGHT", 6, 0)
  ui.stop = W.RedButton(body, "Stop", action("Stop"))
  ui.stop:SetPoint("LEFT", ui.resume, "RIGHT", 6, 0)

  ui.totals = {}
  local x = 0
  for _, t in ipairs(TOTALS) do
    local label = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
    label:SetPoint("TOPLEFT", body, "TOPLEFT", x, -32)
    label:SetText(t.label)
    label:SetTextColor(Theme:Color("grey"))
    local value = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
    value:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -3)
    ui.totals[t.key] = value
    x = x + (t.key == "nodes" and 130 or 88)
  end

  ui.list = W.ColumnList(body, COLUMNS)
  ui.list:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -72)
  ui.list:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 56)
  ui.list.onSort = function(key)
    if key == sortKey() then
      sortDesc = not sortDesc
    else
      sortDesc = key ~= "name"
    end
    profile().session.sortKey = key
    refreshPage(body)
  end
  ui.list.onRowEnter = function(row, rowFrame, cellKey)
    HB:SafeCall("Session", showRowTooltip, row, rowFrame, cellKey)
  end
  ui.list.onRowLeave = function() GameTooltip:Hide() end

  ui.footer = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  ui.footer:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 32)
  ui.footer:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 32)
  ui.footer:SetJustifyH("LEFT")
  ui.footer:SetWordWrap(false)

  ui.prices = W.RedButton(body, "Refresh prices", function() HB:RefreshSessionPrices() end)
  ui.prices:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
  ui.reset = W.RedButton(body, "Reset", function() Session:ConfirmReset() end)
  ui.reset:SetPoint("LEFT", ui.prices, "RIGHT", 6, 0)
  ui.post = W.RedButton(body, "Post to chat", function(btn) postToChat(btn) end)
  ui.post:SetPoint("LEFT", ui.reset, "RIGHT", 6, 0)
end

StaticPopupDialogs["HARVESTBOOK_SESSION_RESET"] = {
  text = "Discard the current gathering session? Its materials and time will not be saved.",
  button1 = YES, button2 = CANCEL,
  OnAccept = function() HB:SafeCall("Session", Session.Reset, Session) end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Post to chat
---------------------------------------------------------------------------

local function chatLine()
  local s = cur()
  if not s then return nil end
  local now = time()
  local sum = SessionMath.Summary(s, now, priceFn())
  return string.format("Harvestbook: %s materials (%d kinds), %s in %s " .. DASH .. " %s/hr",
    Format.Thousands(sum.materials), sum.kinds, Format.Money(sum.copper),
    Format.Duration(SessionMath.ActiveSeconds(s, now)), sum.gph and Format.Money(sum.gph) or DASH)
end

local function send(channel)
  local line = chatLine()
  if not line then return end
  if C_ChatInfo and C_ChatInfo.SendChatMessage then
    C_ChatInfo.SendChatMessage(line, channel)
  else
    SendChatMessage(line, channel)
  end
end

local function partyChannel()
  if LE_PARTY_CATEGORY_HOME and IsInGroup(LE_PARTY_CATEGORY_HOME) then return "PARTY" end
  return "INSTANCE_CHAT"
end

postToChat = function(owner)
  local function choose(channel) HB:SafeCall("Session", send, channel) end
  if not (MenuUtil and MenuUtil.CreateContextMenu) then
    choose("SAY")
    return
  end
  MenuUtil.CreateContextMenu(owner, function(_, root)
    root:CreateTitle("Post to chat")
    local party = root:CreateButton("Party", function() choose(partyChannel()) end)
    party:SetEnabled(IsInGroup() and true or false)
    local guild = root:CreateButton("Guild", function() choose("GUILD") end)
    guild:SetEnabled(IsInGuild() and true or false)
    root:CreateButton("Say", function() choose("SAY") end)
  end)
end

---------------------------------------------------------------------------
-- Companion tabs
---------------------------------------------------------------------------

local function lineRow(parent, y)
  local label = parent:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  label:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
  label:SetTextColor(Theme:Color("grey"))
  local value = parent:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  value:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, y)
  value:SetPoint("LEFT", label, "RIGHT", 6, 0)
  value:SetJustifyH("RIGHT")
  value:SetWordWrap(false)
  return label, value
end

local SESSION_LINES = { "Time", "Nodes", "Gold", "Gold/hr", "Materials", "Last rare" }

local function buildSessionTab(f)
  f.values = {}
  for i, text in ipairs(SESSION_LINES) do
    local label, value = lineRow(f, -(i - 1) * 16)
    label:SetText(text)
    f.values[i] = value
  end
  f.bars = {}
  for i = 1, MAX_GOAL_BARS do
    local bar = W.ProgressBar(f)
    bar:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -(#SESSION_LINES * 16 + 4 + (i - 1) * 20))
    bar:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -(#SESSION_LINES * 16 + 4 + (i - 1) * 20))
    bar:Hide()
    f.bars[i] = bar
  end
end

local function goalBars()
  local goals = HB:GetModule("Goals", true)
  if not (goals and goals:IsEnabled() and goals.GetBars) then return nil end
  return HB:SafeCall("Goals", goals.GetBars, goals)
end

local function refreshSessionTab(f)
  local s = cur()
  local vals = { DASH, DASH, DASH, DASH, DASH, "" }
  if s then
    local now = time()
    local sum = SessionMath.Summary(s, now, priceFn())
    vals[1] = Format.Duration(SessionMath.ActiveSeconds(s, now))
    vals[2] = Format.Thousands(sum.nodes)
    vals[3] = money(sum.copper)
    vals[4] = sum.gph and money(sum.gph) or DASH
    vals[5] = Format.Thousands(sum.materials)
  end
  if lastRare then vals[6] = itemName(lastRare) end
  for i, fs in ipairs(f.values) do fs:SetText(vals[i]) end

  local bars = goalBars() or {}
  for i, bar in ipairs(f.bars) do
    local b = bars[i]
    if b then
      bar:SetProgress(b.current or b[2], b.target or b[3], b.label or b[1], b.fmt)
      bar:Show()
    else
      bar:Hide()
    end
  end
end

-- Builds `n` icon rows (icon, left text, right text) of height h.
local function buildIconRows(f, n, h)
  f.rows = {}
  for i = 1, n do
    local y = -(i - 1) * h
    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(h - 2, h - 2)
    icon:SetPoint("TOPLEFT", f, "TOPLEFT", 0, y)
    local left = f:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
    left:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    left:SetPoint("RIGHT", f, "RIGHT", -90, 0)
    left:SetJustifyH("LEFT")
    left:SetWordWrap(false)
    local right = f:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
    right:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, y - 2)
    right:SetJustifyH("RIGHT")
    f.rows[i] = { icon = icon, left = left, right = right }
  end
end

local function setIconRow(r, tex, left, right)
  r.icon:SetTexture(tex)
  r.icon:SetShown(tex ~= nil)
  r.left:SetText(left or "")
  r.right:SetText(right or "")
end

local function buildMaterialsTab(f)
  buildIconRows(f, TOP_MATERIALS, 18)
end

local function refreshMaterialsTab(f)
  local s = cur()
  local rows = s and SessionMath.Rows(s, time(), priceFn(), "value", true) or {}
  for i, r in ipairs(f.rows) do
    local row = rows[i]
    if row then
      setIconRow(r, itemIcon(row.itemID), "x" .. Format.Thousands(row.count), money(row.value))
    else
      setIconRow(r, nil)
    end
  end
end

local function buildLogTab(f)
  buildIconRows(f, LOG_SIZE, 15)
end

local function refreshLogTab(f)
  for i, r in ipairs(f.rows) do
    local e = gatherLog[i]
    if e then
      local item = e.item
      local text = item and (itemName(item.itemID, item.link) .. " x" .. (item.count or 0)) or ""
      setIconRow(r, Theme.ICONS[e.kind], text, date("%H:%M", e.time))
    else
      setIconRow(r, nil)
    end
  end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local PAGE = { id = "session", title = "Session", order = 10, build = buildPage, refresh = refreshPage }
local TABS = {
  { id = "session", title = "Session", order = 10, build = buildSessionTab, refresh = refreshSessionTab },
  { id = "materials", title = "Materials", order = 20, build = buildMaterialsTab, refresh = refreshMaterialsTab },
  { id = "log", title = "Log", order = 30, build = buildLogTab, refresh = refreshLogTab },
}

local function onEvent(event, fn)
  Session:RegisterEvent(event, function(_, ...) HB:SafeCall("Session", fn, ...) end)
end

function Session:OnEnable()
  local s = cur()
  if s then
    if s.state == "stopped" then
      archive(s)
      HB.char.current = nil
    else
      SessionMath.Restore(s, time()) -- offline / disabled time is not added
    end
  end

  HB:Listen(self, "HB_NODE_GATHERED", self.OnGather)
  HB:Listen(self, "HB_PRICES_UPDATED", refreshAll)
  HB:Listen(self, "HB_RARE_FOUND", self.OnRareFound)

  onEvent("PLAYER_ENTERING_WORLD", function()
    setCondition("instance", IsInInstance() and true or false)
  end)
  onEvent("MAIL_SHOW", function() setCondition("mail", true) end)
  onEvent("MAIL_CLOSED", function() setCondition("mail", false) end)
  onEvent("AUCTION_HOUSE_SHOW", function() setCondition("ah", true) end)
  onEvent("AUCTION_HOUSE_CLOSED", function() setCondition("ah", false) end)
  onEvent("PLAYER_FLAGS_CHANGED", function(unit)
    if unit == "player" then setCondition("afk", isAFK() and true or false) end
  end)
  onEvent("PLAYER_LOGOUT", save)

  PAGE.icon = Theme.ICONS.session
  HB.UI:RegisterPage(PAGE)
  for _, t in ipairs(TABS) do HB.UI:RegisterCompanionTab(t) end

  wipe(active)
  reconcileConditions()
  updateTicker()
  updateStatus()
  refreshAll()
end

function Session:OnDisable()
  save()
  self:UnregisterAllEvents()
  self:UnregisterAllMessages()
  if ticker then
    self:CancelTimer(ticker)
    ticker = nil
  end
  HB.UI:UnregisterPage("session")
  for _, t in ipairs(TABS) do HB.UI:UnregisterCompanionTab(t.id) end
  HB.UI:SetStatus("", "grey")
  HB.UI:SetCompanionState("")
end
