local ADDON, ns = ...

-- Saved data: AceDB defaults, schema migrations, per-character table.

local HB = ns.HB

local function deepcopy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deepcopy(v) end
  return out
end

HB.defaults = {
  profile = {
    modules = {
      Session = { enabled = true },
      NodeLog = { enabled = true },
      MapPins = { enabled = true },
      Records = { enabled = true },
      BestSpot = { enabled = true },
      Goals = { enabled = true },
      Alarms = { enabled = true },
    },
    window = { point = { "CENTER", "UIParent", "CENTER", 0, 0 }, w = 840, h = 715, page = "session" },
    companion = {
      shown = true,
      tabs = { session = true, materials = true, log = true },
      scale = 1, alpha = 0.9, locked = false, autoShow = true, hideNoSession = false,
    },
    session = {
      autoStart = true,
      pause = { instance = true, mail = true, ah = true, afk = true },
      autoResume = true,
      sortKey = "value",
    },
    pricing = { order = { "override", "auctionator", "tsm", "vendor" }, tsmString = "DBMarket" },
    pins = {
      world = true, minimap = true,
      kinds = { herb = true, ore = true, skin = true },
      minGathers = 1, fadeDays = 14, size = 14,
    },
    alarms = deepcopy(ns.AlarmEval.DEFAULTS),
    goals = { list = {} },
    minimap = { hide = false },
    bestspot = { scope = "zones", metric = "gph" },
    goldStyle = "auto",
    debug = false,
  },
  -- schemaVersion is deliberately absent: Migrate must see it unset on a fresh DB.
  global = {
    nodes = {},
    sessions = {},
    records = {},
    prices = {},
    priceOverrides = {},
    lifetime = {},
    lifetimeByChar = {},
    goals = { attempts = {} },
    nodeNames = {},
  },
}

-- migrations[n] = function(global) ... end; run in order for n > schemaVersion.
HB.migrations = {
  [1] = function(global) end, -- no-op: establishes schema v1 on a fresh DB
  [2] = function(global) -- "Biggest single node" record removed
    if global.records then global.records.biggestNode = nil end
  end,
}

function HB:InitDB()
  self.db = LibStub("AceDB-3.0"):New("HarvestbookDB", self.defaults, true)
end
