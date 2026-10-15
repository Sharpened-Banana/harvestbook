local ADDON, ns = ...

local M = {}
ns.AlarmEval = M

local THROTTLE_SECONDS = 2

M.DEFAULTS = {
  muted = false,
  value = { enabled = false, gold = 500 },
  multiple = { enabled = true, n = 3, minNodes = 10 },
  rare = { enabled = true },
  goal = { enabled = true },
  record = { enabled = true },
}

local function fired(rule, text)
  return { { rule = rule, text = text } }
end

local function evalNode(rules, ctx)
  local v = rules.value
  if v and v.enabled and (ctx.nodeCopper or 0) >= v.gold * 10000 then
    return fired("value", "High-value node: " .. ctx.label)
  end
  local m = rules.multiple
  local avg = ctx.avgCopper or 0
  if m and m.enabled and (ctx.nodeCount or 0) >= m.minNodes and avg > 0
      and (ctx.nodeCopper or 0) >= m.n * avg then
    return fired("multiple", "High-value node: " .. ctx.label)
  end
  return nil
end

local SIMPLE = {
  rare = "Rare find: ",
  goal = "Goal reached: ",
  record = "New record: ",
}

function M.Evaluate(rules, ctx, state)
  if rules.muted then return {} end
  if state.lastFire and ctx.now - state.lastFire < THROTTLE_SECONDS then return {} end
  local out
  if ctx.kind == "node" then
    out = evalNode(rules, ctx)
  elseif SIMPLE[ctx.kind] then
    local r = rules[ctx.kind]
    if r and r.enabled then out = fired(ctx.kind, SIMPLE[ctx.kind] .. ctx.label) end
  end
  if not out then return {} end
  state.lastFire = ctx.now
  return out
end
