local ADDON, ns = ...

-- Core addon object: module toggling with dependencies, error isolation,
-- chat output and slash commands. Saved data lives in Core/DB.lua.

local HB = LibStub("AceAddon-3.0"):NewAddon("Harvestbook", "AceEvent-3.0", "AceConsole-3.0", "AceTimer-3.0")
ns.HB = HB
Harvestbook = HB

local PREFIX = "|cffffd100Harvestbook|r: "

-- Dependencies first, dependents after (used for enable/disable ordering).
HB.MODULE_ORDER = { "Session", "NodeLog", "Records", "MapPins", "BestSpot", "Goals", "Alarms" }

HB.DEPENDS = {
  MapPins = { "NodeLog" },
  BestSpot = { "NodeLog", "Records" },
  Records = { "Session" },
  Goals = { "Session" },
  Alarms = { "Session" },
}

HB.MODULE_LABELS = {
  Session = "Session", NodeLog = "Node Log", Records = "Records", MapPins = "Map Pins",
  BestSpot = "Best Spot", Goals = "Goals", Alarms = "Alarms",
}

local function label(name)
  return HB.MODULE_LABELS[name] or name
end

-- Chat output -----------------------------------------------------------------

function HB:Msg(fmt, ...)
  local text = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. text)
end

-- Error isolation -------------------------------------------------------------

HB.errors = {}          -- [moduleName] = last traceback text
local reported = {}     -- [moduleName] = true once the chat notice was printed this login

local function errorHandler(err)
  local stack = debugstack and debugstack(2) or ""
  return tostring(err) .. "\n" .. stack
end

local function finish(moduleName, ok, ...)
  if ok then return ... end
  local trace = ...
  HB.errors[moduleName] = trace
  local debugOn = HB.db and HB.db.profile.debug
  if debugOn then
    HB:Msg("%s error:\n%s", moduleName, tostring(trace))
  elseif not reported[moduleName] then
    reported[moduleName] = true
    HB:Msg("%s error \226\128\148 see /hb debug", moduleName)
  end
  return nil
end

-- Calls fn(...) protected; an error is reported (once per module per login,
-- or every time with traceback when debug is on) and never propagates.
function HB:SafeCall(moduleName, fn, ...)
  local n = select("#", ...)
  local args = { ... }
  return finish(moduleName, xpcall(function() return fn(unpack(args, 1, n)) end, errorHandler))
end

function HB:Listen(module, message, handler)
  module:RegisterMessage(message, function(_, ...)
    HB:SafeCall(module:GetName(), handler, module, ...)
  end)
end

-- Module enable state ---------------------------------------------------------

local function profileEnabled(name)
  local m = HB.db.profile.modules[name]
  return m ~= nil and m.enabled ~= false
end

-- Pure: given DEPENDS and a predicate wanted(name), returns the set of names
-- that end up enabled (wanted and every dependency transitively enabled).
local function resolveEnabled(depends, names, wanted)
  local result, visiting = {}, {}
  local function ok(name)
    if result[name] ~= nil then return result[name] end
    if visiting[name] then return false end
    visiting[name] = true
    local on = wanted(name) and true or false
    if on then
      for _, dep in ipairs(depends[name] or {}) do
        if not ok(dep) then on = false break end
      end
    end
    visiting[name] = nil
    result[name] = on
    return on
  end
  for _, name in ipairs(names) do ok(name) end
  return result
end

-- Pure: names (other than `name`) in `enabledSet` that transitively depend on
-- `name`; these must be disabled when `name` is disabled.
local function dependentsOf(depends, name, enabledSet)
  local out, seen = {}, { [name] = true }
  local queue = { name }
  while #queue > 0 do
    local cur = table.remove(queue, 1)
    for mod, deps in pairs(depends) do
      if not seen[mod] and enabledSet[mod] then
        for _, d in ipairs(deps) do
          if d == cur then
            seen[mod] = true
            out[#out + 1] = mod
            queue[#queue + 1] = mod
            break
          end
        end
      end
    end
  end
  return out
end

local function allModuleNames()
  local names, seen = {}, {}
  for _, n in ipairs(HB.MODULE_ORDER) do names[#names + 1] = n; seen[n] = true end
  for n in HB:IterateModules() do
    if not seen[n] then names[#names + 1] = n; seen[n] = true end
  end
  return names
end

local function isOn(name)
  local mod = HB:GetModule(name, true)
  return mod ~= nil and mod:IsEnabled()
end

-- Called from OnInitialize: sets enabled state before modules get enabled.
function HB:InitModuleStates()
  local names = allModuleNames()
  local want = resolveEnabled(self.DEPENDS, names, function(n)
    return self:GetModule(n, true) ~= nil and profileEnabled(n)
  end)
  for name, mod in self:IterateModules() do
    mod:SetEnabledState(want[name] and true or false)
  end
end

-- Called after a profile change: brings live modules in line with the profile.
function HB:ApplyModuleStates()
  local names = allModuleNames()
  local want = resolveEnabled(self.DEPENDS, names, function(n)
    return self:GetModule(n, true) ~= nil and profileEnabled(n)
  end)
  for i = #names, 1, -1 do
    local name = names[i]
    if not want[name] and isOn(name) then
      self:DisableModule(name)
      self:SendMessage("HB_MODULE_TOGGLED", name, false)
    end
  end
  for _, name in ipairs(names) do
    if want[name] and not isOn(name) and self:GetModule(name, true) then
      self:EnableModule(name)
      self:SendMessage("HB_MODULE_TOGGLED", name, true)
    end
  end
end

function HB:SetModuleEnabled(name, enabled)
  local mod = self:GetModule(name, true)
  if not mod then
    self:Msg("Unknown module: %s", tostring(name))
    return false
  end
  local mods = self.db.profile.modules
  mods[name] = mods[name] or {}

  if enabled then
    local missing = {}
    for _, dep in ipairs(self.DEPENDS[name] or {}) do
      if not isOn(dep) then missing[#missing + 1] = label(dep) end
    end
    if #missing > 0 then
      self:Msg("%s requires %s \226\128\148 enable it first.", label(name), table.concat(missing, ", "))
      return false
    end
    mods[name].enabled = true
    if not mod:IsEnabled() then
      self:EnableModule(name)
      self:SendMessage("HB_MODULE_TOGGLED", name, true)
    end
    return true
  end

  local enabledSet = {}
  for n, m in self:IterateModules() do
    if m:IsEnabled() then enabledSet[n] = true end
  end
  local dependents = dependentsOf(self.DEPENDS, name, enabledSet)
  -- Disable dependents in reverse discovery order (deepest first), then name.
  for i = #dependents, 1, -1 do
    local dep = dependents[i]
    mods[dep] = mods[dep] or {}
    mods[dep].enabled = false
    self:DisableModule(dep)
    self:SendMessage("HB_MODULE_TOGGLED", dep, false)
  end
  mods[name].enabled = false
  if mod:IsEnabled() then
    self:DisableModule(name)
    self:SendMessage("HB_MODULE_TOGGLED", name, false)
  end
  return true
end

-- Lifecycle -------------------------------------------------------------------

function HB:OnInitialize()
  HarvestbookCharDB = HarvestbookCharDB or {}
  self.char = HarvestbookCharDB

  self:InitDB()

  local ok, err = pcall(ns.Migrate.Run, self.db.global, self.migrations)
  if not ok then
    self.errors.Migrate = tostring(err)
    self:Msg("saved data migration failed \226\128\148 %s", tostring(err))
  end

  self.db.RegisterCallback(self, "OnProfileChanged", "ApplyModuleStates")
  self.db.RegisterCallback(self, "OnProfileCopied", "ApplyModuleStates")
  self.db.RegisterCallback(self, "OnProfileReset", "ApplyModuleStates")

  self:InitModuleStates()

  if self.InitOptions then self:InitOptions() end -- Core/Options.lua: profiles tab + Blizzard Settings
  if self.UI and self.UI.Init then self.UI:Init() end -- UI/Box.lua: minimap button, companion

  self:RegisterChatCommand("hb", "OnSlash")
  self:RegisterChatCommand("harvestbook", "OnSlash")
end

-- Slash commands --------------------------------------------------------------

local HELP = {
  "/hb \226\128\148 toggle the Harvestbook window",
  "/hb start | pause | resume | stop | reset \226\128\148 control the gathering session",
  "/hb companion \226\128\148 toggle the companion window",
  "/hb config \226\128\148 open all options",
  "/hb prices \226\128\148 refresh prices for the current session",
  "/hb debug \226\128\148 toggle debug output",
  "/hb help \226\128\148 show this list",
}

function HB:PrintHelp()
  self:Msg("commands (/harvestbook works too):")
  for _, line in ipairs(HELP) do
    DEFAULT_CHAT_FRAME:AddMessage("  " .. line)
  end
end

local function toggleUI()
  if HB.UI and HB.UI.Toggle then
    HB.UI:Toggle()
  else
    HB:Msg("window not available.")
  end
end

local function sessionModule()
  local mod = HB:GetModule("Session", true)
  if mod and mod:IsEnabled() then return mod end
  HB:Msg("the Session module is disabled.")
  return nil
end

local SESSION_CMDS = { start = "Start", pause = "Pause", resume = "Resume", stop = "Stop", reset = "ConfirmReset" }

function HB:OnSlash(input)
  local cmd = string.lower((input or ""):match("^%s*(%S*)") or "")

  if cmd == "" then
    toggleUI()
  elseif SESSION_CMDS[cmd] then
    local mod = sessionModule()
    local method = mod and mod[SESSION_CMDS[cmd]]
    if method then self:SafeCall("Session", method, mod) end
  elseif cmd == "companion" then
    if self.UI and self.UI.ToggleCompanion then
      self.UI:ToggleCompanion()
    else
      self:Msg("companion not available.")
    end
  elseif cmd == "config" then
    local registry = LibStub("AceConfigRegistry-3.0", true)
    local dialog = LibStub("AceConfigDialog-3.0", true)
    if registry and dialog and registry:GetOptionsTable("Harvestbook") then
      dialog:Open("Harvestbook")
    else
      self:Msg("options not available.")
    end
  elseif cmd == "prices" then
    self:RefreshSessionPrices()
  elseif cmd == "debug" then
    local p = self.db.profile
    p.debug = not p.debug
    self:Msg("debug %s.", p.debug and "on" or "off")
    if p.debug then
      for name, trace in pairs(self.errors) do
        self:Msg("last %s error:\n%s", name, tostring(trace))
      end
    end
  else
    self:PrintHelp()
  end
end

function HB:RefreshSessionPrices()
  if not (self.Pricing and self.Pricing.Refresh) then
    self:Msg("pricing not available.")
    return
  end
  local mod = self:GetModule("Session", true)
  local session = mod and mod:IsEnabled() and mod.GetCurrent and mod:GetCurrent()
  if not session or not session.items then
    self:Msg("no active session \226\128\148 nothing to refresh.")
    return
  end
  local list = {}
  for _, it in pairs(session.items) do
    list[#list + 1] = { itemID = it.itemID, quality = it.quality, link = it.link }
  end
  self:SafeCall("Pricing", self.Pricing.Refresh, self.Pricing, list)
  self:Msg("refreshed prices for %d items.", #list)
end

function Harvestbook_OnAddonCompartmentClick()
  toggleUI()
end
