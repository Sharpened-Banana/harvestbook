local ADDON, ns = ...

-- Pure farming-loop builder. Coordinates are normalised map coordinates (0-1).
-- Spots { key, x, y, weight } become a closed visiting order: merge close
-- spots, keep the heaviest stops, nearest-neighbour from the heaviest stop,
-- then bounded 2-opt. Spots are sorted first, so the same set gives the same
-- route whatever order it arrives in (node log zones come from pairs()).
local M = {}
ns.RouteBuilder = M

M.MERGE_DISTANCE = 0.01
M.MAX_STOPS = 30
M.MAX_PASSES = 20
M.DOT_SPACING = 0.025
M.MAX_DOTS = 200

local EPSILON = 1e-9

local function dist(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function isCoord(v)
  return type(v) == "number" and v >= 0 and v <= 1 -- false for NaN too
end

local function heaviestFirst(a, b)
  if a.weight ~= b.weight then return a.weight > b.weight end
  local ka, kb = tostring(a.key), tostring(b.key)
  if ka ~= kb then return ka < kb end
  if a.x ~= b.x then return a.x < b.x end
  return a.y < b.y
end

-- Usable spots as fresh tables, heaviest first.
local function normalise(spots)
  local out = {}
  for _, s in ipairs(spots or {}) do
    if type(s) == "table" and isCoord(s.x) and isCoord(s.y) then
      local w = s.weight
      if type(w) ~= "number" or w ~= w or w < 0 then w = 0 end
      out[#out + 1] = { key = s.key, x = s.x, y = s.y, weight = w }
    end
  end
  table.sort(out, heaviestFirst)
  return out
end

-- Heaviest first, so a stop's position is always its heaviest spot's and a
-- chain of close spots can't drift. A spot joins its nearest stop in range.
local function merge(sorted, mergeDistance)
  local stops = {}
  for _, s in ipairs(sorted) do
    local into, best
    for _, stop in ipairs(stops) do
      local d = dist(stop, s)
      if d <= mergeDistance and (not best or d < best) then into, best = stop, d end
    end
    if into then
      into.weight = into.weight + s.weight
      into.keys[#into.keys + 1] = s.key
    else
      s.keys = { s.key }
      stops[#stops + 1] = s
    end
  end
  return stops
end

local function nearestNeighbour(stops)
  local order, used = { stops[1] }, { [1] = true }
  for _ = 2, #stops do
    local cur = order[#order]
    local pick, best
    for i, s in ipairs(stops) do
      if not used[i] then
        local d = dist(cur, s)
        if not best or d < best then pick, best = i, d end
      end
    end
    used[pick] = true
    order[#order + 1] = stops[pick]
  end
  return order
end

-- Each pass is O(n^2) on at most maxStops stops. The first stop stays first.
local function twoOpt(order, maxPasses)
  local n = #order
  for _ = 1, maxPasses do
    local improved = false
    for i = 1, n - 2 do
      for j = i + 2, n do
        if not (i == 1 and j == n) then -- those two edges share a stop
          local a, b, c, d = order[i], order[i + 1], order[j], order[j % n + 1]
          if dist(a, c) + dist(b, d) < dist(a, b) + dist(c, d) - EPSILON then
            local lo, hi = i + 1, j
            while lo < hi do
              order[lo], order[hi] = order[hi], order[lo]
              lo, hi = lo + 1, hi - 1
            end
            improved = true
          end
        end
      end
    end
    if not improved then break end
  end
end

-- Closed loop length: 0 below two stops, out and back for two.
function M.Length(stops)
  local n, total = #stops, 0
  if n < 2 then return 0 end
  for i = 1, n do
    total = total + dist(stops[i], stops[i % n + 1])
  end
  return total
end

-- opts: mergeDistance, maxStops, maxPasses (all optional).
-- Returns { stops = { { key, keys, x, y, weight }, ... }, length = n }.
function M.Build(spots, opts)
  opts = opts or {}
  local stops = merge(normalise(spots), opts.mergeDistance or M.MERGE_DISTANCE)
  table.sort(stops, heaviestFirst)
  local maxStops = opts.maxStops or M.MAX_STOPS
  for i = #stops, maxStops + 1, -1 do stops[i] = nil end
  if #stops == 0 then return { stops = {}, length = 0 } end
  local order = nearestNeighbour(stops)
  twoOpt(order, opts.maxPasses or M.MAX_PASSES)
  return { stops = order, length = M.Length(order) }
end

-- A node log zone as Build input: real gathers only, so imported spots with
-- no gathers never count. kinds = { herb = true, ... }.
function M.Spots(zone, kinds, minGathers)
  local out = {}
  if type(zone) ~= "table" or type(kinds) ~= "table" then return out end
  local minimum = math.max(minGathers or 1, 1)
  for key, spot in pairs(zone) do
    if type(spot) == "table" and kinds[spot.kind] and (spot.gathers or 0) >= minimum then
      out[#out + 1] = { key = key, x = spot.x, y = spot.y, weight = spot.gathers, kind = spot.kind }
    end
  end
  return out
end

-- Evenly spaced points { x, y } along the legs, excluding the stops. Spacing
-- widens as needed to stay within maxDots. Two stops share one leg.
function M.LegDots(stops, spacing, maxDots)
  local dots, n = {}, #stops
  spacing, maxDots = spacing or M.DOT_SPACING, maxDots or M.MAX_DOTS
  if n < 2 or maxDots <= 0 then return dots end
  local legs = n == 2 and 1 or n
  local total = 0
  for i = 1, legs do total = total + dist(stops[i], stops[i % n + 1]) end
  if total / spacing > maxDots then spacing = total / maxDots end
  for i = 1, legs do
    local a, b = stops[i], stops[i % n + 1]
    local parts = math.floor(dist(a, b) / spacing + EPSILON)
    for p = 1, parts - 1 do
      local t = p / parts
      dots[#dots + 1] = { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t }
    end
  end
  return dots
end

-- A clean copy of a saved route { mapID, target, stops = { { x, y, gathers,
-- nodeID, kind } } }, or nil if it can't be used. target is the stop the last
-- waypoint went to (0 = none yet).
function M.Sanitize(saved)
  if type(saved) ~= "table" or type(saved.mapID) ~= "number" or type(saved.stops) ~= "table" then return nil end
  local count = #saved.stops
  if count == 0 or count > M.MAX_STOPS then return nil end
  local stops = {}
  for i = 1, count do
    local s = saved.stops[i]
    if type(s) ~= "table" or not isCoord(s.x) or not isCoord(s.y) then return nil end
    if type(s.gathers) ~= "number" or s.gathers ~= s.gathers then return nil end
    stops[i] = {
      x = s.x, y = s.y, gathers = s.gathers,
      nodeID = type(s.nodeID) == "number" and s.nodeID or nil,
      kind = type(s.kind) == "string" and s.kind or nil,
    }
  end
  local target = saved.target
  if type(target) ~= "number" or target < 0 or target > count or target % 1 ~= 0 then target = 0 end
  return { mapID = saved.mapID, target = target, stops = stops }
end
