local ADDON, ns = ...

-- NodeLog module (spec §4.2): records what every gathered node gave you,
-- per zone and spot (HB.db.global.nodes[mapID][spotKey], see Logic/NodeGrid),
-- shows the Node Log page and offers a GatherMate2 import.
--
-- Messages sent: HB_NODELOG_CHANGED(mapID, spotKey) after a record or a
-- spot forget; (mapID, nil) after ForgetZone; (nil, nil) after an import.
--
-- GatherMate2 API used by ImportGatherMate (read from GatherMate2 source):
--   _G.GatherMate2                         the addon object
--   GatherMate2.gmdbs[typeName]            node DB per type ("Herb Gathering",
--                                          "Mining"); a metatable'd wrapper whose
--                                          fields __gm2_base_storage and
--                                          __gm2_storage_map[tag] are the raw
--                                          [uiMapID] = { [coord] = nodeID } tables
--   GatherMate2:GetNodesForZone(zone, typeName, true)
--                                          iterator over coord, nodeID (ignoreFilter)
--   GatherMate2:DecodeLoc(coord) -> x, y   0..1; coord = round(x*1e4)*1e6 + round(y*1e4)*100
-- Zones are uiMapIDs (GM2 migrated off MapAreaIDs in 8.0).

local HB = ns.HB
local NodeGrid = ns.NodeGrid
local SessionMath = ns.SessionMath
local Format = ns.Format
local Theme = ns.Theme
local W = ns.Widgets

local NodeLog = HB:NewModule("NodeLog", "AceEvent-3.0")

local DASH = "\226\128\148"
local GM2_TYPES = { { "Herb Gathering", "herb" }, { "Mining", "ore" } }

local curMap        -- mapID shown by the pager
local selectedNode  -- nodeID whose items are shown in the lower list
local pageBody

local function nodes() return HB.db.global.nodes end
local function names() return HB.db.global.nodeNames end
local function money(copper) return Format.Money(copper, HB.db.profile.goldStyle) end

local function nodeName(id)
  return names()[id] or ("Node " .. tostring(id))
end

local function mapName(mapID)
  local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
  return info and info.name or ("Map " .. tostring(mapID))
end

local function itemName(itemID)
  local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
  return name or ("Item " .. tostring(itemID))
end

local function itemIcon(itemID)
  return C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID) or nil
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function NodeLog:GetZone(mapID)
  return mapID and nodes()[mapID] or nil
end

-- mapIDs that have any spot (imported or real), sorted by zone name.
function NodeLog:GetZones()
  local list, label = {}, {}
  for mapID, zone in pairs(nodes()) do
    if next(zone) ~= nil then
      list[#list + 1] = mapID
      label[mapID] = mapName(mapID)
    end
  end
  table.sort(list, function(a, b)
    if label[a] ~= label[b] then return label[a] < label[b] end
    return a < b
  end)
  return list
end

local function dropIfEmpty(mapID)
  local zone = nodes()[mapID]
  if zone and next(zone) == nil then nodes()[mapID] = nil end
end

function NodeLog:ForgetSpot(mapID, spotKey)
  local zone = self:GetZone(mapID)
  if not zone or not zone[spotKey] then return end
  NodeGrid.Forget(zone, spotKey)
  dropIfEmpty(mapID)
  HB:SendMessage("HB_NODELOG_CHANGED", mapID, spotKey)
end

function NodeLog:ForgetZone(mapID)
  if not self:GetZone(mapID) then return end
  nodes()[mapID] = nil
  HB:SendMessage("HB_NODELOG_CHANGED", mapID, nil)
end

function NodeLog:OnGather(gather)
  if type(gather) ~= "table" then return end
  local mapID = gather.mapID
  if not (mapID and gather.x and gather.y) then return end
  local nodeID = gather.objectID or gather.npcID
  if not nodeID then return end
  local zone = nodes()[mapID]
  if not zone then
    zone = {}
    nodes()[mapID] = zone
  end
  local copper = SessionMath.NodeValue(gather, HB.Pricing:Fn())
  local key = NodeGrid.Record(zone, gather, copper)
  if not key then
    dropIfEmpty(mapID)
    return
  end
  if gather.targetName then names()[nodeID] = gather.targetName end
  HB:SendMessage("HB_NODELOG_CHANGED", mapID, key)
end

---------------------------------------------------------------------------
-- GatherMate2 import
---------------------------------------------------------------------------

local function gm2Loaded()
  if C_AddOns and C_AddOns.IsAddOnLoaded then
    return C_AddOns.IsAddOnLoaded("GatherMate2") and true or false
  end
  return false
end

local function gm2Zones(gm, typeName)
  local db = gm.gmdbs and gm.gmdbs[typeName]
  local seen, out = {}, {}
  if not db then return out end
  local function collect(store)
    for mapID in pairs(store or {}) do
      if type(mapID) == "number" and not seen[mapID] then
        seen[mapID] = true
        out[#out + 1] = mapID
      end
    end
  end
  collect(rawget(db, "__gm2_base_storage"))
  for _, store in pairs(rawget(db, "__gm2_storage_map") or {}) do collect(store) end
  return out
end

function NodeLog:ImportGatherMate()
  local gm = _G.GatherMate2
  if not gm or not gm2Loaded() or not gm.GetNodesForZone or not gm.DecodeLoc then
    HB:Msg("GatherMate2 is not loaded.")
    return 0
  end
  local added = 0
  for _, t in ipairs(GM2_TYPES) do
    local typeName, kind = t[1], t[2]
    for _, mapID in ipairs(gm2Zones(gm, typeName)) do
      for coord in gm:GetNodesForZone(mapID, typeName, true) do
        local x, y = gm:DecodeLoc(coord)
        if x and y and (x > 0 or y > 0) then
          local zone = nodes()[mapID]
          if not zone then
            zone = {}
            nodes()[mapID] = zone
          end
          if NodeGrid.ImportPoint(zone, x, y, kind) then added = added + 1 end
          dropIfEmpty(mapID)
        end
      end
    end
  end
  HB:Msg("Imported %d GatherMate2 nodes.", added)
  HB:SendMessage("HB_NODELOG_CHANGED", nil, nil)
  return added
end

---------------------------------------------------------------------------
-- Page
---------------------------------------------------------------------------

local NODE_COLUMNS = {
  { key = "name", title = "Node", width = 190, align = "LEFT" },
  { key = "count", title = "Count", width = 64, align = "RIGHT" },
  { key = "share", title = "Share", width = 64, align = "RIGHT" },
  { key = "avgItems", title = "Avg items", width = 84, align = "RIGHT" },
  { key = "value", title = "Value/node", width = 110, align = "RIGHT" },
}

local ITEM_COLUMNS = {
  { key = "name", title = "Item", width = 250, align = "LEFT" },
  { key = "count", title = "Count", width = 70, align = "RIGHT" },
  { key = "perNode", title = "Per node", width = 84, align = "RIGHT" },
}

local function nodeCell(row, key)
  if key == "name" then
    return nodeName(row.nodeID), Theme.ICONS and Theme.ICONS[row.kind] or nil
  elseif key == "count" then
    return Format.Thousands(row.count)
  elseif key == "share" then
    return string.format("%.1f%%", row.share * 100)
  elseif key == "avgItems" then
    return string.format("%.1f", row.avgItems)
  elseif key == "value" then
    return money(row.valuePerNode)
  end
end

local function itemCell(row, key)
  if key == "name" then
    return itemName(row.itemID), itemIcon(row.itemID)
  elseif key == "count" then
    return Format.Thousands(row.count)
  elseif key == "perNode" then
    return string.format("%.2f", row.perNode)
  end
end

-- Keeps curMap valid; defaults to the player's zone when it has data.
local function resolveCurrent(zones)
  local found
  for _, id in ipairs(zones) do
    if id == curMap then found = true end
  end
  if found then return end
  curMap, selectedNode = nil, nil
  if #zones == 0 then return end
  local here = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  for _, id in ipairs(zones) do
    if id == here then curMap = id end
  end
  curMap = curMap or zones[1]
end

local function refreshPage(body)
  local ui = body.nodelog
  local zones = NodeLog:GetZones()
  resolveCurrent(zones)

  local index
  for i, id in ipairs(zones) do
    if id == curMap then index = i end
  end

  if not index then
    ui.pager:SetText("No zones recorded")
    ui.pager:SetButtonsEnabled(false, false)
    ui.nodes:SetRows({}, nodeCell)
    ui.items:SetRows({}, itemCell)
    ui.footer:SetText("Gather a node to start your log.")
    ui.footer:SetTextColor(Theme:Color("grey"))
    ui.forget:SetEnabled(false)
    return
  end

  ui.pager:SetText(string.format("%s (%d/%d)", mapName(curMap), index, #zones))
  ui.pager:SetButtonsEnabled(index > 1, index < #zones)

  local zone = NodeLog:GetZone(curMap)
  local rows = NodeGrid.Summarize(zone)
  ui.nodes:SetRows(rows, nodeCell)

  local selected
  for _, r in ipairs(rows) do
    if r.nodeID == selectedNode then selected = r end
  end
  local itemRows = {}
  if selected then
    for _, it in ipairs(NodeGrid.ItemsFor(zone, selected.nodeID)) do
      itemRows[#itemRows + 1] = {
        itemID = it.itemID, count = it.count, perNode = it.count / selected.count,
      }
    end
    ui.itemsTitle:SetText(nodeName(selected.nodeID) .. " " .. DASH .. " items")
  else
    selectedNode = nil
    ui.itemsTitle:SetText("Click a node to see its items")
  end
  ui.items:SetRows(itemRows, itemCell)

  local total, copper = 0, 0
  for _, r in ipairs(rows) do
    total = total + r.count
    copper = copper + r.valuePerNode * r.count
  end
  ui.footer:SetText(string.format("This zone: %d nodes of %d kinds, worth %s", total, #rows, money(copper)))
  ui.footer:SetTextColor(1, 1, 1)
  ui.forget:SetEnabled(true)
end

local function step(delta)
  local zones = NodeLog:GetZones()
  for i, id in ipairs(zones) do
    if id == curMap and zones[i + delta] then
      curMap, selectedNode = zones[i + delta], nil
      break
    end
  end
  if pageBody then refreshPage(pageBody) end
end

local function buildPage(body)
  pageBody = body
  local ui = {}
  body.nodelog = ui

  ui.pager = W.Pager(body, function() step(-1) end, function() step(1) end)
  ui.pager:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
  ui.pager:SetWidth(420)

  ui.nodes = W.ColumnList(body, NODE_COLUMNS)
  ui.nodes:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -30)
  ui.nodes:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -30)
  ui.nodes:SetHeight(160)
  ui.nodes.onRowClick = function(row)
    selectedNode = row.nodeID
    refreshPage(body)
  end

  ui.itemsTitle = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontSmall")
  ui.itemsTitle:SetPoint("TOPLEFT", ui.nodes, "BOTTOMLEFT", 4, -10)
  ui.itemsTitle:SetTextColor(Theme:Color("grey"))

  ui.items = W.ColumnList(body, ITEM_COLUMNS)
  ui.items:SetPoint("TOPLEFT", ui.itemsTitle, "BOTTOMLEFT", -4, -4)
  ui.items:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 56)

  ui.footer = body:CreateFontString(nil, "OVERLAY", "HarvestbookFontBody")
  ui.footer:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 32)
  ui.footer:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 32)
  ui.footer:SetJustifyH("LEFT")
  ui.footer:SetWordWrap(false)

  ui.forget = W.RedButton(body, "Forget zone", function()
    if curMap then StaticPopup_Show("HARVESTBOOK_FORGET_ZONE", mapName(curMap), nil, curMap) end
  end)
  ui.forget:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
end

StaticPopupDialogs["HARVESTBOOK_FORGET_ZONE"] = {
  text = "Forget all recorded nodes in %s? This cannot be undone.",
  button1 = YES, button2 = CANCEL,
  OnAccept = function(_, mapID)
    HB:SafeCall("NodeLog", NodeLog.ForgetZone, NodeLog, mapID)
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local PAGE = { id = "nodelog", title = "Node Log", order = 20, build = buildPage, refresh = refreshPage }

local function onChanged() HB.UI:RefreshPage("nodelog") end

function NodeLog:OnEnable()
  HB:Listen(self, "HB_NODE_GATHERED", self.OnGather)
  HB:Listen(self, "HB_NODELOG_CHANGED", onChanged)
  HB:Listen(self, "HB_PRICES_UPDATED", onChanged)
  PAGE.icon = Theme.ICONS and Theme.ICONS.nodelog
  HB.UI:RegisterPage(PAGE)
end

function NodeLog:OnDisable()
  self:UnregisterAllMessages()
  HB.UI:UnregisterPage("nodelog")
end

-- Options group (registered at load; reads state lazily).
HB:AddOptions("nodelog", {
  type = "group",
  name = "Node Log",
  args = {
    importGM2 = {
      type = "execute",
      order = 10,
      name = "Import GatherMate2 nodes",
      desc = "Adds GatherMate2's herb and mining locations as pins with no yield data. Existing data is never overwritten.",
      disabled = function() return not gm2Loaded() end,
      func = function() HB:SafeCall("NodeLog", NodeLog.ImportGatherMate, NodeLog) end,
    },
    gm2Note = {
      type = "description",
      order = 11,
      name = function()
        return gm2Loaded() and "" or "GatherMate2 is not loaded."
      end,
    },
  },
}, 40)
