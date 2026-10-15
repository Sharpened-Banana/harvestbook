local ADDON, ns = ...

-- The main window ("box", spec §5.1/§5.2): title bar, decorative gold tab,
-- parchment sidebar with one button per registered page, content panel.
-- Also owns the minimap launcher, keybinding names and the built-in
-- Window and Settings pages. Companion.lua extends HB.UI.
--
-- Page contract: build(body) / refresh(body) receive the page BODY frame —
-- the content area below the gold page heading (drawn here from `title`),
-- inset 16 px. body.heading is the Widgets.Heading wrapper.

local HB = ns.HB
local Theme = ns.Theme
local W = ns.Widgets

BINDING_HEADER_HARVESTBOOK = "Harvestbook"
BINDING_NAME_HARVESTBOOK_TOGGLE = "Toggle Harvestbook"
BINDING_NAME_HARVESTBOOK_COMPANION = "Toggle companion"

local UI = {}
HB.UI = UI
LibStub("AceEvent-3.0"):Embed(UI)

local APP = "Harvestbook"
local TITLE_H = 56
local SIDEBAR_W = 190
local INSET = 8
local BUTTON_H = 44
local BUTTON_GAP = 4
local MIN_W, MIN_H = 700, 500
local THROTTLE = 0.25

local pages = {}     -- [id] = page record
local retired = {}   -- [id] = { build = fn, pageFrame = frame } kept for reuse
local sorted = {}    -- page records sorted by order
local current        -- id of the page shown in the content panel
local status = { text = "", color = "grey" }
local box            -- HarvestbookBox once built

---------------------------------------------------------------------------
-- Shared helpers (also used by Companion.lua)
---------------------------------------------------------------------------

-- Calls fn now when the last call was >= THROTTLE s ago, otherwise once
-- when the window has passed. `entry` holds the per-target timer state.
function UI._Throttle(entry, fn)
  if entry.timer then return end
  local wait = THROTTLE - (GetTime() - (entry.last or 0))
  if wait <= 0 then
    entry.last = GetTime()
    fn()
  else
    entry.timer = HB:ScheduleTimer(function()
      entry.timer = nil
      entry.last = GetTime()
      fn()
    end, wait)
  end
end

function UI._CancelThrottle(entry)
  if entry.timer then
    HB:CancelTimer(entry.timer)
    entry.timer = nil
  end
end

-- Stores {point, "UIParent", relPoint, x, y} from the frame's first anchor.
function UI._SavePoint(frame, store)
  local p, _, rp, x, y = frame:GetPoint(1)
  if p then store.point = { p, "UIParent", rp or p, x or 0, y or 0 } end
end

function UI._ApplyPoint(frame, point, fallback)
  local p = point or fallback
  frame:ClearAllPoints()
  frame:SetPoint(p[1], UIParent, p[3] or p[1], p[4] or 0, p[5] or 0)
end

-- Keeps WoW's layout cache from overriding our saved position.
function UI._NoLayoutCache(frame)
  if frame.SetDontSavePosition then frame:SetDontSavePosition(true) end
end

local function profile()
  return HB.db.profile
end

---------------------------------------------------------------------------
-- Box frame
---------------------------------------------------------------------------

local function windowDB()
  return profile().window
end

local function saveBoxPoint()
  UI._SavePoint(box, windowDB())
end

local function applyBoxGeometry()
  local db = windowDB()
  UI._ApplyPoint(box, db.point, { "CENTER", "UIParent", "CENTER", 0, 0 })
  box:SetSize(math.max(MIN_W, db.w or 840), math.max(MIN_H, db.h or 715))
end

-- Re-anchors by TOPLEFT so collapsing/expanding keeps the title bar in place.
local function anchorTopLeft()
  local left, top = box:GetLeft(), box:GetTop()
  if not (left and top) then return end
  box:ClearAllPoints()
  box:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
  saveBoxPoint()
end

local function setCollapsed(collapsed)
  box.collapsed = collapsed and true or false
  anchorTopLeft()
  box.sidebar:SetShown(not box.collapsed)
  box.content:SetShown(not box.collapsed)
  box.grip:SetShown(not box.collapsed)
  if box.collapsed then
    box:SetHeight(TITLE_H + 2)
  else
    box:SetHeight(math.max(MIN_H, windowDB().h or 715))
    local p = current and pages[current]
    if p and p.dirty and p.body then
      p.dirty = false
      if p.refresh then HB:SafeCall("UI", p.refresh, p.body) end
    end
  end
end

local function applyStatus()
  if not box then return end
  box.status:SetText(status.text or "")
  box.status:SetTextColor(Theme:Color(status.color or "grey"))
end

local function buildTitleBar(f)
  local bar = CreateFrame("Frame", nil, f, "BackdropTemplate")
  bar:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
  bar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
  bar:SetHeight(TITLE_H)
  Theme:Backdrop(bar, "titleBar")
  bar:EnableMouse(true)
  bar:RegisterForDrag("LeftButton")
  bar:SetScript("OnDragStart", function() f:StartMoving() end)
  bar:SetScript("OnDragStop", function()
    f:StopMovingOrSizing()
    saveBoxPoint()
  end)
  f.titleBar = bar

  local iconBorder = bar:CreateTexture(nil, "ARTWORK", nil, 1)
  iconBorder:SetTexture(Theme.WHITE)
  iconBorder:SetVertexColor(0, 0, 0, 0.85)
  iconBorder:SetSize(38, 38)
  iconBorder:SetPoint("LEFT", bar, "LEFT", 12, 0)
  local icon = bar:CreateTexture(nil, "ARTWORK", nil, 2)
  icon:SetSize(36, 36)
  icon:SetPoint("CENTER", iconBorder, "CENTER")
  icon:SetTexture(Theme.ICONS.herb)
  icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  local title = bar:CreateFontString(nil, "OVERLAY", "HarvestbookFontTitle")
  title:SetPoint("LEFT", iconBorder, "RIGHT", 12, 0)
  title:SetText("HARVESTBOOK")

  -- Parented to the box (not the bar) so the template's default handler
  -- could only ever hide the box; we set our own anyway.
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("RIGHT", bar, "RIGHT", -10, 0)
  close:SetFrameLevel(bar:GetFrameLevel() + 2)
  close:SetScript("OnClick", function() f:Hide() end)

  f.status = bar:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  f.status:SetPoint("RIGHT", close, "LEFT", -14, 0)
  f.status:SetPoint("LEFT", title, "RIGHT", 16, 0)
  f.status:SetJustifyH("RIGHT")
  f.status:SetWordWrap(false)

  -- Decorative gold tab hanging below the title bar; double-click collapses.
  local tab = CreateFrame("Button", nil, f, "BackdropTemplate")
  tab:SetSize(56, 24)
  tab:SetPoint("TOP", bar, "BOTTOM", 0, 10)
  tab:SetFrameLevel(bar:GetFrameLevel() + 5)
  Theme:Backdrop(tab, "gold", "contentBorder")
  local knob = tab:CreateTexture(nil, "OVERLAY")
  knob:SetTexture(Theme.WHITE)
  knob:SetVertexColor(Theme:Color("content"))
  knob:SetSize(8, 6)
  knob:SetPoint("CENTER", tab, "CENTER", 0, -2)
  tab:SetScript("OnDoubleClick", function() setCollapsed(not f.collapsed) end)
  tab:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Double-click to " .. (f.collapsed and "expand" or "collapse"))
    GameTooltip:Show()
  end)
  tab:SetScript("OnLeave", function() GameTooltip:Hide() end)
  f.goldTab = tab
end

local function buildGrip(f)
  local grip = CreateFrame("Button", nil, f)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
  grip:SetFrameLevel(f:GetFrameLevel() + 10)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  grip:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" and not f.collapsed then f:StartSizing("BOTTOMRIGHT") end
  end)
  grip:SetScript("OnMouseUp", function()
    f:StopMovingOrSizing()
    local db = windowDB()
    db.w, db.h = math.floor(f:GetWidth() + 0.5), math.floor(f:GetHeight() + 0.5)
    saveBoxPoint()
  end)
  f.grip = grip
end

local function buildBox()
  local f = CreateFrame("Frame", "HarvestbookBox", UIParent, "BackdropTemplate")
  box = f
  f:Hide()
  f:SetFrameStrata("MEDIUM")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:SetResizable(true)
  if f.SetResizeBounds then
    f:SetResizeBounds(MIN_W, MIN_H)
  elseif f.SetMinResize then
    f:SetMinResize(MIN_W, MIN_H)
  end
  f:EnableMouse(true)
  UI._NoLayoutCache(f)
  Theme:Backdrop(f, "frame", "border")
  tinsert(UISpecialFrames, "HarvestbookBox")

  buildTitleBar(f)

  local sidebar = CreateFrame("Frame", nil, f, "BackdropTemplate")
  sidebar:SetPoint("TOPLEFT", f.titleBar, "BOTTOMLEFT", INSET - 1, -INSET - 2)
  sidebar:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", INSET, INSET)
  sidebar:SetWidth(SIDEBAR_W)
  Theme:Backdrop(sidebar, "parchmentBorder")
  sidebar.buttons = {}
  f.sidebar = sidebar

  local content = CreateFrame("Frame", nil, f, "BackdropTemplate")
  content:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 10, 0)
  content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -INSET, INSET)
  Theme:Backdrop(content, "content", "contentBorder")
  f.content = content

  buildGrip(f)

  f:SetScript("OnShow", function()
    if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN) end
    local id = current
    if not (id and pages[id]) then id = windowDB().page end
    UI:ShowPage(id)
  end)
  f:SetScript("OnHide", function()
    if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE) end
  end)

  applyBoxGeometry()
  applyStatus()
  UI:RebuildSidebar()
  return f
end

local function ensureBox()
  return box or buildBox()
end

---------------------------------------------------------------------------
-- Sidebar
---------------------------------------------------------------------------

local function sortPages()
  wipe(sorted)
  for _, p in pairs(pages) do sorted[#sorted + 1] = p end
  table.sort(sorted, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.id < b.id
  end)
end

function UI:RebuildSidebar()
  sortPages()
  if not box then return end
  local sidebar = box.sidebar
  for i, p in ipairs(sorted) do
    local btn = sidebar.buttons[i]
    if not btn then
      btn = W.SidebarButton(sidebar, nil, "")
      btn:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 0, -(i - 1) * (BUTTON_H + BUTTON_GAP))
      btn:SetPoint("RIGHT", sidebar, "RIGHT", 0, 0)
      btn:SetHeight(BUTTON_H)
      btn:SetScript("OnClick", function(self) UI:ShowPage(self.pageID) end)
      sidebar.buttons[i] = btn
    end
    btn.pageID = p.id
    btn:SetIcon(p.icon)
    btn:SetLabel(p.title)
    btn:SetSelected(p.id == current)
    btn:Show()
  end
  for i = #sorted + 1, #sidebar.buttons do
    sidebar.buttons[i]:Hide()
  end
end

---------------------------------------------------------------------------
-- Pages
---------------------------------------------------------------------------

local function isShowing(p)
  return box ~= nil and box:IsShown() and not box.collapsed and current == p.id and p.body ~= nil
end

local function runRefresh(p)
  if not isShowing(p) then
    p.dirty = true
    return
  end
  p.dirty = false
  if p.refresh then HB:SafeCall("UI", p.refresh, p.body) end
end

local function buildPage(p)
  if p.body then return end
  local reuse = retired[p.id]
  if reuse and reuse.build == p.build then
    retired[p.id] = nil
    p.pageFrame, p.body = reuse.pageFrame, reuse.body
    p.body.heading:SetText(p.title)
    return
  end
  local pf = CreateFrame("Frame", nil, box.content)
  pf:SetPoint("TOPLEFT", box.content, "TOPLEFT", 16, -12)
  pf:SetPoint("BOTTOMRIGHT", box.content, "BOTTOMRIGHT", -16, 12)
  pf:Hide()
  local heading = W.Heading(pf, p.title)
  heading:SetPoint("TOPLEFT", pf, "TOPLEFT", 0, 0)
  heading:SetPoint("TOPRIGHT", pf, "TOPRIGHT", 0, 0)
  local body = CreateFrame("Frame", nil, pf)
  body:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -10)
  body:SetPoint("BOTTOMRIGHT", pf, "BOTTOMRIGHT", 0, 0)
  body.heading = heading
  p.pageFrame, p.body = pf, body
  if p.build then HB:SafeCall("UI", p.build, body) end
end

-- def = { id, title, icon, order, build(body), refresh(body) }
function UI:RegisterPage(def)
  assert(type(def) == "table" and def.id, "RegisterPage: id required")
  if pages[def.id] then self:UnregisterPage(def.id) end
  pages[def.id] = {
    id = def.id,
    title = def.title or def.id,
    icon = def.icon,
    order = def.order or 50,
    build = def.build,
    refresh = def.refresh,
    throttle = {},
    dirty = true,
  }
  self:RebuildSidebar()
  if box and box:IsShown() and not (current and pages[current] and pages[current].body) then
    self:ShowPage(current or windowDB().page)
  end
end

function UI:UnregisterPage(id)
  local p = pages[id]
  if not p then return end
  UI._CancelThrottle(p.throttle)
  if p.pageFrame then
    p.pageFrame:Hide()
    retired[id] = { build = p.build, pageFrame = p.pageFrame, body = p.body }
  end
  pages[id] = nil
  if current == id then current = nil end
  self:RebuildSidebar()
  if box and box:IsShown() and not current and sorted[1] then
    self:ShowPage(sorted[1].id)
  end
end

-- Shows the page (falls back to the first page when id is unknown) and
-- opens the box if it is closed.
function UI:ShowPage(id)
  ensureBox()
  sortPages()
  local p = pages[id] or sorted[1]
  if not p then return end
  if not box:IsShown() then
    current = p.id
    box:Show() -- OnShow calls back into ShowPage(current)
    return
  end
  for otherID, other in pairs(pages) do
    if otherID ~= p.id and other.pageFrame then other.pageFrame:Hide() end
  end
  current = p.id
  windowDB().page = p.id
  for _, btn in ipairs(box.sidebar.buttons) do
    btn:SetSelected(btn:IsShown() and btn.pageID == current)
  end
  buildPage(p)
  p.pageFrame:Show()
  UI._CancelThrottle(p.throttle)
  p.throttle.last = GetTime()
  p.dirty = true
  runRefresh(p)
end

-- Throttled (once per 0.25 s per page); hidden pages refresh on next show.
function UI:RefreshPage(id)
  local p = pages[id]
  if not p then return end
  if not isShowing(p) then
    p.dirty = true
    return
  end
  UI._Throttle(p.throttle, function() runRefresh(p) end)
end

function UI:Toggle()
  ensureBox()
  if box:IsShown() then box:Hide() else box:Show() end
end

function UI:SetStatus(text, colorKey)
  status.text, status.color = text or "", colorKey or "grey"
  applyStatus()
end

---------------------------------------------------------------------------
-- Slider (page-local; Widgets has none)
---------------------------------------------------------------------------

local function makeSlider(parent, label, minV, maxV, step, fmt, get, set)
  local holder = CreateFrame("Frame", nil, parent)
  holder:SetSize(280, 36)
  holder.label = holder:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  holder.label:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
  holder.label:SetText(label)
  holder.value = holder:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  holder.value:SetPoint("TOPRIGHT", holder, "TOPRIGHT", 0, 0)
  holder.value:SetTextColor(Theme:Color("gold"))

  local s = CreateFrame("Slider", nil, holder, "BackdropTemplate")
  s:SetOrientation("HORIZONTAL")
  s:SetHeight(14)
  s:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 0, 2)
  s:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", 0, 2)
  Theme:Backdrop(s, "barBg", "contentBorder")
  s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
  local thumb = s:GetThumbTexture()
  if thumb then thumb:SetSize(28, 28) end
  s:SetMinMaxValues(minV, maxV)
  s:SetValueStep(step)
  if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
  holder.slider = s

  local refreshing = false
  s:SetScript("OnValueChanged", function(_, v)
    v = math.floor(v / step + 0.5) * step
    holder.value:SetText(fmt(v))
    if not refreshing then set(v) end
  end)

  function holder:Refresh()
    refreshing = true
    local v = get()
    s:SetValue(v)
    holder.value:SetText(fmt(v))
    refreshing = false
  end
  holder:SetScript("OnShow", holder.Refresh)
  return holder
end

local function percent(v)
  return math.floor(v * 100 + 0.5) .. "%"
end

---------------------------------------------------------------------------
-- Built-in page: Window (companion options)
---------------------------------------------------------------------------

local function companionDB()
  return profile().companion
end

local function applyCompanion()
  if UI.ApplyCompanionSettings then UI:ApplyCompanionSettings() end
end

local function buildWindowPage(body)
  local y = 0
  local function place(widget, height, x)
    widget:SetPoint("TOPLEFT", body, "TOPLEFT", x or 0, -y)
    y = y + height
  end

  body.toggles = {}
  local function toggle(label, key, after)
    local cb = W.Toggle(body, label,
      function() return companionDB()[key] end,
      function(on)
        companionDB()[key] = on
        if after then after(on) end
      end)
    place(cb, 28)
    body.toggles[#body.toggles + 1] = cb
    return cb
  end

  toggle("Show companion", "shown", function(on)
    if UI.SetCompanionShown then UI:SetCompanionShown(on) end
  end)
  toggle("Lock position", "locked", applyCompanion)
  toggle("Show automatically when gathering", "autoShow")
  toggle("Hide when no session is active", "hideNoSession", applyCompanion)

  y = y + 10
  body.scale = makeSlider(body, "Scale", 0.5, 2, 0.05, percent,
    function() return companionDB().scale or 1 end,
    function(v) companionDB().scale = v; applyCompanion() end)
  place(body.scale, 46, 4)
  body.alpha = makeSlider(body, "Opacity", 0.2, 1, 0.05, percent,
    function() return companionDB().alpha or 0.9 end,
    function(v) companionDB().alpha = v; applyCompanion() end)
  place(body.alpha, 46, 4)

  y = y + 6
  local tabsHeading = W.Heading(body, "Companion tabs")
  tabsHeading:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
  tabsHeading:SetPoint("RIGHT", body, "RIGHT", 0, 0)
  y = y + tabsHeading:GetHeight() + 8
  body.tabsTop = y
  body.tabToggles = {}
end

local function refreshWindowPage(body)
  for _, cb in ipairs(body.toggles) do cb:Refresh() end
  body.scale:Refresh()
  body.alpha:Refresh()
  local tabs = UI.GetCompanionTabs and UI:GetCompanionTabs() or {}
  for i, tab in ipairs(tabs) do
    local cb = body.tabToggles[i]
    if not cb then
      local this
      this = W.Toggle(body, "",
        function() return this ~= nil and companionDB().tabs[this.tabID] ~= false end,
        function(on)
          companionDB().tabs[this.tabID] = on
          if UI.RefreshCompanionTabs then UI:RefreshCompanionTabs() end
        end)
      cb = this
      cb:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -(body.tabsTop + (i - 1) * 28))
      body.tabToggles[i] = cb
    end
    cb.tabID = tab.id
    cb:SetLabel(tab.title)
    cb:Refresh()
    cb:Show()
  end
  for i = #tabs + 1, #body.tabToggles do body.tabToggles[i]:Hide() end
end

---------------------------------------------------------------------------
-- Built-in page: Settings (module switches + full options)
---------------------------------------------------------------------------

local function moduleOn(name)
  local mod = HB:GetModule(name, true)
  if mod then return mod:IsEnabled() end
  local m = profile().modules[name]
  return m ~= nil and m.enabled ~= false
end

local function missingDeps(name)
  local missing = {}
  for _, dep in ipairs(HB.DEPENDS[name] or {}) do
    local mod = HB:GetModule(dep, true)
    if not (mod and mod:IsEnabled()) then
      missing[#missing + 1] = HB.MODULE_LABELS[dep] or dep
    end
  end
  return missing
end

local function buildSettingsPage(body)
  local heading = W.Heading(body, "Modules")
  heading:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
  heading:SetPoint("RIGHT", body, "RIGHT", 0, 0)
  local y = heading:GetHeight() + 8

  body.switches = {}
  for _, name in ipairs(HB.MODULE_ORDER) do
    local cb = W.Toggle(body, HB.MODULE_LABELS[name] or name,
      function() return moduleOn(name) end,
      function(on)
        HB:SetModuleEnabled(name, on)
        UI:RefreshPage("settings")
      end)
    cb:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
    cb.moduleName = name
    cb.hint = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
    cb.hint:SetPoint("LEFT", cb, "LEFT", 170, 0)
    cb.hint:SetTextColor(Theme:Color("grey"))
    body.switches[#body.switches + 1] = cb
    y = y + 28
  end

  local note = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
  note:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -(y + 4))
  note:SetPoint("RIGHT", body, "RIGHT", 0, 0)
  note:SetJustifyH("LEFT")
  note:SetTextColor(Theme:Color("grey"))
  note:SetText("Disabling a module never deletes its data.")

  local all = W.RedButton(body, "All options\226\128\166", function()
    local dialog = LibStub("AceConfigDialog-3.0", true)
    local registry = LibStub("AceConfigRegistry-3.0", true)
    if dialog and registry and registry:GetOptionsTable(APP) then
      dialog:Open(APP)
    else
      HB:Msg("options not available.")
    end
  end)
  all:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -14)
end

local function refreshSettingsPage(body)
  for _, cb in ipairs(body.switches) do
    local name = cb.moduleName
    local missing = missingDeps(name)
    local available = HB:GetModule(name, true) ~= nil
    cb:Refresh()
    cb:SetEnabled(available and #missing == 0)
    if not available then
      cb.hint:SetText("Not loaded")
    elseif #missing > 0 then
      cb.hint:SetText("Requires " .. table.concat(missing, ", "))
    else
      cb.hint:SetText("")
    end
  end
end

UI:RegisterPage({
  id = "window", title = "Window", icon = Theme.ICONS.window, order = 90,
  build = buildWindowPage, refresh = refreshWindowPage,
})

UI:RegisterPage({
  id = "settings", title = "Settings", icon = Theme.ICONS.settings, order = 100,
  build = buildSettingsPage, refresh = refreshSettingsPage,
})

---------------------------------------------------------------------------
-- Minimap launcher (LibDataBroker + LibDBIcon)
---------------------------------------------------------------------------

local function sessionGoldPerHour()
  local mod = HB:GetModule("Session", true)
  if not (mod and mod:IsEnabled() and mod.GetCurrent) then return nil, false end
  local session = mod:GetCurrent()
  if not session then return nil, false end
  return ns.SessionMath.GoldPerHour(session, time(), HB.Pricing:Fn()), true
end

local function onTooltipShow(tt)
  local gr, gg, gb = Theme:Color("gold")
  local r, g, b = Theme:Color("grey")
  tt:AddLine("Harvestbook", gr, gg, gb)
  -- SafeCall returns fn's results, or nil on error (reported, not raised).
  local gph, hasSession = HB:SafeCall("UI", sessionGoldPerHour)
  if hasSession then
    local text = gph and ns.Format.Money(gph, profile().goldStyle) or "\226\128\148"
    tt:AddDoubleLine("Gold/hr:", text, 1, 1, 1, 1, 1, 1)
  end
  tt:AddLine("Left-click: open", r, g, b)
  tt:AddLine("Right-click: companion", r, g, b)
end

local function initLauncher()
  local ldb = LibStub("LibDataBroker-1.1", true)
  local icon = LibStub("LibDBIcon-1.0", true)
  if not ldb then return end
  local obj = ldb:GetDataObjectByName(APP) or ldb:NewDataObject(APP, {
    type = "launcher",
    icon = Theme.ICONS.herb,
    label = "Harvestbook",
    OnClick = function(_, button)
      if button == "RightButton" then UI:ToggleCompanion() else UI:Toggle() end
    end,
    OnTooltipShow = onTooltipShow,
  })
  if icon and obj and not icon:IsRegistered(APP) then
    icon:Register(APP, obj, profile().minimap)
  end
end

---------------------------------------------------------------------------
-- Init (called once from HB:OnInitialize, after HB.db exists)
---------------------------------------------------------------------------

function UI:OnProfileChanged()
  local icon = LibStub("LibDBIcon-1.0", true)
  if icon and icon:IsRegistered(APP) then icon:Refresh(APP, profile().minimap) end
  if box then
    box.collapsed = false
    box.sidebar:Show()
    box.content:Show()
    box.grip:Show()
    applyBoxGeometry()
    if box:IsShown() then self:ShowPage(windowDB().page) end
  end
  if self.OnCompanionProfileChanged then self:OnCompanionProfileChanged() end
end

function UI:Init()
  initLauncher()
  HB.db.RegisterCallback(self, "OnProfileChanged", "OnProfileChanged")
  HB.db.RegisterCallback(self, "OnProfileCopied", "OnProfileChanged")
  HB.db.RegisterCallback(self, "OnProfileReset", "OnProfileChanged")
  -- One handler per message per object (AceEvent); Companion hooks in here.
  self:RegisterMessage("HB_MODULE_TOGGLED", function(_, name, enabled)
    UI:RefreshPage("settings")
    if UI.OnCompanionModuleToggled then UI:OnCompanionModuleToggled(name, enabled) end
  end)
  if self.InitCompanion then self:InitCompanion() end
end
