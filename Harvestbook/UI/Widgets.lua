local ADDON, ns = ...

-- Reusable TackleBox-style building blocks for the box, companion and
-- module pages. Every constructor returns a frame or fontstring with the
-- methods documented above it.

local W = {}
ns.Widgets = W

local Theme = ns.Theme
local WHITE = Theme.WHITE
local ROW_HEIGHT = 18
local CELL_PAD = 4

local function setColor(region, key)
  region:SetTextColor(Theme:Color(key))
end

---------------------------------------------------------------------------
-- SidebarButton(parent, icon, label) -> btn
--   btn:SetSelected(bool), btn:SetLabel(text), btn:SetIcon(texture)
--   btn.icon, btn.label; set click behaviour with btn:SetScript("OnClick", ...)
---------------------------------------------------------------------------
function W.SidebarButton(parent, icon, label)
  local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
  btn:SetSize(200, 44)
  Theme:Backdrop(btn, "parchment", "parchmentBorder")

  local iconBorder = btn:CreateTexture(nil, "ARTWORK", nil, 1)
  iconBorder:SetTexture(WHITE)
  iconBorder:SetVertexColor(0, 0, 0, 0.85)
  iconBorder:SetSize(34, 34)
  iconBorder:SetPoint("LEFT", btn, "LEFT", 10, 0)

  btn.icon = btn:CreateTexture(nil, "ARTWORK", nil, 2)
  btn.icon:SetSize(32, 32)
  btn.icon:SetPoint("CENTER", iconBorder, "CENTER")
  btn.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  btn.label = btn:CreateFontString(nil, "OVERLAY", "HarvestbookFontSidebar")
  btn.label:SetPoint("LEFT", iconBorder, "RIGHT", 10, 0)
  btn.label:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
  btn.label:SetJustifyH("LEFT")
  btn.label:SetWordWrap(false)

  btn.accent = btn:CreateTexture(nil, "OVERLAY")
  btn.accent:SetTexture(WHITE)
  btn.accent:SetVertexColor(Theme:Color("gold"))
  btn.accent:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
  btn.accent:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 1, 1)
  btn.accent:SetWidth(3)
  btn.accent:Hide()

  local hl = btn:CreateTexture(nil, "HIGHLIGHT")
  hl:SetTexture(WHITE)
  hl:SetVertexColor(1, 1, 1, 0.15)
  hl:SetPoint("TOPLEFT", 1, -1)
  hl:SetPoint("BOTTOMRIGHT", -1, 1)

  function btn:SetIcon(tex) self.icon:SetTexture(tex) end
  function btn:SetLabel(text) self.label:SetText(text or "") end
  function btn:SetSelected(selected)
    self.selected = selected and true or false
    self:SetBackdropColor(Theme:Color(self.selected and "parchmentSelected" or "parchment"))
    self.accent:SetShown(self.selected)
  end

  btn:SetIcon(icon)
  btn:SetLabel(label)
  btn:SetSelected(false)
  return btn
end

---------------------------------------------------------------------------
-- RedButton(parent, label, onClick) -> btn
--   Dark red, gold text, width fits the label. onClick(btn, mouseButton).
--   btn:SetLabel(text) (re-fits width), btn.text; Enable/Disable greys text.
---------------------------------------------------------------------------
local function makeRedButton(parent, label, onClick, fixedSize)
  local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
  Theme:Backdrop(btn, "red", "redBorder")
  btn:SetHeight(fixedSize or 22)
  if fixedSize then btn:SetWidth(fixedSize) end

  btn.text = btn:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  btn.text:SetPoint("CENTER")
  setColor(btn.text, "gold")

  function btn:SetLabel(text)
    self.text:SetText(text or "")
    if not fixedSize then
      self:SetWidth(math.max(80, math.ceil(self.text:GetStringWidth()) + 28))
    end
  end

  btn:SetScript("OnEnter", function(self)
    if self:IsEnabled() then self:SetBackdropColor(Theme:Color("redHover")) end
  end)
  btn:SetScript("OnLeave", function(self) self:SetBackdropColor(Theme:Color("red")) end)
  btn:SetScript("OnMouseDown", function(self)
    if self:IsEnabled() then self.text:SetPoint("CENTER", 1, -1) end
  end)
  btn:SetScript("OnMouseUp", function(self) self.text:SetPoint("CENTER", 0, 0) end)
  btn:SetScript("OnDisable", function(self)
    setColor(self.text, "grey")
    self:SetBackdropColor(Theme:Color("red"))
  end)
  btn:SetScript("OnEnable", function(self) setColor(self.text, "gold") end)
  btn:SetScript("OnClick", function(self, button)
    if onClick then onClick(self, button) end
  end)

  btn:SetLabel(label)
  return btn
end

function W.RedButton(parent, label, onClick)
  return makeRedButton(parent, label, onClick)
end

---------------------------------------------------------------------------
-- Pager(parent, onPrev, onNext) -> pager
--   pager:SetText(str), pager:SetButtonsEnabled(prevOk, nextOk)
--   pager.prev, pager.next, pager.text. Caller sets width/anchors; height 22.
---------------------------------------------------------------------------
function W.Pager(parent, onPrev, onNext)
  local pager = CreateFrame("Frame", nil, parent)
  pager:SetHeight(22)

  pager.prev = makeRedButton(pager, "<", function() if onPrev then onPrev() end end, 22)
  pager.prev:SetPoint("LEFT", pager, "LEFT", 0, 0)
  pager.next = makeRedButton(pager, ">", function() if onNext then onNext() end end, 22)
  pager.next:SetPoint("RIGHT", pager, "RIGHT", 0, 0)

  pager.text = pager:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  pager.text:SetPoint("LEFT", pager.prev, "RIGHT", 6, 0)
  pager.text:SetPoint("RIGHT", pager.next, "LEFT", -6, 0)
  pager.text:SetJustifyH("CENTER")
  pager.text:SetWordWrap(false)
  setColor(pager.text, "gold")

  function pager:SetText(str) self.text:SetText(str or "") end
  function pager:SetButtonsEnabled(prevOk, nextOk)
    self.prev:SetEnabled(prevOk and true or false)
    self.next:SetEnabled(nextOk and true or false)
  end
  return pager
end

---------------------------------------------------------------------------
-- ColumnList(parent, columns) -> list
--   columns = { { key, title, width, align = "LEFT"|"RIGHT", sortable }, ... }
--   list:SetRows(rows, cellFn)  cellFn(row, key) -> text, iconTexture|nil, qualityAtlas|nil
--   list:Refresh()              re-render current rows, keeping scroll position
--   list:SetSort(key, descending)  shows the sort arrow on that header
--   Callbacks (assign as fields):
--     list.onSort(key)
--     list.onRowClick(row, mouseButton)
--     list.onRowEnter(row, rowFrame, cellKey)  -- re-fired (after onRowLeave)
--     list.onRowLeave(row, rowFrame)           -- when the hovered cell changes
--   Virtualized with WowScrollBoxList + MinimalScrollBar; rows are 18 px.
---------------------------------------------------------------------------
local function columnOffsets(columns)
  local xs, x = {}, CELL_PAD
  for i, col in ipairs(columns) do
    xs[i] = x
    x = x + (col.width or 80)
  end
  return xs
end

local function cellAt(list, rowFrame)
  local left = rowFrame:GetLeft()
  if not left then return nil end
  local x = GetCursorPosition() / rowFrame:GetEffectiveScale() - left
  for i, col in ipairs(list.columns) do
    local x0 = list.offsets[i]
    if x >= x0 and x < x0 + (col.width or 80) then return col.key end
  end
  return nil
end

local function fireLeave(list, rowFrame)
  local data = rowFrame.hoverData
  rowFrame.hoverData, rowFrame.hoverCell = nil, nil
  if data and list.onRowLeave then list.onRowLeave(data.row, rowFrame) end
end

local function fireEnter(list, rowFrame, cellKey)
  rowFrame.hoverData, rowFrame.hoverCell = rowFrame.data, cellKey
  if rowFrame.data and list.onRowEnter then
    list.onRowEnter(rowFrame.data.row, rowFrame, cellKey)
  end
end

-- Track cell changes (and data changes from scrolling) while hovered.
local function rowOnUpdate(rowFrame)
  local list = rowFrame.list
  local cellKey = cellAt(list, rowFrame)
  if rowFrame.data ~= rowFrame.hoverData or cellKey ~= rowFrame.hoverCell then
    fireLeave(list, rowFrame)
    fireEnter(list, rowFrame, cellKey)
  end
end

local function buildRow(list, rowFrame)
  rowFrame.list = list
  rowFrame:RegisterForClicks("LeftButtonUp", "RightButtonUp")

  rowFrame.stripe = rowFrame:CreateTexture(nil, "BACKGROUND")
  rowFrame.stripe:SetTexture(WHITE)
  rowFrame.stripe:SetVertexColor(1, 1, 1, 0.03)
  rowFrame.stripe:SetAllPoints()

  local hl = rowFrame:CreateTexture(nil, "HIGHLIGHT")
  hl:SetTexture(WHITE)
  hl:SetVertexColor(1, 1, 1, 0.08)
  hl:SetAllPoints()

  rowFrame.cells = {}
  for i, col in ipairs(list.columns) do
    local cell = CreateFrame("Frame", nil, rowFrame)
    cell:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", list.offsets[i], 0)
    cell:SetSize((col.width or 80) - CELL_PAD, ROW_HEIGHT)
    cell.icon = cell:CreateTexture(nil, "ARTWORK")
    cell.icon:SetSize(14, 14)
    cell.icon:SetPoint("LEFT", cell, "LEFT", 0, 0)
    cell.atlas = cell:CreateTexture(nil, "ARTWORK")
    cell.atlas:SetSize(14, 14)
    cell.text = cell:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
    cell.text:SetJustifyH(col.align == "RIGHT" and "RIGHT" or "LEFT")
    cell.text:SetWordWrap(false)
    rowFrame.cells[i] = cell
  end

  rowFrame:SetScript("OnClick", function(self, button)
    if self.data and list.onRowClick then list.onRowClick(self.data.row, button) end
  end)
  rowFrame:SetScript("OnEnter", function(self)
    fireEnter(list, self, cellAt(list, self))
    self:SetScript("OnUpdate", rowOnUpdate)
  end)
  rowFrame:SetScript("OnLeave", function(self)
    self:SetScript("OnUpdate", nil)
    fireLeave(list, self)
  end)
end

local function renderCell(cell, text, icon, atlas)
  local x = 0
  if icon then
    cell.icon:SetTexture(icon)
    cell.icon:Show()
    x = 16
  else
    cell.icon:Hide()
  end
  if atlas then
    cell.atlas:ClearAllPoints()
    cell.atlas:SetPoint("LEFT", cell, "LEFT", x, 0)
    cell.atlas:SetAtlas(atlas)
    cell.atlas:Show()
    x = x + 16
  else
    cell.atlas:Hide()
  end
  cell.text:ClearAllPoints()
  cell.text:SetPoint("LEFT", cell, "LEFT", x, 0)
  cell.text:SetPoint("RIGHT", cell, "RIGHT", 0, 0)
  cell.text:SetText(text ~= nil and tostring(text) or "")
end

local function initRow(list, rowFrame, data)
  if not rowFrame.cells then buildRow(list, rowFrame) end
  rowFrame.data = data
  rowFrame.stripe:SetShown(data.index % 2 == 0)
  local cellFn = list.cellFn
  for i, col in ipairs(list.columns) do
    local text, icon, atlas
    if cellFn then text, icon, atlas = cellFn(data.row, col.key) end
    renderCell(rowFrame.cells[i], text, icon, atlas)
  end
end

local function buildHeader(list)
  local header = CreateFrame("Frame", nil, list)
  header:SetPoint("TOPLEFT", list, "TOPLEFT", 0, 0)
  header:SetPoint("TOPRIGHT", list, "TOPRIGHT", 0, 0)
  header:SetHeight(ROW_HEIGHT)
  list.header = header
  list.headerButtons = {}

  for i, col in ipairs(list.columns) do
    local hb = CreateFrame("Button", nil, header)
    hb:SetPoint("TOPLEFT", header, "TOPLEFT", list.offsets[i], 0)
    hb:SetSize((col.width or 80) - CELL_PAD, ROW_HEIGHT)
    local right = col.align == "RIGHT"

    hb.text = hb:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
    hb.text:SetPoint(right and "RIGHT" or "LEFT", hb, right and "RIGHT" or "LEFT", 0, 0)
    hb.text:SetText(col.title or "")
    setColor(hb.text, "gold")

    hb.arrow = hb:CreateTexture(nil, "OVERLAY")
    hb.arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
    hb.arrow:SetSize(9, 8)
    hb.arrow:SetVertexColor(Theme:Color("gold"))
    if right then
      hb.arrow:SetPoint("RIGHT", hb.text, "LEFT", -3, 0)
    else
      hb.arrow:SetPoint("LEFT", hb.text, "RIGHT", 3, 0)
    end
    hb.arrow:Hide()

    if col.sortable then
      hb:SetScript("OnClick", function()
        if list.onSort then list.onSort(col.key) end
      end)
      local hl = hb:CreateTexture(nil, "HIGHLIGHT")
      hl:SetTexture(WHITE)
      hl:SetVertexColor(1, 0.82, 0, 0.08)
      hl:SetAllPoints()
    else
      hb:EnableMouse(false)
    end
    list.headerButtons[col.key] = hb
  end
end

function W.ColumnList(parent, columns)
  local list = CreateFrame("Frame", nil, parent)
  list.columns = columns
  list.offsets = columnOffsets(columns)
  list.rows = {}
  buildHeader(list)

  list.scrollBar = CreateFrame("EventFrame", nil, list, "MinimalScrollBar")
  list.scrollBar:SetPoint("TOPRIGHT", list.header, "BOTTOMRIGHT", -2, -4)
  list.scrollBar:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -2, 4)
  if list.scrollBar.SetHideIfUnscrollable then
    list.scrollBar:SetHideIfUnscrollable(true)
  end

  list.scrollBox = CreateFrame("Frame", nil, list, "WowScrollBoxList")
  list.scrollBox:SetPoint("TOPLEFT", list.header, "BOTTOMLEFT", 0, -2)
  list.scrollBox:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -16, 0)

  local view = CreateScrollBoxListLinearView()
  view:SetElementExtent(ROW_HEIGHT)
  view:SetElementInitializer("Button", function(rowFrame, data)
    initRow(list, rowFrame, data)
  end)
  ScrollUtil.InitScrollBoxListWithScrollBar(list.scrollBox, list.scrollBar, view)

  function list:SetRows(rows, cellFn)
    self.rows = rows or {}
    if cellFn then self.cellFn = cellFn end
    local wrapped = {}
    for i, row in ipairs(self.rows) do
      wrapped[i] = { row = row, index = i }
    end
    local retain = ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition
    self.scrollBox:SetDataProvider(CreateDataProvider(wrapped), retain)
  end

  function list:Refresh()
    self:SetRows(self.rows, self.cellFn)
  end

  function list:SetSort(key, descending)
    self.sortKey, self.sortDesc = key, descending and true or false
    for k, hb in pairs(self.headerButtons) do
      if k == key then
        if self.sortDesc then
          hb.arrow:SetTexCoord(0, 0.5625, 0, 1)
        else
          hb.arrow:SetTexCoord(0, 0.5625, 1, 0)
        end
        hb.arrow:Show()
      else
        hb.arrow:Hide()
      end
    end
  end

  return list
end

---------------------------------------------------------------------------
-- CoinText(parent) -> fs
--   fs:SetCopper(copper) with Blizzard coin icons; nil shows "—".
---------------------------------------------------------------------------
local function coinString(copper)
  local neg = copper < 0
  local abs = math.floor(neg and -copper or copper)
  local s
  if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
    s = C_CurrencyInfo.GetCoinTextureString(abs)
  elseif GetCoinTextureString then
    s = GetCoinTextureString(abs)
  end
  if not s or s == "" then return ns.Format.Money(copper, "full") end
  return (neg and "-" or "") .. s
end

function W.CoinText(parent)
  local fs = parent:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  function fs:SetCopper(copper)
    if copper == nil then
      self:SetText("\226\128\148")
    else
      self:SetText(coinString(copper))
    end
  end
  return fs
end

---------------------------------------------------------------------------
-- ProgressBar(parent) -> bar
--   bar:SetProgress(current, target, label, formatFn|nil)
--   Gold fill on dark background; label left, "current/target" right
--   (each number through formatFn, default Format.Thousands). target <= 0
--   shows an empty bar. Default height 16; caller sets width/anchors.
---------------------------------------------------------------------------
function W.ProgressBar(parent)
  local bar = CreateFrame("StatusBar", nil, parent, "BackdropTemplate")
  bar:SetHeight(16)
  Theme:Backdrop(bar, "barBg", "contentBorder")
  bar:SetStatusBarTexture(WHITE)
  bar:SetStatusBarColor(Theme:Color("gold"))
  bar:GetStatusBarTexture():SetAlpha(0.75)
  bar:SetMinMaxValues(0, 1)
  bar:SetValue(0)

  bar.label = bar:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
  bar.label:SetPoint("LEFT", bar, "LEFT", 5, 0)
  bar.label:SetJustifyH("LEFT")
  bar.label:SetWordWrap(false)
  bar.value = bar:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
  bar.value:SetPoint("RIGHT", bar, "RIGHT", -5, 0)
  bar.value:SetJustifyH("RIGHT")
  bar.label:SetPoint("RIGHT", bar.value, "LEFT", -6, 0)

  function bar:SetProgress(current, target, label, formatFn)
    current, target = current or 0, target or 0
    local fmt = formatFn or ns.Format.Thousands
    if target <= 0 then
      self:SetMinMaxValues(0, 1)
      self:SetValue(0)
    else
      self:SetMinMaxValues(0, target)
      self:SetValue(math.max(0, math.min(current, target)))
    end
    self.label:SetText(label or "")
    self.value:SetText(fmt(current) .. "/" .. fmt(target))
  end
  return bar
end

---------------------------------------------------------------------------
-- Heading(parent, text) -> heading (Frame)
--   A wrapper frame (height = text height + 6) holding the gold heading text
--   and a 1 px gold underline along its bottom edge. The caller anchors it
--   and gives it a width, e.g. TOPLEFT + TOPRIGHT of the content area; the
--   underline spans the full width. Hide/Show the wrapper to hide both.
--   heading:SetText(str), heading.text (FontString), heading.underline.
---------------------------------------------------------------------------
function W.Heading(parent, text)
  local heading = CreateFrame("Frame", nil, parent)
  local fs = heading:CreateFontString(nil, "OVERLAY", "HarvestbookFontHeading")
  fs:SetPoint("TOPLEFT", heading, "TOPLEFT", 0, 0)
  fs:SetPoint("TOPRIGHT", heading, "TOPRIGHT", 0, 0)
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(false)
  heading.text = fs

  local line = heading:CreateTexture(nil, "ARTWORK")
  line:SetTexture(WHITE)
  line:SetVertexColor(Theme:Color("gold"))
  line:SetAlpha(0.7)
  line:SetHeight(1)
  line:SetPoint("BOTTOMLEFT", heading, "BOTTOMLEFT", 0, 0)
  line:SetPoint("BOTTOMRIGHT", heading, "BOTTOMRIGHT", 0, 0)
  heading.underline = line

  function heading:SetText(str)
    self.text:SetText(str or "")
    local _, size = self.text:GetFont()
    local h = math.max(self.text:GetStringHeight() or 0, size or 16)
    self:SetHeight(math.ceil(h) + 6)
  end

  heading:SetText(text)
  return heading
end

---------------------------------------------------------------------------
-- Dropdown(parent, width, options, get, set) -> dd
--   options: list of { value = any, text = string }, or a function returning
--   that list (evaluated whenever the menu is built/opened).
--   get() -> current value; set(value) on selection. dd:Refresh() re-reads
--   get() and updates the shown text.
--   Uses the Retail menu API (DropdownButton + WowStyle1DropdownTemplate);
--   if unavailable, falls back to a red button that cycles the options.
---------------------------------------------------------------------------
local function resolveOptions(options)
  if type(options) == "function" then return options() or {} end
  return options or {}
end

local function currentText(options, get)
  local cur = get and get()
  for _, opt in ipairs(resolveOptions(options)) do
    if opt.value == cur then return opt.text end
  end
  return ""
end

function W.Dropdown(parent, width, options, get, set)
  local ok, dd = pcall(CreateFrame, "DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
  if ok and dd and dd.SetupMenu then
    dd:SetWidth(width or 160)
    dd:SetupMenu(function(owner, rootDescription)
      for _, opt in ipairs(resolveOptions(options)) do
        rootDescription:CreateRadio(opt.text,
          function(value) return get and get() == value end,
          function(value)
            if set then set(value) end
          end,
          opt.value)
      end
    end)
    function dd:Refresh()
      if self.GenerateMenu then self:GenerateMenu() end
    end
    dd:HookScript("OnShow", function(self) self:Refresh() end)
    dd:Refresh()
    return dd
  end

  -- Fallback: click cycles to the next option.
  local btn = makeRedButton(parent, "", function(self)
    local list, cur = resolveOptions(options), get and get()
    if #list == 0 then return end
    local nextIndex = 1
    for i, opt in ipairs(list) do
      if opt.value == cur then nextIndex = (i % #list) + 1 end
    end
    if set then set(list[nextIndex].value) end
    self:Refresh()
  end)
  btn:SetWidth(width or 160)
  function btn:Refresh()
    self.text:SetText(currentText(options, get))
  end
  btn:HookScript("OnShow", function(self) self:Refresh() end)
  btn:Refresh()
  return btn
end

---------------------------------------------------------------------------
-- Toggle(parent, label, get, set) -> checkbutton
--   get() -> bool, set(bool). cb:Refresh() re-reads get(); also on show.
--   cb.label fontstring; disabling greys the label.
---------------------------------------------------------------------------
function W.Toggle(parent, label, get, set)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetSize(24, 24)
  if cb.Text then cb.Text:SetText("") end

  cb.label = cb:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
  cb.label:SetJustifyH("LEFT")

  function cb:SetLabel(text)
    self.label:SetText(text or "")
    self:SetHitRectInsets(0, -math.ceil(self.label:GetStringWidth()) - 4, 0, 0)
  end
  function cb:Refresh()
    self:SetChecked(get and get() and true or false)
  end

  cb:SetScript("OnClick", function(self)
    local on = self:GetChecked() and true or false
    if SOUNDKIT and PlaySound then
      PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
    end
    if set then set(on) end
  end)
  cb:HookScript("OnShow", function(self) self:Refresh() end)
  cb:HookScript("OnDisable", function(self) setColor(self.label, "grey") end)
  cb:HookScript("OnEnable", function(self) setColor(self.label, "white") end)

  cb:SetLabel(label)
  cb:Refresh()
  return cb
end
