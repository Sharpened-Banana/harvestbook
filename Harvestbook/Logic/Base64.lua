local ADDON, ns = ...

-- Standard base64 (RFC 4648, "=" padding) using arithmetic only (Lua 5.1, no bit ops).
local M = {}
ns.Base64 = M

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ENC, DEC = {}, {}
for i = 1, 64 do
  local c = ALPHABET:sub(i, i)
  ENC[i - 1] = c
  DEC[c] = i - 1
end

local floor = math.floor

function M.Encode(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local c1 = floor(n / 262144)
    local c2 = floor(n / 4096) % 64
    local c3 = floor(n / 64) % 64
    local c4 = n % 64
    out[#out + 1] = ENC[c1] .. ENC[c2]
      .. (b and ENC[c3] or "=")
      .. (c and ENC[c4] or "=")
  end
  return table.concat(out)
end

-- Returns the decoded string, or nil when the input is not valid base64.
-- Whitespace is ignored.
function M.Decode(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("%s+", "")
  if #s % 4 ~= 0 then return nil end
  local out = {}
  for i = 1, #s, 4 do
    local q = s:sub(i, i + 3)
    local last = (i + 3 == #s)
    local pad = 0
    if q:sub(4, 4) == "=" then
      pad = (q:sub(3, 3) == "=") and 2 or 1
      if not last then return nil end
    end
    local v = {}
    for j = 1, 4 - pad do
      local d = DEC[q:sub(j, j)]
      if not d then return nil end
      v[j] = d
    end
    for j = 4 - pad + 1, 4 do
      if q:sub(j, j) ~= "=" then return nil end
    end
    local n = v[1] * 262144 + v[2] * 4096 + (v[3] or 0) * 64 + (v[4] or 0)
    local a = floor(n / 65536)
    local b = floor(n / 256) % 256
    local c = n % 256
    if pad == 0 then
      out[#out + 1] = string.char(a, b, c)
    elseif pad == 1 then
      out[#out + 1] = string.char(a, b)
    else
      out[#out + 1] = string.char(a)
    end
  end
  return table.concat(out)
end
