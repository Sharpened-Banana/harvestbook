local ADDON, ns = ...

-- Pure shopping list logic: list edits, progress, and which zone to gather an
-- item in (from global.nodes, see Logic/NodeGrid). An entry is { itemID, target }.
local M = {}
ns.ShoppingEval = M

local NodeGrid = ns.NodeGrid

M.MAX_ENTRIES = 30
M.MIN_GATHERS = 5 -- below this a zone's average is one lucky node, not a yield

local MAX_ITEM_ID = 2147483647

-- Accepts an item link, "item:123", or a bare number; nil when unparseable.
function M.ParseItem(text)
  if type(text) ~= "string" then return nil end
  text = text:match("^%s*(.-)%s*$")
  local digits = text:match("item:(%d+)") or text:match("^(%d+)$")
  local n = digits and tonumber(digits)
  if not n or n < 1 or n > MAX_ITEM_ID then return nil end
  return n
end

-- Adding an item already listed updates its target. Returns "added" or
-- "updated", or nil + "limit" when a new item doesn't fit.
function M.Upsert(list, itemID, target)
  for _, e in ipairs(list) do
    if e.itemID == itemID then
      e.target = target
      return "updated"
    end
  end
  if #list >= M.MAX_ENTRIES then return nil, "limit" end
  list[#list + 1] = { itemID = itemID, target = target }
  return "added"
end

function M.Remove(list, itemID)
  for i, e in ipairs(list) do
    if e.itemID == itemID then
      table.remove(list, i)
      return true
    end
  end
  return false
end

function M.Remaining(target, have)
  return math.max(0, target - have)
end

function M.Done(target, have)
  return have >= target
end

-- Estimated nodes left: 0 when done, nil when there's no average to go on.
function M.NodesNeeded(target, have, average)
  local remaining = M.Remaining(target, have)
  if remaining == 0 then return 0 end
  if not average or average <= 0 then return nil end
  return math.ceil(remaining / average)
end

-- Zone with the highest average of the item per gather among zones with at
-- least MIN_GATHERS gathers; failing that, the most-gathered zone that gave it.
-- zones = { [mapID] = zone }. Returns mapID, average per gather, or nil.
function M.BestZone(zones, itemID)
  local best, bestAvg, bestGathers
  local most, mostAvg, mostGathers
  for mapID, zone in pairs(zones) do
    local items, gathers = NodeGrid.ItemYield(zone, itemID)
    if items > 0 and gathers > 0 then
      local avg = items / gathers
      if gathers >= M.MIN_GATHERS and (not best or avg > bestAvg
          or (avg == bestAvg and (gathers > bestGathers or (gathers == bestGathers and mapID < best)))) then
        best, bestAvg, bestGathers = mapID, avg, gathers
      end
      if not most or gathers > mostGathers
          or (gathers == mostGathers and (avg > mostAvg or (avg == mostAvg and mapID < most))) then
        most, mostAvg, mostGathers = mapID, avg, gathers
      end
    end
  end
  if best then return best, bestAvg end
  if most then return most, mostAvg end
  return nil
end

-- Unfinished first, then by name; the itemID keeps two qualities of a name stable.
function M.SortRows(rows)
  table.sort(rows, function(a, b)
    local da, db = M.Done(a.target, a.have), M.Done(b.target, b.have)
    if da ~= db then return db end
    if a.name ~= b.name then return a.name < b.name end
    return a.itemID < b.itemID
  end)
  return rows
end

-- Rows ({ itemID, target, have }) that are done and weren't in doneSet.
-- Rewrites doneSet ([itemID] = true) to the rows' current state.
function M.NewlyDone(rows, doneSet)
  local out, now = {}, {}
  for _, row in ipairs(rows) do
    if M.Done(row.target, row.have) then
      now[row.itemID] = true
      if not doneSet[row.itemID] then out[#out + 1] = row end
    end
  end
  for itemID in pairs(doneSet) do doneSet[itemID] = nil end
  for itemID in pairs(now) do doneSet[itemID] = true end
  return out
end
