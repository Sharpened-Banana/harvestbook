local ns = require("tests.helper").load("Logic/NodeGrid.lua", "Logic/ShoppingEval.lua")
local G, E = ns.NodeGrid, ns.ShoppingEval

local ITEM = 100

-- Records `times` gathers of nodeID at (x, y), each giving `count` of the item.
local function gather(zone, nodeID, x, y, times, count, itemID)
  for _ = 1, times do
    G.Record(zone, {
      objectID = nodeID, kind = "herb", x = x, y = y, time = 0,
      items = count > 0 and { { itemID = itemID or ITEM, count = count } } or {},
    }, 0)
  end
end

describe("NodeGrid.ItemYield", function()
  it("is zero for a zone that never gave the item", function()
    local zone = {}
    gather(zone, 1, 0.1, 0.1, 3, 2, 999)
    local items, gathers = G.ItemYield(zone, ITEM)
    assert.are.equal(0, items)
    assert.are.equal(0, gathers)
  end)

  it("sums items and gathers over spots", function()
    local zone = {}
    gather(zone, 1, 0.1, 0.1, 3, 2)
    gather(zone, 1, 0.5, 0.5, 2, 1)
    local items, gathers = G.ItemYield(zone, ITEM)
    assert.are.equal(8, items)
    assert.are.equal(5, gathers)
  end)

  it("counts gathers of the giving node at spots where the item did not drop", function()
    local zone = {}
    gather(zone, 1, 0.1, 0.1, 1, 1)
    gather(zone, 1, 0.5, 0.5, 99, 0)
    local items, gathers = G.ItemYield(zone, ITEM)
    assert.are.equal(1, items)
    assert.are.equal(100, gathers)
  end)

  it("leaves out gathers of other nodes in the zone", function()
    local zone = {}
    gather(zone, 1, 0.1, 0.1, 5, 2)
    gather(zone, 2, 0.5, 0.5, 50, 3, 999)
    local items, gathers = G.ItemYield(zone, ITEM)
    assert.are.equal(10, items)
    assert.are.equal(5, gathers)
  end)

  it("ignores imported spots", function()
    local zone = {}
    G.ImportPoint(zone, 0.9, 0.9, "herb")
    gather(zone, 1, 0.1, 0.1, 2, 1)
    local items, gathers = G.ItemYield(zone, ITEM)
    assert.are.equal(2, items)
    assert.are.equal(2, gathers)
  end)
end)

describe("ShoppingEval.BestZone", function()
  it("returns nil when no zone gave the item", function()
    local zones = { [1] = {} }
    gather(zones[1], 1, 0.1, 0.1, 9, 2, 999)
    assert.is_nil(E.BestZone(zones, ITEM))
    assert.is_nil(E.BestZone({}, ITEM))
  end)

  it("picks the highest average per gather", function()
    local zones = { [1] = {}, [2] = {} }
    gather(zones[1], 1, 0.1, 0.1, 50, 1)
    gather(zones[2], 1, 0.1, 0.1, 5, 3)
    local mapID, avg = E.BestZone(zones, ITEM)
    assert.are.equal(2, mapID)
    assert.are.equal(3, avg)
  end)

  it("does not let one lucky node win", function()
    local zones = { [1] = {}, [2] = {} }
    gather(zones[1], 1, 0.1, 0.1, 6, 1)
    gather(zones[2], 1, 0.1, 0.1, 1, 10)
    local mapID, avg = E.BestZone(zones, ITEM)
    assert.are.equal(1, mapID)
    assert.are.equal(1, avg)
  end)

  it("needs exactly five gathers to qualify", function()
    local zones = { [1] = {}, [2] = {} }
    gather(zones[1], 1, 0.1, 0.1, 40, 1)
    gather(zones[2], 1, 0.1, 0.1, 4, 5)
    assert.are.equal(1, (E.BestZone(zones, ITEM)))
    gather(zones[2], 1, 0.1, 0.1, 1, 5)
    assert.are.equal(2, (E.BestZone(zones, ITEM)))
  end)

  it("falls back to the most-gathered zone that gave it, with that zone's average", function()
    local zones = { [1] = {}, [2] = {}, [3] = {} }
    gather(zones[1], 1, 0.1, 0.1, 4, 1)
    gather(zones[2], 1, 0.1, 0.1, 2, 9)
    gather(zones[3], 1, 0.1, 0.1, 99, 2, 999) -- most gathered, never gave it
    local mapID, avg = E.BestZone(zones, ITEM)
    assert.are.equal(1, mapID)
    assert.are.equal(1, avg)
  end)

  it("rates a rare drop by every gather of its node, not only the lucky spots", function()
    local zones = { [1] = {}, [2] = {} }
    for i = 1, 5 do gather(zones[1], 1, i / 50, 0.1, 1, 1) end -- five lucky spots...
    gather(zones[1], 1, 0.5, 0.5, 995, 0)                      -- ...of 1000 gathers
    gather(zones[2], 1, 0.1, 0.1, 10, 1)
    local mapID, avg = E.BestZone(zones, ITEM)
    assert.are.equal(2, mapID)
    assert.are.equal(1, avg)
    zones[2] = nil
    local _, rare = E.BestZone(zones, ITEM)
    assert.are.equal(0.005, rare)
  end)

  it("breaks an equal average by gathers, then the lower mapID", function()
    local zones = { [7] = {}, [3] = {}, [9] = {} }
    gather(zones[7], 1, 0.1, 0.1, 5, 1)
    gather(zones[3], 1, 0.1, 0.1, 5, 1)
    gather(zones[9], 1, 0.1, 0.1, 8, 1)
    assert.are.equal(9, (E.BestZone(zones, ITEM)))
    zones[9] = nil
    assert.are.equal(3, (E.BestZone(zones, ITEM)))
  end)
end)

describe("ShoppingEval progress", function()
  it("Remaining never goes below zero", function()
    assert.are.equal(150, E.Remaining(200, 50))
    assert.are.equal(0, E.Remaining(200, 200))
    assert.are.equal(0, E.Remaining(200, 500))
  end)

  it("Done at or past the target", function()
    assert.is_false(E.Done(200, 199))
    assert.is_true(E.Done(200, 200))
    assert.is_true(E.Done(200, 201))
  end)

  it("NodesNeeded rounds up", function()
    assert.are.equal(75, E.NodesNeeded(200, 50, 2))
    assert.are.equal(4, E.NodesNeeded(10, 0, 3))
    assert.are.equal(1, E.NodesNeeded(10, 9, 3))
  end)

  it("NodesNeeded is zero when done, nil without an average", function()
    assert.are.equal(0, E.NodesNeeded(10, 10, 3))
    assert.is_nil(E.NodesNeeded(10, 0, nil))
    assert.is_nil(E.NodesNeeded(10, 0, 0))
  end)
end)

describe("ShoppingEval.SortRows", function()
  it("puts unfinished first, then sorts by name, then itemID", function()
    local rows = E.SortRows({
      { itemID = 1, name = "Zinc", target = 5, have = 0 },
      { itemID = 2, name = "Apple", target = 5, have = 5 },
      { itemID = 3, name = "Mint", target = 5, have = 1 },
      { itemID = 5, name = "Bog", target = 5, have = 9 },
      { itemID = 7, name = "Iron", target = 5, have = 0 },
      { itemID = 6, name = "Iron", target = 5, have = 0 },
    })
    local ids = {}
    for i, r in ipairs(rows) do ids[i] = r.itemID end
    assert.are.same({ 6, 7, 3, 1, 2, 5 }, ids)
  end)
end)

describe("ShoppingEval.Upsert", function()
  it("adds a new entry", function()
    local list = {}
    assert.are.equal("added", E.Upsert(list, 10, 200))
    assert.are.same({ { itemID = 10, target = 200 } }, list)
  end)

  it("updates the target of a listed item", function()
    local list = { { itemID = 10, target = 200 }, { itemID = 11, target = 5 } }
    assert.are.equal("updated", E.Upsert(list, 11, 7))
    assert.are.same({ { itemID = 10, target = 200 }, { itemID = 11, target = 7 } }, list)
  end)

  it("refuses a new item at the limit but still updates a listed one", function()
    local list = {}
    for i = 1, E.MAX_ENTRIES do E.Upsert(list, i, 1) end
    assert.are.equal(30, #list)
    local status, reason = E.Upsert(list, 999, 1)
    assert.is_nil(status)
    assert.are.equal("limit", reason)
    assert.are.equal(30, #list)
    assert.are.equal("updated", E.Upsert(list, 30, 8))
    assert.are.equal(8, list[30].target)
  end)
end)

describe("ShoppingEval.Remove", function()
  it("removes a listed item and reports it", function()
    local list = { { itemID = 10, target = 1 }, { itemID = 11, target = 2 } }
    assert.is_true(E.Remove(list, 10))
    assert.are.same({ { itemID = 11, target = 2 } }, list)
    assert.is_false(E.Remove(list, 10))
  end)
end)

describe("ShoppingEval.NewlyDone", function()
  local function row(itemID, target, have) return { itemID = itemID, target = target, have = have } end

  it("reports an item once when it goes from unfinished to done", function()
    local set = {}
    assert.are.same({}, E.NewlyDone({ row(1, 5, 4) }, set))
    local out = E.NewlyDone({ row(1, 5, 5) }, set)
    assert.are.equal(1, #out)
    assert.are.equal(1, out[1].itemID)
    assert.are.same({}, E.NewlyDone({ row(1, 5, 6) }, set))
  end)

  it("reports again after falling back below the target", function()
    local set = { [1] = true }
    assert.are.same({}, E.NewlyDone({ row(1, 5, 4) }, set))
    assert.is_nil(set[1])
    assert.are.equal(1, #E.NewlyDone({ row(1, 5, 5) }, set))
  end)

  it("drops items that left the list", function()
    local set = { [1] = true }
    E.NewlyDone({}, set)
    assert.is_nil(set[1])
  end)
end)

describe("ShoppingEval.ParseItem", function()
  it("reads an item link", function()
    assert.are.equal(236761, E.ParseItem("|cff1eff00|Hitem:236761::::::::80:::::|h[Tranquility Bloom]|h|r"))
  end)

  it("reads a bare or padded item ID", function()
    assert.are.equal(123, E.ParseItem("123"))
    assert.are.equal(123, E.ParseItem("  123 "))
    assert.are.equal(123, E.ParseItem("item:123"))
  end)

  it("rejects anything else", function()
    assert.is_nil(E.ParseItem(nil))
    assert.is_nil(E.ParseItem(""))
    assert.is_nil(E.ParseItem("  "))
    assert.is_nil(E.ParseItem("abc"))
    assert.is_nil(E.ParseItem("12.5"))
    assert.is_nil(E.ParseItem("1e5"))
    assert.is_nil(E.ParseItem("0"))
    assert.is_nil(E.ParseItem("-5"))
  end)
end)

describe("ShoppingEval.ParseItem range", function()
  it("rejects a number no item ID can be", function()
    assert.are.equal(2147483647, E.ParseItem("2147483647"))
    assert.is_nil(E.ParseItem("2147483648"))
    assert.is_nil(E.ParseItem("99999999999999999999"))
  end)
end)
