local ADDON, ns = ...

-- Alarms module (spec §4.7): sound, raid-warning-style text and an optional
-- screen flash for high-value nodes, rare finds, reached goals and broken
-- records. Rule evaluation and the 2 s throttle live in Logic/AlarmEval.lua.
--
-- Per-rule extra keys (ignored by AlarmEval): `sound` (a name from SOUNDS, an
-- "LSM: <name>" entry, or "None") and `flash` (bool). When absent, the
-- DEFAULT_SOUND / DEFAULT_FLASH tables below apply; AlarmEval.DEFAULTS is
-- never modified.

local HB = ns.HB
local AlarmEval = ns.AlarmEval
local SessionMath = ns.SessionMath
local Format = ns.Format
local Theme = ns.Theme
local W = ns.Widgets

local Alarms = HB:NewModule("Alarms", "AceEvent-3.0")

local SOUNDS = { ["Raid warning"] = 8959, ["Ready check"] = 8960, ["Coin"] = 120, ["Quest complete"] = 878 }
local SOUND_ORDER = { "Raid warning", "Ready check", "Coin", "Quest complete" }
local DEFAULT_SOUND = {
  value = "Coin", multiple = "Coin", rare = "Raid warning",
  goal = "Quest complete", record = "Ready check",
}
local DEFAULT_FLASH = { value = false, multiple = false, rare = true, goal = false, record = true }
local FLASH_SECONDS = 0.6
local LSM_PREFIX = "LSM: "

local state = {}   -- AlarmEval throttle state ({ lastFire })
local flashFrame

local function cfg() return HB.db.profile.alarms end
local function money(copper) return Format.Money(copper, HB.db.profile.goldStyle) end

local function lsm()
  return LibStub and LibStub("LibSharedMedia-3.0", true) or nil
end

local function currentSession()
  local s = HB:GetModule("Session", true)
  return s and s.GetCurrent and s:GetCurrent() or nil
end

local function itemName(itemID, link)
  local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
  if name then return name end
  if link then
    local n = link:match("%[(.-)%]")
    if n then return n end
  end
  return "Item " .. tostring(itemID)
end

---------------------------------------------------------------------------
-- Output: sound, text, flash
---------------------------------------------------------------------------

local function soundFor(rule)
  local r = cfg()[rule]
  return (r and r.sound) or DEFAULT_SOUND[rule]
end

local function flashFor(rule)
  local r = cfg()[rule]
  if r and r.flash ~= nil then return r.flash and true or false end
  return DEFAULT_FLASH[rule] and true or false
end

local function playSound(name)
  if not name or name == "None" then return end
  if name:sub(1, #LSM_PREFIX) == LSM_PREFIX then
    local lib = lsm()
    local path = lib and lib:Fetch("sound", name:sub(#LSM_PREFIX + 1), true)
    if path then PlaySoundFile(path, "Master") end
    return
  end
  local id = SOUNDS[name]
  if id then PlaySound(id, "Master") end
end

local function showText(text)
  if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo and ChatTypeInfo["RAID_WARNING"] then
    RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo["RAID_WARNING"])
  elseif UIErrorsFrame then
    UIErrorsFrame:AddMessage(text, 1, 0.82, 0)
  end
end

local function ensureFlash()
  if flashFrame then return flashFrame end
  local f = CreateFrame("Frame", nil, UIParent)
  f:SetAllPoints(UIParent)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:EnableMouse(false)
  local tex = f:CreateTexture(nil, "BACKGROUND")
  tex:SetAllPoints()
  tex:SetTexture("Interface\\Buttons\\WHITE8X8")
  tex:SetVertexColor(1, 0.82, 0, 1)
  f.tex = tex
  f:SetAlpha(0)
  f:Hide()
  f:SetScript("OnUpdate", function(self, elapsed)
    self.t = (self.t or 0) + elapsed
    if self.t >= FLASH_SECONDS then
      self:SetAlpha(0)
      self:Hide()
      return
    end
    self:SetAlpha(0.35 * (1 - self.t / FLASH_SECONDS))
  end)
  flashFrame = f
  return f
end

local function doFlash()
  local f = ensureFlash()
  f.t = 0
  f:SetAlpha(0.35)
  f:Show()
end

local function output(rule, text)
  playSound(soundFor(rule))
  showText(text)
  if flashFor(rule) then doFlash() end
end

---------------------------------------------------------------------------
-- Evaluation
---------------------------------------------------------------------------

local function fire(ctx)
  ctx.now = GetTime()
  for _, f in ipairs(AlarmEval.Evaluate(cfg(), ctx, state)) do
    output(f.rule, f.text)
  end
end

local function nodeTotal(s)
  local n = 0
  for _, c in pairs(s.nodes or {}) do n = n + c end
  return n
end

local function bestItemName(gather, priceFn)
  local bestName, bestVal
  for _, it in ipairs(gather.items or {}) do
    local v = (priceFn(it.itemID, it.quality, it.link) or 0) * (it.count or 0)
    if not bestVal or v > bestVal then
      bestVal, bestName = v, itemName(it.itemID, it.link)
    end
  end
  return bestName or gather.targetName or "Node"
end

function Alarms:OnGather(gather)
  if type(gather) ~= "table" then return end
  local priceFn = HB.Pricing:Fn()
  local nodeCopper = SessionMath.NodeValue(gather, priceFn)
  local ctx = {
    kind = "node", nodeCopper = nodeCopper, avgCopper = 0, nodeCount = 0,
    label = bestItemName(gather, priceFn) .. " (" .. money(nodeCopper) .. ")",
  }
  local s = currentSession()
  if s and s.state == "running" then
    local n = nodeTotal(s)
    if n > 0 then
      ctx.nodeCount = n
      ctx.avgCopper = SessionMath.Value(s, priceFn) / n
    end
  end
  fire(ctx)
end

local function goalLabel(g)
  if g.type == "materials" then
    local name = g.itemID and itemName(g.itemID) or "Any material"
    return name .. " x" .. Format.Thousands(g.target or 0)
  elseif g.type == "gold" then
    return "Gold goal (" .. money(g.target or 0) .. ")"
  end
  return "Minutes goal (" .. Format.Thousands(g.target or 0) .. " min)"
end

local RECORD_NAMES = {
  bestGph = "Best gold/hr", biggestNode = "Biggest node",
  longest = "Longest session", mostNodes = "Most nodes",
}

local function recordLabel(name, value)
  local friendly = RECORD_NAMES[name] or tostring(name)
  local v
  if name == "longest" then v = Format.Duration(value)
  elseif name == "mostNodes" then v = Format.Thousands(value or 0)
  else v = money(value) end
  return friendly .. " " .. v
end

local function rareLabel(itemID, attempts)
  local label = itemName(itemID)
  if (attempts or 0) > 0 then label = label .. " after " .. attempts .. " gathers" end
  return label
end

---------------------------------------------------------------------------
-- Test
---------------------------------------------------------------------------

local SAMPLE = {
  value = "High-value node: Sample Herb (1,000g)",
  multiple = "High-value node: Sample Ore (3x average)",
  rare = "Rare find: Sample Rare after 42 gathers",
  goal = "Goal reached: Sample goal",
  record = "New record: Best gold/hr 12,345g",
}

function Alarms:Test(rule)
  output(rule, SAMPLE[rule] or ("Test: " .. tostring(rule)))
end

---------------------------------------------------------------------------
-- Page
---------------------------------------------------------------------------

local RULES = {
  { key = "value", label = "Node value" },
  { key = "multiple", label = "Node vs. average" },
  { key = "rare", label = "Rare find" },
  { key = "goal", label = "Goal reached" },
  { key = "record", label = "Record broken" },
}

local function soundOptions()
  local out = {}
  for _, name in ipairs(SOUND_ORDER) do out[#out + 1] = { value = name, text = name } end
  out[#out + 1] = { value = "None", text = "None" }
  local lib = lsm()
  if lib then
    local list = lib:List("sound")
    if list then
      for _, name in ipairs(list) do
        out[#out + 1] = { value = LSM_PREFIX .. name, text = LSM_PREFIX .. name }
      end
    end
  end
  return out
end

local function newInput(parent, width)
  local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  box:SetSize(width, 20)
  box:SetAutoFocus(false)
  box:SetTextInsets(2, 2, 0, 0)
  box:SetMaxLetters(7)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() self.reload() end)
  return box
end

-- Numeric box bound to cfg()[rule][field]; ignores non-positive input.
local function bindNumber(box, rule, field, min)
  local function read() return cfg()[rule][field] end
  box.reload = function() box:SetText(tostring(read() or "")) end
  local function commit()
    local n = tonumber(box:GetText())
    if n and n >= (min or 1) then cfg()[rule][field] = n end
    box.reload()
  end
  box:SetScript("OnEnterPressed", function(self) commit() self:ClearFocus() end)
  box:SetScript("OnEditFocusLost", commit)
end

local function hint(parent, text)
  local fs = parent:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
  fs:SetTextColor(Theme:Color("grey"))
  fs:SetText(text)
  return fs
end

local ROW_H = 52

local function buildPage(body)
  local ui = { inputs = {}, toggles = {}, dds = {} }
  body.alarms = ui

  local mute = W.Toggle(body, "Mute all alarms",
    function() return cfg().muted end,
    function(on) cfg().muted = on end)
  mute:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
  ui.toggles[#ui.toggles + 1] = mute
  local note = hint(body, "At most one alarm per 2 seconds.")
  note:SetPoint("LEFT", mute.label, "RIGHT", 16, 0)

  for i, def in ipairs(RULES) do
    local rule = def.key
    local row = CreateFrame("Frame", nil, body)
    row:SetHeight(ROW_H - 4)
    local y = -30 - (i - 1) * ROW_H
    row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, y)
    row:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, y)

    local enable = W.Toggle(row, def.label,
      function() return cfg()[rule].enabled end,
      function(on) cfg()[rule].enabled = on end)
    enable:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    ui.toggles[#ui.toggles + 1] = enable

    -- Line 1, right of the label: thresholds.
    if rule == "value" then
      local l = hint(row, "at least")
      l:SetPoint("LEFT", row, "TOPLEFT", 160, -12)
      local box = newInput(row, 60)
      box:SetPoint("LEFT", l, "RIGHT", 6, 0)
      bindNumber(box, "value", "gold", 1)
      ui.inputs[#ui.inputs + 1] = box
      local u = hint(row, "gold")
      u:SetPoint("LEFT", box, "RIGHT", 6, 0)
    elseif rule == "multiple" then
      local l = hint(row, "at least")
      l:SetPoint("LEFT", row, "TOPLEFT", 160, -12)
      local box = newInput(row, 36)
      box:SetPoint("LEFT", l, "RIGHT", 6, 0)
      bindNumber(box, "multiple", "n", 1)
      ui.inputs[#ui.inputs + 1] = box
      local l2 = hint(row, "x average, after")
      l2:SetPoint("LEFT", box, "RIGHT", 6, 0)
      local box2 = newInput(row, 36)
      box2:SetPoint("LEFT", l2, "RIGHT", 6, 0)
      bindNumber(box2, "multiple", "minNodes", 1)
      ui.inputs[#ui.inputs + 1] = box2
      local u = hint(row, "nodes")
      u:SetPoint("LEFT", box2, "RIGHT", 6, 0)
    end

    -- Line 2: sound, flash, test.
    local dd = W.Dropdown(row, 150, soundOptions,
      function() return soundFor(rule) end,
      function(v) cfg()[rule].sound = v end)
    dd:SetPoint("TOPLEFT", row, "TOPLEFT", 20, -24)
    ui.dds[#ui.dds + 1] = dd

    local flash = W.Toggle(row, "Flash",
      function() return flashFor(rule) end,
      function(on) cfg()[rule].flash = on end)
    flash:SetPoint("LEFT", dd, "RIGHT", 12, 0)
    ui.toggles[#ui.toggles + 1] = flash

    local test = W.RedButton(row, "Test", function() Alarms:Test(rule) end)
    test:SetSize(60, 20)
    test:SetPoint("LEFT", flash.label, "RIGHT", 16, 0)
  end
end

local function refreshPage(body)
  local ui = body.alarms
  if not ui then return end
  for _, t in ipairs(ui.toggles) do t:Refresh() end
  for _, d in ipairs(ui.dds) do d:Refresh() end
  for _, b in ipairs(ui.inputs) do
    if not b:HasFocus() then b.reload() end
  end
end

local PAGE = { id = "alarms", title = "Alarms", order = 60, build = buildPage, refresh = refreshPage }

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Alarms:OnEnable()
  state = {}
  HB:Listen(self, "HB_NODE_GATHERED", function(mod, gather) mod:OnGather(gather) end)
  HB:Listen(self, "HB_GOAL_REACHED", function(_, goal)
    fire({ kind = "goal", label = goalLabel(type(goal) == "table" and goal or {}) })
  end)
  HB:Listen(self, "HB_RARE_FOUND", function(_, itemID, attempts)
    fire({ kind = "rare", label = rareLabel(itemID, attempts) })
  end)
  HB:Listen(self, "HB_RECORD_BROKEN", function(_, name, value)
    fire({ kind = "record", label = recordLabel(name, value) })
  end)

  PAGE.icon = Theme.ICONS and Theme.ICONS.alarms
  HB.UI:RegisterPage(PAGE)
end

function Alarms:OnDisable()
  self:UnregisterAllMessages()
  if flashFrame then flashFrame:Hide() flashFrame:SetAlpha(0) end
  HB.UI:UnregisterPage("alarms")
end
