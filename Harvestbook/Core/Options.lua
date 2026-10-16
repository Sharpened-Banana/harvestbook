local ADDON, ns = ...

-- AceConfig root (spec §5.4). Registered at file load so modules can call
-- HB:AddOptions any time; every get/set reads HB.db lazily. HB:InitOptions
-- (called from OnInitialize, once HB.db exists) adds the profiles tab and
-- registers the Blizzard Settings entry.

local HB = ns.HB
local Base64 = ns.Base64

local AceConfig = LibStub("AceConfig-3.0")
local AceConfigRegistry = LibStub("AceConfigRegistry-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")
local AceDBOptions = LibStub("AceDBOptions-3.0")
local AceSerializer = LibStub("AceSerializer-3.0")

local APP = "Harvestbook"
local EXPORT_PREFIX = "HB1:"

local function deepcopy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deepcopy(v) end
  return out
end

-- Fills keys missing from dst with copies of def (recursively).
local function fillDefaults(dst, def)
  for k, v in pairs(def) do
    if dst[k] == nil then
      dst[k] = deepcopy(v)
    elseif type(v) == "table" and type(dst[k]) == "table" then
      fillDefaults(dst[k], v)
    end
  end
end

local function notify()
  AceConfigRegistry:NotifyChange(APP)
end

-- Module switches -------------------------------------------------------------

local function moduleOn(name)
  local mod = HB:GetModule(name, true)
  return mod ~= nil and mod:IsEnabled()
end

local function dependsText(name)
  local deps = HB.DEPENDS[name]
  if not deps or #deps == 0 then
    return "Turns the " .. HB.MODULE_LABELS[name] .. " module on or off. Disabling never deletes its data."
  end
  local labels = {}
  for i, dep in ipairs(deps) do labels[i] = HB.MODULE_LABELS[dep] or dep end
  return "Requires " .. table.concat(labels, " and ")
end

local function moduleToggles()
  local args = {
    header = { type = "header", name = "Modules", order = 0 },
  }
  for i, name in ipairs(HB.MODULE_ORDER) do
    args[name] = {
      type = "toggle",
      order = i,
      name = HB.MODULE_LABELS[name] or name,
      desc = dependsText(name),
      get = function()
        if HB:GetModule(name, true) then return moduleOn(name) end
        local m = HB.db.profile.modules[name]
        return m ~= nil and m.enabled ~= false
      end,
      set = function(_, value)
        HB:SetModuleEnabled(name, value and true or false)
        notify()
      end,
      disabled = function()
        for _, dep in ipairs(HB.DEPENDS[name] or {}) do
          if not moduleOn(dep) then return true end
        end
        return false
      end,
    }
  end
  return args
end

-- Pricing ---------------------------------------------------------------------

local SOURCE_NAMES = { "override", "auctionator", "tsm", "vendor" }
local SOURCE_VALUES = {
  override = "Manual override",
  auctionator = "Auctionator",
  tsm = "TradeSkillMaster",
  vendor = "Vendor price",
}

-- Puts value into slot, moving the slot's old value to wherever value was,
-- so the order always stays a permutation of the four sources.
local function swapSlot(order, slot, value)
  local old = order[slot]
  if old == value then return end
  for j = 1, #order do
    if order[j] == value then
      order[j] = old
      break
    end
  end
  order[slot] = value
end

local function priceOrderChanged()
  if HB.Pricing and HB.Pricing.ClearCache then HB.Pricing:ClearCache() end
  notify()
end

local function detectedSources()
  local found = {}
  if Auctionator and Auctionator.API and Auctionator.API.v1 then found[#found + 1] = "Auctionator" end
  if TSM_API then found[#found + 1] = "TradeSkillMaster" end
  if #found == 0 then return "No auction addon detected \226\128\148 vendor prices and overrides only." end
  return "Detected: " .. table.concat(found, ", ") .. ". Missing sources are skipped."
end

local function pricingArgs()
  local args = {
    header = { type = "header", name = "Price sources", order = 0 },
    detected = { type = "description", order = 1, name = detectedSources, fontSize = "medium" },
  }
  for slot = 1, #SOURCE_NAMES do
    args["slot" .. slot] = {
      type = "select",
      order = 1 + slot,
      width = "normal",
      name = "Source " .. slot,
      desc = "Sources are tried in this order; the first with a price wins. Choosing a source swaps it with this slot.",
      values = SOURCE_VALUES,
      sorting = SOURCE_NAMES,
      get = function() return HB.db.profile.pricing.order[slot] end,
      set = function(_, value)
        swapSlot(HB.db.profile.pricing.order, slot, value)
        priceOrderChanged()
      end,
    }
  end
  args.tsmString = {
    type = "input",
    order = 10,
    width = "double",
    name = "TSM price string",
    desc = "TradeSkillMaster custom price used for the TSM source (default DBMarket).",
    get = function() return HB.db.profile.pricing.tsmString end,
    set = function(_, value)
      value = strtrim(value or "")
      HB.db.profile.pricing.tsmString = value ~= "" and value or "DBMarket"
      priceOrderChanged()
    end,
  }
  args.ahCut = {
    type = "toggle",
    order = 11,
    width = "full",
    name = "Subtract the auction house cut (5%)",
    desc = "Auctionator and TSM prices are listing prices. On: they count 95% of that, what a sale actually pays. Vendor prices and manual overrides are not changed.",
    get = function() return HB.db.profile.pricing.ahCut end,
    set = function(_, value)
      HB.db.profile.pricing.ahCut = value and true or false
      HB:SendMessage("HB_PRICES_UPDATED")
    end,
  }
  return args
end

-- Auto-pause + minimap ---------------------------------------------------------

local function sessionToggle(order, name, desc, path1, path2)
  return {
    type = "toggle", order = order, name = name, desc = desc, width = "full",
    get = function()
      local s = HB.db.profile.session
      if path2 then return s[path1][path2] end
      return s[path1]
    end,
    set = function(_, value)
      local s = HB.db.profile.session
      if path2 then s[path1][path2] = value else s[path1] = value end
    end,
  }
end

local function minimapToggle(order)
  return {
    type = "toggle", order = order, width = "full",
    name = "Show minimap button",
    get = function() return not HB.db.profile.minimap.hide end,
    set = function(_, value)
      HB.db.profile.minimap.hide = not value
      local icon = LibStub("LibDBIcon-1.0", true)
      if icon and icon:IsRegistered(APP) then
        if value then icon:Show(APP) else icon:Hide(APP) end
      end
    end,
  }
end

-- Export / import --------------------------------------------------------------

local function exportString()
  return EXPORT_PREFIX .. Base64.Encode(AceSerializer:Serialize(HB.db.profile))
end

-- Returns a profile table, or nil + reason.
local function decodeImport(text)
  if type(text) ~= "string" then return nil, "empty string" end
  text = text:gsub("%s+", "")
  if text == "" then return nil, "empty string" end
  if text:sub(1, #EXPORT_PREFIX) ~= EXPORT_PREFIX then return nil, "not a Harvestbook settings string" end
  local raw = Base64.Decode(text:sub(#EXPORT_PREFIX + 1))
  if not raw then return nil, "damaged string (bad encoding)" end
  local ok, data = AceSerializer:Deserialize(raw)
  if not ok or type(data) ~= "table" then return nil, "damaged string (cannot read settings)" end
  return data
end

local function validOrder(order)
  if type(order) ~= "table" or #order ~= #SOURCE_NAMES then return false end
  local seen = {}
  for _, n in ipairs(order) do
    if not SOURCE_VALUES[n] or seen[n] then return false end
    seen[n] = true
  end
  return true
end

-- Overwrites the current profile's known keys with the imported values;
-- keys missing from the import fall back to defaults.
local function applyImport(data)
  local profile = HB.db.profile
  for key, def in pairs(HB.defaults.profile) do
    local v = data[key]
    if v ~= nil and type(v) == type(def) then
      v = deepcopy(v)
      if type(v) == "table" then fillDefaults(v, def) end
      profile[key] = v
    end
  end
  if not validOrder(profile.pricing.order) then
    profile.pricing.order = deepcopy(HB.defaults.profile.pricing.order)
  end
  HB:ApplyModuleStates()
  if HB.Pricing and HB.Pricing.ClearCache then HB.Pricing:ClearCache() end
  notify()
  HB:Msg("settings imported. Some changes apply after /reload.")
end

StaticPopupDialogs["HARVESTBOOK_IMPORT"] = {
  text = "Overwrite the current Harvestbook profile with the imported settings?",
  button1 = ACCEPT, button2 = CANCEL,
  OnAccept = function(_, data) HB:SafeCall("Options", applyImport, data) end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Reset all data ------------------------------------------------------------------

local function resetAllData()
  local g = HB.db.global
  for k in pairs(g) do
    if k ~= "schemaVersion" then g[k] = nil end
  end
  for k, v in pairs(HB.defaults.global) do g[k] = deepcopy(v) end
  HB.db:ResetProfile()
  if HB.char then
    HB.char.current = nil
    HB.char.goalsReached = nil
  end
  StaticPopup_Show("HARVESTBOOK_RELOAD")
end

StaticPopupDialogs["HARVESTBOOK_RESET_1"] = {
  text = "Reset ALL Harvestbook data? Node log, sessions, records, goals, prices and settings will be erased.",
  button1 = YES, button2 = CANCEL,
  OnAccept = function()
    -- Defer so the second popup is not hidden by this one closing.
    C_Timer.After(0, function() StaticPopup_Show("HARVESTBOOK_RESET_2") end)
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["HARVESTBOOK_RESET_2"] = {
  text = "Are you absolutely sure? This cannot be undone.",
  button1 = "Erase everything", button2 = CANCEL,
  OnAccept = function()
    C_Timer.After(0, function() HB:SafeCall("Options", resetAllData) end)
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3, showAlert = true,
}

StaticPopupDialogs["HARVESTBOOK_RELOAD"] = {
  text = "Harvestbook data has been reset. Reload the UI now to finish?",
  button1 = RELOADUI or "Reload UI", button2 = LATER or CANCEL,
  OnAccept = function() ReloadUI() end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function dataArgs()
  return {
    shareHeader = { type = "header", name = "Share settings", order = 0 },
    export = {
      type = "input", order = 1, width = "full", multiline = 4,
      name = "Export",
      desc = "Copy this string (Ctrl+A, Ctrl+C) to share or back up the current profile's settings.",
      get = function() return exportString() end,
      set = function() end,
    },
    import = {
      type = "input", order = 2, width = "full", multiline = 4,
      name = "Import",
      desc = "Paste a Harvestbook settings string and press Accept.",
      get = function() return "" end,
      set = function(_, value)
        local data, reason = decodeImport(value)
        if not data then
          HB:Msg("import failed: %s.", reason)
          return
        end
        StaticPopup_Show("HARVESTBOOK_IMPORT", nil, nil, data)
      end,
    },
    resetHeader = { type = "header", name = "Danger zone", order = 10 },
    reset = {
      type = "execute", order = 11,
      name = "Reset all data",
      desc = "Erases every node, session, record, goal, price and setting. Asks twice.",
      func = function() StaticPopup_Show("HARVESTBOOK_RESET_1") end,
    },
  }
end

-- Root ----------------------------------------------------------------------------

HB.options = {
  type = "group",
  name = "Harvestbook",
  childGroups = "tab",
  args = {
    general = {
      type = "group", order = 1, name = "General",
      args = {
        modules = { type = "group", inline = true, order = 1, name = "Modules", args = moduleToggles() },
        pricing = { type = "group", inline = true, order = 2, name = "Pricing", args = pricingArgs() },
        session = {
          type = "group", inline = true, order = 3, name = "Session",
          args = {
            autoStart = sessionToggle(1, "Start a session on the first gather", nil, "autoStart"),
            idleStop = sessionToggle(1.1, "End the session when I stop gathering",
              "Ends the session after the minutes below without a gather. Its time ends at the last gather, so idle minutes don't lower gold/hr.", "idleStop"),
            idleMinutes = {
              type = "range", order = 1.2, name = "Minutes without a gather", min = 1, max = 60, step = 1,
              disabled = function() return not HB.db.profile.session.idleStop end,
              get = function() return HB.db.profile.session.idleMinutes or 5 end,
              set = function(_, v) HB.db.profile.session.idleMinutes = v end,
            },
            keepOnLogout = sessionToggle(1.3, "Keep the session across logouts",
              "Off: a session still open when you log out is saved to history at your next login. /reload never ends a session.", "keepOnLogout"),
            instance = sessionToggle(2, "Pause in instances", nil, "pause", "instance"),
            mail = sessionToggle(3, "Pause at the mailbox", nil, "pause", "mail"),
            ah = sessionToggle(4, "Pause at the auction house", nil, "pause", "ah"),
            afk = sessionToggle(5, "Pause while AFK", nil, "pause", "afk"),
            autoResume = sessionToggle(6, "Resume automatically", "Resume the session when the pause reason ends.", "autoResume"),
          },
        },
        minimap = {
          type = "group", inline = true, order = 4, name = "Minimap",
          args = { show = minimapToggle(1) },
        },
      },
    },
    data = { type = "group", order = 90, name = "Data", args = dataArgs() },
  },
}

AceConfig:RegisterOptionsTable(APP, HB.options)
AceConfigDialog:SetDefaultSize(APP, 760, 620)

-- Modules add their own tab/group. order defaults to 50 (between General and Data).
function HB:AddOptions(key, groupTable, order)
  if order then groupTable.order = order end
  if groupTable.order == nil then groupTable.order = 50 end
  self.options.args[key] = groupTable
  notify()
end

local blizRegistered = false

-- Called from OnInitialize once HB.db exists.
function HB:InitOptions()
  local profiles = AceDBOptions:GetOptionsTable(self.db)
  profiles.order = 100
  self.options.args.profiles = profiles
  if not blizRegistered then
    blizRegistered = true
    AceConfigDialog:AddToBlizOptions(APP, "Harvestbook")
  end
  notify()
end
