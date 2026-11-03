local ADDON, ns = ...

local M = {}
ns.GoalEval = M

local S = ns.SessionMath

function M.Progress(goal, session, now, priceFn)
  local current = 0
  if goal.type == "materials" then
    for _, e in pairs(session.items) do
      if goal.itemID == nil or e.itemID == goal.itemID then
        current = current + e.count
      end
    end
  elseif goal.type == "gold" then
    current = S.Value(session, priceFn)
  elseif goal.type == "minutes" then
    current = S.ActiveSeconds(session, now) / 60
  end
  return current, goal.target, current >= goal.target
end

-- Strict number entry for goals: "5000", "5,000,000", "250k", "2.5m". Rejects
-- "1e5", "0x10", and anything else tonumber would quietly accept. Returns a
-- positive whole number or nil. allowSuffix = false rejects k / m and decimals.
function M.ParseTarget(text, allowSuffix)
  if type(text) ~= "string" then return nil end
  text = text:gsub("%s", ""):lower()
  -- A comma must group thousands: "2,5m" is a decimal comma, not 25 million.
  local whole, rest = text:match("^([%d,]+)(.*)$")
  if whole and whole:find(",", 1, true) then
    local head, n = whole, 1
    while n > 0 do head, n = head:gsub(",%d%d%d$", "") end
    if not head:match("^%d%d?%d?$") then return nil end
    text = whole:gsub(",", "") .. rest
  end
  local digits, suffix = text:match("^([%d%.]+)([km]?)$")
  if not digits or (suffix ~= "" and allowSuffix == false) then return nil end
  if not (digits:match("^%d+$") or (digits:match("^%d+%.%d+$") and suffix ~= "")) then return nil end
  local n = tonumber(digits)
  if suffix == "k" then n = n * 1000 elseif suffix == "m" then n = n * 1000000 end
  n = math.floor(n + 0.5)
  if n < 1 or n > 999999999999 then return nil end
  return n
end

function M.NewlyReached(goals, session, now, priceFn, reached)
  local out = {}
  for _, goal in ipairs(goals) do
    if not reached[goal.id] then
      local _, _, done = M.Progress(goal, session, now, priceFn)
      if done then
        reached[goal.id] = true
        out[#out + 1] = goal
      end
    end
  end
  return out
end

function M.UpdateAttempts(attempts, gather)
  local found = {}
  local have = {}
  for _, it in ipairs(gather.items or {}) do have[it.itemID] = true end
  for itemID, a in pairs(attempts) do
    if a.kind == nil or a.kind == gather.kind then
      if have[itemID] then
        a.found = (a.found or 0) + 1
        a.sinceLast = 0
        found[#found + 1] = itemID
      else
        a.attempts = (a.attempts or 0) + 1
        a.sinceLast = (a.sinceLast or 0) + 1
      end
    end
  end
  table.sort(found)
  return found
end
