local ADDON, ns = ...

-- The single gather observer (spec §2.4). Broadcasts HB_NODE_GATHERED:
-- { time, kind, objectID, npcID, targetName, mapID, x, y,
--   items = { { itemID, count, quality, link }, ... } }
--
-- State machine (one pending gather at a time):
--   UNIT_SPELLCAST_SENT / _SUCCEEDED (player, gathering spell) -> pending
--   LOOT_READY within LOOT_WAIT s of the cast -> snapshot loot + position (once)
--   LOOT_CLOSED -> fire, clear
--   UNIT_SPELLCAST_FAILED / _INTERRUPTED of the pending cast -> clear
--   LOOT_READY whose sources don't fit the kind (Creature for herb/ore,
--     GameObject for skin) -> clear (it is other loot, not this gather)
--   no LOOT_READY within LOOT_WAIT s -> chat fallback: CHAT_MSG_LOOT self-loot
--     lines are aggregated and fired once CHAT_WAIT s later (objectID/npcID nil).
--     Lines are buffered from the cast onward, because with instant auto-loot
--     they arrive before the LOOT_WAIT timeout expires.

local HB = ns.HB
local GatherParse = ns.GatherParse

local LOOT_WAIT = 3
local CHAT_WAIT = 2

local Gather = {}
HB.Gather = Gather
LibStub("AceEvent-3.0"):Embed(Gather)
LibStub("AceTimer-3.0"):Embed(Gather)

local function secret(v) return issecretvalue and issecretvalue(v) end

local lastFiredCastGUID -- castGUID of the last snapshot fired on LOOT_CLOSED
local pending        -- { kind, time, targetName, castGUID, snapshot, items, objectID, npcID, mapID, x, y, chat }
local lootTimer, chatTimer
local matcher

local function debugOn()
  return HB.db and HB.db.profile.debug
end

local function getMatcher()
  if not matcher then
    matcher = GatherParse.NewSpellMatcher(GatherParse.KNOWN_SPELLS, C_Spell.GetSpellName)
  end
  return matcher
end

local function cancelTimers()
  if lootTimer then Gather:CancelTimer(lootTimer); lootTimer = nil end
  if chatTimer then Gather:CancelTimer(chatTimer); chatTimer = nil end
end

-- AceTimer callbacks are not protected; route them through SafeCall.
local function schedule(fn, delay)
  return Gather:ScheduleTimer(function() HB:SafeCall("Gather", fn) end, delay)
end

local function clearPending()
  cancelTimers()
  pending = nil
end

-- Returns mapID, x, y or nil (instances / no map position).
local function playerPosition()
  local mapID = C_Map.GetBestMapForUnit("player")
  if not mapID or secret(mapID) then return nil end
  local pos = C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then return nil end
  local x, y = pos:GetXY()
  if not x or not y or secret(x) or secret(y) then return nil end
  return mapID, x, y
end

local function itemIDFromLink(link)
  return tonumber(string.match(link, "item:(%d+)"))
end

-- 12.1+: GetItemReagentQualityInfo (Midnight's Silver / Gold tiers); older
-- clients: GetItemReagentQualityByItemInfo.
local function reagentQuality(link)
  local api = C_TradeSkillUI
  if not api then return nil end
  if api.GetItemReagentQualityInfo then
    local ok, info = pcall(api.GetItemReagentQualityInfo, link)
    if ok and type(info) == "table" and type(info.quality) == "number" and not secret(info.quality) then
      return info.quality
    end
  end
  if api.GetItemReagentQualityByItemInfo then
    local ok, q = pcall(api.GetItemReagentQualityByItemInfo, link)
    if ok and type(q) == "number" and not secret(q) then return q end
  end
  return nil
end

-- Adds count of link to items (merging same itemID + quality).
local function addItem(items, link, count)
  local itemID = itemIDFromLink(link)
  if not itemID then return end
  local quality = reagentQuality(link)
  for _, it in ipairs(items) do
    if it.itemID == itemID and it.quality == quality then
      it.count = it.count + count
      return
    end
  end
  items[#items + 1] = { itemID = itemID, count = count, quality = quality, link = link }
end

local function describe(p)
  local parts = {}
  for _, it in ipairs(p.items) do
    local name = it.link and it.link:match("%[(.-)%]") or tostring(it.itemID)
    local q = it.quality and (" q" .. it.quality) or ""
    parts[#parts + 1] = string.format("%s%s x%d", name, q, it.count)
  end
  local src
  if p.objectID then src = "obj=" .. p.objectID
  elseif p.npcID then src = "npc=" .. p.npcID
  else src = "obj=nil" end
  return string.format("HB_NODE_GATHERED %s %s map=%d %.3f,%.3f items=%d (%s)%s",
    p.kind, src, p.mapID, p.x, p.y, #p.items, table.concat(parts, ", "),
    p.targetName and (" target=" .. p.targetName) or "")
end

local function fire(p, via)
  if #p.items == 0 then
    if debugOn() then HB:Msg("gather (%s) dropped: no items", p.kind) end
    return
  end
  if not p.mapID then
    if debugOn() then HB:Msg("gather (%s) dropped: no map position (instance?)", p.kind) end
    return
  end
  local payload = {
    time = time(),
    kind = p.kind,
    objectID = p.objectID,
    npcID = p.npcID,
    targetName = p.targetName,
    mapID = p.mapID, x = p.x, y = p.y,
    items = p.items,
  }
  if debugOn() then HB:Msg("%s%s", describe(payload), via and (" via " .. via) or "") end
  HB:SendMessage("HB_NODE_GATHERED", payload)
end

-- Chat fallback ---------------------------------------------------------------

-- { { pattern, order }, ... } built from the localized loot format globals.
-- Multiple-count forms come first: the single forms' "(.+)" would also match them.
local chatPatterns
local function getChatPatterns()
  if chatPatterns then return chatPatterns end
  chatPatterns = {}
  local fmts = { LOOT_ITEM_SELF_MULTIPLE, LOOT_ITEM_PUSHED_SELF_MULTIPLE, LOOT_ITEM_SELF, LOOT_ITEM_PUSHED_SELF }
  for i = 1, 4 do
    local fmt = fmts[i]
    if type(fmt) == "string" and fmt ~= "" then
      local pattern, order = GatherParse.PatternFromFormat(fmt)
      chatPatterns[#chatPatterns + 1] = { pattern = pattern, order = order }
    end
  end
  return chatPatterns
end

-- Maps captures back to format arguments: arg 1 = item link, arg 2 = count
-- (absent for the single forms -> 1). Returns link, count or nil.
local function parseLootLine(text, patterns)
  for _, p in ipairs(patterns) do
    local caps = { string.match(text, p.pattern) }
    if caps[1] then
      local args = {}
      for i, argIndex in ipairs(p.order) do args[argIndex] = caps[i] end
      local link = args[1]
      if link and string.match(link, "item:%d+") then
        return link, tonumber(args[2]) or 1
      end
    end
  end
  return nil
end

-- Fires a pending gather from its buffered chat lines (no loot source).
local function fireFromChat(p)
  p.items = p.chat or {}
  p.objectID, p.npcID = nil, nil
  fire(p, "chat")
end

local function onChatWindowEnd()
  chatTimer = nil
  local p = pending
  if not p or p.snapshot then return end
  clearPending()
  fireFromChat(p)
end

local function onLootTimeout()
  lootTimer = nil
  if not pending or pending.snapshot then return end
  chatTimer = schedule(onChatWindowEnd, CHAT_WAIT)
end

-- Ends the current pending gather early (a new cast started): a snapshot
-- that never saw LOOT_CLOSED fires as-is; buffered chat loot fires as a
-- chat gather; a cast with nothing captured is discarded.
local function flushPending()
  local p = pending
  clearPending()
  if not p then return end
  if p.snapshot then
    fire(p)
  elseif p.chat and #p.chat > 0 then
    fireFromChat(p)
  end
end

-- Event handlers --------------------------------------------------------------

-- isSent: UNIT_SPELLCAST_SENT starts a new gather; UNIT_SPELLCAST_SUCCEEDED
-- confirms the pending one (refreshing its loot window) or starts one if the
-- SENT was missed.
local function startPending(kind, targetName, castGUID, isSent)
  local now = GetTime()
  local p = pending
  -- A late SUCCEEDED for a cast whose loot was already snapshotted (or
  -- already fired) must not flush or re-open it.
  if not isSent and castGUID then
    if p and p.snapshot and p.castGUID == castGUID then return end
    if not p and castGUID == lastFiredCastGUID then return end
  end
  if not isSent and p and p.kind == kind and not p.snapshot
      and (not p.castGUID or not castGUID or p.castGUID == castGUID) then
    -- Restart the loot window from the completed cast (also leaves a chat
    -- window that a long cast time may have opened).
    if chatTimer then Gather:CancelTimer(chatTimer); chatTimer = nil end
    p.time = now
    p.targetName = p.targetName or targetName
    p.castGUID = p.castGUID or castGUID
  else
    flushPending()
    p = { kind = kind, time = now, targetName = targetName, castGUID = castGUID, chat = {} }
    -- Cast position; LOOT_READY re-captures it. Used by the chat fallback.
    p.mapID, p.x, p.y = playerPosition()
    pending = p
  end
  if lootTimer then Gather:CancelTimer(lootTimer) end
  lootTimer = schedule(onLootTimeout, LOOT_WAIT)
end

local function onCast(unit, spellID, target, castGUID, isSent)
  if secret(unit) or unit ~= "player" then return end
  if secret(spellID) or type(spellID) ~= "number" then return end
  local name = C_Spell.GetSpellName(spellID)
  if secret(name) then name = nil end
  local kind = getMatcher()(spellID, name)
  if not kind then return end
  local targetName
  if target ~= nil and not secret(target) and type(target) == "string" and target ~= "" then
    targetName = target
  end
  if secret(castGUID) or type(castGUID) ~= "string" or castGUID == "" then castGUID = nil end
  startPending(kind, targetName, castGUID, isSent)
end

function Gather:UNIT_SPELLCAST_SENT(event, unit, target, castGUID, spellID)
  onCast(unit, spellID, target, castGUID, true)
end

function Gather:UNIT_SPELLCAST_SUCCEEDED(event, unit, castGUID, spellID)
  onCast(unit, spellID, nil, castGUID, false)
end

-- A failed/interrupted gathering cast ends the pending gather, so loot that
-- follows (e.g. a mob) is not counted. Matched by castGUID when known; a
-- FAILED for a different cast (spam-click while casting) is ignored.
local function onCastEnded(unit, castGUID)
  local p = pending
  if not p or p.snapshot then return end
  if secret(unit) or unit ~= "player" then return end
  if p.castGUID then
    if secret(castGUID) or castGUID ~= p.castGUID then return end
  end
  if debugOn() then HB:Msg("gather (%s) cancelled: cast failed or interrupted", p.kind) end
  clearPending()
end

function Gather:UNIT_SPELLCAST_FAILED(event, unit, castGUID, spellID)
  onCastEnded(unit, castGUID)
end

function Gather:UNIT_SPELLCAST_INTERRUPTED(event, unit, castGUID, spellID)
  onCastEnded(unit, castGUID)
end

local function isItemSlot(slot)
  if GetLootSlotType and Enum and Enum.LootSlotType then
    local t = GetLootSlotType(slot)
    if secret(t) then return false end
    if t ~= nil and t ~= Enum.LootSlotType.Item then return false end
  end
  local _, _, quantity, currencyID, _, _, _, _, _, isCoin = GetLootSlotInfo(slot)
  if secret(currencyID) or secret(isCoin) or secret(quantity) then return false end
  if isCoin or currencyID then return false end
  return true, quantity
end

local function lootSource(slot)
  local sources = { GetLootSourceInfo(slot) }
  for i = 1, #sources, 2 do
    local guid = sources[i]
    if guid ~= nil and not secret(guid) then
      local unitType, id = GatherParse.ParseGUID(guid)
      if unitType then return unitType, id end
    end
  end
  return nil
end

function Gather:LOOT_READY(event)
  local p = pending
  if not p or p.snapshot or chatTimer then return end
  if GetTime() - p.time > LOOT_WAIT then return end

  local n = GetNumLootItems()
  if secret(n) then n = 0 end

  -- Source-type cross-check: herb/ore come from GameObjects, skins from Creatures.
  local wrongType = (p.kind == "skin") and "GameObject" or "Creature"
  for slot = 1, n or 0 do
    if lootSource(slot) == wrongType then
      if debugOn() then HB:Msg("gather (%s) cancelled: loot is from a %s", p.kind, wrongType) end
      clearPending()
      return
    end
  end

  p.snapshot = true
  if lootTimer then self:CancelTimer(lootTimer); lootTimer = nil end
  p.chat = nil

  local items = {}
  for slot = 1, n or 0 do
    local ok, quantity = isItemSlot(slot)
    local link = ok and GetLootSlotLink(slot)
    if link and not secret(link) then
      local count = (type(quantity) == "number" and quantity > 0) and quantity or 1
      addItem(items, link, count)
      if not p.objectID and not p.npcID then
        local unitType, id = lootSource(slot)
        if unitType == "GameObject" then p.objectID = id
        elseif unitType == "Creature" then p.npcID = id end
      end
    end
  end
  p.items = items
  p.mapID, p.x, p.y = playerPosition()
end

function Gather:LOOT_CLOSED(event)
  local p = pending
  if not p or not p.snapshot then return end
  clearPending()
  lastFiredCastGUID = p.castGUID
  fire(p)
end

function Gather:CHAT_MSG_LOOT(event, text)
  local p = pending
  if not p or p.snapshot or not p.chat then return end
  if secret(text) or type(text) ~= "string" then return end
  local link, count = parseLootLine(text, getChatPatterns())
  if link then addItem(p.chat, link, count) end
end

-- Registration: handlers run protected so a failure never escapes.
local EVENTS = {
  "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_SUCCEEDED",
  "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED",
  "LOOT_READY", "LOOT_CLOSED", "CHAT_MSG_LOOT",
}

for _, event in ipairs(EVENTS) do
  Gather:RegisterEvent(event, function(...)
    if not HB.db then return end
    HB:SafeCall("Gather", Gather[event], Gather, ...)
  end)
end
