local ns = require("tests.helper").load("Logic/GoldLedger.lua")
local L = ns.GoldLedger

describe("GoldLedger", function()
  it("Add grows the total and each bucket given a key", function()
    local g = {}
    L.Add(g, 100, { day = "2026-11-02", daily = 86400 })
    L.Add(g, 50, { day = "2026-11-02" })
    assert.are.equal(150, g.total)
    assert.are.equal(150, g.day["2026-11-02"])
    assert.are.equal(100, g.daily[86400])
    assert.is_nil(g.weekly)
  end)

  it("Add ignores zero, negative and non-numbers", function()
    local g = { total = 5 }
    L.Add(g, 0, { day = "d" })
    L.Add(g, -3, { day = "d" })
    L.Add(g, nil, { day = "d" })
    assert.are.equal(5, g.total)
    assert.is_nil(g.day)
  end)

  it("Add prunes the oldest buckets, never the total", function()
    local g = {}
    for i = 1, L.MAX_BUCKETS.weekly + 5 do L.Add(g, 1, { weekly = i }) end
    local n = 0
    for _ in pairs(g.weekly) do n = n + 1 end
    assert.are.equal(L.MAX_BUCKETS.weekly, n)
    assert.is_nil(g.weekly[1])
    assert.are.equal(L.MAX_BUCKETS.weekly + 5, g.total)
  end)

  it("ResetKey keeps a period under one key despite clock drift", function()
    local day = L.PERIOD_SECONDS.daily
    local a = L.ResetKey(1000, 90000, day)
    local b = L.ResetKey(1000, 90004, day)
    assert.are.equal(a, b)
  end)

  it("ResetKey is the end of the period containing t", function()
    local day = L.PERIOD_SECONDS.daily
    assert.are.equal(90000, L.ResetKey(89999, 90000, day))
    assert.are.equal(90000 + day, L.ResetKey(90000, 90000, day))
    assert.are.equal(90000 - day, L.ResetKey(90000 - day - 1, 90000, day))
  end)

  it("Summary reports current, average and best over active periods", function()
    local sum = L.Summary({ a = 100, b = 300 }, "b")
    assert.are.equal(300, sum.current)
    assert.are.equal(200, sum.average)
    assert.are.equal(300, sum.best)
    assert.are.equal(2, sum.periods)
    assert.are.equal(0, L.Summary(nil, "x").current)
    assert.are.equal(0, L.Summary({ a = 1 }, "x").current)
  end)

  it("Rows are newest first", function()
    local rows = L.Rows({ ["2026-11-01"] = 1, ["2026-11-03"] = 3, ["2026-11-02"] = 2 })
    assert.are.equal("2026-11-03", rows[1].key)
    assert.are.equal(1, rows[3].copper)
  end)

  it("GoalCrossed is true only on the gain that crosses", function()
    assert.is_true(L.GoalCrossed(99, 100, 100))
    assert.is_false(L.GoalCrossed(100, 150, 100))
    assert.is_false(L.GoalCrossed(10, 20, 100))
    assert.is_false(L.GoalCrossed(10, 20, nil))
  end)

  it("Backfill adds each session at its start time", function()
    local g = {}
    L.Backfill(g, { { started = 1, v = 10 }, { started = 2, v = 20 } },
      function(s) return s.v end, function(t) return { day = "d" .. t } end)
    assert.are.equal(30, g.total)
    assert.are.equal(20, g.day.d2)
  end)
end)
