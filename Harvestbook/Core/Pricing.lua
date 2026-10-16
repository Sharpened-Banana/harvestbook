local ADDON, ns = ...

-- Price resolution + cache (spec §6). Values are integer copper.
-- Cache: global.prices[itemKey] = { value = copper, source = name, time = unix }.
-- Cached prices are reused by Get without expiry; Refresh, RefreshStale
-- (login / session start, entries older than an hour) and SetOverride
-- replace them, so a known price is never re-queried during gathering.
-- Unpriced items are not cached and are re-resolved on each Get.
-- The cache holds listing prices; Get applies the optional auction house cut
-- (profile.pricing.ahCut) on the way out, so toggling it needs no re-query.

local HB = ns.HB
local PriceChain = ns.PriceChain
local ItemKey = ns.SessionMath.ItemKey

local CALLER = "Harvestbook"

local Pricing = {}
HB.Pricing = Pricing

local function auctionatorAPI()
  return Auctionator and Auctionator.API and Auctionator.API.v1
end

-- name -> { available = fn() -> bool, fn = fn(itemID, quality, link) -> copper|nil }
-- Every fn runs inside PriceChain.Resolve's pcall.
local SOURCES = {
  override = {
    available = function() return true end,
    fn = function(itemID, quality)
      return HB.db.global.priceOverrides[ItemKey(itemID, quality)]
    end,
  },
  auctionator = {
    available = function() return auctionatorAPI() ~= nil end,
    fn = function(itemID, quality, link)
      local api = auctionatorAPI()
      if link and api.GetAuctionPriceByItemLink then
        return api.GetAuctionPriceByItemLink(CALLER, link)
      end
      return api.GetAuctionPriceByItemID(CALLER, itemID)
    end,
  },
  tsm = {
    available = function() return TSM_API ~= nil end,
    fn = function(itemID, quality, link)
      local itemString = TSM_API.ToItemString(link or ("i:" .. itemID))
      if not itemString then return nil end
      local str = HB.db.profile.pricing.tsmString
      if type(str) ~= "string" or str == "" then str = "DBMarket" end
      return (TSM_API.GetCustomPriceValue(str, itemString))
    end,
  },
  vendor = {
    available = function() return C_Item ~= nil and C_Item.GetItemInfo ~= nil end,
    fn = function(itemID)
      -- 11th return is sellPrice; nil while the item is not cached yet.
      return (select(11, C_Item.GetItemInfo(itemID)))
    end,
  },
}

Pricing.SOURCE_LABELS = {
  override = "Manual override",
  auctionator = "Auctionator",
  tsm = "TradeSkillMaster",
  vendor = "Vendor price",
  none = "No price",
}

-- Ordered source list for PriceChain, from profile.pricing.order, skipping
-- unknown names, duplicates, and sources whose addon/API is absent.
function Pricing:Sources()
  local list, seen = {}, {}
  for _, name in ipairs(HB.db.profile.pricing.order or {}) do
    local src = SOURCES[name]
    if src and not seen[name] and src.available() then
      seen[name] = true
      list[#list + 1] = { name = name, fn = src.fn }
    end
  end
  return list
end

-- True when a source ranked above `winner` (other than the manual override,
-- whose nil just means "no override") is loaded but gave no price, e.g. TSM
-- or Auctionator still initialising. Such a result is only provisional.
local function provisional(sources, winner)
  for _, src in ipairs(sources) do
    if src.name == winner then return false end
    if src.name ~= "override" then return true end
  end
  return false
end

-- Only real prices are cached; an unpriced result (0, "none") clears any
-- stale entry so the item is re-resolved on the next Get (e.g. once the
-- vendor price is available from the item cache). A provisional price is
-- returned but not cached (and leaves any existing entry alone), so the
-- better source is asked again next time.
local function net(copper, source)
  return PriceChain.AfterCut(copper, source, HB.db.profile.pricing.ahCut)
end

local function resolveAndCache(self, itemID, quality, link)
  local sources = self:Sources()
  local copper, source = PriceChain.Resolve(itemID, quality, link, sources)
  local key = ItemKey(itemID, quality)
  if copper > 0 then
    if not provisional(sources, source) then
      HB.db.global.prices[key] = { value = copper, source = source, time = time() }
    end
  else
    HB.db.global.prices[key] = nil
  end
  return copper, source
end

function Pricing:Get(itemID, quality, link)
  if not itemID then return 0, "none" end
  local cached = HB.db.global.prices[ItemKey(itemID, quality)]
  if cached and type(cached.value) == "number" and cached.value > 0 then
    return net(cached.value, cached.source), cached.source
  end
  local copper, source = resolveAndCache(self, itemID, quality, link)
  return net(copper, source), source
end

-- Cache entry (or nil) for UI: { value, source, time }.
function Pricing:GetCached(itemID, quality)
  return HB.db.global.prices[ItemKey(itemID, quality)]
end

-- itemList: { { itemID = n, quality = n|nil, link = s|nil }, ... }
function Pricing:Refresh(itemList)
  for _, e in ipairs(itemList or {}) do
    local itemID = e.itemID or e[1]
    if itemID then
      resolveAndCache(self, itemID, e.quality or e[2], e.link or e[3])
    end
  end
  HB:SendMessage("HB_PRICES_UPDATED")
end

-- Re-resolves cached prices older than maxAge seconds (default 3600) for the
-- given items; sends HB_PRICES_UPDATED only if a cached value or source
-- changed. Never called from the gather path (spec §6).
function Pricing:RefreshStale(itemList, maxAge)
  maxAge = maxAge or 3600
  local prices, now, changed = HB.db.global.prices, time(), false
  for _, e in ipairs(itemList or {}) do
    local itemID = e.itemID or e[1]
    if itemID then
      local quality = e.quality or e[2]
      local key = ItemKey(itemID, quality)
      local old = prices[key]
      if old and now - (old.time or 0) > maxAge then
        resolveAndCache(self, itemID, quality, e.link or e[3])
        local new = prices[key]
        if not new or new.value ~= old.value or new.source ~= old.source then changed = true end
      end
    end
  end
  if changed then HB:SendMessage("HB_PRICES_UPDATED") end
  return changed
end

-- priceFn(itemID, quality, link) -> copper, source (SessionMath signature).
function Pricing:Fn()
  return function(itemID, quality, link)
    return self:Get(itemID, quality, link)
  end
end

-- copper = nil clears the override. Drops the cached price for that key.
function Pricing:SetOverride(itemID, quality, copper)
  local key = ItemKey(itemID, quality)
  if type(copper) == "number" then
    HB.db.global.priceOverrides[key] = math.floor(copper)
  else
    HB.db.global.priceOverrides[key] = nil
  end
  HB.db.global.prices[key] = nil
  HB:SendMessage("HB_PRICES_UPDATED")
end

-- Drops every cached price (e.g. after the source order changes).
function Pricing:ClearCache()
  wipe(HB.db.global.prices)
  HB:SendMessage("HB_PRICES_UPDATED")
end
