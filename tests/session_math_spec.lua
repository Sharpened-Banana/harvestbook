local ns = require("tests.helper").load("Logic/SessionMath.lua")
local S = ns.SessionMath

local prices = { [1] = 100, [2] = 250 }
local function priceFn(id)
  local p = prices[id]
  if p then return p, "stub" end
  return 0, "none"
end

local function gather(map, items, kind)
  return { kind = kind or "herb", mapID = map, items = items }
end

describe("SessionMath", function()
  it("New sets running state and zero counts", function()
    local s = S.New(10)
    assert.are.equal("running", s.state)
    assert.are.equal(10, s.started)
    assert.are.equal(10, s.lastResume)
    assert.are.equal(0, s.activeSeconds)
    assert.are.same({ herb = 0, ore = 0, skin = 0 }, s.nodes)
    assert.are.equal("", s.note)
  end)

  it("ActiveSeconds excludes paused time", function()
    local s = S.New(0)
    S.Pause(s, 100)
    S.Resume(s, 400)
    assert.are.equal(200, S.ActiveSeconds(s, 500))
  end)

  it("AddGather while paused returns false and leaves items empty", function()
    local s = S.New(0)
    S.Pause(s, 10)
    assert.is_false(S.AddGather(s, gather(10, { { itemID = 1, count = 1 } }), 20, priceFn))
    assert.are.same({}, s.items)
  end)

  it("AddGather sums counts per itemKey and splits by quality", function()
    local s = S.New(0)
    S.AddGather(s, gather(10, { { itemID = 1, count = 2, quality = 1, link = "L1" } }), 1, priceFn)
    S.AddGather(s, gather(10, { { itemID = 1, count = 1, quality = 2 } }), 2, priceFn)
    assert.are.equal(2, s.items["1:1"].count)
    assert.are.equal(1, s.items["1:2"].count)
    assert.are.equal("L1", s.items["1:1"].link)
    assert.are.equal(2, s.nodes.herb)
    assert.are.equal(2, s.zones[10])
    assert.are.equal(300, s.zoneCopper[10])
  end)

  it("zone change splits zoneSeconds", function()
    local s = S.New(0)
    S.AddGather(s, gather(10, { { itemID = 1, count = 1 } }), 0, priceFn)
    S.AddGather(s, gather(20, { { itemID = 1, count = 1 } }), 300, priceFn)
    S.Pause(s, 600)
    assert.are.equal(300, s.zoneSeconds[10])
    assert.are.equal(300, s.zoneSeconds[20])
  end)

  it("GoldPerHour is nil under 60 active seconds", function()
    local s = S.New(0)
    S.AddGather(s, gather(10, { { itemID = 1, count = 10 } }), 1, priceFn)
    assert.is_nil(S.GoldPerHour(s, 59, priceFn))
  end)

  it("GoldPerHour computes per hour", function()
    local s = S.New(0)
    S.AddGather(s, gather(10, { { itemID = 1, count = 10 } }), 1, priceFn)
    assert.are.equal(2000, S.GoldPerHour(s, 1800, priceFn))
  end)

  it("Rows handles zero-price items", function()
    local s = S.New(0)
    S.AddGather(s, gather(10, { { itemID = 3, count = 4 } }), 1, priceFn)
    local rows = S.Rows(s, 100, priceFn)
    assert.are.equal(1, #rows)
    assert.are.equal(0, rows[1].value)
    assert.are.equal("none", rows[1].source)
  end)

  it("Rows sorts by value descending by default", function()
    local s = S.New(0)
    S.AddGather(s, gather(10, { { itemID = 1, count = 1 }, { itemID = 2, count = 3 } }), 1, priceFn)
    local rows = S.Rows(s, 100, priceFn)
    assert.are.equal(2, rows[1].itemID)
    assert.are.equal(1, rows[2].itemID)
    local asc = S.Rows(s, 100, priceFn, "count", false)
    assert.are.equal(1, asc[1].itemID)
  end)

  it("Stop freezes prices", function()
    local s = S.New(0)
    S.AddGather(s, gather(10, { { itemID = 1, count = 2 } }), 1, priceFn)
    S.Stop(s, 100, priceFn)
    assert.are.equal("stopped", s.state)
    assert.are.equal(200, S.Value(s, priceFn))
    local other = function() return 9999, "x" end
    assert.are.equal(200, S.Value(s, other))
    assert.are.equal(100, S.ActiveSeconds(s, 5000))
  end)

  it("Restore resets lastResume to now for a running session", function()
    local s = S.New(0)
    S.Checkpoint(s, 100)
    S.Restore(s, 5000)
    assert.are.equal(110, S.ActiveSeconds(s, 5010))
  end)
end)
