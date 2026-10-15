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
-- Listens: HB_NODELOG_CHANGED(mapID, spotKey): (nil, nil) or (mapID, nil)
-- rebuild everything; (mapID, spotKey) updates one spot.

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
local gphCache                               -- { [mapID] = gph } for one tooltip show

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
local function onLeave() GameTooltip:Hide() end

local function onClick(pin, button)
  if button == "RightButton" and IsShiftKeyDown() then
    GameTooltip:Hide()
    local nl = nodeLog()
    if nl then HB:SafeCall("MapPins", nl.ForgetSpot, nl, pin.mapID, pin.spotKey) end
  end
end

local function newPin()
  local pin = CreateFrame("Button", nil, UIParent)
  pin:SetFrameStrata("HIGH")
  pin:RegisterForClicks("RightButtonUp")

  pin.bg = pin:CreateTexture(nil, "BACKGROUND")
  pin.bg:SetAllPoints()
  pin.bg:SetColorTexture(0.03, 0.06, 0.05, 0.95)
  pin.bgMask = pin:CreateMaskTexture()
  pin.bgMask:SetAllPoints()
  pin.bgMask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  pin.bg:AddMaskTexture(pin.bgMask)

  pin.icon = pin:CreateTexture(nil, "ARTWORK")
  pin.icon:SetPoint("TOPLEFT", 1, -1)
  pin.icon:SetPoint("BOTTOMRIGHT", -1, 1)
  pin.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  pin.iconMask = pin:CreateMaskTexture()
  pin.iconMask:SetAllPoints(pin.icon)
  pin.iconMask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  pin.icon:AddMaskTexture(pin.iconMask)

  pin:SetScript("OnEnter", onEnter)
  pin:SetScript("OnLeave", onLeave)
  pin:SetScript("OnClick", onClick)
  return pin
end

local function acquire(mapType)
  local pool = pools[mapType]
  return table.remove(pool) or newPin()
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
  pin:Hide()
  pin:ClearAllPoints()
  pin.mapID, pin.spotKey = nil, nil
  pools[mapType][#pools[mapType] + 1] = pin
end

local function releaseAll()
  HBDPins:RemoveAllWorldMapIcons(MapPins)
  HBDPins:RemoveAllMinimapIcons(MapPins)
  for mapType, set in pairs(active) do
    for key, pin in pairs(set) do
      pin:Hide()
      pin:ClearAllPoints()
      pin.mapID, pin.spotKey = nil, nil
      pools[mapType][#pools[mapType] + 1] = pin
      set[key] = nil
    end
  end
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

-- Creates, updates or removes the pins for one spot, per map type.
local function updateSpot(mapID, spotKey, spot)
  local p = cfg()
  local key = pinKey(mapID, spotKey)
  local show = shouldShow(spot, p)
  local now = time()
  for _, mapType in ipairs({ "world", "minimap" }) do
    if show and p[mapType] then
      local pin = active[mapType][key]
      if not pin then
        pin = acquire(mapType)
        active[mapType][key] = pin
      end
      pin.mapID, pin.spotKey = mapID, spotKey
      pin:SetSize(p.size, p.size)
      pin.icon:SetTexture(Theme.ICONS and Theme.ICONS[spot.kind])
      pin:SetAlpha(alphaFor(spot, p, now))
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
end

function MapPins:Rebuild()
  if not self:IsEnabled() then return end
  releaseAll()
  local nl = nodeLog()
  if not nl then return end
  for _, mapID in ipairs(nl:GetZones()) do
    for spotKey, spot in pairs(nl:GetZone(mapID)) do
      updateSpot(mapID, spotKey, spot)
    end
  end
end

function MapPins:OnNodeLogChanged(mapID, spotKey)
  if not mapID or not spotKey then
    self:Rebuild()
    return
  end
  local nl = nodeLog()
  local zone = nl and nl:GetZone(mapID)
  updateSpot(mapID, spotKey, zone and zone[spotKey] or nil)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function MapPins:OnEnable()
  if not HBDPins then return end
  HB:Listen(self, "HB_NODELOG_CHANGED", self.OnNodeLogChanged)
  self:Rebuild()
end

function MapPins:OnDisable()
  self:UnregisterAllMessages()
  if not HBDPins then return end
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
    size = {
      type = "range", order = 32, name = "Pin size",
      min = 8, max = 32, step = 1,
      get = function() return cfg().size end,
      set = function(_, v) cfg().size = v; rebuild() end,
    },
  },
}, 50)
