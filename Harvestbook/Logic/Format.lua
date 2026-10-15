local ADDON, ns = ...

local M = {}
ns.Format = M

function M.Thousands(n)
  n = math.floor((n or 0) + 0.5)
  local neg = n < 0
  local s = tostring(neg and -n or n)
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  if out:sub(1, 1) == "," then out = out:sub(2) end
  return (neg and "-" or "") .. out
end

function M.Money(copper, style)
  copper = math.floor(copper or 0)
  local neg = copper < 0
  if neg then copper = -copper end
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  local out
  if style == "full" then
    local parts = {}
    if g > 0 then parts[#parts + 1] = M.Thousands(g) .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 then parts[#parts + 1] = c .. "c" end
    out = #parts > 0 and table.concat(parts, " ") or "0c"
  else
    out = M.Thousands(g) .. "g"
  end
  return (neg and "-" or "") .. out
end

function M.Duration(seconds)
  seconds = math.floor(seconds or 0)
  if seconds < 0 then seconds = 0 end
  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = seconds % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end
