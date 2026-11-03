local ns = require("tests.helper").load("Logic/RouteBuilder.lua")
local R = ns.RouteBuilder

local function spot(key, x, y, weight) return { key = key, x = x, y = y, weight = weight } end

-- Deterministic pseudo-random points spread far enough apart not to merge.
local function scatter(n, seed)
  local out, s = {}, seed
  local function nextValue()
    s = (s * 1103515245 + 12345) % 2147483648
    return s / 2147483648
  end
  for i = 1, n do
    out[i] = spot("s" .. i, nextValue(), nextValue(), 1 + i % 3)
  end
  return out
end

local function keys(stops)
  local out = {}
  for i, s in ipairs(stops) do out[i] = s.key end
  return out
end

local function shortestLoop(stops)
  local best = math.huge
  local order = {}
  for i, s in ipairs(stops) do order[i] = s end
  local function permute(i)
    if i > #order then
      best = math.min(best, R.Length(order))
      return
    end
    for j = i, #order do
      order[i], order[j] = order[j], order[i]
      permute(i + 1)
      order[i], order[j] = order[j], order[i]
    end
  end
  permute(2) -- the loop is closed, so the first stop can stay fixed
  return best
end

describe("RouteBuilder.Build", function()
  it("handles no spots", function()
    local r = R.Build({})
    assert.are.same({}, r.stops)
    assert.are.equal(0, r.length)
    assert.are.same({}, R.Build(nil).stops)
  end)

  it("handles one spot with zero length", function()
    local r = R.Build({ spot("a", 0.5, 0.5, 3) })
    assert.are.same({ "a" }, keys(r.stops))
    assert.are.equal(0, r.length)
  end)

  it("handles two spots as out and back", function()
    local r = R.Build({ spot("a", 0.1, 0.5, 1), spot("b", 0.5, 0.5, 9) })
    assert.are.same({ "b", "a" }, keys(r.stops))
    assert.is_true(math.abs(r.length - 0.8) < 1e-9)
  end)

  it("merges duplicate coordinates even with a zero merge distance", function()
    local r = R.Build({ spot("a", 0.5, 0.5, 2), spot("b", 0.5, 0.5, 3), spot("c", 0.5, 0.5, 1) }, { mergeDistance = 0 })
    assert.are.equal(1, #r.stops)
    assert.are.equal(6, r.stops[1].weight)
    assert.are.equal(0, r.length)
  end)

  it("merges close spots: sums weights, keeps the heavier's position", function()
    local r = R.Build({ spot("light", 0.504, 0.5, 2), spot("heavy", 0.5, 0.5, 5), spot("far", 0.9, 0.9, 1) })
    assert.are.equal(2, #r.stops)
    local merged = r.stops[1]
    assert.are.equal("heavy", merged.key)
    assert.are.equal(0.5, merged.x)
    assert.are.equal(0.5, merged.y)
    assert.are.equal(7, merged.weight)
    assert.are.same({ "heavy", "light" }, merged.keys)
  end)

  it("does not chain merges past the merge distance", function()
    local d = R.MERGE_DISTANCE
    local r = R.Build({ spot("a", 0.5, 0.5, 3), spot("b", 0.5 + d * 0.9, 0.5, 2), spot("c", 0.5 + d * 1.8, 0.5, 1) })
    assert.are.equal(2, #r.stops)
  end)

  it("keeps the highest-weight stops, counted after merging", function()
    local r = R.Build({
      spot("a", 0.1, 0.1, 5), spot("b", 0.5, 0.5, 4), spot("c", 0.9, 0.9, 3),
      spot("c2", 0.9, 0.904, 3),
    }, { maxStops = 2 })
    table.sort(r.stops, function(x, y) return x.key < y.key end)
    assert.are.same({ "a", "c" }, keys(r.stops))
    assert.are.equal(6, r.stops[2].weight)
  end)

  it("applies the default stop limit", function()
    local spots = {}
    for i = 1, R.MAX_STOPS + 10 do spots[i] = spot("s" .. i, i * 0.02 % 1, (i % 7) * 0.13, i) end
    assert.are.equal(R.MAX_STOPS, #R.Build(spots).stops)
  end)

  it("removes crossings: a square is visited around its edge", function()
    local r = R.Build({
      spot("a", 0.2, 0.2, 9), spot("c", 0.8, 0.8, 1), spot("b", 0.8, 0.2, 1), spot("d", 0.2, 0.8, 1),
    })
    assert.is_true(math.abs(r.length - 2.4) < 1e-9)
    assert.are.equal("a", r.stops[1].key)
  end)

  it("2-opt shortens the nearest-neighbour loop", function()
    local improved = false
    for seed = 1, 10 do
      local spots = scatter(R.MAX_STOPS, seed)
      local nn = R.Build(spots, { maxPasses = 0 }).length
      local opt = R.Build(spots).length
      assert.is_true(opt <= nn + 1e-9)
      if opt < nn - 1e-6 then improved = true end
    end
    assert.is_true(improved)
  end)

  it("stays close to the true shortest loop on small inputs", function()
    for seed = 1, 5 do
      local r = R.Build(scatter(8, seed))
      assert.are.equal(8, #r.stops)
      assert.is_true(r.length <= shortestLoop(r.stops) * 1.15)
    end
  end)

  it("returns a loop that visits every stop exactly once", function()
    local r = R.Build(scatter(25, 7))
    local seen = {}
    for _, s in ipairs(r.stops) do
      assert.is_nil(seen[s.key])
      seen[s.key] = true
    end
    assert.are.equal(25, #r.stops)
    assert.is_true(math.abs(r.length - R.Length(r.stops)) < 1e-9)
  end)

  it("gives the same result whatever order the spots arrive in", function()
    local spots = scatter(20, 3)
    spots[#spots + 1] = spot("dupA", 0.4, 0.4, 2)
    spots[#spots + 1] = spot("dupB", 0.4, 0.4, 2)
    local reversed = {}
    for i = #spots, 1, -1 do reversed[#reversed + 1] = spots[i] end
    local a, b = R.Build(spots), R.Build(reversed)
    assert.are.same(a, b)
    assert.are.same(a, R.Build(spots))
  end)

  it("does not change its input", function()
    local spots = { spot("b", 0.1, 0.1, 1), spot("a", 0.100001, 0.1, 5) }
    R.Build(spots)
    assert.are.same({ spot("b", 0.1, 0.1, 1), spot("a", 0.100001, 0.1, 5) }, spots)
  end)

  it("skips unusable spots and treats a bad weight as zero", function()
    local r = R.Build({
      spot("noX", nil, 0.5, 1), spot("text", "0.5", 0.5, 1), spot("out", 1.5, 0.5, 1),
      spot("nan", 0 / 0, 0.5, 1), "junk", spot("ok", 0.5, 0.5, nil),
    })
    assert.are.same({ "ok" }, keys(r.stops))
    assert.are.equal(0, r.stops[1].weight)
  end)
end)

describe("RouteBuilder.Length", function()
  it("is zero below two stops and closes the loop", function()
    assert.are.equal(0, R.Length({}))
    assert.are.equal(0, R.Length({ { x = 0.5, y = 0.5 } }))
    local triangle = { { x = 0, y = 0 }, { x = 0.3, y = 0 }, { x = 0.3, y = 0.4 } }
    assert.is_true(math.abs(R.Length(triangle) - 1.2) < 1e-9)
  end)
end)

describe("RouteBuilder.Spots", function()
  local zone = {
    ["1:1"] = { x = 0.02, y = 0.02, kind = "herb", gathers = 5 },
    ["2:2"] = { x = 0.04, y = 0.04, kind = "ore", gathers = 1 },
    ["3:3"] = { x = 0.06, y = 0.06, kind = "skin", gathers = 9 },
    ["4:4"] = { x = 0.08, y = 0.08, kind = "herb", gathers = 0, imported = true },
  }

  local function sortedKeys(spots)
    local out = keys(spots)
    table.sort(out)
    return out
  end

  it("uses gathers as weight", function()
    local spots = R.Spots(zone, { herb = true }, 1)
    assert.are.same({ "1:1" }, keys(spots))
    assert.are.equal(5, spots[1].weight)
    assert.are.equal(0.02, spots[1].x)
    assert.are.equal("herb", spots[1].kind)
  end)

  it("filters by kind and minimum gathers", function()
    local all = { herb = true, ore = true, skin = true }
    assert.are.same({ "1:1", "2:2", "3:3" }, sortedKeys(R.Spots(zone, all, 1)))
    assert.are.same({ "1:1", "3:3" }, sortedKeys(R.Spots(zone, all, 5)))
    assert.are.same({ "3:3" }, sortedKeys(R.Spots(zone, { skin = true, ore = false }, 1)))
  end)

  it("never includes imported spots with no gathers, even at minimum 0", function()
    assert.are.same({ "1:1" }, keys(R.Spots(zone, { herb = true }, 0)))
  end)

  it("copes with a missing zone or kinds", function()
    assert.are.same({}, R.Spots(nil, { herb = true }, 1))
    assert.are.same({}, R.Spots(zone, nil, 1))
    assert.are.same({}, R.Spots({ bad = "junk" }, { herb = true }, 1))
  end)
end)

describe("RouteBuilder.LegDots", function()
  local function stop(x, y) return { x = x, y = y } end

  it("has no dots below two stops or for stops closer than the spacing", function()
    assert.are.same({}, R.LegDots({}))
    assert.are.same({}, R.LegDots({ stop(0.5, 0.5) }))
    assert.are.same({}, R.LegDots({ stop(0.5, 0.5), stop(0.5, 0.5) }))
    assert.are.same({}, R.LegDots({ stop(0.5, 0.5), stop(0.51, 0.5) }, 0.02))
  end)

  it("spaces dots evenly and leaves the stops themselves free", function()
    local dots = R.LegDots({ stop(0.1, 0.5), stop(0.5, 0.5) }, 0.1)
    assert.are.equal(3, #dots)
    assert.is_true(math.abs(dots[1].x - 0.2) < 1e-9)
    assert.is_true(math.abs(dots[2].x - 0.3) < 1e-9)
    assert.is_true(math.abs(dots[3].x - 0.4) < 1e-9)
    assert.are.equal(0.5, dots[1].y)
  end)

  it("draws a two-stop route's shared leg only once", function()
    assert.are.equal(3, #R.LegDots({ stop(0.1, 0.5), stop(0.5, 0.5) }, 0.1))
  end)

  it("includes the leg back to the first stop", function()
    local dots = R.LegDots({ stop(0.1, 0.1), stop(0.5, 0.1), stop(0.5, 0.5) }, 0.1)
    assert.are.equal(3 + 3 + 4, #dots)
    local last = dots[#dots]
    assert.is_true(last.x < 0.5 and last.y < 0.5)
  end)

  it("widens the spacing instead of exceeding the dot limit", function()
    local stops = {}
    for i, s in ipairs(scatter(R.MAX_STOPS, 11)) do stops[i] = stop(s.x, s.y) end
    local dots = R.LegDots(stops, 0.001, 50)
    assert.is_true(#dots <= 50)
    assert.is_true(#dots > 0)
    assert.is_true(#R.LegDots(stops, 0.001) <= R.MAX_DOTS)
  end)

  it("gives no dots when the limit is zero", function()
    assert.are.same({}, R.LegDots({ stop(0.1, 0.5), stop(0.5, 0.5) }, 0.1, 0))
  end)
end)

describe("RouteBuilder.Sanitize", function()
  local function saved()
    return {
      mapID = 2371, target = 1,
      stops = {
        { x = 0.1, y = 0.2, gathers = 3, nodeID = 77, kind = "herb" },
        { x = 0.5, y = 0.6, gathers = 1 },
      },
    }
  end

  it("accepts a good route", function()
    assert.are.same(saved(), R.Sanitize(saved()))
  end)

  it("rejects things that are not routes", function()
    assert.is_nil(R.Sanitize(nil))
    assert.is_nil(R.Sanitize("route"))
    assert.is_nil(R.Sanitize({}))
    assert.is_nil(R.Sanitize({ mapID = "x", stops = saved().stops }))
    assert.is_nil(R.Sanitize({ mapID = 1, stops = "x" }))
    assert.is_nil(R.Sanitize({ mapID = 1, stops = {} }))
  end)

  it("rejects a route with any unreadable stop", function()
    for _, bad in ipairs({
      "junk",
      { x = 0.1, gathers = 1 },
      { x = "0.1", y = 0.1, gathers = 1 },
      { x = 1.2, y = 0.1, gathers = 1 },
      { x = 0 / 0, y = 0.1, gathers = 1 },
      { x = 0.1, y = 0.1 },
    }) do
      local r = saved()
      r.stops[2] = bad
      assert.is_nil(R.Sanitize(r))
    end
  end)

  it("rejects more stops than a route can have", function()
    local r = saved()
    for i = 1, R.MAX_STOPS do r.stops[#r.stops + 1] = { x = 0.1, y = 0.1, gathers = 1 } end
    assert.is_nil(R.Sanitize(r))
  end)

  it("resets a bad waypoint position rather than losing the route", function()
    for _, target in ipairs({ -1, 3, 1.5, "1", false }) do
      local r = saved()
      r.target = target
      assert.are.equal(0, R.Sanitize(r).target)
    end
    local r = saved()
    r.target = nil
    assert.are.equal(0, R.Sanitize(r).target)
  end)

  it("drops unreadable optional fields but keeps the stop", function()
    local r = saved()
    r.stops[1].nodeID = "x"
    r.stops[1].kind = 5
    local out = R.Sanitize(r)
    assert.is_nil(out.stops[1].nodeID)
    assert.is_nil(out.stops[1].kind)
    assert.are.equal(3, out.stops[1].gathers)
  end)
end)
