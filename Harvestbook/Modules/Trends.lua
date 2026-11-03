local ADDON, ns = ...
local L = ns.L

-- Price trends module: records the market price of what you gather, one per
-- day (global.priceHistory, see Logic/PriceTrend), and charts it on a page.
--
-- Listens to HB_NODE_GATHERED and HB_BONUS_LOOT. Only market sources are kept:
-- vendor prices don't trend and overrides are the user's own. The history holds
-- the cache's listing price, so the auction house cut toggle can't move it.
-- Turning the module off stops recording and keeps the history.

local HB = ns.HB
local PriceChain = ns.PriceChain
local Trend = ns.PriceTrend
local Format = ns.Format
local Theme = ns.Theme
local W = ns.Widgets

local Trends = HB:NewModule("Trends", "AceEvent-3.0")

local DASH = "\226\128\148"
local WHITE = Theme.WHITE
local DAY_FORMAT = "%Y-%m-%d"

local LINE_THICKNESS = 1.5
local DOT_SIZE = 3

-- This login only.
local selectedKey
local sortKey, sortDesc = "pct7", true

local function colorCode(key)
  local r, g, b = Theme:Color(key)
  return string.format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5),
    math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

local GREEN, RED, GREY, GOLD = colorCode("green"), colorCode("redText"), colorCode("grey"), colorCode("gold")

local function money(copper) return Format.Money(copper, HB.db.profile.goldStyle) end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------

-- Dated by when the cache read the price: a cached price from an earlier day
-- must not pass for today's (the cache is only refreshed outside the gather
-- path), or the history would show a flat line that never happened.
local function recordItem(history, priceFn, it)
  local _, source = priceFn(it.itemID, it.quality, it.link)
  if not PriceChain.AH_SOURCES[source] then return false end
  -- No cache entry means a provisional price (see Core/Pricing): skip it.
  local cached = HB.Pricing:GetCached(it.itemID, it.quality)
  if not cached or cached.source ~= source then return false end
  local key = ns.SessionMath.ItemKey(it.itemID, it.quality)
  local day = date(DAY_FORMAT, cached.time or time())
  local isNew = Trend.Record(history, key, day, cached.value)
  if isNew then Trend.Prune(history) end
  return true
end

local function onLoot(_, payload)
  local history, priceFn, recorded = HB.db.global.priceHistory, HB.Pricing:Fn(), false
  for _, it in ipairs(payload and payload.items or {}) do
    if it.itemID and recordItem(history, priceFn, it) then recorded = true end
  end
  if recorded then HB.UI:RefreshPage("trends") end
end

---------------------------------------------------------------------------
-- Page
---------------------------------------------------------------------------

-- Columns + 4 px pad + 16 px scrollbar must be <= 440: 420.
local COLUMNS = {
  { key = "name", title = L["Item"], width = 200, align = "LEFT", sortable = true },
  { key = "latest", title = L["Latest"], width = 80, align = "RIGHT", sortable = true },
  { key = "pct7", title = L["7 days"], width = 70, align = "RIGHT", sortable = true },
  { key = "pct30", title = L["30 days"], width = 70, align = "RIGHT", sortable = true },
}

local LABEL_GUTTER = 76 -- left of the plot: min and max price labels
local TITLE_HEIGHT = 16
local PLOT_TOP = TITLE_HEIGHT + 4
local PLOT_HEIGHT = 110
local PLOT_PAD = 4 -- keeps the line off the plot's border
local LIST_TOP = PLOT_TOP + PLOT_HEIGHT + 18 -- leaves room for the date labels

local function pctText(pct)
  if pct == nil then return GREY .. DASH .. "|r" end
  local text = string.format("%.1f", math.abs(pct))
  if text == "0.0" then return "0.0%" end
  if pct > 0 then return GREEN .. "+" .. text .. "%|r" end
  return RED .. "-" .. text .. "%|r"
end

local function cell(row, key)
  if key == "name" then
    local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(row.itemID) or nil
    local name = row.itemKey == selectedKey and (GOLD .. row.name .. "|r") or row.name
    return name, icon, HB:ItemQualityInfo(row).small or nil
  elseif key == "latest" then
    return row.latest and money(row.latest) or (GREY .. DASH .. "|r")
  end
  return pctText(row[key])
end

local function buildRows()
  local today, rows = date(DAY_FORMAT), {}
  for itemKey, days in pairs(HB.db.global.priceHistory) do
    local itemID, quality = Trend.ParseKey(itemKey)
    if itemID then
      local row = Trend.Summary(days, today)
      row.itemKey, row.itemID, row.quality = itemKey, itemID, quality
      row.name = HB:ItemName(itemID)
      rows[#rows + 1] = row
    end
  end
  return rows
end

-- Line objects when the client has them (guarded); the dots alone otherwise.
local function acquireLine(ui, i)
  if ui.lines[i] then return ui.lines[i] end
  if not ui.plot.CreateLine then return nil end
  local ok, line = pcall(ui.plot.CreateLine, ui.plot, nil, "ARTWORK")
  if not ok or not line then return nil end
  line:SetColorTexture(Theme:Color("gold"))
  line:SetThickness(LINE_THICKNESS)
  ui.lines[i] = line
  return line
end

local function acquireDot(ui, i)
  local dot = ui.dots[i]
  if not dot then
    dot = ui.plot:CreateTexture(nil, "OVERLAY")
    dot:SetTexture(WHITE)
    dot:SetVertexColor(Theme:Color("gold"))
    dot:SetSize(DOT_SIZE, DOT_SIZE)
    ui.dots[i] = dot
  end
  return dot
end

local function drawChart(ui)
  local row = ui.selected
  local series = row and row.series or {}
  ui.title:SetText(row and (row.name .. HB:ItemQualityMarkup(row, 14)) or "")

  local w = (ui.plot:GetWidth() or 0) - 2 * PLOT_PAD
  local h = (ui.plot:GetHeight() or 0) - 2 * PLOT_PAD
  local points, lo, hi = Trend.ChartPoints(series, w, h)
  local drawn = #points >= 2 and w > 1 and h > 1
  if not drawn then points = {} end

  for i, p in ipairs(points) do
    local dot = acquireDot(ui, i)
    dot:ClearAllPoints()
    dot:SetPoint("CENTER", ui.plot, "BOTTOMLEFT", p.x + PLOT_PAD, p.y + PLOT_PAD)
    dot:Show()
    if i > 1 then
      local line = acquireLine(ui, i - 1)
      if line then
        local a = points[i - 1]
        line:SetStartPoint("BOTTOMLEFT", ui.plot, a.x + PLOT_PAD, a.y + PLOT_PAD)
        line:SetEndPoint("BOTTOMLEFT", ui.plot, p.x + PLOT_PAD, p.y + PLOT_PAD)
        line:Show()
      end
    end
  end
  for i = #points + 1, #ui.dots do ui.dots[i]:Hide() end
  for i = math.max(#points, 1), #ui.lines do ui.lines[i]:Hide() end

  ui.maxLabel:SetText(drawn and money(hi) or "")
  ui.minLabel:SetText(drawn and money(lo) or "")
  ui.firstDate:SetText(drawn and series[1].day or "")
  ui.lastDate:SetText(drawn and series[#series].day or "")

  if drawn then
    ui.message:SetText("")
  elseif not row then
    ui.message:SetText(L["No prices recorded yet. Gather a material that has an Auctionator or TSM price."])
  else
    ui.message:SetText(L["Not enough history for a chart yet: it needs prices from at least two days in the last %d."]:format(Trend.WINDOW_DAYS))
  end
end

local function selectRow(ui, row)
  selectedKey = row and row.itemKey or nil
  ui.selected = row
end

local function findRow(rows, itemKey)
  for _, row in ipairs(rows) do
    if row.itemKey == itemKey then return row end
  end
  return nil
end

local function refreshPage(body)
  local ui = body.trends
  if not ui then return end

  local rows = Trend.SortRows(buildRows(), sortKey, sortDesc)
  ui.rows = rows
  -- The selected item can leave the data (pruned, or Reset all data).
  selectRow(ui, findRow(rows, selectedKey) or findRow(rows, Trend.MostHistory(rows)))

  ui.list:SetSort(sortKey, sortDesc)
  ui.list:SetRows(rows, cell)
  drawChart(ui)
end

local function buildPage(body)
  local ui = { lines = {}, dots = {} }
  body.trends = ui

  ui.title = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  ui.title:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
  ui.title:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, 0)
  ui.title:SetHeight(TITLE_HEIGHT)
  ui.title:SetJustifyH("LEFT")
  ui.title:SetWordWrap(false)
  ui.title:SetTextColor(Theme:Color("gold"))

  ui.plot = CreateFrame("Frame", nil, body, "BackdropTemplate")
  ui.plot:SetPoint("TOPLEFT", body, "TOPLEFT", LABEL_GUTTER, -PLOT_TOP)
  ui.plot:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -PLOT_TOP)
  ui.plot:SetHeight(PLOT_HEIGHT)
  Theme:Backdrop(ui.plot, "barBg", "contentBorder")

  local function priceLabel(point)
    local fs = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
    fs:SetPoint(point, ui.plot, point == "TOPRIGHT" and "TOPLEFT" or "BOTTOMLEFT", -4, 0)
    fs:SetWidth(LABEL_GUTTER - 4)
    fs:SetJustifyH("RIGHT")
    fs:SetWordWrap(false)
    fs:SetTextColor(Theme:Color("parchment"))
    return fs
  end
  ui.maxLabel = priceLabel("TOPRIGHT")
  ui.minLabel = priceLabel("BOTTOMRIGHT")

  local function dateLabel(point, relative)
    local fs = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
    fs:SetPoint(point, ui.plot, relative, 0, -2)
    fs:SetHeight(14)
    fs:SetTextColor(Theme:Color("parchment"))
    return fs
  end
  ui.firstDate = dateLabel("TOPLEFT", "BOTTOMLEFT")
  ui.lastDate = dateLabel("TOPRIGHT", "BOTTOMRIGHT")

  ui.message = ui.plot:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  ui.message:SetPoint("LEFT", ui.plot, "LEFT", 12, 0)
  ui.message:SetPoint("RIGHT", ui.plot, "RIGHT", -12, 0)
  ui.message:SetJustifyH("CENTER")
  ui.message:SetTextColor(Theme:Color("grey"))

  ui.note = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
  ui.note:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
  ui.note:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
  ui.note:SetHeight(28) -- two lines at the smallest window
  ui.note:SetJustifyH("LEFT")
  ui.note:SetJustifyV("BOTTOM")
  ui.note:SetTextColor(Theme:Color("grey"))
  ui.note:SetText(L["Prices come from Auctionator / TSM and are recorded when you gather that item, so gaps are normal."])

  ui.list = W.ColumnList(body, COLUMNS)
  ui.list:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -LIST_TOP)
  ui.list:SetPoint("BOTTOMRIGHT", ui.note, "TOPRIGHT", 0, 4)
  ui.list:SetSort(sortKey, sortDesc)
  ui.list.onSort = function(key)
    if key == sortKey then
      sortDesc = not sortDesc
    else
      sortKey, sortDesc = key, key ~= "name"
    end
    refreshPage(body)
  end
  ui.list.onRowClick = function(row)
    selectRow(ui, row)
    ui.list:Refresh() -- the selected name turns gold
    drawChart(ui)
  end

  -- HookScript: BackdropTemplate uses this script too.
  ui.plot:HookScript("OnSizeChanged", function()
    HB:SafeCall("Trends", drawChart, ui)
  end)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local PAGE = { id = "trends", title = L["Trends"], order = 48, build = buildPage, refresh = refreshPage }

function Trends:OnEnable()
  HB:Listen(self, "HB_NODE_GATHERED", onLoot)
  HB:Listen(self, "HB_BONUS_LOOT", onLoot)
  PAGE.icon = Theme.ICONS and Theme.ICONS.trends
  HB.UI:RegisterPage(PAGE)
end

function Trends:OnDisable()
  self:UnregisterAllMessages()
  HB.UI:UnregisterPage("trends")
end
