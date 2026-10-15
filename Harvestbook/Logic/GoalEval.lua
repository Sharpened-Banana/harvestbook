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
