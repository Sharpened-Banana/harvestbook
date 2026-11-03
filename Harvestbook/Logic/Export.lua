local ADDON, ns = ...

-- CSV text of the player's data, for pasting into a spreadsheet. Each function
-- returns the header row first and no trailing newline; anything needing the
-- WoW API is passed in. Text cells may start a formula, numbers are written as
-- plain numbers; %.0f and %.2f because tostring switches to exponents.

local M = {}
ns.Export = M

local SessionMath = ns.SessionMath
local GoldLedger = ns.GoldLedger

local function finite(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function number(v)
  return finite(v) and string.format("%.0f", v) or ""
end

-- Copper as gold: up to 2 decimals, trailing zeros dropped.
local function gold(copper)
  if not finite(copper) then return "" end
  local hundredths = math.floor(copper / 100 + 0.5)
  return (string.format("%.2f", hundredths / 100):gsub("%.?0+$", ""))
end

local function text(v)
  if v == nil then return "" end
  if type(v) == "number" then return number(v) end
  v = tostring(v)
  if v:find("^[=+%-@]") then v = "'" .. v end
  if v:find('[,"\r\n]') then v = '"' .. v:gsub('"', '""') .. '"' end
  return v
end

-- rows[i] is an array of finished cells.
local function csv(header, rows)
  local lines = { table.concat(header, ",") }
  for _, row in ipairs(rows) do lines[#lines + 1] = table.concat(row, ",") end
  return table.concat(lines, "\n")
end

-- Every zone, most gathers first. Semicolons: names can hold commas themselves.
local function zoneList(s, zoneName)
  local zones, ids = s.zones or {}, {}
  for mapID in pairs(zones) do ids[#ids + 1] = mapID end
  table.sort(ids, function(a, b)
    if zones[a] ~= zones[b] then return zones[a] > zones[b] end
    return a < b
  end)
  for i, mapID in ipairs(ids) do ids[i] = tostring(zoneName(mapID)) end
  return table.concat(ids, "; ")
end

-- helpers = { date(epoch) -> text, zoneName(mapID) -> text, price = priceFn }. Newest first.
function M.Sessions(sessions, helpers)
  local list = {}
  for i, s in ipairs(sessions or {}) do list[i] = s end
  table.sort(list, function(a, b)
    if (a.started or 0) ~= (b.started or 0) then return (a.started or 0) > (b.started or 0) end
    return (a.id or 0) > (b.id or 0)
  end)
  local rows = {}
  for i, s in ipairs(list) do
    local nodes = s.nodes or {}
    rows[i] = {
      text(helpers.date(s.started or 0)),
      number(s.activeSeconds or 0),
      text(zoneList(s, helpers.zoneName)),
      number(nodes.herb or 0),
      number(nodes.ore or 0),
      number(nodes.skin or 0),
      gold(SessionMath.Value(s, helpers.price)),
      gold(SessionMath.GoldPerHour(s, 0, helpers.price)),
    }
  end
  return csv({ "Date", "Duration (seconds)", "Zones", "Herb nodes", "Ore nodes", "Skin nodes", "Gold", "Gold per hour" }, rows)
end

-- Largest count first, like the Records page.
function M.Materials(lifetime, nameOf)
  local ids = {}
  for itemID in pairs(lifetime or {}) do ids[#ids + 1] = itemID end
  table.sort(ids, function(a, b)
    if lifetime[a] ~= lifetime[b] then return lifetime[a] > lifetime[b] end
    return a < b
  end)
  local rows = {}
  for i, itemID in ipairs(ids) do
    rows[i] = { number(itemID), text(nameOf(itemID)), number(lifetime[itemID]) }
  end
  return csv({ "Item ID", "Item name", "Lifetime count" }, rows)
end

-- period = "day" | "daily" | "weekly"; labelOf(key) -> text. Newest first.
function M.Gold(ledger, period, labelOf)
  local bucket = ledger and ledger[period]
  local rows = {}
  if type(bucket) == "table" then
    for i, row in ipairs(GoldLedger.Rows(bucket)) do
      local label = row.key
      if labelOf then label = labelOf(row.key) end
      rows[i] = { text(label), gold(row.copper) }
    end
  end
  return csv({ "Period", "Gold" }, rows)
end

ns.Export = M
