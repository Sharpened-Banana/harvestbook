local ns = require("tests.helper").load("Logic/Rankings.lua")
local R = ns.Rankings

local function sess(secs, copper, nodes)
  return { zones = nodes or {}, zoneSeconds = secs or {}, zoneCopper = copper or {} }
end

describe("Rankings", function()
  it("Zones sums across sessions", function()
    local rows = R.Zones({
      sess({ [1] = 1000 }, { [1] = 5000 }, { [1] = 10 }),
      sess({ [1] = 800, [2] = 900 }, { [1] = 1000, [2] = 100 }, { [1] = 2, [2] = 3 }),
    }, "gph", 900)
    assert.are.equal(2, #rows)
    local z1
    for _, r in ipairs(rows) do if r.mapID == 1 then z1 = r end end
    assert.are.equal(1800, z1.seconds)
    assert.are.equal(6000, z1.copper)
    assert.are.equal(12, z1.nodes)
    assert.are.equal(6000 * 3600 / 1800, z1.gph)
    assert.are.equal(500, z1.perNode)
    assert.are.equal(12 * 3600 / 1800, z1.nodesPerHour)
    assert.is_false(z1.lowData)
  end)

  it("Zones marks under 15 minutes as low data and sorts it last", function()
    local rows = R.Zones({
      sess({ [1] = 600, [2] = 1000 }, { [1] = 99999, [2] = 10 }, { [1] = 5, [2] = 1 }),
    }, "gph", 900)
    assert.are.equal(2, rows[1].mapID)
    assert.is_false(rows[1].lowData)
    assert.are.equal(1, rows[2].mapID)
    assert.is_true(rows[2].lowData)
  end)

  it("Zones sorts by chosen metric", function()
    local s = { sess({ [1] = 3600, [2] = 3600 }, { [1] = 1000, [2] = 500 }, { [1] = 100, [2] = 5 }) }
    assert.are.equal(1, R.Zones(s, "gph", 900)[1].mapID)
    assert.are.equal(2, R.Zones(s, "perNode", 900)[1].mapID)
    assert.are.equal(1, R.Zones(s, "nodesPerHour", 900)[1].mapID)
  end)

  it("Zones handles zero seconds/nodes and ties by mapID", function()
    local rows = R.Zones({ sess({ [3] = 0, [2] = 1000, [1] = 1000 }, { [3] = 5, [2] = 0, [1] = 0 }, {}) }, "gph", 900)
    assert.are.equal(1, rows[1].mapID)
    assert.are.equal(2, rows[2].mapID)
    assert.are.equal(3, rows[3].mapID)
    assert.is_nil(rows[3].gph)
    assert.is_nil(rows[1].perNode)
  end)

  it("Spots excludes imported cells", function()
    local rows = R.Spots({
      a = { x = .1, y = .1, kind = "herb", gathers = 6, copper = 600 },
      b = { x = .2, y = .2, kind = "herb", gathers = 0, copper = 0, imported = true },
    }, 5)
    assert.are.equal(1, #rows)
    assert.are.equal("a", rows[1].spotKey)
    assert.are.equal(100, rows[1].perNode)
  end)

  it("Spots marks under 5 gathers low data", function()
    local rows = R.Spots({
      a = { x = 0, y = 0, kind = "ore", gathers = 2, copper = 9000 },
      b = { x = 0, y = 0, kind = "ore", gathers = 5, copper = 500 },
      c = { x = 0, y = 0, kind = "ore", gathers = 5, copper = 500 },
    }, 5)
    assert.are.equal("b", rows[1].spotKey)
    assert.are.equal("c", rows[2].spotKey)
    assert.are.equal("a", rows[3].spotKey)
    assert.is_true(rows[3].lowData)
    assert.is_false(rows[1].lowData)
  end)
end)
