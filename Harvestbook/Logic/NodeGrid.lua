local ADDON, ns = ...

-- Pure per-zone spot table (spec 3.2). `zone` is nodes[mapID].
local M = {}
ns.NodeGrid = M

local floor = math.floor

function M.CellKey(x, y)
  return floor(x * 50) .. ":" .. floor(y * 50)
end

-- Resolve the key for a (cell, kind): plain key unless occupied by another kind.
local function resolveKey(zone, x, y, kind)
  local key = M.CellKey(x, y)
  local spot = zone[key]
  if spot and spot.kind ~= kind then
    key = key .. ":" .. kind
  end
  return key
end

function M.Record(zone, gather, copper)
  local nodeID = gather.objectID or gather.npcID
  if not nodeID then return nil end
  local key = resolveKey(zone, gather.x, gather.y, gather.kind)
  local spot = zone[key]
  if not spot then
    spot = {
      x = gather.x, y = gather.y, kind = gather.kind,
      nodeIDs = {}, items = {}, gathers = 0, copper = 0,
      firstSeen = gather.time, lastSeen = gather.time,
    }
    zone[key] = spot
  end
  local n = spot.gathers
  spot.x = (spot.x * n + gather.x) / (n + 1)
  spot.y = (spot.y * n + gather.y) / (n + 1)
  if n == 0 then
    spot.imported = nil
    spot.firstSeen = gather.time
  end
  spot.gathers = n + 1
  spot.nodeIDs[nodeID] = (spot.nodeIDs[nodeID] or 0) + 1
  for _, it in ipairs(gather.items or {}) do
    spot.items[it.itemID] = (spot.items[it.itemID] or 0) + (it.count or 0)
  end
  spot.copper = spot.copper + (copper or 0)
  spot.lastSeen = gather.time
  return key
end

function M.Forget(zone, spotKey)
  zone[spotKey] = nil
end

-- Most-gathered nodeID in a spot; ties go to the lowest nodeID.
local function dominant(spot)
  local best, bestN
  for id, n in pairs(spot.nodeIDs) do
    if not bestN or n > bestN or (n == bestN and id < best) then
      best, bestN = id, n
    end
  end
  return best
end

local function sum(t)
  local s = 0
  for _, v in pairs(t) do s = s + v end
  return s
end

function M.Summarize(zone)
  local byNode, total = {}, 0
  for _, spot in pairs(zone) do
    if (spot.gathers or 0) > 0 then
      local dom = dominant(spot)
      if dom then
        for id, n in pairs(spot.nodeIDs) do
          local r = byNode[id]
          if not r then
            r = { nodeID = id, kind = spot.kind, count = 0, items = 0, copper = 0 }
            byNode[id] = r
          end
          r.count = r.count + n
          total = total + n
        end
        byNode[dom].items = byNode[dom].items + sum(spot.items)
        byNode[dom].copper = byNode[dom].copper + (spot.copper or 0)
      end
    end
  end
  local rows = {}
  for _, r in pairs(byNode) do
    rows[#rows + 1] = {
      nodeID = r.nodeID, kind = r.kind, count = r.count,
      share = r.count / total,
      avgItems = r.items / r.count,
      valuePerNode = r.copper / r.count,
    }
  end
  table.sort(rows, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.nodeID < b.nodeID
  end)
  return rows
end

-- Item totals of the spots attributed to `nodeID` (same rule as Summarize),
-- sorted by count desc then itemID: { {itemID, count}, ... }.
function M.ItemsFor(zone, nodeID)
  local totals = {}
  for _, spot in pairs(zone) do
    if (spot.gathers or 0) > 0 and dominant(spot) == nodeID then
      for itemID, n in pairs(spot.items) do
        totals[itemID] = (totals[itemID] or 0) + n
      end
    end
  end
  local rows = {}
  for itemID, n in pairs(totals) do rows[#rows + 1] = { itemID = itemID, count = n } end
  table.sort(rows, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.itemID < b.itemID
  end)
  return rows
end

function M.ImportPoint(zone, x, y, kind)
  local key = resolveKey(zone, x, y, kind)
  if zone[key] then return nil end
  zone[key] = {
    x = x, y = y, kind = kind,
    nodeIDs = {}, items = {}, gathers = 0, copper = 0,
    imported = true,
  }
  return key
end
