local ns = require("tests.helper").load("Logic/SessionMath.lua", "Logic/GearCompare.lua")
local G = ns.GearCompare

local function priceFn() return 100, "stub" end

-- A stopped session: value = copper (stored as one item at 1 copper each).
local function sess(sig, seconds, copper, nodes, zones)
  return {
    state = "stopped",
    activeSeconds = seconds,
    nodes = { herb = nodes or 0 },
    zones = zones or {},
    items = { ["1:0"] = { itemID = 1, quality = 0, count = copper } },
    prices = { ["1:0"] = { copper = 1, source = "stub" } },
    gear = sig and { sig = sig, items = {} } or nil,
  }
end

describe("GearCompare.BuildGear", function()
  it("sorts itemIDs numerically into the signature and keeps duplicates", function()
    local gear = G.BuildGear({ { itemID = 200 }, { itemID = 30 }, { itemID = 200 } })
    assert.are.equal("30,200,200", gear.sig)
    assert.are.equal(3, #gear.items)
    assert.are.equal(200, gear.items[1].itemID)
  end)

  it("gives the same signature whichever slots the items are in", function()
    assert.are.equal(G.BuildGear({ { itemID = 1 }, { itemID = 2 } }).sig,
      G.BuildGear({ { itemID = 2 }, { itemID = 1 } }).sig)
  end)

  it("is an empty signature with no gear", function()
    local gear = G.BuildGear({})
    assert.are.equal("", gear.sig)
    assert.are.equal(0, #gear.items)
  end)
end)

describe("GearCompare.MainZone", function()
  it("is the most-gathered zone", function()
    assert.are.equal(2, G.MainZone({ zones = { [1] = 3, [2] = 9 } }))
  end)

  it("breaks a tie on the lower mapID", function()
    assert.are.equal(4, G.MainZone({ zones = { [7] = 5, [4] = 5, [9] = 5 } }))
  end)

  it("is nil without gathers", function()
    assert.is_nil(G.MainZone({ zones = {} }))
    assert.is_nil(G.MainZone({}))
  end)
end)

describe("GearCompare.Compare", function()
  it("groups by signature and totals each set", function()
    local out = G.Compare({
      sess("1", 3600, 1000, 10),
      sess("1", 1800, 500, 5),
    }, priceFn)
    assert.are.equal(1, #out.sets)
    local set = out.sets[1]
    assert.are.equal("1", set.sig)
    assert.are.equal(2, set.sessions)
    assert.are.equal(5400, set.seconds)
    assert.are.equal(1500, set.value)
    assert.are.equal(15, set.nodes)
    assert.are.equal(1000, set.gph)
    assert.are.equal(10, set.nodesPerHour)
    assert.are.equal(100, set.itemsPerNode)
  end)

  it("computes gold per hour from totals, not an average of averages", function()
    local out = G.Compare({
      sess("1", 3600, 1000), -- 1000/hr
      sess("1", 60, 1000),   -- 60000/hr
    }, priceFn)
    assert.are.equal(2000 * 3600 / 3660, out.sets[1].gph)
  end)

  it("has no items per node for a set without nodes", function()
    assert.is_nil(G.Compare({ sess("1", 3600, 10, 0) }, priceFn).sets[1].itemsPerNode)
  end)

  it("sorts best gold/hr first with the percent difference from the best", function()
    local out = G.Compare({
      sess("low", 3600, 500),
      sess("best", 3600, 2000),
      sess("mid", 3600, 1500),
    }, priceFn)
    assert.are.equal("best", out.sets[1].sig)
    assert.are.equal("mid", out.sets[2].sig)
    assert.are.equal("low", out.sets[3].sig)
    assert.are.equal(0, out.sets[1].pct)
    assert.are.equal(-25, out.sets[2].pct)
    assert.are.equal(-75, out.sets[3].pct)
  end)

  it("breaks gold/hr ties on the signature and has no divide by zero", function()
    local out = G.Compare({ sess("b", 3600, 0), sess("a", 3600, 0) }, priceFn)
    assert.are.equal("a", out.sets[1].sig)
    assert.are.equal(0, out.sets[1].pct)
    assert.are.equal(0, out.sets[2].pct)
  end)

  it("treats an empty signature as a real set", function()
    local out = G.Compare({ sess("", 3600, 100) }, priceFn)
    assert.are.equal(1, #out.sets)
    assert.are.equal("", out.sets[1].sig)
  end)

  it("ignores sessions under 60 active seconds, keeping exactly 60", function()
    local out = G.Compare({ sess("1", 59, 9999), sess("1", 60, 10) }, priceFn)
    assert.are.equal(1, out.sets[1].sessions)
    assert.are.equal(60, out.sets[1].seconds)
    assert.are.equal(10, out.sets[1].value)
  end)

  it("counts sessions without gear separately, short ones not at all", function()
    local out = G.Compare({ sess(nil, 3600, 10), sess(nil, 3600, 10), sess(nil, 30, 10), sess("1", 3600, 1) }, priceFn)
    assert.are.equal(2, out.noGear)
    assert.are.equal(1, #out.sets)
    assert.are.equal(1, out.sets[1].sessions)
  end)

  it("keeps only sessions whose most-gathered zone is the filter", function()
    local sessions = {
      sess("1", 3600, 100, 1, { [5] = 9, [6] = 1 }),
      sess("1", 3600, 300, 1, { [5] = 1, [6] = 9 }),
      sess(nil, 3600, 100, 1, { [5] = 2 }),
      sess(nil, 3600, 100, 1, { [6] = 2 }),
      sess("2", 3600, 100, 0),
    }
    local out = G.Compare(sessions, priceFn, 6)
    assert.are.equal(1, #out.sets)
    assert.are.equal(1, out.sets[1].sessions)
    assert.are.equal(300, out.sets[1].value)
    assert.are.equal(1, out.noGear)
  end)

  it("keeps the items of the set and copes with nothing", function()
    local s = sess("7", 3600, 1)
    s.gear.items = { { itemID = 7, tool = true } }
    assert.are.equal(7, G.Compare({ s }, priceFn).sets[1].items[1].itemID)
    local out = G.Compare(nil, priceFn)
    assert.are.equal(0, #out.sets)
    assert.are.equal(0, out.noGear)
  end)

  it("prices a session that is not stopped through priceFn", function()
    local s = sess("1", 3600, 2)
    s.state = "paused"
    assert.are.equal(200, G.Compare({ s }, priceFn).sets[1].value)
  end)
end)

describe("GearCompare.Zones", function()
  it("lists the main zones of usable sessions once each, sorted", function()
    local zones = G.Zones({
      sess("1", 3600, 1, 1, { [9] = 5, [2] = 1 }),
      sess("2", 3600, 1, 1, { [3] = 5 }),
      sess("1", 3600, 1, 1, { [9] = 1 }),
      sess("1", 30, 1, 1, { [4] = 5 }),  -- too short
      sess(nil, 3600, 1, 1, { [5] = 5 }), -- no gear
      sess("1", 3600, 1, 0),              -- no zone
    })
    assert.are.same({ 3, 9 }, zones)
  end)

  it("is empty with nothing", function()
    assert.are.same({}, G.Zones(nil))
  end)
end)

describe("GearCompare.Label", function()
  local function nameFn(itemID) return "Item" .. itemID end

  it("is the no-gear text with no items", function()
    assert.are.equal("No profession gear", G.Label({}, nameFn))
  end)

  it("is the only item's name with no suffix", function()
    assert.are.equal("Item5", G.Label({ { itemID = 5 } }, nameFn))
  end)

  it("prefers the tool, counting the rest", function()
    assert.are.equal("Item8 +2", G.Label({
      { itemID = 5 }, { itemID = 8, tool = true }, { itemID = 9 },
    }, nameFn))
  end)

  it("falls back to the first item without a tool", function()
    assert.are.equal("Item5 +1", G.Label({ { itemID = 5 }, { itemID = 9 } }, nameFn))
  end)

  it("passes the link to nameFn", function()
    local seen
    G.Label({ { itemID = 5, link = "L" } }, function(_, link) seen = link return "x" end)
    assert.are.equal("L", seen)
  end)
end)
