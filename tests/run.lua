-- Minimal busted-like runner. Usage: luajit tests/run.lua [spec files...]
package.path = "./?.lua;" .. package.path

local function serialize(v, seen)
  local t = type(v)
  if t == "string" then return string.format("%q", v) end
  if t ~= "table" then return tostring(v) end
  seen = seen or {}
  if seen[v] then return "<cycle>" end
  seen[v] = true
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    if ta == "number" or ta == "string" then return a < b end
    return tostring(a) < tostring(b)
  end)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = "[" .. serialize(k, seen) .. "]=" .. serialize(v[k], seen)
  end
  seen[v] = nil
  return "{" .. table.concat(parts, ", ") .. "}"
end

local function deep_equal(a, b, seen)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  seen = seen or {}
  if seen[a] == b then return true end
  seen[a] = b
  for k, v in pairs(a) do
    if not deep_equal(v, b[k], seen) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

assert = setmetatable({
  are = {
    equal = function(expected, actual)
      if expected ~= actual then
        error("expected " .. serialize(expected) .. " but got " .. serialize(actual), 2)
      end
    end,
    same = function(expected, actual)
      if not deep_equal(expected, actual) then
        error("expected (deep) " .. serialize(expected) .. " but got " .. serialize(actual), 2)
      end
    end,
  },
  is_true = function(v)
    if v ~= true then error("expected true but got " .. serialize(v), 2) end
  end,
  is_false = function(v)
    if v ~= false then error("expected false but got " .. serialize(v), 2) end
  end,
  is_nil = function(v)
    if v ~= nil then error("expected nil but got " .. serialize(v), 2) end
  end,
  has_error = function(fn)
    if pcall(fn) then error("expected function to raise an error", 2) end
  end,
}, { __call = function(_, v, msg)
  if not v then error(msg or "assertion failed", 2) end
  return v
end })

local stack = {}      -- describe name stack
local befores = {}    -- stack of before_each lists
local tests = {}      -- collected { spec, name, fns }
local current_spec

function describe(name, fn)
  stack[#stack + 1] = name
  befores[#befores + 1] = {}
  fn()
  table.remove(befores)
  table.remove(stack)
end

function before_each(fn)
  local list = befores[#befores]
  list[#list + 1] = fn
end

function it(name, fn)
  local hooks = {}
  for _, list in ipairs(befores) do
    for _, h in ipairs(list) do hooks[#hooks + 1] = h end
  end
  local full = table.concat(stack, " ") .. (#stack > 0 and " " or "") .. name
  tests[#tests + 1] = { spec = current_spec, name = full, hooks = hooks, fn = fn }
end

local files = { ... }
if #files == 0 then
  local p = io.popen("ls tests/*_spec.lua 2>/dev/null")
  for line in p:lines() do files[#files + 1] = line end
  p:close()
end

local failed, passed = 0, 0

for _, f in ipairs(files) do
  current_spec = f
  local chunk, err = loadfile(f)
  if not chunk then
    failed = failed + 1
    print("FAIL " .. f .. " (load error)\n  " .. tostring(err))
  else
    local ok, e = pcall(chunk)
    if not ok then
      failed = failed + 1
      print("FAIL " .. f .. " (error while defining specs)\n  " .. tostring(e))
    end
  end
end

for _, t in ipairs(tests) do
  local ok, e = pcall(function()
    for _, h in ipairs(t.hooks) do h() end
    t.fn()
  end)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL [" .. t.spec .. "] " .. t.name .. "\n  " .. tostring(e))
  end
end

print(passed .. " passed, " .. failed .. " failed")
os.exit(failed == 0 and 0 or 1)
