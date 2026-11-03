local ADDON, ns = ...
local L = ns.L

-- Shopping list module: materials you want to gather, with how many you have,
-- the best zone for each (from the node log, see Logic/ShoppingEval) and an
-- estimate of the nodes left.
--
-- Listens to BAG_UPDATE_DELAYED, HB_NODE_GATHERED, HB_BONUS_LOOT and
-- HB_NODELOG_CHANGED. Storage: global.shopping.list = { {itemID, target}, ... },
-- shared by the warband. Turning the module off keeps the list.

local HB = ns.HB
local Eval = ns.ShoppingEval
local GoalEval = ns.GoalEval
local Format = ns.Format
local Theme = ns.Theme
local W = ns.Widgets

local Shopping = HB:NewModule("Shopping", "AceEvent-3.0")

local DASH = "\226\128\148"
local SEED_DELAY = 5 -- quiet seconds after the last bag update before notices start

-- This login only.
local selected        -- itemID of the selected row
local itemBox         -- EditBox that accepts Shift-clicked links
local hooked = false
local doneSet         -- [itemID] = true; nil until seeded, so login never announces
local seedTimer
local throttle = {}
local bestCache, bestFor = {}, nil

local function colorCode(key)
  local r, g, b = Theme:Color(key)
  return string.format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5),
    math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

local GREEN, GREY, GOLD = colorCode("green"), colorCode("grey"), colorCode("gold")

local function list() return HB.db.global.shopping.list end

local function mapName(mapID)
  local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
  return info and info.name or L["Map %s"]:format(tostring(mapID))
end

---------------------------------------------------------------------------
-- Counting
---------------------------------------------------------------------------

local function tryCount(...)
  local ok, n = pcall(C_Item.GetItemCount, ...)
  return ok and type(n) == "number" and n or nil
end

-- Bags, bank, reagent bank and warband bank of the current character.
local function countOf(itemID)
  if not (C_Item and C_Item.GetItemCount) then return 0 end
  return tryCount(itemID, true, nil, true, true) or tryCount(itemID, true, nil, true)
    or tryCount(itemID, true) or 0
end

local function countRows()
  local rows = {}
  for i, e in ipairs(list()) do
    rows[i] = { itemID = e.itemID, target = e.target, have = countOf(e.itemID) }
  end
  return rows
end

-- Runs whether or not the page is showing: the notice can't wait for a refresh.
local function check()
  if doneSet then
    for _, row in ipairs(Eval.NewlyDone(countRows(), doneSet)) do
      HB:Msg(L["Shopping list: %s done (%s/%s)."], HB:ItemName(row.itemID),
        Format.Thousands(row.have), Format.Thousands(row.target))
    end
  end
  HB.UI:RefreshPage("shopping")
end

local function queueCheck()
  HB.UI._Throttle(throttle, function() HB:SafeCall("Shopping", check) end)
end

local function seed()
  seedTimer = nil
  doneSet = {}
  Eval.NewlyDone(countRows(), doneSet)
end

-- Bank counts can arrive after login, so the seed waits for the bags to go quiet.
local function startSeedTimer()
  if seedTimer then seedTimer:Cancel() end
  seedTimer = C_Timer.NewTimer(SEED_DELAY, function() HB:SafeCall("Shopping", seed) end)
end

-- A full scan of the node log per item, so it isn't repeated on every bag update.
-- The nodes table itself changes on Reset all data.
local function bestZone(itemID)
  local zones = HB.db.global.nodes
  if zones ~= bestFor then bestCache, bestFor = {}, zones end
  local c = bestCache[itemID]
  if not c then
    local mapID, avg = Eval.BestZone(zones, itemID)
    c = { mapID = mapID, avg = avg }
    bestCache[itemID] = c
  end
  return c.mapID, c.avg
end

---------------------------------------------------------------------------
-- List edits
---------------------------------------------------------------------------

local function refresh() HB.UI:RefreshPage("shopping") end

-- False only when the game says there's no such item; an API problem lets it through.
local function itemExists(itemID)
  local fn = C_Item and C_Item.GetItemInfoInstant
  if not fn then return true end
  local ok, id = pcall(fn, itemID)
  return not ok or id ~= nil
end

local function addItem(ui)
  local itemID = Eval.ParseItem(ui.item:GetText())
  if not itemID then
    HB:Msg(L["Shift-click an item (or type its item ID) to add it."])
    return
  end
  if not itemExists(itemID) then
    HB:Msg(L["There is no item with ID %d."], itemID)
    return
  end
  local target = GoalEval.ParseTarget(ui.target:GetText(), false)
  if not target then
    HB:Msg(L["Enter how many you need, as a whole number greater than zero."])
    return
  end
  if not Eval.Upsert(list(), itemID, target) then
    HB:Msg(L["The shopping list holds up to %d items."], Eval.MAX_ENTRIES)
    return
  end
  -- Adding or re-targeting is not gathering: no notice from this change.
  if doneSet then doneSet[itemID] = Eval.Done(target, countOf(itemID)) or nil end
  selected = itemID
  ui.item:SetText("")
  ui.target:SetText("")
  ui.item:ClearFocus()
  ui.target:ClearFocus()
  refresh()
end

local function removeSelected()
  if not selected then return end
  Eval.Remove(list(), selected)
  if doneSet then doneSet[selected] = nil end
  selected = nil
  refresh()
end

local function clearAll()
  HB.db.global.shopping.list = {}
  if doneSet then doneSet = {} end
  selected = nil
  refresh()
end

StaticPopupDialogs["HARVESTBOOK_SHOPPING_CLEAR"] = {
  text = L["Clear your whole shopping list?"],
  button1 = YES, button2 = CANCEL,
  OnAccept = function() HB:SafeCall("Shopping", clearAll) end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Shift-click item link capture (same hooks as Modules/Goals.lua; Goals can be off)
---------------------------------------------------------------------------

local function captureLink(link)
  if type(link) ~= "string" or not Shopping:IsEnabled() then return end
  if itemBox and itemBox:IsVisible() and itemBox:HasFocus() then itemBox:SetText(link) end
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

local function newInput(parent, width)
  local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  box:SetSize(width, 20)
  box:SetAutoFocus(false)
  box:SetTextInsets(2, 2, 0, 0)
  box:SetScript("OnEscapePressed", box.ClearFocus)
  box:SetScript("OnEnterPressed", box.ClearFocus)
  return box
end

---------------------------------------------------------------------------
-- Page
---------------------------------------------------------------------------

-- Columns + 4 px pad + 16 px scrollbar must be <= 440: 420.
local COLUMNS = {
  { key = "name", title = L["Item"], width = 180, align = "LEFT" },
  { key = "have", title = L["Have/Target"], width = 80, align = "RIGHT" },
  { key = "zone", title = L["Best zone"], width = 105, align = "LEFT" },
  { key = "nodes", title = L["Nodes"], width = 55, align = "RIGHT" },
}

-- ItemQualityInfo remembers "no badge" for an item with no known quality, so
-- it's only asked once the item has loaded.
local function qualityAtlas(itemID)
  local loaded = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
  if not loaded then return nil end
  return HB:ItemQualityInfo({ itemID = itemID }).small or nil
end

local function cell(row, key)
  if key == "name" then
    local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(row.itemID) or nil
    local name = row.itemID == selected and (GOLD .. row.name .. "|r") or row.name
    return name, icon, qualityAtlas(row.itemID)
  elseif key == "have" then
    return Format.Thousands(row.have) .. "/" .. Format.Thousands(row.target)
  elseif key == "zone" then
    return row.mapID and mapName(row.mapID) or (GREY .. DASH .. "|r")
  elseif key == "nodes" then
    if row.done then return GREEN .. L["Done"] .. "|r" end
    return row.nodes and Format.Thousands(row.nodes) or (GREY .. DASH .. "|r")
  end
end

local function buildRows()
  local rows = countRows()
  for _, row in ipairs(rows) do
    local mapID, avg = bestZone(row.itemID)
    row.name = HB:ItemName(row.itemID)
    row.mapID = mapID
    row.done = Eval.Done(row.target, row.have)
    row.nodes = Eval.NodesNeeded(row.target, row.have, avg)
  end
  return Eval.SortRows(rows)
end

local function refreshPage(body)
  local ui = body.shopping
  if not ui then return end
  local rows = buildRows()
  local found = false
  for _, row in ipairs(rows) do
    if row.itemID == selected then found = true end
  end
  if not found then selected = nil end -- e.g. Reset all data
  ui.list:SetRows(rows, cell)
  ui.empty:SetShown(#rows == 0)
  ui.remove:SetEnabled(selected ~= nil)
  ui.clear:SetEnabled(#rows > 0)
end

local function buildPage(body)
  installHooks()
  local ui = {}
  body.shopping = ui

  local function label(text, box)
    local fs = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
    fs:SetPoint("BOTTOMLEFT", box, "TOPLEFT", 0, 2)
    fs:SetTextColor(Theme:Color("grey"))
    fs:SetText(text)
  end

  ui.item = newInput(body, 200)
  ui.item:SetPoint("TOPLEFT", body, "TOPLEFT", 6, -16) -- the box's border sits outside its frame
  label(L["Item (Shift-click, or item ID)"], ui.item)
  itemBox = ui.item

  ui.target = newInput(body, 70)
  ui.target:SetMaxLetters(14)
  ui.target:SetPoint("LEFT", ui.item, "RIGHT", 10, 0)
  label(L["How many"], ui.target)

  ui.add = W.RedButton(body, L["Add"], function() HB:SafeCall("Shopping", addItem, ui) end)
  ui.add:SetPoint("LEFT", ui.target, "RIGHT", 10, 0)

  ui.note = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
  ui.note:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
  ui.note:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
  ui.note:SetHeight(28) -- two lines at the smallest window
  ui.note:SetJustifyH("LEFT")
  ui.note:SetJustifyV("BOTTOM")
  ui.note:SetTextColor(Theme:Color("grey"))
  ui.note:SetText(L["Have counts this character and the warband bank, not your other characters. Nodes is an estimate from your node log."])

  ui.remove = W.RedButton(body, L["Remove"], function() HB:SafeCall("Shopping", removeSelected) end)
  ui.remove:SetPoint("BOTTOMLEFT", ui.note, "TOPLEFT", 0, 4)

  ui.clear = W.RedButton(body, L["Clear all"], function() StaticPopup_Show("HARVESTBOOK_SHOPPING_CLEAR") end)
  ui.clear:SetPoint("LEFT", ui.remove, "RIGHT", 8, 0)

  ui.list = W.ColumnList(body, COLUMNS)
  ui.list:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -44)
  ui.list:SetPoint("BOTTOMRIGHT", ui.note, "TOPRIGHT", 0, 30)
  ui.list.onRowClick = function(row)
    selected = row.itemID
    refreshPage(body)
  end

  ui.empty = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  ui.empty:SetPoint("TOPLEFT", ui.list, "TOPLEFT", 4, -30)
  ui.empty:SetPoint("RIGHT", body, "RIGHT", -4, 0)
  ui.empty:SetJustifyH("LEFT")
  ui.empty:SetTextColor(Theme:Color("grey"))
  ui.empty:SetText(L["Your shopping list is empty. Add a material you want to gather and how many you need."])
  ui.empty:Hide()
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local PAGE = { id = "shopping", title = L["Shopping"], order = 37, build = buildPage, refresh = refreshPage }

function Shopping:OnEnable()
  doneSet = nil
  bestCache, bestFor = {}, nil
  startSeedTimer()
  self:RegisterEvent("BAG_UPDATE_DELAYED", function()
    HB:SafeCall("Shopping", function()
      if not doneSet then startSeedTimer() end
      queueCheck()
    end)
  end)
  HB:Listen(self, "HB_NODE_GATHERED", queueCheck)
  HB:Listen(self, "HB_BONUS_LOOT", queueCheck)
  HB:Listen(self, "HB_NODELOG_CHANGED", function()
    bestCache = {}
    refresh()
  end)
  PAGE.icon = Theme.ICONS and Theme.ICONS.shopping
  HB.UI:RegisterPage(PAGE)
end

function Shopping:OnDisable()
  self:UnregisterAllMessages()
  self:UnregisterAllEvents()
  if seedTimer then seedTimer:Cancel() seedTimer = nil end
  HB.UI._CancelThrottle(throttle)
  doneSet = nil
  HB.UI:UnregisterPage("shopping")
end
