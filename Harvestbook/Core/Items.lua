local ADDON, ns = ...

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
  return nameFromLink(link) or ("Item " .. tostring(itemID))
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
