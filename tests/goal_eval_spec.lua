local ns = require("tests.helper").load("Logic/SessionMath.lua", "Logic/GoalEval.lua")
local S, G = ns.SessionMath, ns.GoalEval

local function priceFn() return 100, "stub" end

local function session()
  local s = S.New(0)
  S.AddGather(s, { kind = "herb", mapID = 1, items = {
    { itemID = 10, quality = 1, count = 3 },
    { itemID = 10, quality = 2, count = 2 },
    { itemID = 20, quality = 1, count = 5 },
  } }, 0, priceFn)
  return s
end

describe("GoalEval", function()
  it("materials goal counts any item when itemID nil", function()
    local cur, target, done = G.Progress({ id = 1, type = "materials", target = 10 }, session(), 10, priceFn)
    assert.are.equal(10, cur)
    assert.are.equal(10, target)
    assert.is_true(done)
  end)

  it("materials goal with itemID counts all qualities", function()
    local cur, target, done = G.Progress({ id = 1, type = "materials", itemID = 10, target = 6 }, session(), 10, priceFn)
    assert.are.equal(5, cur)
    assert.are.equal(6, target)
    assert.is_false(done)
  end)

  it("gold goal uses session value", function()
    local cur, _, done = G.Progress({ id = 2, type = "gold", target = 1000 }, session(), 10, priceFn)
    assert.are.equal(1000, cur)
    assert.is_true(done)
    local _, _, done2 = G.Progress({ id = 2, type = "gold", target = 1001 }, session(), 10, priceFn)
    assert.is_false(done2)
  end)

  it("minutes goal uses active time", function()
    local s = S.New(0)
    local cur, target, done = G.Progress({ id = 3, type = "minutes", target = 2 }, s, 60, priceFn)
    assert.are.equal(1, cur)
    assert.are.equal(2, target)
    assert.is_false(done)
    local _, _, done2 = G.Progress({ id = 3, type = "minutes", target = 2 }, s, 120, priceFn)
    assert.is_true(done2)
  end)

  it("NewlyReached fires once", function()
    local goals = { { id = 1, type = "materials", target = 10 }, { id = 2, type = "gold", target = 99999 } }
    local reached = {}
    local r = G.NewlyReached(goals, session(), 10, priceFn, reached)
    assert.are.equal(1, #r)
    assert.are.equal(1, r[1].id)
    assert.is_true(reached[1])
    assert.are.equal(0, #G.NewlyReached(goals, session(), 10, priceFn, reached))
  end)

  it("UpdateAttempts counts misses and resets on find", function()
    local a = { [5] = { attempts = 0, found = 0, kind = nil, sinceLast = 0 } }
    local found = G.UpdateAttempts(a, { kind = "herb", items = { { itemID = 9, count = 1 } } })
    assert.are.same({}, found)
    G.UpdateAttempts(a, { kind = "ore", items = {} })
    assert.are.equal(2, a[5].attempts)
    assert.are.equal(2, a[5].sinceLast)
    found = G.UpdateAttempts(a, { kind = "herb", items = { { itemID = 5, count = 1 } } })
    assert.are.same({ 5 }, found)
    assert.are.equal(1, a[5].found)
    assert.are.equal(0, a[5].sinceLast)
    assert.are.equal(2, a[5].attempts)
  end)

  it("UpdateAttempts ignores other kinds", function()
    local a = { [5] = { attempts = 0, found = 0, kind = "ore", sinceLast = 0 } }
    local found = G.UpdateAttempts(a, { kind = "herb", items = { { itemID = 5, count = 1 } } })
    assert.are.same({}, found)
    assert.are.equal(0, a[5].attempts)
    assert.are.equal(0, a[5].found)
  end)
end)
