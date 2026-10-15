local ns = require("tests.helper").load("Logic/AlarmEval.lua")
local A = ns.AlarmEval

local function rules(over)
  local r = {
    muted = false,
    value = { enabled = false, gold = 500 },
    multiple = { enabled = true, n = 3, minNodes = 10 },
    rare = { enabled = true }, goal = { enabled = true }, record = { enabled = true },
  }
  for k, v in pairs(over or {}) do r[k] = v end
  return r
end

describe("AlarmEval", function()
  it("exports DEFAULTS", function()
    assert.is_false(A.DEFAULTS.muted)
    assert.are.equal(500, A.DEFAULTS.value.gold)
    assert.are.equal(10, A.DEFAULTS.multiple.minNodes)
  end)

  it("value rule fires at threshold", function()
    local r = rules({ value = { enabled = true, gold = 500 } })
    local out = A.Evaluate(r, { kind = "node", nodeCopper = 5000000, avgCopper = 0, nodeCount = 1, label = "Lotus", now = 100 }, {})
    assert.are.same({ { rule = "value", text = "High-value node: Lotus" } }, out)
    assert.are.equal(0, #A.Evaluate(r, { kind = "node", nodeCopper = 4999999, avgCopper = 0, nodeCount = 1, label = "x", now = 100 }, {}))
  end)

  it("value wins over multiple", function()
    local r = rules({ value = { enabled = true, gold = 1 } })
    local out = A.Evaluate(r, { kind = "node", nodeCopper = 100000, avgCopper = 100, nodeCount = 50, label = "x", now = 1 }, {})
    assert.are.equal(1, #out)
    assert.are.equal("value", out[1].rule)
  end)

  it("multiple rule waits for minNodes", function()
    local r = rules()
    local ctx = { kind = "node", nodeCopper = 3000, avgCopper = 1000, nodeCount = 9, label = "Rose", now = 1 }
    assert.are.equal(0, #A.Evaluate(r, ctx, {}))
    ctx.nodeCount = 10
    assert.are.same({ { rule = "multiple", text = "High-value node: Rose" } }, A.Evaluate(r, ctx, {}))
    ctx.nodeCopper = 2999
    assert.are.equal(0, #A.Evaluate(r, ctx, {}))
  end)

  it("other kinds use their rules", function()
    local r = rules()
    assert.are.same({ { rule = "rare", text = "Rare find: A" } }, A.Evaluate(r, { kind = "rare", label = "A", now = 1 }, {}))
    assert.are.same({ { rule = "goal", text = "Goal reached: B" } }, A.Evaluate(r, { kind = "goal", label = "B", now = 1 }, {}))
    assert.are.same({ { rule = "record", text = "New record: C" } }, A.Evaluate(r, { kind = "record", label = "C", now = 1 }, {}))
    r.rare.enabled = false
    assert.are.equal(0, #A.Evaluate(r, { kind = "rare", label = "A", now = 1 }, {}))
  end)

  it("throttle suppresses within 2 seconds", function()
    local r = rules()
    local st = {}
    assert.are.equal(1, #A.Evaluate(r, { kind = "rare", label = "A", now = 10 }, st))
    assert.are.equal(10, st.lastFire)
    assert.are.equal(0, #A.Evaluate(r, { kind = "rare", label = "A", now = 11.9 }, st))
    assert.are.equal(1, #A.Evaluate(r, { kind = "rare", label = "A", now = 12 }, st))
  end)

  it("mute suppresses all", function()
    local r = rules({ muted = true })
    local st = {}
    assert.are.equal(0, #A.Evaluate(r, { kind = "rare", label = "A", now = 10 }, st))
    assert.is_nil(st.lastFire)
  end)
end)
