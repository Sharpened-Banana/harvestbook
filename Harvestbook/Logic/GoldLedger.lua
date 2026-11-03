local ADDON, ns = ...

-- Gold earned over time: an all-time total, buckets per calendar day, per
-- daily reset and per weekly reset, and the all-time goal.
-- ledger = { total, day = {[key]=copper}, daily = {...}, weekly = {...}, goal? }
-- Keys: day = "YYYY-MM-DD"; daily / weekly = the epoch at which that period ends.

local M = {}
ns.GoldLedger = M

M.PERIOD_SECONDS = { daily = 86400, weekly = 604800 }
M.MAX_BUCKETS = { day = 400, daily = 400, weekly = 120 }

-- The server's "seconds until reset" drifts by a few seconds between calls, so
-- the anchor is rounded to keep one period under one key.
local ANCHOR_ROUND = 300

-- The epoch at which the period containing t ends.
function M.ResetKey(t, nextReset, period)
  local anchor = math.floor(nextReset / ANCHOR_ROUND + 0.5) * ANCHOR_ROUND
  return anchor + (math.floor((t - anchor) / period) + 1) * period
end

local function prune(bucket, max)
  local keys = {}
  for k in pairs(bucket) do keys[#keys + 1] = k end
  if #keys <= max then return end
  table.sort(keys)
  for i = 1, #keys - max do bucket[keys[i]] = nil end
end

-- keys = { day = k, daily = k, weekly = k }; a missing key skips that bucket.
function M.Add(ledger, copper, keys)
  if type(copper) ~= "number" or copper <= 0 then return end
  ledger.total = (ledger.total or 0) + copper
  for name, max in pairs(M.MAX_BUCKETS) do
    local key = keys and keys[name]
    if key ~= nil then
      local bucket = ledger[name]
      if not bucket then
        bucket = {}
        ledger[name] = bucket
      end
      bucket[key] = (bucket[key] or 0) + copper
      prune(bucket, max)
    end
  end
end

-- current: the given key's amount; average and best over periods with earnings.
function M.Summary(bucket, currentKey)
  local total, count, best = 0, 0, 0
  for _, v in pairs(bucket or {}) do
    total, count = total + v, count + 1
    if v > best then best = v end
  end
  return {
    current = bucket and bucket[currentKey] or 0,
    average = count > 0 and total / count or 0,
    best = best,
    periods = count,
  }
end

-- { { key, copper }, ... } newest first.
function M.Rows(bucket)
  local rows = {}
  for k, v in pairs(bucket or {}) do rows[#rows + 1] = { key = k, copper = v } end
  table.sort(rows, function(a, b) return a.key > b.key end)
  return rows
end

-- True when this gain crossed the goal.
function M.GoalCrossed(before, after, goal)
  return type(goal) == "number" and goal > 0 and before < goal and after >= goal
end

-- Adds each session once. valueOf(s) -> copper; keysAt(t) -> keys.
function M.Backfill(ledger, sessions, valueOf, keysAt)
  for _, s in ipairs(sessions or {}) do
    M.Add(ledger, valueOf(s), keysAt(s.started or 0))
  end
end

ns.GoldLedger = M
