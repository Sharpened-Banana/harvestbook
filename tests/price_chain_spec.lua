local ns = require("tests.helper").load("Logic/PriceChain.lua")
local P = ns.PriceChain

describe("PriceChain", function()
  it("first source with a value wins", function()
    local sources = {
      { name = "a", fn = function() return nil end },
      { name = "b", fn = function() return 120 end },
      { name = "c", fn = function() return 999 end },
    }
    local c, n = P.Resolve(1, 1, "link", sources)
    assert.are.equal(120, c)
    assert.are.equal("b", n)
  end)

  it("passes itemID, quality and link to sources", function()
    local got
    P.Resolve(7, 3, "L", { { name = "x", fn = function(...) got = { ... }; return 5 end } })
    assert.are.same({ 7, 3, "L" }, got)
  end)

  it("PriceChain skips a source that errors", function()
    local sources = {
      { name = "bad", fn = function() error("bad key") end },
      { name = "next", fn = function() return 50 end },
    }
    local c, n = P.Resolve(1, nil, nil, sources)
    assert.are.equal(50, c)
    assert.are.equal("next", n)
  end)

  it("PriceChain falls through to none", function()
    local c, n = P.Resolve(1, nil, nil, { { name = "a", fn = function() return nil end } })
    assert.are.equal(0, c)
    assert.are.equal("none", n)
    c, n = P.Resolve(1, nil, nil, {})
    assert.are.equal(0, c)
    assert.are.equal("none", n)
    c, n = P.Resolve(1, nil, nil, nil)
    assert.are.equal(0, c)
    assert.are.equal("none", n)
  end)

  it("zero is treated as no price", function()
    local sources = {
      { name = "zero", fn = function() return 0 end },
      { name = "neg", fn = function() return -5 end },
      { name = "real", fn = function() return 10 end },
    }
    local c, n = P.Resolve(1, nil, nil, sources)
    assert.are.equal(10, c)
    assert.are.equal("real", n)
  end)

  it("non-number results are treated as no price", function()
    local sources = {
      { name = "str", fn = function() return "100" end },
      { name = "tbl", fn = function() return {} end },
      { name = "nan", fn = function() return 0 / 0 end },
      { name = "real", fn = function() return 10 end },
    }
    local c, n = P.Resolve(1, nil, nil, sources)
    assert.are.equal(10, c)
    assert.are.equal("real", n)
  end)

  it("floors results to integer copper", function()
    local c, n = P.Resolve(1, nil, nil, { { name = "a", fn = function() return 12.9 end } })
    assert.are.equal(12, c)
    assert.are.equal("a", n)
  end)

  it("a fractional price below 1 copper falls through", function()
    local sources = {
      { name = "tiny", fn = function() return 0.5 end },
      { name = "real", fn = function() return 3 end },
    }
    local c, n = P.Resolve(1, nil, nil, sources)
    assert.are.equal(3, c)
    assert.are.equal("real", n)
  end)

  it("AfterCut takes 5% off auction sources only when on", function()
    assert.are.equal(950, P.AfterCut(1000, "auctionator", true))
    assert.are.equal(950, P.AfterCut(1000, "tsm", true))
    assert.are.equal(1000, P.AfterCut(1000, "vendor", true))
    assert.are.equal(1000, P.AfterCut(1000, "override", true))
    assert.are.equal(1000, P.AfterCut(1000, "tsm", false))
    assert.are.equal(0, P.AfterCut(0, "none", true))
  end)

  it("AfterCut floors to whole copper", function()
    assert.are.equal(9, P.AfterCut(10, "tsm", true)) -- 9.5 -> 9
  end)
end)
