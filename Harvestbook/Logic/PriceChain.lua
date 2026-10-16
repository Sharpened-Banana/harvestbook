local ADDON, ns = ...

local M = {}

-- sources: ordered array of { name = string, fn = function(itemID, quality, link) -> copper|nil }
-- Returns copper (integer, floored), sourceName. Nothing usable -> 0, "none".
function M.Resolve(itemID, quality, link, sources)
  for i = 1, #(sources or {}) do
    local src = sources[i]
    local ok, v = pcall(src.fn, itemID, quality, link)
    if ok and type(v) == "number" and v == v and v < math.huge then
      v = math.floor(v)
      if v > 0 then return v, src.name end
    end
  end
  return 0, "none"
end

-- Auction prices are listing prices; the auction house keeps a 5% cut of a sale.
M.AH_CUT = 0.05
M.AH_SOURCES = { auctionator = true, tsm = true }

-- copper after the auction house cut when `cut` is on and the price came from
-- an auction source (vendor prices and manual overrides are left as they are).
function M.AfterCut(copper, source, cut)
  if not cut or not M.AH_SOURCES[source] or type(copper) ~= "number" then return copper end
  return math.floor(copper * (1 - M.AH_CUT))
end

ns.PriceChain = M
