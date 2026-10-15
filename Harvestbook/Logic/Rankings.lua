local ADDON, ns = ...

-- Pure Best Spot rankings over saved sessions / a zone's spot table.
local M = {}
ns.Rankings = M

local function sortRows(rows, metric, tieKey)
  table.sort(rows, function(a, b)
    if a.lowData ~= b.lowData then return b.lowData end
    local va, vb = a[metric], b[metric]
    if va ~= vb then
      if va == nil then return false end
      if vb == nil then return true end
      return va > vb
    end
    return a[tieKey] < b[tieKey]
  end)
end

function M.Zones(sessions, metric, minSeconds)
  local acc = {}
  local function row(mapID)
    local r = acc[mapID]
    if not r then
      r = { mapID = mapID, seconds = 0, copper = 0, nodes = 0 }
      acc[mapID] = r
    end
    return r
  end
  for _, s in ipairs(sessions or {}) do
    for mapID, n in pairs(s.zones or {}) do row(mapID).nodes = row(mapID).nodes + n end
    for mapID, n in pairs(s.zoneSeconds or {}) do row(mapID).seconds = row(mapID).seconds + n end
    for mapID, n in pairs(s.zoneCopper or {}) do row(mapID).copper = row(mapID).copper + n end
  end
  local rows = {}
  for _, r in pairs(acc) do
    if r.seconds > 0 then
      r.gph = r.copper * 3600 / r.seconds
      r.nodesPerHour = r.nodes * 3600 / r.seconds
    end
    if r.nodes > 0 then r.perNode = r.copper / r.nodes end
    r.lowData = r.seconds < minSeconds
    rows[#rows + 1] = r
  end
  sortRows(rows, metric, "mapID")
  return rows
end

function M.Spots(zone, minGathers)
  local rows = {}
  for key, spot in pairs(zone or {}) do
    if (spot.gathers or 0) > 0 then
      rows[#rows + 1] = {
        spotKey = key, x = spot.x, y = spot.y, kind = spot.kind,
        gathers = spot.gathers,
        perNode = spot.copper / spot.gathers,
        lowData = spot.gathers < minGathers,
      }
    end
  end
  sortRows(rows, "perNode", "spotKey")
  return rows
end
