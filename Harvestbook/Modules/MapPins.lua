local ADDON, ns = ...

-- MapPins module (spec 4.3): world map and minimap pins for every recorded
-- spot, via HereBeDragons-Pins-2.0.
--
-- HBD-Pins API used (read from libs/HereBeDragons/HereBeDragons-Pins-2.0.lua):
--   AddWorldMapIconMap(ref, icon, uiMapID, x, y, showFlag)
--   AddMinimapIconMap(ref, icon, uiMapID, x, y, showInParentZone, floatOnEdge)
--   RemoveWorldMapIcon(ref, icon), RemoveMinimapIcon(ref, icon)
--   RemoveAllWorldMapIcons(ref), RemoveAllMinimapIcons(ref)
--   HBD_PINS_WORLDMAP_SHOW_PARENT (global constant)
-- A frame can only be in one pin set, so world and minimap pins use separate
-- pools. `ref` is this module.
--
-- Pins are built lazily: minimap pins only for the player's current zone,
-- world map pins only for zones the map has viewed (plus their children).
-- Listens: HB_NODELOG_CHANGED(mapID, spotKey): (nil, nil) or (mapID, nil)
-- rebuild everything; (mapID, spotKey) updates one built spot.

local HB = ns.HB
local Format = ns.Format
local Rankings = ns.Rankings
local Theme = ns.Theme

local MapPins = HB:NewModule("MapPins", "AceEvent-3.0")

local HBDPins = LibStub("HereBeDragons-Pins-2.0", true)

local DOT = "\194\183"
local KIND_LABEL = { herb = "Herb", ore = "Ore", skin = "Skin" }
local FADED_ALPHA = 0.4
local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

local pools = { world = {}, minimap = {} }   -- free pins per map type
local active = { world = {}, minimap = {} }  -- key -> pin per map type
local worldBuilt = {}                        -- mapIDs whose world pins are built
local minimapZone                            -- mapID whose minimap pins are built

local function cfg() return HB.db.profile.pins end
local function nodeLog() return HB:GetModule("NodeLog", true) end

local function pinKey(mapID, spotKey) return mapID .. "|" .. spotKey end

---------------------------------------------------------------------------
-- Tooltip
---------------------------------------------------------------------------

local function nodeName(id)
  return HB.db.global.nodeNames[id] or ("Node " .. tostring(id))
end

local function itemName(itemID)
  local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
  return name or ("Item " .. tostring(itemID))
end

-- Most-gathered nodeID; ties go to the lowest id.
local function dominantNode(spot)
  local best, bestN
  for id, n in pairs(spot.nodeIDs or {}) do
    if not bestN or n > bestN or (n == bestN and id < best) then best, bestN = id, n end
  end
  return best
end

local function zoneGph(mapID)
  local rows = Rankings.Zones(HB.db.global.sessions, "gph", 0)
  for _, r in ipairs(rows) do
    if r.mapID == mapID then return r.gph end
  end
  return nil
end

local function showTooltip(pin)
  local nl = nodeLog()
  local zone = nl and nl:GetZone(pin.mapID)
  local spot = zone and zone[pin.spotKey]
  if not spot then return end

  GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
  local dom = dominantNode(spot)
  local title = dom and nodeName(dom) or KIND_LABEL[spot.kind] or "Node"
  GameTooltip:AddLine(title, Theme:Color("gold"))

  local gathers = spot.gathers or 0
  if spot.imported and gathers == 0 then
    GameTooltip:AddLine("Imported from GatherMate2", 1, 1, 1)
  else
    local line = string.format("%d gathers here", gathers)
    local gph = zoneGph(pin.mapID) -- once per tooltip show
    if gph then
      line = line .. " " .. DOT .. " " .. Format.Money(gph, HB.db.profile.goldStyle) .. " per hour"
    end
    GameTooltip:AddLine(line, 1, 1, 1)

    local list = {}
    for itemID, n in pairs(spot.items or {}) do list[#list + 1] = { itemID = itemID, n = n } end
    table.sort(list, function(a, b)
      if a.n ~= b.n then return a.n > b.n end
      return a.itemID < b.itemID
    end)
    for i = 1, math.min(4, #list) do
      GameTooltip:AddLine(itemName(list[i].itemID) .. " x" .. list[i].n, Theme:Color("parchment"))
    end
  end
  GameTooltip:AddLine("Shift-right-click to forget this spot", Theme:Color("grey"))
  GameTooltip:Show()
end

---------------------------------------------------------------------------
-- Pin frames
---------------------------------------------------------------------------

local function onEnter(pin) HB:SafeCall("MapPins", showTooltip, pin) end
local function onLeave(pin)
  if GameTooltip:GetOwner() == pin then GameTooltip:Hide() end
end

local function onClick(pin, button)
  if button == "RightButton" and IsShiftKeyDown() then
    if GameTooltip:GetOwner() == pin then GameTooltip:Hide() end
    local nl = nodeLog()
    if nl then HB:SafeCall("MapPins", nl.ForgetSpot, nl, pin.mapID, pin.spotKey) end
  end
end

local function newPin()
  local pin = CreateFrame("Button", nil, UIParent)
  pin:SetFrameStrata("HIGH")
  pin:RegisterForClicks("RightButtonUp")

  -- One circular mask shared by the dark backing and the icon.
  pin.mask = pin:CreateMaskTexture()
  pin.mask:SetAllPoints()
  pin.mask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")

  pin.bg = pin:CreateTexture(nil, "BACKGROUND")
  pin.bg:SetAllPoints()
  pin.bg:SetColorTexture(0.03, 0.06, 0.05, 0.95)
  pin.bg:AddMaskTexture(pin.mask)

  pin.icon = pin:CreateTexture(nil, "ARTWORK")
  pin.icon:SetPoint("TOPLEFT", 1, -1)
  pin.icon:SetPoint("BOTTOMRIGHT", -1, 1)
  pin.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  pin.icon:AddMaskTexture(pin.mask)

  pin:SetScript("OnEnter", onEnter)
  pin:SetScript("OnLeave", onLeave)
  pin:SetScript("OnClick", onClick)
  return pin
end

local function acquire(mapType)
  return table.remove(pools[mapType]) or newPin()
end

local function recycle(mapType, pin)
  pin:Hide()
  pin:ClearAllPoints()
  pin.mapID, pin.spotKey = nil, nil
  pools[mapType][#pools[mapType] + 1] = pin
end

local function release(mapType, key)
  local pin = active[mapType][key]
  if not pin then return end
  active[mapType][key] = nil
  if mapType == "world" then
    HBDPins:RemoveWorldMapIcon(MapPins, pin)
  else
    HBDPins:RemoveMinimapIcon(MapPins, pin)
  end
  recycle(mapType, pin)
end

local function releaseAll()
  if not HBDPins then return end
  HBDPins:RemoveAllWorldMapIcons(MapPins)
  HBDPins:RemoveAllMinimapIcons(MapPins)
  for mapType, set in pairs(active) do
    for key, pin in pairs(set) do
      set[key] = nil
      recycle(mapType, pin)
    end
  end
  wipe(worldBuilt)
  minimapZone = nil
end

local function shouldShow(spot, p)
  if not spot or not p.kinds[spot.kind] then return false end
  local gathers = spot.gathers or 0
  if gathers == 0 then
    return spot.imported and p.minGathers <= 1 or false
  end
  return gathers >= p.minGathers
end

local function alphaFor(spot, p, now)
  if not spot.lastSeen then return FADED_ALPHA end
  if now - spot.lastSeen > p.fadeDays * 86400 then return FADED_ALPHA end
  return 1
end

-- Creates, updates or removes one pin of one map type.
local function updatePin(mapType, mapID, spotKey, spot, p, now)
  local key = pinKey(mapID, spotKey)
  if shouldShow(spot, p) and p[mapType] then
    local pin = active[mapType][key]
    if not pin then
      pin = acquire(mapType)
      active[mapType][key] = pin
    end
    pin.mapID, pin.spotKey = mapID, spotKey
    pin:SetSize(p.size, p.size)
    pin.icon:SetTexture(Theme.ICONS and Theme.ICONS[spot.kind])
    local alpha = alphaFor(spot, p, now)
    if mapType == "minimap" then alpha = alpha * (p.minimapAlpha or 0.6) end
    pin:SetAlpha(alpha)
    local ok
    if mapType == "world" then
      ok = HBDPins:AddWorldMapIconMap(MapPins, pin, mapID, spot.x, spot.y, HBD_PINS_WORLDMAP_SHOW_PARENT)
    else
      ok = HBDPins:AddMinimapIconMap(MapPins, pin, mapID, spot.x, spot.y, true, false)
    end
    if ok then pin:Show() else release(mapType, key) end
  else
    release(mapType, key)
  end
end

local function buildZone(mapType, mapID)
  local nl = nodeLog()
  local zone = nl and nl:GetZone(mapID)
  if not zone then return end
  local p, now = cfg(), time()
  for spotKey, spot in pairs(zone) do
    updatePin(mapType, mapID, spotKey, spot, p, now)
  end
end

local function currentZone()
  return C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player") or nil
end

-- Minimap pins exist only for the player's current zone.
local function syncMinimap()
  local id = currentZone()
  if id == minimapZone then return end
  for key, pin in pairs(active.minimap) do
    if pin.mapID == minimapZone then release("minimap", key) end
  end
  minimapZone = id
  if id then buildZone("minimap", id) end
end

-- World map pins exist only for zones the map has shown: the viewed zone and
-- its direct children (HBD shows child pins in their parent).
local function ensureWorldZone(mapID)
  if not mapID or worldBuilt[mapID] then return end
  worldBuilt[mapID] = true
  buildZone("world", mapID)
end

local function syncWorldMap()
  if not WorldMapFrame or not WorldMapFrame.GetMapID then return end
  local mapID = WorldMapFrame:GetMapID()
  if not mapID then return end
  ensureWorldZone(mapID)
  local children = C_Map and C_Map.GetMapChildrenInfo and C_Map.GetMapChildrenInfo(mapID, nil, false)
  for _, child in ipairs(children or {}) do
    ensureWorldZone(child.mapID)
  end
end

function MapPins:Rebuild()
  if not HBDPins or not self:IsEnabled() then return end
  releaseAll()
  syncMinimap()
  syncWorldMap()
end

function MapPins:OnNodeLogChanged(mapID, spotKey)
  if not mapID or not spotKey then
    self:Rebuild()
    return
  end
  local nl = nodeLog()
  local zone = nl and nl:GetZone(mapID)
  local spot = zone and zone[spotKey] or nil
  local p, now = cfg(), time()
  if worldBuilt[mapID] then updatePin("world", mapID, spotKey, spot, p, now) end
  if mapID == minimapZone then updatePin("minimap", mapID, spotKey, spot, p, now) end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local worldHooked
local profileOwner = {} -- unique AceDB callback owner (HB and HB.UI register their own)

-- Map Pins settings live in the profile; a profile switch/copy/reset that
-- keeps the module enabled must redraw with the new settings. (Init.lua's
-- ApplyModuleStates only enables/disables modules.)
local function onProfileChanged()
  if MapPins:IsEnabled() then HB:SafeCall("MapPins", MapPins.Rebuild, MapPins) end
end

function MapPins:OnEnable()
  if not HBDPins then return end
  if not profileOwner.registered then
    profileOwner.registered = true
    HB.db.RegisterCallback(profileOwner, "OnProfileChanged", onProfileChanged)
    HB.db.RegisterCallback(profileOwner, "OnProfileCopied", onProfileChanged)
    HB.db.RegisterCallback(profileOwner, "OnProfileReset", onProfileChanged)
  end
  HB:Listen(self, "HB_NODELOG_CHANGED", self.OnNodeLogChanged)
  local function onZone() HB:SafeCall("MapPins", syncMinimap) end
  self:RegisterEvent("ZONE_CHANGED_NEW_AREA", onZone)
  self:RegisterEvent("ZONE_CHANGED", onZone)
  self:RegisterEvent("PLAYER_ENTERING_WORLD", onZone)
  if not worldHooked and WorldMapFrame and WorldMapFrame.OnMapChanged then
    worldHooked = true
    hooksecurefunc(WorldMapFrame, "OnMapChanged", function()
      if MapPins:IsEnabled() then HB:SafeCall("MapPins", syncWorldMap) end
    end)
  end
  self:Rebuild()
end

function MapPins:OnDisable()
  self:UnregisterAllMessages()
  self:UnregisterAllEvents()
  releaseAll()
end

---------------------------------------------------------------------------
-- Options (registered at load; reads state lazily)
---------------------------------------------------------------------------

local function rebuild() HB:SafeCall("MapPins", MapPins.Rebuild, MapPins) end

local function toggle(order, name, getter, setter)
  return {
    type = "toggle", order = order, name = name,
    get = getter,
    set = function(_, v) setter(v); rebuild() end,
  }
end

local function kindToggle(order, kind, name)
  return toggle(order, name,
    function() return cfg().kinds[kind] end,
    function(v) cfg().kinds[kind] = v and true or false end)
end

HB:AddOptions("mappins", {
  type = "group",
  name = "Map Pins",
  args = {
    world = toggle(10, "Show on world map",
      function() return cfg().world end, function(v) cfg().world = v end),
    minimap = toggle(11, "Show on minimap",
      function() return cfg().minimap end, function(v) cfg().minimap = v end),
    kindsHeader = { type = "header", order = 20, name = "Show these kinds" },
    herb = kindToggle(21, "herb", "Herbs"),
    ore = kindToggle(22, "ore", "Ore"),
    skin = kindToggle(23, "skin", "Skinning"),
    minGathers = {
      type = "range", order = 30, name = "Minimum gathers to show",
      desc = "Spots gathered fewer times are hidden. Imported spots show when this is 1.",
      min = 1, max = 50, step = 1,
      get = function() return cfg().minGathers end,
      set = function(_, v) cfg().minGathers = v; rebuild() end,
    },
    fadeDays = {
      type = "range", order = 31, name = "Fade pins not visited in (days)",
      desc = "Older pins fade to 40% opacity.",
      min = 1, max = 90, step = 1,
      get = function() return cfg().fadeDays end,
      set = function(_, v) cfg().fadeDays = v; rebuild() end,
    },
    minimapAlpha = {
      type = "range", order = 33, name = "Minimap pin opacity",
      desc = "Lower values let the game's own minimap node icons show through Harvestbook's pins.",
      min = 0.1, max = 1, step = 0.05, isPercent = true,
      get = function() return cfg().minimapAlpha or 0.6 end,
      set = function(_, v) cfg().minimapAlpha = v; rebuild() end,
    },
    size = {
      type = "range", order = 32, name = "Pin size",
      min = 8, max = 32, step = 1,
      get = function() return cfg().size end,
      set = function(_, v) cfg().size = v; rebuild() end,
    },
  },
}, 50)
