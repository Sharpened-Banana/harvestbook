local LOCALES = {}

-- Runs an addon file with GetLocale stubbed (nil = the API is missing).
local function loadLocale(file, locale)
  local saved = _G.GetLocale
  _G.GetLocale = locale and function() return locale end or nil
  local ns = {}
  local function run(path) assert(loadfile(path))("Harvestbook", ns) end
  run("Harvestbook/Locale/Locale.lua")
  run("Harvestbook/Locale/" .. file)
  _G.GetLocale = saved
  return ns.L
end

local function entries(L)
  local out = {}
  for k, v in next, L do out[k] = v end
  return out
end

-- Format conversions in order. A positional %2$s sorts by position; a lone %
-- ("5% cut") is not a conversion.
local function placeholders(s)
  local found, i, seq = {}, 1, 0
  while true do
    i = s:find("%", i, true)
    if not i then break end
    if s:sub(i + 1, i + 1) == "%" then
      seq = seq + 1
      found[#found + 1] = { seq, "%%" }
      i = i + 2
    else
      local pos = s:match("^(%d+)%$", i + 1)
      local start = i + 1 + (pos and #pos + 1 or 0)
      local conv = s:match("^[-+0]*%d*%.?%d*[sdfgxc]", start)
      if conv then
        seq = seq + 1
        found[#found + 1] = { pos and tonumber(pos) or seq, "%" .. conv }
        i = start + #conv
      else
        i = i + 1
      end
    end
  end
  table.sort(found, function(a, b) return a[1] < b[1] end)
  local out = {}
  for n, f in ipairs(found) do out[n] = f[2] end
  return table.concat(out, " ")
end

local function sourceFiles()
  local files = {}
  local p = io.popen("find Harvestbook -name '*.lua' -not -path '*/libs/*' -not -path '*/Locale/*'")
  for line in p:lines() do files[#files + 1] = line end
  p:close()
  return files
end

-- key -> file for every L["..."] in the source; dynamic L[x] would hide keys from this.
local function usedKeys()
  local used, dynamic = {}, {}
  for _, path in ipairs(sourceFiles()) do
    local f = assert(io.open(path))
    local text = f:read("*a")
    f:close()
    for raw in text:gmatch('%f[%w_.]L%["([^"]*)"%]') do
      used[assert(loadstring('return "' .. raw .. '"'))()] = path
    end
    for nextChar in text:gmatch('%f[%w_.]L%[(.)') do
      if nextChar ~= '"' then dynamic[#dynamic + 1] = path end
    end
  end
  return used, dynamic
end

describe("locale", function()
  local reference = entries(loadLocale("enUS.lua", nil))

  it("falls back to the key", function()
    local L = loadLocale("enUS.lua", "koKR")
    assert.are.equal("Not a real key: %s", L["Not a real key: %s"])
    assert.are.equal("Start", L["Start"])
  end)

  it("enUS maps true to the key", function()
    assert.are.equal("Modules", reference["Modules"])
  end)

  it("every key used in the source is in enUS", function()
    local used, dynamic = usedKeys()
    assert.are.same({}, dynamic)
    local missing = {}
    for key, path in pairs(used) do
      if reference[key] == nil then missing[key] = path end
    end
    assert.are.same({}, missing)
  end)

  it("enUS has no key the source no longer uses", function()
    local used = usedKeys()
    local stale = {}
    for key in pairs(reference) do
      if not used[key] then stale[#stale + 1] = key end
    end
    assert.are.same({}, stale)
  end)

  for _, def in ipairs(LOCALES) do
    local file, locale = def[1], def[2]
    describe(file, function()
      local translated = entries(loadLocale(file, locale))

      it("applies only for its locale", function()
        assert.are.same({}, entries(loadLocale(file, nil)))
        assert.are.same({}, entries(loadLocale(file, "koKR")))
        for _, alias in ipairs(def.aliases or {}) do
          assert.are.same(translated, entries(loadLocale(file, alias)))
        end
      end)

      it("has no stale keys", function()
        local stale = {}
        for key in pairs(translated) do
          if reference[key] == nil then stale[#stale + 1] = key end
        end
        assert.are.same({}, stale)
      end)

      it("translates every key", function()
        local missing = {}
        for key in pairs(reference) do
          if type(translated[key]) ~= "string" or translated[key] == "" then missing[#missing + 1] = key end
        end
        assert.are.same({}, missing)
      end)

      it("keeps every placeholder", function()
        local wrong = {}
        for key, value in pairs(translated) do
          if placeholders(key) ~= placeholders(value) then wrong[key] = value end
        end
        assert.are.same({}, wrong)
      end)

      it("keeps slash commands literal", function()
        local wrong = {}
        for key, value in pairs(translated) do
          local command = key:match("^(/hb.-) \226\128\148")
          if command and value:sub(1, #command + 1) ~= command .. " " then wrong[key] = value end
        end
        assert.are.same({}, wrong)
      end)
    end)
  end
end)

describe("locale placeholders helper", function()
  it("reads conversions and ignores a lone percent", function()
    assert.are.equal("%.1f %%", placeholders("Goal: %.1f%%"))
    assert.are.equal("", placeholders("after the 5% auction house cut"))
    assert.are.equal("%d %s", placeholders("%2$s then %1$d"))
  end)
end)
