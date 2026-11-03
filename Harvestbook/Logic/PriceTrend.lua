local ADDON, ns = ...

-- Pure price history: global.priceHistory[itemKey] = { [dayKey] = copper },
-- dayKey "YYYY-MM-DD". No date(): callers pass today's key in, and day
-- arithmetic uses day numbers computed from y/m/d.
local M = {}
ns.PriceTrend = M

M.MAX_DAYS = 90
M.MAX_ITEMS = 300
M.WINDOW_DAYS = 90 -- the chart's series: today and the 89 days before it

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function isLeap(y)
  return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

-- Days since 1970-01-01 (proleptic Gregorian), or nil if key isn't a real day.
function M.DayNumber(key)
  if type(key) ~= "string" then return nil end
  local ys, ms, ds = key:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not ys then return nil end
  local y, m, d = tonumber(ys), tonumber(ms), tonumber(ds)
  if m < 1 or m > 12 or d < 1 then return nil end
  local last = DAYS_IN_MONTH[m]
  if m == 2 and isLeap(y) then last = 29 end
  if d > last then return nil end
  -- Years count from March so the leap day falls at the end of the year.
  local adjusted = m <= 2 and y - 1 or y
  local era = math.floor(adjusted / 400)
  local yearOfEra = adjusted - era * 400
  local shifted = m > 2 and m - 3 or m + 9
  local dayOfYear = math.floor((153 * shifted + 2) / 5) + d - 1
  local dayOfEra = yearOfEra * 365 + math.floor(yearOfEra / 4) - math.floor(yearOfEra / 100) + dayOfYear
  return era * 146097 + dayOfEra - 719468
end

-- "itemID:quality" -> itemID, quality (nil for quality 0 = none), or nil.
function M.ParseKey(itemKey)
  if type(itemKey) ~= "string" then return nil end
  local id, q = itemKey:match("^(%d+):(%d+)$")
  if not id then return nil end
  q = tonumber(q)
  return tonumber(id), q ~= 0 and q or nil
end

-- Stores the day's price (the last one of a day wins). True only when this
-- added a new day, which is when the limits can be exceeded (see Prune).
function M.Record(all, itemKey, dayKey, copper)
  if not itemKey or not M.DayNumber(dayKey) then return false end
  if type(copper) ~= "number" or copper ~= copper or copper == math.huge or copper <= 0 then
    return false
  end
  local days = all[itemKey]
  if not days then
    days = {}
    all[itemKey] = days
  end
  local isNew = days[dayKey] == nil
  days[dayKey] = math.floor(copper)
  return isNew
end

-- The item's valid days as { { key, num }, ... }, oldest first.
local function sortedDays(days)
  local list = {}
  for key in pairs(days) do
    local num = M.DayNumber(key)
    if num then list[#list + 1] = { key = key, num = num } end
  end
  table.sort(list, function(a, b) return a.num < b.num end)
  return list
end

-- In place: at most maxDays per item (oldest dropped), then at most maxItems
-- (items with the oldest latest entry dropped; ties drop the later key).
-- Invalid days and items left empty are removed.
function M.Prune(all, maxDays, maxItems)
  if not all then return end
  maxDays, maxItems = maxDays or M.MAX_DAYS, maxItems or M.MAX_ITEMS
  local items = {}
  for itemKey, days in pairs(all) do
    if type(days) ~= "table" then
      all[itemKey] = nil
    else
      for key in pairs(days) do
        if not M.DayNumber(key) then days[key] = nil end
      end
      local list = sortedDays(days)
      for i = 1, #list - maxDays do days[list[i].key] = nil end
      if #list == 0 then
        all[itemKey] = nil
      else
        items[#items + 1] = { key = itemKey, latest = list[#list].num }
      end
    end
  end
  if #items <= maxItems then return end
  table.sort(items, function(a, b)
    if a.latest ~= b.latest then return a.latest > b.latest end
    return tostring(a.key) < tostring(b.key)
  end)
  for i = maxItems + 1, #items do all[items[i].key] = nil end
end

-- Percent from old to new; nil without both prices or from a zero old price.
function M.PercentChange(old, new)
  if not old or not new or old <= 0 then return nil end
  return (new - old) / old * 100
end

-- days = one item's { [dayKey] = copper }. Returns {
--   latest, latestDay, latestNum: newest entry at or before today (future days,
--     from a changed clock, and invalid days are ignored)
--   price7, price30: nearest entry at or before that many days ago, or nil
--   pct7, pct30: change from those to latest; nil when there is nothing to
--     compare (no entry, a zero price, or that entry is the latest itself)
--   series: { { day, num, price }, ... } oldest first, the last WINDOW_DAYS days
-- }
function M.Summary(days, todayKey)
  local out = { series = {} }
  local today = M.DayNumber(todayKey)
  if not days or not today then return out end
  local list = sortedDays(days)

  local latestIndex
  for i = #list, 1, -1 do
    if list[i].num <= today then latestIndex = i break end
  end
  if not latestIndex then return out end
  local latest = list[latestIndex]
  out.latest, out.latestDay, out.latestNum = days[latest.key], latest.key, latest.num

  local function back(n)
    for i = latestIndex, 1, -1 do
      if list[i].num <= today - n then return days[list[i].key], i ~= latestIndex end
    end
    return nil, false
  end
  local price7, older7 = back(7)
  local price30, older30 = back(30)
  out.price7, out.price30 = price7, price30
  out.pct7 = older7 and M.PercentChange(price7, out.latest) or nil
  out.pct30 = older30 and M.PercentChange(price30, out.latest) or nil

  for i = 1, latestIndex do
    if list[i].num > today - M.WINDOW_DAYS then
      out.series[#out.series + 1] = { day = list[i].key, num = list[i].num, price = days[list[i].key] }
    end
  end
  return out
end

-- In place, and returned. Rows missing the key are always last, whichever the
-- direction; ties go by itemKey so the order is stable between refreshes.
function M.SortRows(rows, key, descending)
  table.sort(rows, function(a, b)
    local av, bv = a[key], b[key]
    if av == nil or bv == nil then
      if av ~= nil then return true end
      if bv ~= nil then return false end
    elseif av ~= bv then
      if descending then return av > bv end
      return av < bv
    end
    return a.itemKey < b.itemKey
  end)
  return rows
end

-- itemKey of the row with the most chart points (ties: newest entry, then key).
function M.MostHistory(rows)
  local best
  for _, row in ipairs(rows) do
    local n, bn = #row.series, best and #best.series
    local latest, bestLatest = row.latestNum or 0, best and (best.latestNum or 0)
    if not best or n > bn or (n == bn and (latest > bestLatest
        or (latest == bestLatest and row.itemKey < best.itemKey))) then
      best = row
    end
  end
  return best and best.itemKey
end

-- Summary series -> plot positions { { x, y }, ... } within w x h (origin
-- bottom-left; x by day so gaps show), lowest price, highest price. Under two
-- entries there is no line to draw: no points. A flat history sits mid-height.
function M.ChartPoints(series, w, h)
  local lo, hi
  for _, p in ipairs(series) do
    if not lo or p.price < lo then lo = p.price end
    if not hi or p.price > hi then hi = p.price end
  end
  local points = {}
  if #series < 2 then return points, lo, hi end
  local first, last = series[1].num, series[#series].num
  for i, p in ipairs(series) do
    points[i] = {
      x = (p.num - first) / (last - first) * w,
      y = hi > lo and (p.price - lo) / (hi - lo) * h or h / 2,
    }
  end
  return points, lo, hi
end
