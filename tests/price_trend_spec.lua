local ns = require("tests.helper").load("Logic/PriceTrend.lua")
local T = ns.PriceTrend

local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- { [dayKey] = copper } for the last n days of December 2025.
local function decemberDays(n)
  local days = {}
  for i = 0, n - 1 do
    days[string.format("2025-12-%02d", 31 - i)] = 100 + i
  end
  return days
end

describe("PriceTrend.DayNumber", function()
  it("counts single days across month ends", function()
    assert.are.equal(1, T.DayNumber("2025-02-01") - T.DayNumber("2025-01-31"))
    assert.are.equal(1, T.DayNumber("2025-05-01") - T.DayNumber("2025-04-30"))
  end)

  it("counts across year ends", function()
    assert.are.equal(1, T.DayNumber("2026-01-01") - T.DayNumber("2025-12-31"))
    assert.are.equal(365, T.DayNumber("2026-01-01") - T.DayNumber("2025-01-01"))
  end)

  it("handles leap years, including the century rules", function()
    assert.are.equal(2, T.DayNumber("2024-03-01") - T.DayNumber("2024-02-28"))
    assert.are.equal(1, T.DayNumber("2025-03-01") - T.DayNumber("2025-02-28"))
    assert.are.equal(366, T.DayNumber("2025-01-01") - T.DayNumber("2024-01-01"))
    assert.are.equal(2, T.DayNumber("2000-03-01") - T.DayNumber("2000-02-28"))
    assert.are.equal(1, T.DayNumber("2100-03-01") - T.DayNumber("2100-02-28"))
  end)

  it("is 0 at the Unix epoch", function()
    assert.are.equal(0, T.DayNumber("1970-01-01"))
    assert.are.equal(20089, T.DayNumber("2025-01-01"))
  end)

  it("rejects anything that is not a real calendar day", function()
    assert.is_nil(T.DayNumber(nil))
    assert.is_nil(T.DayNumber(20250101))
    assert.is_nil(T.DayNumber(""))
    assert.is_nil(T.DayNumber("2025-1-01"))
    assert.is_nil(T.DayNumber("2025-13-01"))
    assert.is_nil(T.DayNumber("2025-00-10"))
    assert.is_nil(T.DayNumber("2025-02-29"))
    assert.is_nil(T.DayNumber("2025-04-31"))
    assert.is_nil(T.DayNumber("2025-01-00"))
    assert.is_nil(T.DayNumber("2025-01-01x"))
  end)
end)

describe("PriceTrend.ParseKey", function()
  it("splits an item key", function()
    local id, q = T.ParseKey("1234:2")
    assert.are.equal(1234, id)
    assert.are.equal(2, q)
  end)

  it("treats quality 0 as no quality", function()
    local id, q = T.ParseKey("1234:0")
    assert.are.equal(1234, id)
    assert.is_nil(q)
  end)

  it("returns nil for a malformed key", function()
    assert.is_nil(T.ParseKey("junk"))
    assert.is_nil(T.ParseKey(nil))
  end)
end)

describe("PriceTrend.Record", function()
  it("creates the item and reports a new day", function()
    local all = {}
    assert.is_true(T.Record(all, "1:0", "2025-03-01", 500))
    assert.are.equal(500, all["1:0"]["2025-03-01"])
  end)

  it("last value of the day wins, and is not a new day", function()
    local all = {}
    T.Record(all, "1:0", "2025-03-01", 500)
    assert.is_false(T.Record(all, "1:0", "2025-03-01", 700))
    assert.are.equal(700, all["1:0"]["2025-03-01"])
    assert.are.equal(1, count(all["1:0"]))
  end)

  it("stores whole copper", function()
    local all = {}
    T.Record(all, "1:0", "2025-03-01", 500.9)
    assert.are.equal(500, all["1:0"]["2025-03-01"])
  end)

  it("ignores zero, negative, NaN, non-number prices and bad days", function()
    local all = {}
    assert.is_false(T.Record(all, "1:0", "2025-03-01", 0))
    assert.is_false(T.Record(all, "1:0", "2025-03-01", -5))
    assert.is_false(T.Record(all, "1:0", "2025-03-01", 0 / 0))
    assert.is_false(T.Record(all, "1:0", "2025-03-01", math.huge))
    assert.is_false(T.Record(all, "1:0", "2025-03-01", "12"))
    assert.is_false(T.Record(all, "1:0", "not-a-day", 5))
    assert.is_false(T.Record(all, nil, "2025-03-01", 5))
    assert.are.equal(0, count(all))
  end)

  it("a bad price leaves the day's value alone", function()
    local all = {}
    T.Record(all, "1:0", "2025-03-01", 500)
    T.Record(all, "1:0", "2025-03-01", 0)
    assert.are.equal(500, all["1:0"]["2025-03-01"])
  end)
end)

describe("PriceTrend.Prune", function()
  it("keeps the newest 90 days of an item", function()
    local days = {}
    for i = 1, 31 do days[string.format("2025-01-%02d", i)] = i end
    for i = 1, 28 do days[string.format("2025-02-%02d", i)] = i end
    for i = 1, 31 do days[string.format("2025-03-%02d", i)] = i end
    for i = 1, 5 do days[string.format("2025-04-%02d", i)] = i end
    local all = { ["1:0"] = days }
    T.Prune(all)
    assert.are.equal(90, count(days))
    assert.is_nil(days["2025-01-05"])
    assert.are.equal(6, days["2025-01-06"])
    assert.are.equal(5, days["2025-04-05"])
  end)

  it("orders days across a year end when dropping", function()
    local days = { ["2024-12-31"] = 1, ["2025-01-01"] = 2, ["2025-01-02"] = 3 }
    T.Prune({ ["1:0"] = days }, 2)
    assert.is_nil(days["2024-12-31"])
    assert.are.equal(2, count(days))
  end)

  it("leaves an item at the limit untouched", function()
    local days = decemberDays(31)
    T.Prune({ ["1:0"] = days }, 31)
    assert.are.equal(31, count(days))
  end)

  it("drops the items whose latest entry is oldest", function()
    local all = {
      old = { ["2025-01-01"] = 1 },
      mid = { ["2024-01-01"] = 1, ["2025-06-01"] = 1 },
      new = { ["2025-12-31"] = 1 },
    }
    T.Prune(all, 90, 2)
    assert.is_nil(all.old)
    assert.are.equal("table", type(all.mid))
    assert.are.equal("table", type(all.new))
  end)

  it("keeps at most 300 items by default", function()
    local all = {}
    for i = 1, 310 do
      local month, day = math.floor((i - 1) / 28) + 1, (i - 1) % 28 + 1
      all["i" .. i] = { [string.format("2025-%02d-%02d", month, day)] = 1 }
    end
    T.Prune(all)
    assert.are.equal(300, count(all))
    for i = 1, 10 do assert.is_nil(all["i" .. i]) end
    assert.are.equal("table", type(all.i11))
  end)

  it("drops the same item on every run when latest days tie", function()
    local function run()
      local all = {
        a = { ["2025-01-01"] = 1 }, b = { ["2025-01-01"] = 1 }, c = { ["2025-01-01"] = 1 },
      }
      T.Prune(all, 90, 2)
      return all
    end
    for _ = 1, 5 do
      local all = run()
      assert.is_nil(all.c)
      assert.are.equal("table", type(all.a))
      assert.are.equal("table", type(all.b))
    end
  end)

  it("removes invalid day keys and items left with nothing", function()
    local all = {
      bad = { ["nope"] = 1 },
      notTable = 5,
      mixed = { ["nope"] = 1, ["2025-01-01"] = 2 },
    }
    T.Prune(all)
    assert.is_nil(all.bad)
    assert.is_nil(all.notTable)
    assert.are.same({ ["2025-01-01"] = 2 }, all.mixed)
  end)

  it("handles an empty or missing table", function()
    T.Prune({})
    T.Prune(nil)
  end)
end)

describe("PriceTrend.PercentChange", function()
  it("is relative to the old price", function()
    assert.are.equal(50, T.PercentChange(100, 150))
    assert.are.equal(-25, T.PercentChange(100, 75))
    assert.are.equal(0, T.PercentChange(100, 100))
  end)

  it("never divides by zero", function()
    assert.is_nil(T.PercentChange(0, 100))
    assert.is_nil(T.PercentChange(0, 0))
    assert.are.equal(-100, T.PercentChange(100, 0))
  end)

  it("is nil when either side is missing", function()
    assert.is_nil(T.PercentChange(nil, 100))
    assert.is_nil(T.PercentChange(100, nil))
  end)
end)

describe("PriceTrend.Summary", function()
  it("handles an empty or missing history", function()
    for _, h in ipairs({ {}, false }) do
      local s = T.Summary(h or nil, "2025-03-10")
      assert.is_nil(s.latest)
      assert.is_nil(s.price7)
      assert.is_nil(s.price30)
      assert.is_nil(s.pct7)
      assert.is_nil(s.pct30)
      assert.are.same({}, s.series)
    end
  end)

  it("handles a single point recorded today", function()
    local s = T.Summary({ ["2025-03-10"] = 200 }, "2025-03-10")
    assert.are.equal(200, s.latest)
    assert.are.equal("2025-03-10", s.latestDay)
    assert.is_nil(s.price7)
    assert.is_nil(s.pct7)
    assert.is_nil(s.price30)
    assert.is_nil(s.pct30)
    assert.are.equal(1, #s.series)
  end)

  it("does not compare the latest entry with itself", function()
    local s = T.Summary({ ["2025-03-01"] = 200 }, "2025-03-20")
    assert.are.equal(200, s.latest)
    assert.are.equal(200, s.price7) -- nearest entry at or before that day
    assert.is_nil(s.pct7)
    assert.is_nil(s.pct30)
  end)

  it("uses the exact day when it exists", function()
    local s = T.Summary({
      ["2025-03-10"] = 150, ["2025-03-03"] = 100, ["2025-02-08"] = 300, ["2025-03-05"] = 999,
    }, "2025-03-10")
    assert.are.equal(150, s.latest)
    assert.are.equal(100, s.price7)
    assert.are.equal(50, s.pct7)
    assert.are.equal(300, s.price30)
    assert.are.equal(-50, s.pct30)
  end)

  it("takes the nearest entry at or before, never after", function()
    local s = T.Summary({
      ["2025-03-10"] = 200, ["2025-03-04"] = 999, ["2025-03-01"] = 100,
    }, "2025-03-10")
    assert.are.equal(100, s.price7)
    assert.are.equal(100, s.pct7)
    assert.is_nil(s.price30)
  end)

  it("looks back across a month end", function()
    local s = T.Summary({ ["2025-03-03"] = 200, ["2025-02-24"] = 100 }, "2025-03-03")
    assert.are.equal(100, s.price7) -- exactly 7 days back in a 28-day February
  end)

  it("looks back across a year end", function()
    local s = T.Summary({
      ["2026-01-03"] = 200, ["2025-12-27"] = 100, ["2025-12-04"] = 50,
    }, "2026-01-03")
    assert.are.equal(100, s.price7)
    assert.are.equal(50, s.price30)
    assert.are.equal(300, s.pct30)
  end)

  it("gives no percent against a zero price and does not error", function()
    local s = T.Summary({ ["2025-03-10"] = 100, ["2025-03-03"] = 0 }, "2025-03-10")
    assert.are.equal(0, s.price7)
    assert.is_nil(s.pct7)
  end)

  it("orders the series by day across a year end", function()
    local s = T.Summary({
      ["2026-01-02"] = 3, ["2025-12-31"] = 1, ["2026-01-01"] = 2,
    }, "2026-01-02")
    assert.are.equal("2025-12-31", s.series[1].day)
    assert.are.equal(1, s.series[1].price)
    assert.are.equal("2026-01-01", s.series[2].day)
    assert.are.equal("2026-01-02", s.series[3].day)
    assert.are.equal(s.series[1].num + 1, s.series[2].num)
  end)

  it("keeps only the last 90 days in the series, not in the comparison", function()
    local s = T.Summary({
      ["2025-03-10"] = 200, -- today
      ["2024-12-11"] = 100, -- 89 days back: in
      ["2024-12-10"] = 50,  -- 90 days back: out
    }, "2025-03-10")
    assert.are.equal(2, #s.series)
    assert.are.equal("2024-12-11", s.series[1].day)
    assert.are.equal(100, s.price7)
  end)

  it("ignores invalid and future days", function()
    local s = T.Summary({
      ["2025-03-10"] = 200, ["2025-03-11"] = 999, ["garbage"] = 1,
    }, "2025-03-10")
    assert.are.equal(200, s.latest)
    assert.are.equal(1, #s.series)
  end)

  it("gives an empty summary for an invalid today", function()
    local s = T.Summary({ ["2025-03-10"] = 200 }, "nope")
    assert.is_nil(s.latest)
    assert.are.same({}, s.series)
  end)
end)

describe("PriceTrend.SortRows", function()
  local function rows()
    return {
      { itemKey = "a", pct7 = 5, name = "Zinc" },
      { itemKey = "b", pct7 = nil, name = "Iron" },
      { itemKey = "c", pct7 = -3, name = "Lead" },
      { itemKey = "d", pct7 = 20, name = "Gold" },
      { itemKey = "e", pct7 = nil, name = "Tin" },
    }
  end
  local function keys(list)
    local out = {}
    for i, r in ipairs(list) do out[i] = r.itemKey end
    return table.concat(out)
  end

  it("sorts by change, biggest rise first when descending", function()
    assert.are.equal("dacbe", keys(T.SortRows(rows(), "pct7", true)))
  end)

  it("sorts ascending, and rows without data stay last", function()
    assert.are.equal("cadbe", keys(T.SortRows(rows(), "pct7", false)))
  end)

  it("sorts names", function()
    assert.are.equal("dbcea", keys(T.SortRows(rows(), "name", false)))
    assert.are.equal("aecbd", keys(T.SortRows(rows(), "name", true)))
  end)
end)

describe("PriceTrend.MostHistory", function()
  local function row(key, n, latestNum)
    local series = {}
    for i = 1, n do series[i] = {} end
    return { itemKey = key, series = series, latestNum = latestNum }
  end

  it("picks the item with the most points", function()
    assert.are.equal("b", T.MostHistory({ row("a", 2, 9), row("b", 5, 1), row("c", 3, 9) }))
  end)

  it("breaks ties by the newest entry, then the key", function()
    assert.are.equal("b", T.MostHistory({ row("a", 2, 1), row("b", 2, 9) }))
    assert.are.equal("a", T.MostHistory({ row("b", 2, 9), row("a", 2, 9) }))
  end)

  it("is nil with no rows", function()
    assert.is_nil(T.MostHistory({}))
  end)
end)

describe("PriceTrend.ChartPoints", function()
  local function series(...)
    local out = {}
    for i, pair in ipairs({ ... }) do out[i] = { num = pair[1], price = pair[2] } end
    return out
  end

  it("spaces x by days and y by price", function()
    local pts, lo, hi = T.ChartPoints(series({ 100, 10 }, { 101, 30 }, { 104, 20 }), 200, 100)
    assert.are.equal(10, lo)
    assert.are.equal(30, hi)
    assert.are.equal(0, pts[1].x)
    assert.are.equal(0, pts[1].y)
    assert.are.equal(50, pts[2].x)
    assert.are.equal(100, pts[2].y)
    assert.are.equal(200, pts[3].x)
    assert.are.equal(50, pts[3].y)
  end)

  it("draws a flat history in the middle", function()
    local pts, lo, hi = T.ChartPoints(series({ 1, 50 }, { 2, 50 }), 100, 80)
    assert.are.equal(50, lo)
    assert.are.equal(50, hi)
    assert.are.equal(40, pts[1].y)
    assert.are.equal(40, pts[2].y)
  end)

  it("gives no points under two entries", function()
    local pts, lo, hi = T.ChartPoints(series({ 1, 50 }), 100, 80)
    assert.are.same({}, pts)
    assert.are.equal(50, lo)
    assert.are.equal(50, hi)
    pts, lo, hi = T.ChartPoints({}, 100, 80)
    assert.are.same({}, pts)
    assert.is_nil(lo)
    assert.is_nil(hi)
  end)
end)

describe("PriceTrend.NeedsPrune", function()
  it("is true only over a cap", function()
    local all = { a = { d1 = 1, d2 = 1 }, b = { d1 = 1 } }
    assert.is_false(T.NeedsPrune(all, "a", 2, 2))
    assert.is_true(T.NeedsPrune(all, "a", 1, 2))
    assert.is_true(T.NeedsPrune(all, "b", 2, 1))
    assert.is_false(T.NeedsPrune(all, "missing", 2, 2))
  end)
end)
