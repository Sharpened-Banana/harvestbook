local ns = require("tests.helper").load("Logic/SessionMath.lua", "Logic/GoldLedger.lua", "Logic/Export.lua")
local E = ns.Export

local SESSION_HEADER = "Date,Duration (seconds),Zones,Herb nodes,Ore nodes,Skin nodes,Gold,Gold per hour"

local NAMES = { [1] = "Eversong Woods", [2] = "Zul'Aman", [3] = "Quel'Thalas, Upper", [4] = "=SUM(A1)" }

local helpers = {
  date = function(t) return "D" .. t end,
  zoneName = function(mapID) return NAMES[mapID] end,
  price = function() return 0, "stub" end,
}

-- A stopped session worth `copper`: one item at a frozen price.
local function session(id, started, active, copper, zones, nodes)
  return {
    id = id, state = "stopped", started = started, activeSeconds = active,
    zones = zones or {}, nodes = nodes or { herb = 0, ore = 0, skin = 0 },
    items = { ["10:1"] = { itemID = 10, quality = 1, count = 1 } },
    prices = { ["10:1"] = { copper = copper, source = "stub" } },
  }
end

local function lines(text)
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
  return out
end

describe("Export.Sessions", function()
  it("is the header alone with no sessions", function()
    assert.are.equal(SESSION_HEADER, E.Sessions({}, helpers))
    assert.are.equal(SESSION_HEADER, E.Sessions(nil, helpers))
  end)

  it("writes one row per session with every column", function()
    local s = session(1, 500, 3600, 1234567, { [1] = 2 }, { herb = 5, ore = 2, skin = 1 })
    local rows = lines(E.Sessions({ s }, helpers))
    assert.are.equal(2, #rows)
    assert.are.equal(SESSION_HEADER, rows[1])
    assert.are.equal("D500,3600,Eversong Woods,5,2,1,123.46,123.46", rows[2])
  end)

  it("lists every zone, most visited first, quoting names with commas", function()
    local s = session(1, 0, 3600, 0, { [1] = 1, [2] = 3, [3] = 1 })
    local row = lines(E.Sessions({ s }, helpers))[2]
    assert.are.equal('D0,3600,"Zul\'Aman; Eversong Woods; Quel\'Thalas, Upper",0,0,0,0,0', row)
  end)

  it("leaves gold per hour empty for a very short session", function()
    local row = lines(E.Sessions({ session(1, 0, 30, 10000) }, helpers))[2]
    assert.are.equal("D0,30,,0,0,0,1,", row)
  end)

  it("orders newest first and breaks ties by id, without touching the input", function()
    local list = { session(1, 100, 60, 0), session(3, 200, 60, 0), session(2, 200, 60, 0) }
    local rows = lines(E.Sessions(list, helpers))
    assert.are.equal("D200", rows[2]:match("^[^,]+"))
    assert.are.equal(3, list[2].id)
    assert.are.equal(1, list[1].id)
    assert.are.equal(E.Sessions(list, helpers), E.Sessions({ list[3], list[1], list[2] }, helpers))
  end)

  it("uses the price function for a session that is not stopped", function()
    local s = session(1, 0, 3600, 0)
    s.state = "paused"
    local h = { date = helpers.date, zoneName = helpers.zoneName, price = function() return 20000, "stub" end }
    assert.are.equal("D0,3600,,0,0,0,2,2", lines(E.Sessions({ s }, h))[2])
  end)

  it("treats a formula-like zone name as text", function()
    local row = lines(E.Sessions({ session(1, 0, 60, 0, { [4] = 1 }) }, helpers))[2]
    assert.are.equal("D0,60,'=SUM(A1),0,0,0,0,0", row)
  end)

  it("tolerates a session without node counts", function()
    local s = session(1, 0, 60, 0)
    s.nodes = nil
    assert.are.equal("D0,60,,0,0,0,0,0", lines(E.Sessions({ s }, helpers))[2])
  end)
end)

describe("Export gold formatting", function()
  local function goldOf(copper)
    return lines(E.Gold({ day = { k = copper } }, "day"))[2]:match(",(.*)$")
  end

  it("uses whole gold with up to 2 decimals", function()
    assert.are.equal("120", goldOf(1200000))
    assert.are.equal("120.5", goldOf(1205000))
    assert.are.equal("120.05", goldOf(1200500))
    assert.are.equal("1.23", goldOf(12345))
    assert.are.equal("0.01", goldOf(100))
    assert.are.equal("100", goldOf(1000000))
    assert.are.equal("0", goldOf(0))
  end)

  it("rounds to the nearest hundredth of a gold", function()
    assert.are.equal("0.02", goldOf(150))
    assert.are.equal("1", goldOf(9999))
  end)

  it("never uses exponent notation", function()
    assert.are.equal("1234567890123.45", goldOf(12345678901234500))
  end)

  it("leaves a negative number alone", function()
    assert.are.equal("-1.5", goldOf(-15000))
  end)
end)

describe("Export.Materials", function()
  local function nameOf(id) return ({ [1] = "Peacebloom", [2] = "Hunter's Ore, Rich", [3] = 'The "Best" Herb',
    [4] = "Line\nBreak", [5] = "Dale's", [6] = "-Minus", [7] = "+Plus", [8] = "@At", [9] = "=1+1",
    [10] = '=a,"b"' })[id] end

  local function row(id) return lines(E.Materials({ [id] = 7 }, nameOf))[2] end

  it("is the header alone with no materials", function()
    assert.are.equal("Item ID,Item name,Lifetime count", E.Materials({}, nameOf))
    assert.are.equal("Item ID,Item name,Lifetime count", E.Materials(nil, nameOf))
  end)

  it("orders by count, then item ID", function()
    local rows = lines(E.Materials({ [5] = 3, [1] = 3, [2] = 9 }, nameOf))
    assert.are.equal('2,"Hunter\'s Ore, Rich",9', rows[2])
    assert.are.equal("1,Peacebloom,3", rows[3])
    assert.are.equal("5,Dale's,3", rows[4])
  end)

  it("leaves a plain apostrophe unquoted", function()
    assert.are.equal("5,Dale's,7", row(5))
  end)

  it("wraps commas and doubles internal quotes", function()
    assert.are.equal('2,"Hunter\'s Ore, Rich",7', row(2))
    assert.are.equal('3,"The ""Best"" Herb",7', row(3))
  end)

  it("wraps embedded newlines", function()
    assert.are.equal('4,"Line\nBreak",7', E.Materials({ [4] = 7 }, nameOf):match("\n(.*)$"))
  end)

  it("prefixes every formula starter with one apostrophe", function()
    assert.are.equal("6,'-Minus,7", row(6))
    assert.are.equal("7,'+Plus,7", row(7))
    assert.are.equal("8,'@At,7", row(8))
    assert.are.equal("9,'=1+1,7", row(9))
  end)

  it("prefixes before quoting", function()
    assert.are.equal('10,"\'=a,""b""",7', row(10))
  end)

  it("writes large counts in full and an empty cell for a missing name", function()
    assert.are.equal("99,,123456789012345", lines(E.Materials({ [99] = 123456789012345 }, nameOf))[2])
  end)
end)

describe("Export.Gold", function()
  local function label(key) return "L" .. key end

  it("is the header alone with no data or a bad period", function()
    assert.are.equal("Period,Gold", E.Gold({}, "day", label))
    assert.are.equal("Period,Gold", E.Gold(nil, "day", label))
    assert.are.equal("Period,Gold", E.Gold({ total = 500 }, "total", label))
  end)

  it("writes the chosen bucket only, newest first", function()
    local ledger = {
      total = 90000,
      day = { ["2026-01-01"] = 10000, ["2026-01-03"] = 30000, ["2026-01-02"] = 20000 },
      weekly = { [604800] = 50000 },
    }
    assert.are.equal("Period,Gold\nL2026-01-03,3\nL2026-01-02,2\nL2026-01-01,1", E.Gold(ledger, "day", label))
    assert.are.equal("Period,Gold\nL604800,5", E.Gold(ledger, "weekly", label))
    assert.are.equal("Period,Gold", E.Gold(ledger, "daily", label))
  end)

  it("sorts numeric reset keys as numbers", function()
    local out = E.Gold({ daily = { [900000] = 10000, [1000000] = 20000 } }, "daily", label)
    assert.are.equal("Period,Gold\nL1000000,2\nL900000,1", out)
  end)

  it("escapes a label like any text", function()
    assert.are.equal('Period,Gold\n"\'-x, y",1', E.Gold({ day = { k = 10000 } }, "day", function() return "-x, y" end))
  end)
end)

describe("Export size", function()
  it("builds 500 sessions without a trailing newline", function()
    local list = {}
    for i = 1, 500 do list[i] = session(i, i, 3600, i * 100, { [1] = 1, [2] = 2, [3] = 3 }) end
    local text = E.Sessions(list, helpers)
    assert.are.equal(501, #lines(text))
    assert.is_nil(text:find("\n$"))
  end)
end)
