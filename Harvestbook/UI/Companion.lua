local ADDON, ns = ...

-- The companion (spec §5.3): small translucent session window with a gold
-- title, right-aligned state text and an underlined tab strip. Modules add
-- tabs with HB.UI:RegisterCompanionTab; build(frame)/refresh(frame) receive
-- the tab's content frame (area below the tab strip).
--
-- Visibility: profile.companion.shown is the user's wish (toggle, X, Window
-- page). With autoShow, the next HB_NODE_GATHERED sets it again. With
-- hideNoSession, the frame also stays hidden while no session exists.

local HB = ns.HB
local Theme = ns.Theme
local UI = HB.UI

local WIDTH, HEIGHT = 300, 230
local PAD = 10
local TITLE_ROW = 26
local TAB_H = 20
local DEFAULT_POINT = { "CENTER", "UIParent", "CENTER", 320, -120 }

local tabs = {}       -- [id] = tab record
local retired = {}    -- [id] = { build, frame } kept for reuse
local visible = {}    -- shown tab records sorted by order
local activeTab       -- id
local stateText = ""
local sessionActive = false
local throttle = {}
local frame           -- HarvestbookCompanion once built

local function db()
  return HB.db.profile.companion
end

local function sortByOrder(list)
  table.sort(list, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.id < b.id
  end)
end

local function querySession()
  local mod = HB:GetModule("Session", true)
  if not (mod and mod:IsEnabled() and mod.GetCurrent) then return false end
  local s = HB:SafeCall("UI", mod.GetCurrent, mod) -- nil on error (reported)
  return s ~= nil and s.state ~= "stopped"
end

---------------------------------------------------------------------------
-- Tabs
---------------------------------------------------------------------------

local function refreshActive()
  local t = activeTab and tabs[activeTab]
  if not (frame and frame:IsShown() and t and t.frame) then return end
  if t.refresh then HB:SafeCall("UI", t.refresh, t.frame) end
end

local function buildTab(t)
  if t.frame then return end
  local old = retired[t.id]
  if old and old.build == t.build then
    retired[t.id] = nil
    t.frame = old.frame
    return
  end
  local f = CreateFrame("Frame", nil, frame.content)
  f:SetAllPoints(frame.content)
  f:Hide()
  t.frame = f
  if t.build then HB:SafeCall("UI", t.build, f) end
end

local function tabButton(i)
  local btn = frame.tabButtons[i]
  if btn then return btn end
  btn = CreateFrame("Button", nil, frame.strip)
  btn:SetHeight(TAB_H)
  btn.text = btn:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  btn.text:SetPoint("CENTER", btn, "CENTER", 0, 1)
  btn.underline = btn:CreateTexture(nil, "OVERLAY")
  btn.underline:SetTexture(Theme.WHITE)
  btn.underline:SetVertexColor(Theme:Color("gold"))
  btn.underline:SetHeight(2)
  btn.underline:SetPoint("BOTTOM", btn, "BOTTOM", 0, 0)
  btn:SetScript("OnClick", function(self) UI:ShowCompanionTab(self.tabID) end)
  btn:SetScript("OnEnter", function(self)
    if self.tabID ~= activeTab then self.text:SetTextColor(1, 1, 1) end
  end)
  btn:SetScript("OnLeave", function(self)
    if self.tabID ~= activeTab then self.text:SetTextColor(Theme:Color("grey")) end
  end)
  frame.tabButtons[i] = btn
  return btn
end

local function layoutTabs()
  local n = #visible
  local width = (WIDTH - 2 * PAD) / math.max(n, 1)
  for i, t in ipairs(visible) do
    local btn = tabButton(i)
    btn.tabID = t.id
    btn:ClearAllPoints()
    btn:SetPoint("TOPLEFT", frame.strip, "TOPLEFT", (i - 1) * width, 0)
    btn:SetWidth(width)
    btn.text:SetText(t.title)
    local active = t.id == activeTab
    btn.text:SetTextColor(Theme:Color(active and "gold" or "grey"))
    btn.underline:SetWidth(math.min(width - 4, math.ceil(btn.text:GetStringWidth()) + 24))
    btn.underline:SetShown(active)
    btn:Show()
  end
  for i = n + 1, #frame.tabButtons do frame.tabButtons[i]:Hide() end
end

function UI:RefreshCompanionTabs()
  wipe(visible)
  local tabDB = HB.db and db().tabs or {}
  for id, t in pairs(tabs) do
    if tabDB[id] ~= false then visible[#visible + 1] = t end
  end
  sortByOrder(visible)
  local found = false
  for _, t in ipairs(visible) do
    if t.id == activeTab then found = true break end
  end
  if not found then activeTab = visible[1] and visible[1].id or nil end
  if not frame then return end
  layoutTabs()
  for id, t in pairs(tabs) do
    if t.frame and id ~= activeTab then t.frame:Hide() end
  end
  local t = activeTab and tabs[activeTab]
  if t then
    buildTab(t)
    t.frame:Show()
    refreshActive()
  end
end

function UI:ShowCompanionTab(id)
  if not tabs[id] then return end
  activeTab = id
  self:RefreshCompanionTabs()
end

-- def = { id, title, order, build(frame), refresh(frame) }
function UI:RegisterCompanionTab(def)
  assert(type(def) == "table" and def.id, "RegisterCompanionTab: id required")
  if tabs[def.id] then self:UnregisterCompanionTab(def.id) end
  tabs[def.id] = {
    id = def.id,
    title = def.title or def.id,
    order = def.order or 50,
    build = def.build,
    refresh = def.refresh,
  }
  self:RefreshCompanionTabs()
  self:RefreshPage("window")
end

function UI:UnregisterCompanionTab(id)
  local t = tabs[id]
  if not t then return end
  if t.frame then
    t.frame:Hide()
    retired[id] = { build = t.build, frame = t.frame }
  end
  tabs[id] = nil
  self:RefreshCompanionTabs()
  self:RefreshPage("window")
end

-- All registered tabs sorted by order (the Window page lists them).
function UI:GetCompanionTabs()
  local list = {}
  for _, t in pairs(tabs) do list[#list + 1] = t end
  sortByOrder(list)
  return list
end

-- Throttled to once per 0.25 s; a hidden companion refreshes when shown.
function UI:RefreshCompanion()
  if not (frame and frame:IsShown()) then return end
  UI._Throttle(throttle, refreshActive)
end

function UI:SetCompanionState(text)
  stateText = text or ""
  if frame then frame.state:SetText(stateText) end
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------

local function applySettings()
  local c = db()
  frame:SetScale(c.scale or 1)
  frame:SetAlpha(c.alpha or 0.9)
  frame:SetMovable(not c.locked)
end

local function buildFrame()
  local f = CreateFrame("Frame", "HarvestbookCompanion", UIParent, "BackdropTemplate")
  frame = f
  f:Hide()
  f:SetSize(WIDTH, HEIGHT)
  f:SetFrameStrata("MEDIUM")
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  UI._NoLayoutCache(f)
  Theme:Backdrop(f, "barBg", "border")
  f:SetScript("OnDragStart", function(self)
    if not db().locked then self:StartMoving() end
  end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    UI._SavePoint(self, db())
  end)
  f:SetScript("OnShow", function()
    UI._CancelThrottle(throttle)
    refreshActive()
  end)

  local title = f:CreateFontString(nil, "OVERLAY", "HarvestbookFontHeading")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -8)
  title:SetText("Harvestbook")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetSize(20, 20)
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -3, -4)
  close:SetScript("OnClick", function() UI:SetCompanionShown(false) end)

  f.state = f:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  f.state:SetPoint("RIGHT", close, "LEFT", -4, 0)
  f.state:SetPoint("LEFT", title, "RIGHT", 8, 0)
  f.state:SetJustifyH("RIGHT")
  f.state:SetWordWrap(false)
  f.state:SetText(stateText)

  f.strip = CreateFrame("Frame", nil, f)
  f.strip:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(TITLE_ROW + 4))
  f.strip:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -(TITLE_ROW + 4))
  f.strip:SetHeight(TAB_H)
  f.tabButtons = {}

  f.content = CreateFrame("Frame", nil, f)
  f.content:SetPoint("TOPLEFT", f.strip, "BOTTOMLEFT", 0, -6)
  f.content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, 8)

  applySettings()
  UI._ApplyPoint(f, db().point, DEFAULT_POINT)
  UI:RefreshCompanionTabs()
  return f
end

local function wantVisible()
  local c = db()
  return c.shown and (not c.hideNoSession or sessionActive)
end

local function updateVisibility()
  if wantVisible() then
    if not frame then buildFrame() end
    frame:Show()
  elseif frame then
    frame:Hide()
  end
end

function UI:ApplyCompanionSettings()
  if frame then applySettings() end
  updateVisibility()
end

function UI:SetCompanionShown(on, quiet)
  db().shown = on and true or false
  if on and not quiet and db().hideNoSession and not sessionActive then
    HB:Msg("the companion is hidden while no session is active (see the Window page).")
  end
  updateVisibility()
  self:RefreshPage("window")
end

function UI:ToggleCompanion()
  self:SetCompanionShown(not (frame and frame:IsShown()))
end

---------------------------------------------------------------------------
-- Messages and profile changes (wired from UI:Init in Box.lua)
---------------------------------------------------------------------------

function UI:OnCompanionModuleToggled(name)
  if name == "Session" then
    sessionActive = querySession()
    updateVisibility()
  end
end

function UI:OnCompanionProfileChanged()
  if frame then
    applySettings()
    UI._ApplyPoint(frame, db().point, DEFAULT_POINT)
  end
  self:RefreshCompanionTabs()
  updateVisibility()
end

function UI:InitCompanion()
  self:RegisterMessage("HB_NODE_GATHERED", function()
    if db().autoShow and not db().shown then UI:SetCompanionShown(true, true) end
  end)
  self:RegisterMessage("HB_SESSION_CHANGED", function(_, state, session)
    if state == "stopped" or session == nil then
      sessionActive = false
    else
      sessionActive = true
    end
    updateVisibility()
  end)
  self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    sessionActive = querySession()
    updateVisibility()
  end)
  updateVisibility()
end
