local ADDON, ns = ...

local M = {}
ns.SessionMath = M

local MIN_GPH_SECONDS = 60

function M.ItemKey(itemID, quality)
  return itemID .. ":" .. (quality or 0)
end

function M.New(now)
  return {
    id = now,
    state = "running",
    started = now,
    lastResume = now,
    activeSeconds = 0,
    zones = {},
    zoneSeconds = {},
    zoneCopper = {},
    nodes = { herb = 0, ore = 0, skin = 0 },
    items = {},
    prices = {},
    note = "",
    currentMap = nil,
    zoneSince = nil,
  }
end

-- Accrue the open zone segment up to `now` into zoneSeconds and close it.
local function closeSegment(s, now)
  if s.currentMap and s.zoneSince then
    local d = now - s.zoneSince
    if d > 0 then
      s.zoneSeconds[s.currentMap] = (s.zoneSeconds[s.currentMap] or 0) + d
    end
  end
  s.zoneSince = nil
end

local function foldRunning(s, now)
  if s.state == "running" then
    local d = now - s.lastResume
    if d > 0 then s.activeSeconds = s.activeSeconds + d end
    s.lastResume = now
  end
end

function M.Pause(s, now)
  if s.state ~= "running" then return end
  foldRunning(s, now)
  closeSegment(s, now)
  s.state = "paused"
end

function M.Resume(s, now)
  if s.state ~= "paused" then return end
  s.state = "running"
  s.lastResume = now
  s.zoneSince = now
end

function M.Checkpoint(s, now)
  if s.state ~= "running" then return end
  foldRunning(s, now)
  closeSegment(s, now)
  s.zoneSince = now
end

function M.Restore(s, now)
  if s.state == "running" then
    s.lastResume = now
    s.zoneSince = now
  end
end

function M.ActiveSeconds(s, now)
  local a = s.activeSeconds
  if s.state == "running" then
    local d = now - s.lastResume
    if d > 0 then a = a + d end
  end
  return a
end

function M.NodeValue(gather, priceFn)
  local total = 0
  for _, it in ipairs(gather.items or {}) do
    local p = priceFn(it.itemID, it.quality, it.link) or 0
    total = total + p * (it.count or 0)
  end
  return total
end

function M.AddGather(s, gather, now, priceFn)
  if s.state ~= "running" then return false end
  local mapID = gather.mapID
  if mapID and mapID ~= s.currentMap then
    closeSegment(s, now)
    s.currentMap = mapID
    s.zoneSince = now
  end
  for _, it in ipairs(gather.items or {}) do
    local key = M.ItemKey(it.itemID, it.quality)
    local e = s.items[key]
    if not e then
      e = { itemID = it.itemID, quality = it.quality, count = 0 }
      s.items[key] = e
    end
    e.count = e.count + (it.count or 0)
    if it.link then e.link = it.link end
  end
  if gather.kind then
    s.nodes[gather.kind] = (s.nodes[gather.kind] or 0) + 1
  end
  if mapID then
    s.zones[mapID] = (s.zones[mapID] or 0) + 1
    s.zoneCopper[mapID] = (s.zoneCopper[mapID] or 0) + M.NodeValue(gather, priceFn)
  end
  return true
end

function M.Stop(s, now, priceFn)
  if s.state == "stopped" then return end
  if s.state == "running" then
    foldRunning(s, now)
    closeSegment(s, now)
  end
  s.state = "stopped"
  for key, e in pairs(s.items) do
    local copper, source = priceFn(e.itemID, e.quality, e.link)
    s.prices[key] = { copper = copper or 0, source = source or "none" }
  end
end

local function priceOf(s, key, e, priceFn)
  if s.state == "stopped" then
    local p = s.prices[key]
    if p then return p.copper or 0, p.source end
    return 0, "none"
  end
  local copper, source = priceFn(e.itemID, e.quality, e.link)
  return copper or 0, source or "none"
end

function M.Value(s, priceFn)
  local total = 0
  for key, e in pairs(s.items) do
    local unit = priceOf(s, key, e, priceFn)
    total = total + unit * e.count
  end
  return total
end

function M.GoldPerHour(s, now, priceFn)
  local active = M.ActiveSeconds(s, now)
  if active < MIN_GPH_SECONDS then return nil end
  return M.Value(s, priceFn) / active * 3600
end

function M.Rows(s, now, priceFn, sortKey, descending)
  sortKey = sortKey or "value"
  if descending == nil then descending = true end
  local active = M.ActiveSeconds(s, now)
  local rows = {}
  for key, e in pairs(s.items) do
    local unit, source = priceOf(s, key, e, priceFn)
    rows[#rows + 1] = {
      itemKey = key,
      itemID = e.itemID,
      quality = e.quality,
      link = e.link,
      count = e.count,
      perHour = active >= MIN_GPH_SECONDS and (e.count / active * 3600) or nil,
      unit = unit,
      value = unit * e.count,
      source = source,
    }
  end
  local field = sortKey == "name" and "itemID" or sortKey
  table.sort(rows, function(a, b)
    local av, bv = a[field] or 0, b[field] or 0
    if av ~= bv then
      if descending then return av > bv end
      return av < bv
    end
    return a.itemKey < b.itemKey
  end)
  return rows
end

function M.Summary(s, now, priceFn)
  local materials, kinds = 0, 0
  for _, e in pairs(s.items) do
    materials = materials + e.count
    kinds = kinds + 1
  end
  local nodes = 0
  for _, n in pairs(s.nodes) do nodes = nodes + n end
  return {
    materials = materials,
    kinds = kinds,
    copper = M.Value(s, priceFn),
    gph = M.GoldPerHour(s, now, priceFn),
    nodes = nodes,
  }
end
