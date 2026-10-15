# Harvestbook v1 — Design Spec

**Date:** 2026-10-15
**Target:** World of Warcraft Retail, Midnight 12.1.x only
**Professions tracked:** Herbalism, Mining, Skinning (fishing is out of scope — Angler's TackleBox covers it; the two must coexist)

## 1. Intent

An all-in-one gathering addon whose main window looks and feels like Angler's TackleBox (`/tb menu`). Every feature is a module that can be enabled/disabled from Settings without `/reload`. v1 ships the core plus four feature groups: Sessions & gold/hr (with a materials list), Node Log & map pins, Best Spot & Records, Goals & Alarms.

**Success criteria**
- Gathering a node while a session runs updates the materials list, gold, and gold/hr within one frame of the loot window closing.
- Each module can be toggled off and on at runtime; off removes its sidebar page, companion tab, pins, and event handlers; data is retained.
- Session survives `/reload`, disconnect, and client crash (state saved per gather).
- Works with no auction addon installed (vendor price fallback).
- The main box is visually recognizable as TackleBox-style (see §5.1).

**Out of scope for v1** (later modules, each with their own spec): Shopping List, Routes, HUD, one-key gathering mode, gear/stat-aware session comparison, CSV/JSON export, price-trend charts, fishing.

## 2. Architecture

### 2.1 Libraries (embedded under `libs/`)
LibStub, CallbackHandler-1.0, AceAddon-3.0, AceDB-3.0, AceDBOptions-3.0, AceEvent-3.0, AceConsole-3.0, AceConfig-3.0 (+Registry, Dialog, Cmd), AceGUI-3.0 (only as AceConfigDialog's dependency), LibDataBroker-1.1, LibDBIcon-1.0, HereBeDragons-2.0 (+ HereBeDragons-Pins-2.0).

The main box and companion window are custom frames; AceGUI is not used for them.

### 2.2 File layout
```
Harvestbook/
  Harvestbook.toc
  libs/                     embedded libraries + embeds.xml
  Core/
    Init.lua                AceAddon object `HB`, module registry, slash commands
    DB.lua                  AceDB defaults, schemaVersion, migrations, profiles
    Gather.lua              gather detection → HB_NODE_GATHERED
    Pricing.lua             price resolution + cache
    Options.lua             AceConfig root table; modules inject sub-tables
  Logic/                    pure Lua, no WoW API calls (unit-tested)
    SessionMath.lua
    NodeGrid.lua
    Rankings.lua
    PriceChain.lua
    GoalEval.lua
    AlarmEval.lua
  UI/
    Theme.lua               colors, fonts, textures, backdrops
    Widgets.lua             SidebarButton, RedButton, ColumnList, CoinText, Pager, ProgressBar, Dropdown
    Box.lua                 main window + page registry
    Companion.lua           compact session window with tabs
  Modules/
    Session.lua
    NodeLog.lua
    MapPins.lua             depends on NodeLog
    BestSpot.lua            depends on NodeLog + Records
    Records.lua             depends on Session
    Goals.lua               depends on Session
    Alarms.lua              depends on Session
  tests/                    busted specs + WoW API stubs
```

### 2.3 Data flow
`Core/Gather.lua` is the only code that observes gathering. On a completed gather it fires an internal AceEvent message:

```lua
HB:SendMessage("HB_NODE_GATHERED", {
  time = <unix seconds>,
  kind = "herb" | "ore" | "skin",
  objectID = <number or nil>,     -- GameObject ID from loot source GUID; nil for skinning (creature) or if unknown
  npcID = <number or nil>,        -- creature ID for skinning
  mapID = <uiMapID>, x = <0..1>, y = <0..1>,
  items = { { itemID = n, count = n, quality = <reagent rank or nil> }, ... },
})
```
Other core messages: `HB_SESSION_CHANGED` (state: running/paused/stopped), `HB_PRICES_UPDATED`, `HB_MODULE_TOGGLED(name, enabled)`.

Modules communicate only via these messages and core services (`HB.DB`, `HB.Pricing`, `HB.UI`). A module never calls another module's functions, except reading another module's public query API listed in §4 (e.g. BestSpot reads `NodeLog:GetZone(mapID)`).

### 2.4 Gather detection (Core/Gather.lua)
1. `UNIT_SPELLCAST_SENT` / `UNIT_SPELLCAST_SUCCEEDED` for `player` with a gathering spell records `pendingKind` and timestamp. A spell counts as gathering if its ID is in the known-ID table **or** its name equals the localized name of a known ID (catches new expansion variants). All event args are checked with `issecretvalue()` first; secret args are ignored.
2. On `LOOT_READY`, if a gather is pending (within 3 s), iterate loot slots: `GetLootSlotLink`, `GetLootSlotInfo` for count, `GetLootSourceInfo(slot)` for the source GUID. Parse objectID/npcID from the GUID.
3. Capture position via `C_Map.GetBestMapForUnit("player")` + `C_Map.GetPlayerMapPosition`.
4. Fire `HB_NODE_GATHERED` on `LOOT_CLOSED` (so auto-loot and manual loot both work).
5. If the loot source can't be determined, still fire with `objectID = nil`; the Session counts it, NodeLog skips it.
5a. If no `LOOT_READY` arrives within 3 s of a gather cast (instant auto-loot edge case), parse `CHAT_MSG_LOOT` self-loot lines for the next 2 s and fire with `objectID = nil`.
6. Debug: `/hb debug` toggles chat printing of each event payload.

Exact 12.x API names are confirmed in §8 (API verification notes).

### 2.5 Module toggling
Each feature module is an AceAddon module (`HB:NewModule(name, "AceEvent-3.0")`) with `profile.modules[name].enabled`. Toggling calls `Enable/Disable`; `OnDisable` unregisters events, calls `HB.UI:UnregisterPage(id)`, removes companion tabs and pins. Dependents auto-disable (greyed out in Settings with "Requires Node Log"). Data in the DB is never deleted by disabling.

### 2.6 Error isolation
Message handlers are wrapped with `xpcall`; an error in one module's handler is reported once per session via chat (`Harvestbook: <module> error — see /hb debug`) and does not stop other handlers or gather detection.

## 3. Data model

### 3.1 Saved variables
- `HarvestbookDB` (account): AceDB with `profile` (all settings) and `global`:
  - `global.schemaVersion = 1`
  - `global.nodes[mapID][spotKey]` — see 3.2
  - `global.sessions[]` — finished sessions (see 3.3), newest last, capped at 500 (oldest pruned)
  - `global.records` — see §4.4
  - `global.prices[itemID] = { value, source, time }`, `global.priceOverrides[itemID] = copper`
  - `global.lifetime[itemID] = count`, keyed additionally by character in `global.lifetimeByChar[charKey][itemID]`
  - `global.goals.attempts[itemID] = { attempts, found, firstSeen }`
- `HarvestbookCharDB` (character): `current` — the in-progress session, written after every gather and every state change.

### 3.2 Node log
```lua
spotKey = format("%d:%d", floor(x * 50), floor(y * 50))   -- 2% grid of the zone map
nodes[mapID][spotKey] = {
  x = <avg x>, y = <avg y>,           -- running mean of gather positions in the cell
  kind = "herb" | "ore" | "skin",
  nodeIDs = { [objectID] = times },   -- skinning uses npcID
  items = { [itemID] = totalCount },
  gathers = n,
  copper = <total value at gather-time prices>,
  firstSeen = t, lastSeen = t,
}
```
Grid math lives in `Logic/NodeGrid.lua`. If a cell contains gathers of two kinds, the cell key is suffixed with kind (`"12:30:ore"`).

### 3.3 Session
```lua
session = {
  id = <start time>, state = "running" | "paused" | "stopped",
  started = t, activeSeconds = n, lastResume = t,
  zones = { [mapID] = gathers },
  zoneSeconds = { [mapID] = activeSeconds },             -- accrued on zone change / pause / stop
  zoneCopper = { [mapID] = copper },                     -- value gathered in each zone
  nodes = { herb = n, ore = n, skin = n },
  items = { [itemKey] = { itemID, quality, count } },   -- itemKey = itemID .. ":" .. (quality or 0)
  prices = { [itemKey] = { copper, source } },          -- frozen on stop
  note = "",
}
```
Active time only accrues while running. Gold/hr = value / activeSeconds × 3600; shown as `—` until 60 active seconds.

### 3.4 Migrations
`DB.lua` holds `migrations[n] = function(db) ... end`; on `PLAYER_LOGIN`, runs every migration with `n > schemaVersion` in order, then sets `schemaVersion`.

## 4. Modules

### 4.1 Session (Modules/Session.lua)
- Controls: Start / Pause / Resume / Stop via Session page, companion, `/hb start|pause|resume|stop`.
- Options: auto-start on first gather (default on); auto-pause on entering instance, mailbox open, auction house open, AFK (each a toggle, default on); auto-resume when the condition ends (default on).
- **Materials list**: one row per itemKey — icon, name, reagent quality badge (Midnight: 2 tiers, Silver/Gold), count, per hour, unit price, total value. Sortable by any column (default: value desc). Hovering the row shows the item tooltip; the price cell tooltip shows price source and age.
- Totals strip: active time, nodes (by kind), materials count, gold, gold/hr, nodes/hr.
- Footer line: `This session: 214 materials of 9 kinds, worth 3,410g · 1,820g/hr`. Buttons: **Reset** (confirm via StaticPopup), **Post to chat** (party/guild/say chooser; one-line summary).
- On Stop: freezes prices into the session, appends to `global.sessions`, fires `HB_SESSION_CHANGED("stopped", session)`.
- Public API: `Session:GetCurrent()`, `Session:GetValue(session)`.

### 4.2 NodeLog (Modules/NodeLog.lua)
- On `HB_NODE_GATHERED` with an objectID/npcID: update the spot cell (§3.2).
- Page: `< Zone name (i/n) >` pager over zones with data (current zone first). Table of node types in the zone: Node, Count, Share %, Avg items/node, Value/node. Clicking a row expands item breakdown for that node type. Footer: `This zone: N nodes of K kinds, worth Xg`; **Forget zone** (confirm).
- Optional: import GatherMate2 node locations (button in Settings, only if GatherMate2 is loaded) — creates cells with `gathers = 0` and `imported = true` so pins appear without yield data.
- Public API: `NodeLog:GetZone(mapID)`, `NodeLog:GetZones()`, `NodeLog:ForgetSpot(mapID, spotKey)`, `NodeLog:ForgetZone(mapID)`.

### 4.3 MapPins (Modules/MapPins.lua)
- HereBeDragons-Pins world-map and minimap icons per spot. Icons: herb / ore / skin textures (Blizzard tracking icons).
- Tooltip: gold title = most-common node name; `N gathers here · Xg per hour` (gold/hr from sessions in that cell's zone); top 4 items with counts; grey hint `Shift-right-click to forget this spot`.
- Options: world map on/off, minimap on/off, filter per kind, minimum gathers to show, fade pins not visited in N days (default 14; fades to 40 % alpha), pin size.
- Refreshes on `HB_NODE_GATHERED` (single pin) and zone change.

### 4.4 Records (Modules/Records.lua)
- Records: best gold/hr session (min 10 min), biggest single-node value, longest session, most nodes in a session. Updated on session stop and per gather (biggest node). Alarm fires on new record if Alarms enabled (via `HB_RECORD_BROKEN` message).
- Lifetime totals per material, account-wide and per character (warband view toggle).
- Session history list: date, duration, zones, gold, gold/hr; click to open its materials list (read-only Session table widget). Delete-session button.
- Public API: `Records:GetSessions(filter)`.

### 4.5 BestSpot (Modules/BestSpot.lua)
- Dropdown: rank **Zones** or **Spots in current zone**. Metric dropdown: gold/hr, value per node, nodes/hr.
- Zone gold/hr = sum of session value attributable to the zone ÷ active time in that zone (`zoneCopper` / `zoneSeconds` from §3.3, summed across saved sessions). Spot ranking uses value per node (gold/hr per spot is not meaningful).
- Minimum sample: zones need ≥ 15 active minutes; spots need ≥ 5 gathers. Below-threshold rows show greyed with "(low data)".
- Clicking a spot row sets a map waypoint (`C_Map.SetUserWaypoint`) and opens the world map.
- Ranking math in `Logic/Rankings.lua`.

### 4.6 Goals (Modules/Goals.lua)
- Session goals: materials (any or specific itemID), gold, minutes. Each shows a progress bar on the Goals page and optionally in the companion Session tab. Each goal fires `HB_GOAL_REACHED` once per session.
- Rare-drop attempt counters: user adds an item (Shift-click item link into the input, or drag item); attempts = gathers of the relevant kind since last found; found count; "last found N gathers ago". Default seeded list: none (user-driven, avoids stale hard-coded item IDs).
- Logic in `Logic/GoalEval.lua`.

### 4.7 Alarms (Modules/Alarms.lua)
- Rules: node value ≥ X gold; node value ≥ N × session average node value (default N = 3, after ≥ 10 nodes); rare drop (an item on the attempt list); goal reached; record broken.
- Per rule: enabled, sound (Blizzard sound kit list + "None"; LibSharedMedia sounds if that library is present), raid-warning-style text, screen edge flash (on/off).
- Global: master mute, throttle (no more than one alarm per 2 s).
- Logic in `Logic/AlarmEval.lua`.

## 5. UI

### 5.1 Theme (match Angler's TackleBox)
- Frame: dark teal-green backdrop (`#14302B`-ish, 95 % opaque) with a thin light border; title bar band slightly lighter teal.
- Title: profession-bag icon (left), `HARVESTBOOK` in gold (`#FFD100`), large serif-ish font (`Fonts\\MORPHEUS.TTF` fallback `GameFontNormalHuge`), status text right in green (`Session running · 1:42:10`) or grey (`No session`), red close button (`UIPanelCloseButton` restyled red).
- Small gold tab centered under the title bar (decorative; double-click collapses to title bar).
- Sidebar: parchment buttons (`#D8C9A3` with darker border), square 32 px icon + label in dark brown text; selected button lighter with gold left accent; hover highlight.
- Content panel: very dark teal (`#0E1F1C`), page heading in gold with 1 px gold underline; table headers gold, rows white, numeric columns right-aligned; coin text uses Blizzard coin icons.
- Buttons: dark red with gold text (`Forget zone`, `Export`), pager buttons small red squares with `<` `>`.
- Footer: summary line white; secondary line grey.
- Default size 840 × 715; resizable min 700 × 500; position, size, last page saved in profile.

### 5.2 Box (UI/Box.lua)
- Page API: `HB.UI:RegisterPage{ id, title, icon, order, build = function(frame) end, refresh = function(frame) end }`, `HB.UI:UnregisterPage(id)`, `HB.UI:ShowPage(id)`, `HB.UI:RefreshPage(id)`.
- Pages build lazily on first view. `refresh` is called on show and on relevant messages (throttled to once per 0.25 s).
- Sidebar order: Session, Node Log, Best Spot, Records, Goals, Alarms, Window, Settings.
- Open: `/hb`, `/harvestbook`, minimap button (LibDBIcon; left-click box, right-click companion toggle), Addon Compartment entry, keybinding.
- Escape closes (`UISpecialFrames`).

### 5.3 Companion (UI/Companion.lua)
- Small translucent dark frame (~300 × 230), gold title `Harvestbook`, right-aligned state (`Herbalism` / `Mining` / `Mixed` / `Paused`).
- Tabs (underlined active tab, TackleBox style): **Session** (time, nodes, gold, gold/hr, materials count, last rare, goal bars), **Materials** (top 8 by value: icon, count, value), **Log** (last 10 gathers: time, node, top item).
- Modules add tabs via `HB.UI:RegisterCompanionTab{ id, title, order, build, refresh }`.
- Options (Window page): which tabs, scale, opacity, lock, auto-show on gather, hide when no session, X hides until next gather.

### 5.4 Settings page
- Top: module switches (Session, Node Log, Map Pins, Best Spot, Records, Goals, Alarms) with dependency hints.
- Then: price source order (Auctionator / TSM / vendor; TSM price string, default `DBMarket`), auto-pause rules, minimap button, GatherMate2 import, profiles (AceDBOptions), settings export/import string (serialized profile via AceSerializer + base64-like encode), "Reset all data" (confirm twice).
- The same AceConfig table is registered in Blizzard Settings (`Harvestbook`) and as `/hb config`.

## 6. Pricing (Core/Pricing.lua)
`HB.Pricing:Get(itemID, quality) → copper, source`. Resolution chain (in `Logic/PriceChain.lua`, sources injected): user override → Auctionator → TSM custom price (configurable string) → vendor sell price (`select(11, C_Item.GetItemInfo(id))`) → 0. Results cached in `global.prices` with source and time. Cached prices are reused; `Refresh` (button on Session page / `/hb prices`) re-queries all items seen in the current session. Prices are never re-queried automatically during gathering.

## 7. Slash commands
`/hb` (toggle box) · `/hb start|pause|resume|stop|reset` · `/hb companion` · `/hb config` · `/hb prices` · `/hb debug` · `/hb help`. `/harvestbook` is an alias.

## 8. API verification notes
Checked against Blizzard's generated API docs (wow-ui-source `live`, 12.1.5.70391), warcraft.wiki.gg, and library sources, 2026-10-15. Not yet verified in-game; items marked **(verify in-game)** go on the manual checklist.

| Need | API (12.1.5) | Status / decision |
|---|---|---|
| Detect gather cast | `UNIT_SPELLCAST_SENT(unit, target, castGUID, spellID)`; `UNIT_SPELLCAST_SUCCEEDED(unit, castGUID, spellID, castBarID)` | Readable for `"player"` (secret restriction applies only to non-player units). Guard every arg with `issecretvalue()` like GatherMate2. Match by spell ID set **and** by localized spell name from `C_Spell.GetSpellName` of known IDs, so new expansion IDs (e.g. Mining 471013) still match. Known IDs: Mining 2575, 195122, 423341, 471013; Herb Gathering 2366; Skinning 8613 **(verify in-game; add any Midnight variants)**. |
| Loot items | `GetNumLootItems`, `GetLootSlotInfo(slot)` → `icon, name, quantity, currencyID, quality, …`, `GetLootSlotLink(slot)` | Unchanged. |
| Loot source | `GetLootSourceInfo(slot)` → `guid1, qty1, guid2, qty2, …` | GameObject GUID for herb/ore (`strsplit("-", guid)`: type `"GameObject"`, 6th field = objectID); Creature GUID for skinning (6th field = npcID). Secret status undocumented → guard with `issecretvalue`; if secret/nil, emit with `objectID = nil`. |
| Loot fallback | `CHAT_MSG_LOOT` | Open-world readable (secret only under chat-messaging lockdown: instances/M+/PvP). Used only when `LOOT_READY` didn't fire within 3 s of a gather cast (fast auto-loot edge case); gives items but no source. |
| Position | `C_Map.GetBestMapForUnit("player")`, `C_Map.GetPlayerMapPosition(mapID, "player")` | Unrestricted; nil in instances (gathering there is ignored). |
| Reagent quality | `C_TradeSkillUI.GetItemReagentQualityByItemInfo(itemInfo)` → number? | Midnight reagents have **2 tiers** (Silver/Gold), not 3. Store the returned number as-is; UI badge shows the Blizzard quality atlas for that tier **(verify returns 1/2)**. |
| Auctionator | `Auctionator.API.v1.GetAuctionPriceByItemID("Harvestbook", itemID)` / `…ByItemLink` → copper? | Use ByItemLink when a link exists (keeps quality tier). Wrap in `pcall`. |
| TSM | `TSM_API.ToItemString(link)`, `TSM_API.GetCustomPriceValue(priceStr, itemString)` → copper?, err | Wrap in `pcall` (throws on unknown keys). |
| Map pins | HereBeDragons 2.18 (HBD-2.0 r35, Pins-2.0 r17): `AddWorldMapIconMap(ref, icon, mapID, x, y, HBD_PINS_WORLDMAP_SHOW_PARENT)`, `AddMinimapIconMap(ref, icon, mapID, x, y, showInParentZone, floatOnEdge)`, `RemoveWorldMapIcon`, `RemoveMinimapIcon`, `RemoveAllWorldMapIcons`, `RemoveAllMinimapIcons` | Works in 12.1.x. |
| Libraries | Ace3 Release-r1403; LibDBIcon-1.0 v12.1.1; LibDataBroker-1.1 | All 12.1.x compatible. |
| Auto-pause | `MAIL_SHOW`/`MAIL_CLOSED`, `AUCTION_HOUSE_SHOW`/`AUCTION_HOUSE_CLOSED`, `PLAYER_FLAGS_CHANGED` + `UnitIsAFK("player")`, `PLAYER_ENTERING_WORLD` + `IsInInstance()` | Present. `UnitIsAFK` may be secret in instances — irrelevant since sessions are already paused there. |
| TOC | `## Interface: 120100, 120105`; optional `Category`, `IconTexture`, `AddonCompartmentFunc*`; `## AllowLoadGameType: mainline` | Use all of these. |

**Design impacts already applied:** reagent rank badge is 2-tier (§4.1); detection uses SENT+SUCCEEDED with secret guards and a name-based spell match (§2.4); `CHAT_MSG_LOOT` fallback (§2.4); `AllowLoadGameType` (§10).

**Midnight gathering notes (for later modules, not v1):** Finesse / Perception / Deftness stats still exist; Mining has Rich deposits, Seams, and Infused deposits that drop motes. These feed the future gear-aware comparison module. Infused/Rich deposits appear in v1 simply as distinct objectIDs in the Node Log.

## 9. Testing
- **Unit (busted, off-client):** everything in `Logic/` — session time accrual across pause/resume, gold/hr thresholds, grid keys and running means, ranking thresholds, price-chain fallback order, goal and alarm evaluation, migrations. `tests/wowstub.lua` provides minimal globals (`time`, `floor`, `format`) only; Logic files must not reference WoW APIs.
- **In-game manual checklist** (`docs/testing/manual-checklist.md`): gather herb/ore/skin with auto-loot on and off; `/reload` mid-session; toggle each module off/on; no-auction-addon pricing; pins appear/fade/forget; alarms fire once; companion tabs toggle.
- `/hb debug` prints every `HB_NODE_GATHERED` payload.

## 10. Packaging
- `Harvestbook.toc`: `## Interface` for 12.1.0 and 12.1.5 (comma-separated), `## Title: Harvestbook`, `## SavedVariables: HarvestbookDB`, `## SavedVariablesPerCharacter: HarvestbookCharDB`, `## IconTexture`, `## AddonCompartmentFunc`, `## Category: Professions`, `## AllowLoadGameType: mainline`. Load order: libs → Core → Logic → UI → Modules.
- Libraries vendored into `libs/` (no packager dependency).
