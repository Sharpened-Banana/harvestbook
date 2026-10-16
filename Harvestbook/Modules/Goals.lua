local ADDON, ns = ...

-- Goals module (spec §4.6): session goals (materials / gold / minutes) with
-- progress bars, and rare-drop attempt counters.
--
-- Messages sent: HB_GOAL_REACHED(goal) once per goal per session (the
-- `reached` set resets when a new session starts); HB_RARE_FOUND(itemID,
-- attemptsBeforeFind) when a tracked item drops.
--
-- Storage: profile.goals.list = { {id, type, itemID?, target}, ... } with
-- profile.goals.nextID; global.goals.attempts[itemID] =
-- { attempts, found, kind, sinceLast }.
-- Attempt counters update on every gather, whatever the session state.

local HB = ns.HB
local GoalEval = ns.GoalEval
local Format = ns.Format
local Theme = ns.Theme
local W = ns.Widgets

local Goals = HB:NewModule("Goals", "AceEvent-3.0")

local MAX_GOALS = 5
local TICK_SECONDS = 5
local DASH = "\226\128\148"

-- Reached goals persist in HB.char.goalsReached = { sessionID, ids = {[goalID]=true} }
-- so a /reload mid-session does not re-fire them.
local function reachedFor(sessionID)
  local st = HB.char.goalsReached
  if not st or st.sessionID ~= sessionID then
    st = { sessionID = sessionID, ids = {} }
    HB.char.goalsReached = st
  end
  return st.ids
end
local ticker
local boxes = {}         -- item EditBoxes that accept Shift-clicked links
local hooked = false

local function pg() return HB.db.profile.goals end
local function ag() return HB.db.global.goals.attempts end
local function money(copper) return Format.Money(copper, HB.db.profile.goldStyle) end

local function itemName(itemID)
  local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
  return name or ("Item " .. tostring(itemID))
end

local function itemIcon(itemID)
  return C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID) or nil
end

local function currentSession()
  local s = HB:GetModule("Session", true)
  return s and s.GetCurrent and s:GetCurrent() or nil
end

-- Accepts an item link, "item:123", or a bare number; nil when unparseable.
local function parseItemID(text)
  if not text then return nil end
  text = strtrim and strtrim(text) or text:match("^%s*(.-)%s*$")
  if text == "" then return nil end
  local n = text:match("item:(%d+)") or text:match("^(%d+)$")
  return n and tonumber(n) or nil
end

local function say(msg)
  if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffffd100Harvestbook:|r " .. msg) end
end

---------------------------------------------------------------------------
-- Goals
---------------------------------------------------------------------------

local function goalLabel(g)
  if g.type == "materials" then
    local name = g.itemID and itemName(g.itemID) or "Any material"
    return name .. " x" .. Format.Thousands(g.target)
  elseif g.type == "gold" then
    return money(g.target)
  end
  return Format.Thousands(g.target) .. " min"
end

local function fmtFor(g)
  if g.type == "gold" then return money end
  if g.type == "minutes" then return function(v) return Format.Thousands(math.floor(v)) end end
  return nil
end

local function progress(g)
  local s = currentSession()
  if not s then return 0, g.target, false end
  return GoalEval.Progress(g, s, time(), HB.Pricing:Fn())
end

-- Companion/Session-tab API: { {label, current, target, fmt}, ... }.
function Goals:GetBars()
  local out = {}
  for _, g in ipairs(pg().list) do
    local cur, target = progress(g)
    out[#out + 1] = { label = goalLabel(g), current = cur, target = target, fmt = fmtFor(g) }
  end
  return out
end

function Goals:AddGoal(gtype, itemID, target)
  local p = pg()
  if #p.list >= MAX_GOALS then return nil, "limit" end
  p.nextID = (p.nextID or 0) + 1
  local g = { id = p.nextID, type = gtype, itemID = itemID, target = target }
  p.list[#p.list + 1] = g
  return g
end

function Goals:DeleteGoal(id)
  local list = pg().list
  for i, g in ipairs(list) do
    if g.id == id then
      table.remove(list, i)
      local st = HB.char.goalsReached
      if st and st.ids then st.ids[id] = nil end
      return true
    end
  end
  return false
end

function Goals:Evaluate()
  local s = currentSession()
  if not s or s.state ~= "running" then return end
  local list = pg().list
  if #list == 0 then return end
  for _, g in ipairs(GoalEval.NewlyReached(list, s, time(), HB.Pricing:Fn(), reachedFor(s.id))) do
    HB:SendMessage("HB_GOAL_REACHED", g)
  end
end

---------------------------------------------------------------------------
-- Rare-drop counters
---------------------------------------------------------------------------

function Goals:AddRare(itemID, kind)
  local a = ag()
  local e = a[itemID]
  if e then
    e.kind = kind
  else
    a[itemID] = { attempts = 0, found = 0, kind = kind, sinceLast = 0 }
  end
end

function Goals:DeleteRare(itemID)
  ag()[itemID] = nil
end

function Goals:OnGather(gather)
  if type(gather) ~= "table" then return end
  local a = ag()
  local before = {}
  for itemID, e in pairs(a) do before[itemID] = e.sinceLast or 0 end
  for _, itemID in ipairs(GoalEval.UpdateAttempts(a, gather)) do
    HB:SendMessage("HB_RARE_FOUND", itemID, before[itemID] or 0)
  end
  self:Evaluate()
end

function Goals:OnSession(state, s)
  if state == "running" and s then reachedFor(s.id) end
end

---------------------------------------------------------------------------
-- Shift-click item link capture
---------------------------------------------------------------------------

-- Blizzard's ChatEdit_InsertLink only writes to chat boxes; its secure
-- post-hook lets us copy the link into a focused Harvestbook input. The
-- HandleModifiedItemClick hook covers item clicks that route around it.
local function captureLink(link)
  if type(link) ~= "string" or not Goals:IsEnabled() then return end
  for box in pairs(boxes) do
    if box:IsVisible() and box:HasFocus() then box:SetText(link) end
  end
end

local function installHooks()
  if hooked then return end
  hooked = true
  if ChatEdit_InsertLink then hooksecurefunc("ChatEdit_InsertLink", captureLink) end
  if HandleModifiedItemClick then
    hooksecurefunc("HandleModifiedItemClick", function(link)
      if IsModifiedClick and IsModifiedClick("CHATLINK") then captureLink(link) end
    end)
  end
end

local function newInput(parent, width, numeric)
  local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  box:SetSize(width, 20)
  box:SetAutoFocus(false)
  box:SetTextInsets(2, 2, 0, 0)
  if numeric then box:SetMaxLetters(9) end
  box:SetScript("OnEscapePressed", box.ClearFocus)
  box:SetScript("OnEnterPressed", box.ClearFocus)
  boxes[box] = true
  return box
end

---------------------------------------------------------------------------
-- Page
---------------------------------------------------------------------------

local TYPE_OPTIONS = {
  { value = "materials", text = "Materials" },
  { value = "gold", text = "Gold" },
  { value = "minutes", text = "Minutes" },
}
local KIND_OPTIONS = {
  { value = "any", text = "Any" },
  { value = "herb", text = "Herb" },
  { value = "ore", text = "Ore" },
  { value = "skin", text = "Skin" },
}
local TARGET_HINT = {
  materials = "Item (Shift-click, blank = any)  /  count",
  gold = "Gold target (in gold)",
  minutes = "Minutes target",
}

-- Columns total 395 + 4 pad + 16 scrollbar = 415 <= 440.
local RARE_COLUMNS = {
  { key = "name", title = "Item", width = 150, align = "LEFT" },
  { key = "kind", title = "Kind", width = 50, align = "LEFT" },
  { key = "attempts", title = "Attempts", width = 65, align = "RIGHT" },
  { key = "found", title = "Found", width = 50, align = "RIGHT" },
  { key = "last", title = "Last found", width = 80, align = "RIGHT" },
}

local addType, addKind = "materials", "any"

local function kindText(k)
  if k == "herb" then return "Herb" elseif k == "ore" then return "Ore" elseif k == "skin" then return "Skin" end
  return "Any"
end

local function lastText(e)
  if (e.found or 0) == 0 then return "never" end
  local n = e.sinceLast or 0
  if n == 0 then return "last gather" end
  return n .. " gathers ago"
end

local function rareCell(row, key)
  local e = row.e
  if key == "name" then return itemName(row.itemID), itemIcon(row.itemID)
  elseif key == "kind" then return kindText(e.kind)
  elseif key == "attempts" then return Format.Thousands(e.attempts or 0)
  elseif key == "found" then return Format.Thousands(e.found or 0)
  elseif key == "last" then return lastText(e) end
end

local function rareRows()
  local rows = {}
  for itemID, e in pairs(ag()) do rows[#rows + 1] = { itemID = itemID, e = e } end
  table.sort(rows, function(x, y) return x.itemID < y.itemID end)
  return rows
end

local function refreshPage(body)
  local ui = body.goals
  if not ui then return end
  local list = pg().list
  for i, row in ipairs(ui.rows) do
    local g = list[i]
    if g then
      local cur, target = progress(g)
      row.goalID = g.id
      row.bar:SetProgress(cur, target, goalLabel(g), fmtFor(g))
      row:Show()
    else
      row:Hide()
    end
  end
  ui.empty:SetShown(#list == 0)
  ui.typeDD:Refresh()
  ui.kindDD:Refresh()
  ui.hint:SetText(TARGET_HINT[addType])
  ui.rare:SetRows(rareRows(), rareCell)
end

local function changed()
  HB.UI:RefreshPage("goals")
  HB.UI:RefreshCompanion()
end

local function buildPage(body)
  installHooks()
  local ui = {}
  body.goals = ui

  local h1 = W.Heading(body, "Session goals")
  h1:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
  h1:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, 0)

  ui.rows = {}
  for i = 1, MAX_GOALS do
    local row = CreateFrame("Frame", nil, body)
    row:SetHeight(18)
    local y = -28 - (i - 1) * 20
    row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, y)
    row:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, y)
    local del = W.RedButton(row, "X", function()
      if row.goalID and Goals:DeleteGoal(row.goalID) then changed() end
    end)
    del:SetSize(22, 16)
    del:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.bar = W.ProgressBar(row)
    row.bar:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.bar:SetPoint("RIGHT", del, "LEFT", -4, 0)
    ui.rows[i] = row
  end

  ui.empty = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
  ui.empty:SetPoint("TOPLEFT", body, "TOPLEFT", 4, -32)
  ui.empty:SetTextColor(Theme:Color("grey"))
  ui.empty:SetText("No goals yet. Add one below.")

  ui.hint = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
  ui.hint:SetPoint("TOPLEFT", body, "TOPLEFT", 4, -132)
  ui.hint:SetTextColor(Theme:Color("grey"))

  ui.typeDD = W.Dropdown(body, 110, TYPE_OPTIONS, function() return addType end, function(v)
    addType = v
    ui.hint:SetText(TARGET_HINT[v])
  end)
  ui.typeDD:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -146)

  ui.item = newInput(body, 130, false)
  ui.item:SetPoint("LEFT", ui.typeDD, "RIGHT", 12, 0)

  ui.target = newInput(body, 70, true)
  ui.target:SetPoint("LEFT", ui.item, "RIGHT", 10, 0)

  ui.add = W.RedButton(body, "Add goal", function()
    local target = tonumber(ui.target:GetText())
    if not target or target <= 0 then say("Enter a target greater than zero.") return end
    local itemID
    if addType == "materials" then
      local text = ui.item:GetText()
      itemID = parseItemID(text)
      if text and text:match("%S") and not itemID then say("Could not read an item from that input.") return end
    end
    if addType == "gold" then target = target * 10000 end
    target = math.floor(target)
    if target <= 0 then return end
    local g, err = Goals:AddGoal(addType, itemID, target)
    if not g then say("You can track up to " .. MAX_GOALS .. " goals.") return end
    ui.item:SetText("")
    ui.target:SetText("")
    ui.item:ClearFocus()
    ui.target:ClearFocus()
    changed()
  end)
  ui.add:SetPoint("LEFT", ui.target, "RIGHT", 10, 0)

  local h2 = W.Heading(body, "Rare drops")
  h2:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -182)
  h2:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -182)

  ui.rare = W.ColumnList(body, RARE_COLUMNS)
  ui.rare:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -210)
  ui.rare:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 34)
  ui.rare.onRowClick = function(row, button)
    if button == "RightButton" then
      StaticPopup_Show("HARVESTBOOK_DELETE_RARE", itemName(row.itemID), nil, row.itemID)
    end
  end

  ui.kindDD = W.Dropdown(body, 80, KIND_OPTIONS, function() return addKind end, function(v) addKind = v end)
  ui.kindDD:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 2)

  ui.rareItem = newInput(body, 150, false)
  ui.rareItem:SetPoint("LEFT", ui.kindDD, "RIGHT", 12, 0)

  ui.rareAdd = W.RedButton(body, "Track item", function()
    local itemID = parseItemID(ui.rareItem:GetText())
    if not itemID then say("Shift-click an item (or type its item ID) to track it.") return end
    Goals:AddRare(itemID, addKind ~= "any" and addKind or nil)
    ui.rareItem:SetText("")
    ui.rareItem:ClearFocus()
    changed()
  end)
  ui.rareAdd:SetPoint("LEFT", ui.rareItem, "RIGHT", 10, 0)

  local tip = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
  tip:SetPoint("LEFT", ui.rareAdd, "RIGHT", 8, 0)
  tip:SetPoint("RIGHT", body, "RIGHT", 0, 0)
  tip:SetJustifyH("LEFT")
  tip:SetWordWrap(false)
  tip:SetTextColor(Theme:Color("grey"))
  tip:SetText("Right-click a row to delete")
end

StaticPopupDialogs["HARVESTBOOK_DELETE_RARE"] = {
  text = "Stop tracking %s and delete its attempt counter?",
  button1 = YES, button2 = CANCEL,
  OnAccept = function(_, itemID)
    Goals:DeleteRare(itemID)
    changed()
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local PAGE = { id = "goals", title = "Goals", order = 50, build = buildPage, refresh = refreshPage }

function Goals:OnEnable()
  pg().nextID = pg().nextID or 0
  local cur = currentSession()
  local st = HB.char.goalsReached
  if cur and (not st or st.sessionID ~= cur.id) then
    -- Enabled mid-session (or first run): goals already met must not burst.
    local ids = reachedFor(cur.id)
    local priceFn = HB.Pricing:Fn()
    local now = time()
    for _, g in ipairs(pg().list) do
      local _, _, done = GoalEval.Progress(g, cur, now, priceFn)
      if done then ids[g.id] = true end
    end
  end

  -- One handler per message (AceEvent keeps a single callback per object).
  HB:Listen(self, "HB_NODE_GATHERED", function(mod, gather)
    mod:OnGather(gather)
    changed()
  end)
  HB:Listen(self, "HB_BONUS_LOOT", function(mod) -- materials goals move; not a node
    mod:Evaluate()
    changed()
  end)
  HB:Listen(self, "HB_SESSION_CHANGED", function(mod, state, s)
    mod:OnSession(state, s)
    mod:Evaluate()
    changed()
  end)
  HB:Listen(self, "HB_PRICES_UPDATED", function(mod)
    mod:Evaluate()
    changed()
  end)

  -- Minute goals (and price-driven gold goals) need a periodic check.
  ticker = C_Timer.NewTicker(TICK_SECONDS, function()
    HB:SafeCall("Goals", Goals.Evaluate, Goals)
    HB.UI:RefreshPage("goals")
    HB.UI:RefreshCompanion()
  end)

  PAGE.icon = Theme.ICONS and Theme.ICONS.goals
  HB.UI:RegisterPage(PAGE)
end

function Goals:OnDisable()
  self:UnregisterAllMessages()
  if ticker then ticker:Cancel() ticker = nil end
  HB.UI:UnregisterPage("goals")
end
