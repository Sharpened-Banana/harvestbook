local ADDON, ns = ...

local M = {}
ns.GatherParse = M

M.KNOWN_SPELLS = {
  [2575] = "ore", [195122] = "ore", [423341] = "ore", [471013] = "ore",
  [2366] = "herb",
  [8613] = "skin",
}

-- Items the game pushes into the bags a while after a gather, outside the
-- node's loot window. They count as loot of the last gather (not a new node).
--   274777 Neutralized Venom Clot: a Venomous node on the Coiled Isle (12.1)
--          leaves venom puddles; running into one pushes the clot.
M.BONUS_ITEMS = {
  [274777] = true,
}
M.BONUS_WINDOW = 180 -- seconds after the last gather

-- True when itemID is a bonus item received within the window of a gather at lastTime.
function M.IsBonusLoot(itemID, now, lastTime)
  if not (itemID and M.BONUS_ITEMS[itemID]) then return false end
  if type(lastTime) ~= "number" or type(now) ~= "number" then return false end
  local age = now - lastTime
  return age >= 0 and age <= M.BONUS_WINDOW
end

-- "Type-0-server-instance-zoneUID-ID-spawnUID" -> type, numeric ID (6th field).
-- Only GameObject and Creature GUIDs are recognised.
function M.ParseGUID(guid)
  if type(guid) ~= "string" then return nil end
  local unitType, id = guid:match("^(%a+)%-[^%-]*%-[^%-]*%-[^%-]*%-[^%-]*%-(%d+)%-[^%-]+$")
  if unitType ~= "GameObject" and unitType ~= "Creature" then return nil end
  return unitType, tonumber(id)
end

-- knownIDs = { [spellID] = kind }; nameOf(spellID) -> localized name or nil.
function M.NewSpellMatcher(knownIDs, nameOf)
  local names = {}
  for id, kind in pairs(knownIDs) do
    local ok, name = pcall(nameOf, id)
    if ok and type(name) == "string" and name ~= "" then
      names[name] = kind
    end
  end
  return function(spellID, spellName)
    local kind = spellID and knownIDs[spellID]
    if kind then return kind end
    if type(spellName) == "string" and spellName ~= "" then
      return names[spellName]
    end
    return nil
  end
end

local function escape(s)
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- Converts a Blizzard format string into an anchored Lua pattern.
-- Returns pattern, order where order[i] is the format-argument index of
-- the i-th capture (differs from i for positional forms like "%2$d").
function M.PatternFromFormat(fmt)
  local out, order = { "^" }, {}
  local pos, nextArg = 1, 1
  while pos <= #fmt do
    local s = fmt:find("%", pos, true)
    if not s then
      out[#out + 1] = escape(fmt:sub(pos))
      break
    end
    out[#out + 1] = escape(fmt:sub(pos, s - 1))
    local idx, conv = fmt:match("^%%(%d+)%$([sd])", s)
    if idx then
      order[#order + 1] = tonumber(idx)
      out[#out + 1] = (conv == "s") and "(.+)" or "(%d+)"
      pos = s + #idx + 3
    else
      conv = fmt:match("^%%([sd%%])", s)
      if conv == "%" then
        out[#out + 1] = "%%"
      elseif conv then
        order[#order + 1] = nextArg
        nextArg = nextArg + 1
        out[#out + 1] = (conv == "s") and "(.+)" or "(%d+)"
      else
        out[#out + 1] = "%%" -- unsupported specifier: keep the % literal
        pos = s + 1
        conv = nil
      end
      if conv then pos = s + 2 end
    end
  end
  out[#out + 1] = "$"
  return table.concat(out), order
end
