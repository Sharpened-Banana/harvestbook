local ns = require("tests.helper").load("Logic/Migrate.lua")
local Migrate = ns.Migrate

describe("Migrate", function()
  it("Run applies only newer migrations in order", function()
    local log = {}
    local migrations = {
      function() log[#log + 1] = 1 end,
      function() log[#log + 1] = 2 end,
      function() log[#log + 1] = 3 end,
    }
    local g = { schemaVersion = 1 }
    assert.are.equal(3, Migrate.Run(g, migrations))
    assert.are.same({ 2, 3 }, log)
    assert.are.equal(3, g.schemaVersion)
  end)
  it("Run on fresh db applies all", function()
    local log = {}
    local migrations = {
      function(g) log[#log + 1] = 1; g.a = true end,
      function(g) log[#log + 1] = 2; g.b = true end,
    }
    local g = {}
    assert.are.equal(2, Migrate.Run(g, migrations))
    assert.are.same({ 1, 2 }, log)
    assert.is_true(g.a)
    assert.is_true(g.b)
    assert.are.equal(2, g.schemaVersion)
  end)
end)
