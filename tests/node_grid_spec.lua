local ns = require("tests.helper").load("Logic/NodeGrid.lua")
local G = ns.NodeGrid

local function gather(o)
  local g = { time = 100, kind = "herb", objectID = 1, mapID = 1, x = 0.5, y = 0.5, items = {} }
  for k, v in pairs(o or {}) do g[k] = v end
  if g.objectID == false then g.objectID = nil end
  return g
end

describe("NodeGrid", function()
  it("CellKey floors to a 2% grid", function()
    assert.are.equal("6:49", G.CellKey(0.123, 0.987))
    assert.are.equal("0:0", G.CellKey(0, 0))
  end)

  it("Record averages positions within a cell", function()
    local zone = {}
    local k = G.Record(zone, gather({ x = 0.500, y = 0.500, time = 10,
      items = { { itemID = 7, count = 2 } } }), 300)
    G.Record(zone, gather({ x = 0.510, y = 0.515, time = 20,
      items = { { itemID = 7, count = 3 }, { itemID = 8, count = 1 } } }), 100)
    assert.are.equal("25:25", k)
    local s = zone[k]
    assert.are.equal(2, s.gathers)
    assert.are.equal(400, s.copper)
    assert.are.equal(5, s.items[7])
    assert.are.equal(1, s.items[8])
    assert.are.equal(2, s.nodeIDs[1])
    assert.are.equal(10, s.firstSeen)
    assert.are.equal(20, s.lastSeen)
    assert.is_true(math.abs(s.x - 0.505) < 1e-9)
    assert.is_true(math.abs(s.y - 0.5075) < 1e-9)
  end)

  it("NodeGrid keeps different kinds in the same cell apart", function()
    local zone = {}
    local a = G.Record(zone, gather({ kind = "herb" }), 0)
    local b = G.Record(zone, gather({ kind = "ore", objectID = 2 }), 0)
    assert.are.equal("25:25", a)
    assert.are.equal("25:25:ore", b)
    local c = G.Record(zone, gather({ kind = "ore", objectID = 2 }), 0)
    assert.are.equal("25:25:ore", c)
    assert.are.equal(2, zone["25:25:ore"].gathers)
    assert.are.equal(1, zone["25:25"].gathers)
  end)

  it("Record ignores gathers without a source", function()
    local zone = {}
    assert.is_nil(G.Record(zone, gather({ objectID = false }), 5))
    assert.is_nil(G.Record(zone, gather({ objectID = false, npcID = nil }), 5))
    assert.is_nil(next(zone))
  end)

  it("Record uses npcID for skinning", function()
    local zone = {}
    local k = G.Record(zone, gather({ kind = "skin", objectID = false, npcID = 99 }), 0)
    assert.are.equal(1, zone[k].nodeIDs[99])
  end)

  it("Summarize computes share and avg items", function()
    local zone = {}
    G.Record(zone, gather({ objectID = 1, x = 0.1, y = 0.1, items = { { itemID = 7, count = 4 } } }), 400)
    G.Record(zone, gather({ objectID = 1, x = 0.1, y = 0.1, items = { { itemID = 7, count = 2 } } }), 200)
    G.Record(zone, gather({ objectID = 2, x = 0.8, y = 0.8, items = { { itemID = 8, count = 1 } } }), 50)
    local rows = G.Summarize(zone)
    assert.are.equal(2, #rows)
    assert.are.equal(1, rows[1].nodeID)
    assert.are.equal("herb", rows[1].kind)
    assert.are.equal(2, rows[1].count)
    assert.is_true(math.abs(rows[1].share - 2 / 3) < 1e-9)
    assert.are.equal(3, rows[1].avgItems)
    assert.are.equal(300, rows[1].valuePerNode)
    assert.are.equal(2, rows[2].nodeID)
    assert.are.equal(1, rows[2].avgItems)
    assert.are.equal(50, rows[2].valuePerNode)
  end)

  it("Summarize attributes a mixed spot to its most-gathered node (ties: lowest id)", function()
    local zone = {}
    G.Record(zone, gather({ objectID = 5, items = { { itemID = 7, count = 2 } } }), 20)
    G.Record(zone, gather({ objectID = 3, items = { { itemID = 7, count = 2 } } }), 20)
    G.Record(zone, gather({ objectID = 5, items = { { itemID = 7, count = 2 } } }), 20)
    G.Record(zone, gather({ objectID = 3, items = { { itemID = 7, count = 2 } } }), 20)
    local rows = G.Summarize(zone)
    assert.are.equal(3, rows[1].nodeID)
    assert.are.equal(2, rows[1].count)
    assert.are.equal(4, rows[1].avgItems)
    assert.are.equal(40, rows[1].valuePerNode)
    assert.are.equal(5, rows[2].nodeID)
    assert.are.equal(0, rows[2].avgItems)
    assert.are.equal(0, rows[2].valuePerNode)
  end)

  it("Summarize skips imported cells", function()
    local zone = {}
    G.ImportPoint(zone, 0.3, 0.3, "ore")
    assert.are.same({}, G.Summarize(zone))
  end)

  it("Forget removes a spot", function()
    local zone = {}
    local k = G.Record(zone, gather(), 0)
    G.Forget(zone, k)
    assert.is_nil(zone[k])
  end)

  it("ImportPoint does not overwrite real data", function()
    local zone = {}
    local real = G.Record(zone, gather({ x = 0.5, y = 0.5 }), 10)
    assert.is_nil(G.ImportPoint(zone, 0.505, 0.505, "herb"))
    assert.are.equal(1, zone[real].gathers)
    local k = G.ImportPoint(zone, 0.1, 0.1, "ore")
    assert.are.equal("5:5", k)
    assert.are.equal(0, zone[k].gathers)
    assert.is_true(zone[k].imported)
    assert.is_nil(G.ImportPoint(zone, 0.1, 0.1, "ore"))
  end)
  it("ItemsFor sums items of spots attributed to the node, sorted by count", function()
    local zone = {}
    G.Record(zone, gather({ objectID = 1, x = 0.1, y = 0.1, items = { { itemID = 10, count = 2 }, { itemID = 11, count = 5 } } }), 0)
    G.Record(zone, gather({ objectID = 1, x = 0.1, y = 0.1, items = { { itemID = 10, count = 1 } } }), 0)
    G.Record(zone, gather({ objectID = 2, x = 0.5, y = 0.5, items = { { itemID = 99, count = 4 } } }), 0)
    assert.are.same({ { 11, 5 }, { 10, 3 } }, (function()
      local out = {}
      for i, r in ipairs(G.ItemsFor(zone, 1)) do out[i] = { r.itemID, r.count } end
      return out
    end)())
    assert.are.equal(1, #G.ItemsFor(zone, 2))
    assert.are.same({}, G.ItemsFor(zone, 7))
  end)

  it("ItemsFor ignores imported cells and uses the dominant node of a mixed spot", function()
    local zone = {}
    G.ImportPoint(zone, 0.3, 0.3, "ore")
    G.Record(zone, gather({ objectID = 1, items = { { itemID = 10, count = 1 } } }), 0)
    G.Record(zone, gather({ objectID = 2, items = { { itemID = 20, count = 1 } } }), 0)
    G.Record(zone, gather({ objectID = 2, items = { { itemID = 20, count = 1 } } }), 0)
    assert.are.same({}, G.ItemsFor(zone, 1))
    local rows = G.ItemsFor(zone, 2)
    assert.are.equal(2, #rows)
    assert.are.equal(20, rows[1].itemID)
    assert.are.equal(2, rows[1].count)
    assert.are.equal(10, rows[2].itemID)
  end)
end)
