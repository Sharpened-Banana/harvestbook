local ADDON, ns = ...

-- Pure gear comparison: groups sessions by the profession gear equipped when
-- they started (s.gear, see Modules/GearCompare) and compares the sets.
local M = {}
ns.GearCompare = M

local SessionMath = ns.SessionMath

local MIN_SECONDS = 60

-- items = { { itemID, link, tool }, ... } in slot order -> what s.gear stores.
function M.BuildGear(items)
  local ids = {}
  for i, it in ipairs(items) do ids[i] = it.itemID end
  table.sort(ids)
  return { sig = table.concat(ids, ","), items = items }
end

-- The session's most-gathered zone (ties: the lower mapID), or nil.
function M.MainZone(s)
  local best, bestCount
  for mapID, count in pairs(s.zones or {}) do
    if not best or count > bestCount or (count == bestCount and mapID < best) then
      best, bestCount = mapID, count
    end
  end
  return best
end

local function usable(s)
  return (s.activeSeconds or 0) >= MIN_SECONDS
end

-- Returns { sets = { set, ... }, noGear = n }, best gold/hr first. A set has
-- sig, items, sessions, seconds, value, nodes, gph, nodesPerHour, itemsPerNode
-- (nil without nodes) and pct (<= 0, percent difference from the best set).
-- mapID, when given, keeps sessions whose most-gathered zone is that map.
function M.Compare(sessions, priceFn, mapID)
  local bySig, sets, noGear = {}, {}, 0
  for _, s in ipairs(sessions or {}) do
    if usable(s) and (not mapID or M.MainZone(s) == mapID) then
      if s.gear and s.gear.sig then
        local set = bySig[s.gear.sig]
        if not set then
          set = { sig = s.gear.sig, items = s.gear.items or {}, sessions = 0,
            seconds = 0, value = 0, nodes = 0, materials = 0 }
          bySig[s.gear.sig] = set
          sets[#sets + 1] = set
        end
        set.sessions = set.sessions + 1
        set.seconds = set.seconds + s.activeSeconds
        set.value = set.value + SessionMath.Value(s, priceFn)
        for _, n in pairs(s.nodes or {}) do set.nodes = set.nodes + n end
        for _, e in pairs(s.items or {}) do set.materials = set.materials + (e.count or 0) end
      else
        noGear = noGear + 1
      end
    end
  end

  for _, set in ipairs(sets) do
    set.gph = set.value * 3600 / set.seconds
    set.nodesPerHour = set.nodes * 3600 / set.seconds
    if set.nodes > 0 then set.itemsPerNode = set.materials / set.nodes end
  end
  table.sort(sets, function(a, b)
    if a.gph ~= b.gph then return a.gph > b.gph end
    return a.sig < b.sig
  end)
  local best = sets[1] and sets[1].gph or 0
  for _, set in ipairs(sets) do
    set.pct = best > 0 and (set.gph - best) * 100 / best or 0
  end
  return { sets = sets, noGear = noGear }
end

-- Sorted mapIDs a zone filter can usefully offer: the main zones of sessions
-- that Compare would put in a set.
function M.Zones(sessions)
  local seen, out = {}, {}
  for _, s in ipairs(sessions or {}) do
    local mapID = usable(s) and s.gear and s.gear.sig and M.MainZone(s)
    if mapID and not seen[mapID] then
      seen[mapID] = true
      out[#out + 1] = mapID
    end
  end
  table.sort(out)
  return out
end

-- nameFn(itemID, link) -> name. The tool's name, or the first item's, "+N".
function M.Label(items, nameFn)
  local main = items[1]
  if not main then return "No profession gear" end
  for _, it in ipairs(items) do
    if it.tool then main = it break end
  end
  local name = nameFn(main.itemID, main.link)
  if #items > 1 then return name .. " +" .. (#items - 1) end
  return name
end
