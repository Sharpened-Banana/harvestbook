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

ns.PriceChain = M
