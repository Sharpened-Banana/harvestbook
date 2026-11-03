local ADDON, ns = ...
local L = ns.L

-- Item names for every page. A name the client has not loaded yet is requested
-- once; when it arrives all pages and the companion redraw.

local HB = ns.HB

local REFRESH_DELAY = 0.25

local requested = {} -- [itemID] = true while a load is outstanding
local refreshQueued = false

local function refreshAll()
  refreshQueued = false
  local UI = HB.UI
  if not UI then return end
  if UI.RefreshAllPages then UI:RefreshAllPages() end
  if UI.RefreshCompanion then UI:RefreshCompanion() end
end

-- Reagent links embed the quality atlas inside the brackets.
local function nameFromLink(link)
  local name = type(link) == "string" and link:match("%[(.-)%]")
  if not name then return nil end
  return (name:gsub("|A.-|a", ""):gsub("%s+$", ""))
end

function HB:ItemName(itemID, link)
  local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
  if name then return name end
  if itemID and not requested[itemID] and C_Item and C_Item.RequestLoadItemDataByID then
    requested[itemID] = true
    pcall(C_Item.RequestLoadItemDataByID, itemID)
  end
  return nameFromLink(link) or L["Item %s"]:format(tostring(itemID))
end

-- Quality badges come from the game (12.1+ GetItemReagentQualityInfo), so
-- Midnight's Silver / Gold tiers show their own icons. Cached per item key;
-- older clients fall back to the Dragonflight tier atlas.
local qualityIcons = {} -- [itemKey] = { small = atlas|false, chat = atlas|false }

-- row = { itemID, quality, link }.
function HB:ItemQualityInfo(row)
  local key = ns.SessionMath.ItemKey(row.itemID, row.quality)
  local c = qualityIcons[key]
  if c then return c end
  c = { small = false, chat = false }
  local api = C_TradeSkillUI
  if api and api.GetItemReagentQualityInfo then
    local ok, info = pcall(api.GetItemReagentQualityInfo, row.link or row.itemID)
    if ok and type(info) == "table" then
      c.small = type(info.iconSmall) == "string" and info.iconSmall or false
      c.chat = type(info.iconChat) == "string" and info.iconChat or c.small
    end
  elseif type(row.quality) == "number" then
    c.small = "Professions-Icon-Quality-Tier" .. row.quality .. "-Small"
    c.chat = c.small
  end
  -- A tiered item whose info isn't loaded yet is asked again next refresh.
  if c.small or type(row.quality) ~= "number" then qualityIcons[key] = c end
  return c
end

-- Inline quality badge for font strings ("" for items without a quality).
function HB:ItemQualityMarkup(row, size)
  local atlas = self:ItemQualityInfo(row).chat
  if not atlas then return "" end
  return string.format(" |A:%s:%d:%d|a", atlas, size, size)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
frame:SetScript("OnEvent", function(_, _, itemID)
  if not requested[itemID] then return end
  requested[itemID] = nil
  if refreshQueued then return end
  refreshQueued = true
  C_Timer.After(REFRESH_DELAY, function() HB:SafeCall("Items", refreshAll) end)
end)
