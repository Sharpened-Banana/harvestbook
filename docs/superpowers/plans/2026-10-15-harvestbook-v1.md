# Harvestbook v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Harvestbook, a Retail (12.1.x) WoW gathering addon with a TackleBox-style main window and seven toggleable modules: Session (gold/hr + materials list), Node Log, Map Pins, Best Spot, Records, Goals, Alarms.

**Architecture:** Ace3 addon. `Core/Gather.lua` is the only gather observer and broadcasts `HB_NODE_GATHERED`; modules subscribe to messages and use core services. All math lives in pure-Lua `Logic/` files (no WoW API) that are unit-tested off-client with LuaJIT; `UI/` builds custom TackleBox-style frames; `Modules/` glue Logic to events and UI.

**Tech Stack:** Lua 5.1 (WoW / LuaJIT), Ace3 Release-r1403, HereBeDragons 2.18, LibDBIcon-1.0, LibDataBroker-1.1. Tests: in-repo busted-style runner on `/opt/homebrew/bin/luajit`.

**Spec:** `docs/superpowers/specs/2026-10-15-harvestbook-v1-design.md` — read it alongside this plan; section refs (§) point there.

## Global Constraints

- Retail only. TOC: `## Interface: 120100, 120105`, `## AllowLoadGameType: mainline`, `## Title: Harvestbook`, `## SavedVariables: HarvestbookDB`, `## SavedVariablesPerCharacter: HarvestbookCharDB`, `## Category: Professions`, `## IconTexture`, `## AddonCompartmentFunc: Harvestbook_OnAddonCompartmentClick`.
- Lua 5.1 only: no `goto`, no integer division `//`, no `utf8`, no bit ops syntax. Tests run under `luajit` to enforce this.
- Every addon file begins `local ADDON, ns = ...`. Logic modules attach to `ns` (e.g. `ns.SessionMath = M`) and **must not reference any WoW global** (`C_Map`, `strsplit`, `time`, `GetTime`, etc.) — time is passed in as `now`.
- Core object is `ns.HB` (AceAddon "Harvestbook"); also exposed as global `Harvestbook` for macros.
- Internal messages (AceEvent `SendMessage`): `HB_NODE_GATHERED(payload)`, `HB_SESSION_CHANGED(state, session)`, `HB_PRICES_UPDATED()`, `HB_MODULE_TOGGLED(name, enabled)`, `HB_GOAL_REACHED(goal)`, `HB_RECORD_BROKEN(recordName, value)`.
- Additional module messages: `HB_NODELOG_CHANGED(mapID, spotKey)` (NodeLog), `HB_RARE_FOUND(itemID, attemptsBeforeFind)` (Goals).
- Gather payload shape as spec §2.3 plus two fields: `{ time, kind = "herb"|"ore"|"skin", objectID, npcID, targetName, mapID, x, y, items = { {itemID, count, quality, link}, ... } }`. `link` enables pricing by link (keeps quality tier); `targetName` is the `UNIT_SPELLCAST_SENT` target string when not secret (used to name nodes).
- Money is always integer copper internally; formatting only in UI.
- Prices are never re-queried automatically during gathering (spec §6).
- Disabling a module never deletes its data (spec §2.5).
- Colors (spec §5.1): frame `#14302B` @ 0.95, content `#0E1F1C`, gold `#FFD100`, parchment `#D8C9A3`, status green `#33FF33`, grey `#9D9D9D`, red button `#7A1010`.
- Commit after every task with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` as the last line.

## Review Focus

1. **Gathering while paused** — the Session must ignore it (no counts, no value), but NodeLog still records the node. Test: `SessionMath AddGather while paused returns false and leaves items empty` (Task 2).
2. **`/reload` or crash while running** — offline time must not count as active time. Test: `SessionMath Restore resets lastResume to now for a running session` (Task 2).
3. **Item with no price from any source** — value 0, source `"none"`, gold/hr still computed, nothing errors. Tests: `PriceChain falls through to none` (Task 4) and `SessionMath Rows handles zero-price items` (Task 2).
4. **Price addon throws** (TSM unknown key, Auctionator not ready) — fall through to next source. Test: `PriceChain skips a source that errors` (Task 4).
5. **Herb and ore node in the same 2% grid cell** — must become two spots, not a merged one. Test: `NodeGrid keeps different kinds in the same cell apart` (Task 3).

---

## File Structure

```
Harvestbook/                      ← the addon folder (copy this into AddOns/)
  Harvestbook.toc
  embeds.xml                      loads libs
  libs/                           vendored by tools/fetch-libs.sh (committed)
  Core/Init.lua  Core/DB.lua  Core/Gather.lua  Core/Pricing.lua  Core/Options.lua
  Logic/SessionMath.lua  Logic/NodeGrid.lua  Logic/PriceChain.lua  Logic/Rankings.lua
  Logic/GoalEval.lua  Logic/AlarmEval.lua  Logic/Migrate.lua  Logic/GatherParse.lua  Logic/Format.lua
  UI/Theme.lua  UI/Widgets.lua  UI/Box.lua  UI/Companion.lua
  Modules/Session.lua  Modules/NodeLog.lua  Modules/MapPins.lua  Modules/Records.lua
  Modules/BestSpot.lua  Modules/Goals.lua  Modules/Alarms.lua
tests/run.lua                     busted-style runner (describe/it/assert)
tests/helper.lua                  load(path) → ns with the Logic file applied
tests/*_spec.lua
tools/check.sh                    syntax-compile all addon Lua, verify TOC entries exist, run tests
tools/fetch-libs.sh
docs/testing/manual-checklist.md
```
Repo root holds `Harvestbook/`, `tests/`, `tools/`, `docs/`. The two extra Logic files beyond the spec (`Migrate`, `GatherParse`, `Format`) exist so DB migrations, GUID/spell parsing, and money/time formatting are unit-testable.

---

### Task 1: Scaffold, test runner, libraries, check script

**Files:**
- Create: `Harvestbook/Harvestbook.toc`, `Harvestbook/embeds.xml`, `tests/run.lua`, `tests/helper.lua`, `tests/runner_spec.lua`, `tools/check.sh`, `tools/fetch-libs.sh`, `.gitignore`
- Create (vendored): `Harvestbook/libs/**`

**Interfaces:**
- Produces: `luajit tests/run.lua [spec files...]` (defaults to `tests/*_spec.lua`), exits non-zero on any failure, prints `N passed, M failed`. Globals inside specs: `describe(name, fn)`, `it(name, fn)`, `before_each(fn)`, `assert.are.equal(expected, actual)`, `assert.are.same(expected, actual)` (deep), `assert.is_true(v)`, `assert.is_false(v)`, `assert.is_nil(v)`, `assert.has_error(fn)`.
- Produces: `tests/helper.lua` returning `load(...)`: `local ns = require("tests.helper").load("Logic/NodeGrid.lua", "Logic/Format.lua")` — runs each file (path relative to `Harvestbook/`) as a chunk with args `("Harvestbook", ns)` and returns `ns`.
- Produces: `tools/check.sh` — (1) `luajit -bl <file> >/dev/null` on every `Harvestbook/{Core,Logic,UI,Modules}/*.lua`; (2) every non-comment, non-`##` line of the TOC names an existing file; (3) runs `luajit tests/run.lua`. Exit non-zero on any failure.

- [ ] **Step 1:** Write `tests/runner_spec.lua` with three cases: `same` passes on equal nested tables, `same` fails on differing nested tables (wrap in `assert.has_error`), `equal` fails on 1 vs 2 (wrap in `assert.has_error`).
- [ ] **Step 2:** Run `luajit tests/run.lua tests/runner_spec.lua` — expected: fails (`tests/run.lua` missing).
- [ ] **Step 3:** Implement `tests/run.lua` and `tests/helper.lua` (set `package.path` to include `./?.lua` so `require("tests.helper")` works from repo root). Failure messages include the spec name, test name, and expected/actual via a small serializer.
- [ ] **Step 4:** Run `luajit tests/run.lua tests/runner_spec.lua` — expected: `3 passed, 0 failed`.
- [ ] **Step 5:** Write `tools/fetch-libs.sh`: shallow-clone into a temp dir then copy into `Harvestbook/libs/`: `https://github.com/WoWUIDev/Ace3` tag `Release-r1403` (copy `LibStub`, `CallbackHandler-1.0`, `AceAddon-3.0`, `AceDB-3.0`, `AceDBOptions-3.0`, `AceEvent-3.0`, `AceConsole-3.0`, `AceConfig-3.0`, `AceGUI-3.0`, `AceSerializer-3.0`, `AceTimer-3.0`); `https://github.com/Nevcairiel/HereBeDragons` tag `2.18` (copy `HereBeDragons-2.0.lua`, `HereBeDragons-Pins-2.0.lua` into `libs/HereBeDragons/`); LibDBIcon-1.0 and LibDataBroker-1.1 from their GitHub repos (verify the current repo URLs on their CurseForge "Source" links before running; record the URLs used in a comment at the top of the script). Run it.
- [ ] **Step 6:** Write `embeds.xml` loading each lib's own `.xml`/`.lua` in dependency order (LibStub → CallbackHandler → LibDataBroker → LibDBIcon → HereBeDragons → Ace*), and the TOC with all Global Constraints fields plus the load order: `embeds.xml`, `Logic/*`, `Core/Init.lua`, `Core/DB.lua`, `Core/Pricing.lua`, `Core/Gather.lua`, `Core/Options.lua`, `UI/Theme.lua`, `UI/Widgets.lua`, `UI/Box.lua`, `UI/Companion.lua`, `Modules/Session.lua`, `Modules/NodeLog.lua`, `Modules/MapPins.lua`, `Modules/Records.lua`, `Modules/BestSpot.lua`, `Modules/Goals.lua`, `Modules/Alarms.lua`. Create each listed addon file as a stub containing only `local ADDON, ns = ...` so the check passes; later tasks fill them. `## IconTexture: Interface\Icons\Trade_Herbalism`.
- [ ] **Step 7:** Write `tools/check.sh`; run `bash tools/check.sh` — expected: exit 0, `3 passed, 0 failed`.
- [ ] **Step 8:** Commit: `chore: scaffold addon, test runner, vendored libs, check script`.

---

### Task 2: Logic/SessionMath + Logic/Format

**Files:**
- Create: `Harvestbook/Logic/SessionMath.lua`, `Harvestbook/Logic/Format.lua`
- Test: `tests/session_math_spec.lua`, `tests/format_spec.lua`

**Interfaces:**
- Consumes: none.
- Produces (`ns.SessionMath`): a session table exactly per spec §3.3 plus `currentMap` and `zoneSince`. `priceFn(itemID, quality, link) -> copper, source` is supplied by callers.
  - `New(now) -> session` (state `"running"`, `started = lastResume = now`, `activeSeconds = 0`, all sub-tables empty, `nodes = {herb=0, ore=0, skin=0}`, `note = ""`)
  - `Pause(s, now)`, `Resume(s, now)` — no-ops if already in that state; Pause also closes the current zone segment
  - `Stop(s, now, priceFn)` — sets `"stopped"`, folds running time, fills `s.prices[itemKey] = {copper, source}` for every item
  - `Restore(s, now)` — after login: if running, `lastResume = now`, `zoneSince = now`
  - `Checkpoint(s, now)` — folds running time into `activeSeconds` and sets `lastResume = now` (called before saving)
  - `ActiveSeconds(s, now) -> number`
  - `ItemKey(itemID, quality) -> string` (`itemID .. ":" .. (quality or 0)`)
  - `AddGather(s, gather, now, priceFn) -> boolean` — false and no change unless running; otherwise updates `items`, `nodes[kind]`, `zones[mapID]`, `zoneCopper[mapID]`, switches zone segment if `mapID ~= currentMap` (accruing `zoneSeconds` for the old map)
  - `NodeValue(gather, priceFn) -> copper`
  - `Value(s, priceFn) -> copper` (uses frozen `s.prices` when stopped)
  - `GoldPerHour(s, now, priceFn) -> copper|nil` (nil when `ActiveSeconds < 60`)
  - `Rows(s, now, priceFn, sortKey, descending) -> { {itemKey, itemID, quality, link, count, perHour, unit, value, source}, ... }`; `sortKey` ∈ `"name"|"count"|"perHour"|"unit"|"value"`, default `"value"` desc; `"name"` sorts by itemID (UI resolves names)
  - `Summary(s, now, priceFn) -> { materials, kinds, copper, gph, nodes }`
- Produces (`ns.Format`): `Money(copper, style) -> string` (`style` `"gold"` → `"3,410g"` rounded down; `"full"` → `"3,410g 12s 5c"`, omitting zero lower units); `Duration(seconds) -> "1:42:10"` (`"4:05"` under an hour); `Thousands(n) -> "1,234"`.

- [ ] **Step 1:** Write `tests/session_math_spec.lua` covering, with a stub `priceFn` returning 100 copper for itemID 1, 250 for itemID 2, `nil→0,"none"` for itemID 3:
  - `New sets running state and zero counts`
  - `ActiveSeconds excludes paused time`: New(0), Pause(100), Resume(400), ActiveSeconds(500) == 200
  - `AddGather while paused returns false and leaves items empty`
  - `AddGather sums counts per itemKey and splits by quality`: two gathers of item 1 q1 ×2 and item 1 q2 ×1 → keys `"1:1"` count 2, `"1:2"` count 1
  - `zone change splits zoneSeconds`: New(0) gather mapID 10 at t=0, gather mapID 20 at t=300, Pause(600) → `zoneSeconds[10]==300`, `zoneSeconds[20]==300`
  - `GoldPerHour is nil under 60 active seconds`; `GoldPerHour computes per hour`: 1,000 copper over 1,800 s → 2,000
  - `Rows handles zero-price items`: item 3 row has `value == 0`, `source == "none"`
  - `Rows sorts by value descending by default`
  - `Stop freezes prices`: after Stop, changing priceFn does not change `Value`
  - `Restore resets lastResume to now for a running session`: New(0), Checkpoint(100), Restore(5000), ActiveSeconds(5010) == 110
- [ ] **Step 2:** Write `tests/format_spec.lua`: `Money(34101205,"gold") == "3,410g"`, `Money(34101205,"full") == "3,410g 12s 5c"`, `Money(500,"full") == "5s"`, `Money(0,"gold") == "0g"`, `Duration(6130) == "1:42:10"`, `Duration(245) == "4:05"`.
- [ ] **Step 3:** Run `luajit tests/run.lua tests/session_math_spec.lua tests/format_spec.lua` — expected: FAIL (modules nil).
- [ ] **Step 4:** Implement both files.
- [ ] **Step 5:** Run the same command — expected: all pass. Run `bash tools/check.sh` — exit 0.
- [ ] **Step 6:** Commit: `feat(logic): session math and formatting`.

---

### Task 3: Logic/NodeGrid

**Files:** Create `Harvestbook/Logic/NodeGrid.lua`; Test `tests/node_grid_spec.lua`

**Interfaces:**
- Produces (`ns.NodeGrid`), operating on one zone table `zone = nodes[mapID]` (spec §3.2):
  - `CellKey(x, y) -> "i:j"` with `i = floor(x*50)`, `j = floor(y*50)`
  - `Record(zone, gather, copper) -> spotKey` — key is `CellKey`; if that cell exists with a different `kind`, key becomes `CellKey .. ":" .. kind`. Updates running-mean `x,y`, `nodeIDs[objectID or npcID]`, `items[itemID]`, `gathers`, `copper`, `firstSeen/lastSeen = gather.time`. Gathers with neither objectID nor npcID are not recorded (return nil).
  - `Forget(zone, spotKey)`
  - `Summarize(zone) -> { {nodeID, kind, count, share, avgItems, valuePerNode}, ... }` sorted by count desc (share is 0..1; avgItems = items from spots dominated by that nodeID ÷ its count — attribute each spot's totals to the spot's most-gathered nodeID)
  - `ImportPoint(zone, x, y, kind)` — creates a cell with `gathers = 0, imported = true` if none exists

- [ ] **Step 1:** Write tests: `CellKey floors to a 2% grid` (`0.123, 0.987 → "6:49"`); `Record averages positions within a cell`; `NodeGrid keeps different kinds in the same cell apart` (herb then ore at same x,y → two keys, second ends `":ore"`); `Record ignores gathers without a source`; `Summarize computes share and avg items`; `ImportPoint does not overwrite real data`.
- [ ] **Step 2:** Run — expected FAIL. **Step 3:** Implement. **Step 4:** Run — expected PASS; `bash tools/check.sh` exit 0.
- [ ] **Step 5:** Commit: `feat(logic): node grid`.

---

### Task 4: Logic/PriceChain

**Files:** Create `Harvestbook/Logic/PriceChain.lua`; Test `tests/price_chain_spec.lua`

**Interfaces:**
- Produces (`ns.PriceChain`): `Resolve(itemID, quality, link, sources) -> copper, sourceName` where `sources` is an ordered array of `{ name = string, fn = function(itemID, quality, link) -> copper|nil }`. Each `fn` is called with `pcall`; errors and nil/≤0 results fall through. Nothing found → `0, "none"`.

- [ ] **Step 1:** Tests: `first source with a value wins`; `PriceChain skips a source that errors` (fn calls `error("bad key")`, next returns 50 → `50, "next"`); `PriceChain falls through to none`; `zero is treated as no price`.
- [ ] **Step 2–4:** Fail → implement → pass; `bash tools/check.sh` exit 0.
- [ ] **Step 5:** Commit: `feat(logic): price chain`.

---

### Task 5: Logic/Rankings

**Files:** Create `Harvestbook/Logic/Rankings.lua`; Test `tests/rankings_spec.lua`

**Interfaces:**
- Consumes: saved session shape (Task 2), zone table shape (Task 3).
- Produces (`ns.Rankings`):
  - `Zones(sessions, metric, minSeconds) -> rows` — aggregates `zoneSeconds`, `zoneCopper`, `zones` (gathers) across sessions per mapID. Row: `{ mapID, seconds, copper, nodes, gph, perNode, nodesPerHour, lowData }`; `lowData = seconds < minSeconds` (spec: 900). Sorted by `metric` (`"gph"|"perNode"|"nodesPerHour"`) desc, lowData rows last.
  - `Spots(zone, minGathers) -> rows` — `{ spotKey, x, y, kind, gathers, perNode, lowData }`; `lowData = gathers < minGathers` (spec: 5); sorted by `perNode` desc, lowData last; imported cells (`gathers == 0`) excluded.

- [ ] **Step 1:** Tests: `Zones sums across sessions`; `Zones marks under 15 minutes as low data and sorts it last`; `Zones sorts by chosen metric`; `Spots excludes imported cells`; `Spots marks under 5 gathers low data`.
- [ ] **Step 2–4:** Fail → implement → pass; check.sh exit 0.
- [ ] **Step 5:** Commit: `feat(logic): rankings`.

---

### Task 6: Logic/GoalEval + Logic/AlarmEval

**Files:** Create `Harvestbook/Logic/GoalEval.lua`, `Harvestbook/Logic/AlarmEval.lua`; Test `tests/goal_eval_spec.lua`, `tests/alarm_eval_spec.lua`

**Interfaces:**
- Consumes: SessionMath (Task 2).
- Produces (`ns.GoalEval`):
  - goal = `{ id, type = "materials"|"gold"|"minutes", itemID = number|nil, target = number }` (gold target in copper; minutes in minutes)
  - `Progress(goal, session, now, priceFn) -> current, target, done`
  - `NewlyReached(goals, session, now, priceFn, reached) -> { goal, ... }` — `reached` is a set keyed by goal.id, mutated so each goal fires once
  - `UpdateAttempts(attempts, gather) -> foundItemIDs` — `attempts[itemID] = { attempts, found, kind, sinceLast }`; for each tracked item whose `kind` is nil or equals `gather.kind`: if the gather contains the item → `found += 1`, `sinceLast = 0`, add to result; else `attempts += 1`, `sinceLast += 1`
- Produces (`ns.AlarmEval`):
  - rules table (profile): `{ value = {enabled, gold}, multiple = {enabled, n, minNodes}, rare = {enabled}, goal = {enabled}, record = {enabled} }` (defaults: value off/500g, multiple on/3/10, rare on, goal on, record on)
  - `Evaluate(rules, ctx, state) -> { {rule, text}, ... }` — `ctx = { kind = "node"|"rare"|"goal"|"record", nodeCopper, avgCopper, nodeCount, itemIDs, label, now }`; `state.lastFire` throttles: nothing fires within 2 s of the previous fire; master mute `rules.muted` returns empty.

- [ ] **Step 1:** Goal tests: `materials goal counts any item when itemID nil`; `gold goal uses session value`; `minutes goal uses active time`; `NewlyReached fires once`; `UpdateAttempts counts misses and resets on find`; `UpdateAttempts ignores other kinds`.
- [ ] **Step 2:** Alarm tests: `value rule fires at threshold`; `multiple rule waits for minNodes`; `throttle suppresses within 2 seconds`; `mute suppresses all`.
- [ ] **Step 3–5:** Fail → implement → pass; check.sh exit 0.
- [ ] **Step 6:** Commit: `feat(logic): goal and alarm evaluation`.

---

### Task 7: Logic/Migrate + Logic/GatherParse

**Files:** Create `Harvestbook/Logic/Migrate.lua`, `Harvestbook/Logic/GatherParse.lua`; Test `tests/migrate_spec.lua`, `tests/gather_parse_spec.lua`

**Interfaces:**
- Produces (`ns.Migrate`): `Run(global, migrations) -> version` — runs `migrations[n](global)` for every `n > (global.schemaVersion or 0)` in ascending order, sets `global.schemaVersion`.
- Produces (`ns.GatherParse`):
  - `ParseGUID(guid) -> unitType, id` — `"GameObject-0-1-2-3-4-5678-ABC"` → `"GameObject", 5678`; `"Creature-0-1-2-3-12345-ABC"` → `"Creature", 12345`; nil/malformed → nil. Use `string.match`, not `strsplit`.
  - `NewSpellMatcher(knownIDs, nameOf) -> match(spellID, spellName) -> kind|nil` — `knownIDs = { [spellID] = kind }`; builds `names[nameOf(id)] = kind` once; matches by ID first, then name.
  - `PatternFromFormat(fmt) -> luaPattern` — converts a Blizzard format like `"You receive loot: %sx%d."` to a pattern capturing link and count (escape magic chars; `%s`→`(.+)`, `%d`→`(%d+)`).
  - `KNOWN_SPELLS = { [2575]="ore", [195122]="ore", [423341]="ore", [471013]="ore", [2366]="herb", [8613]="skin" }`

- [ ] **Step 1:** Tests: `Run applies only newer migrations in order`; `Run on fresh db applies all`; `ParseGUID reads GameObject id`; `ParseGUID reads Creature id`; `ParseGUID rejects malformed`; `matcher matches unknown ID by name` (nameOf(2575)="Mining", match(999999,"Mining") == "ore"); `PatternFromFormat extracts link and count`.
- [ ] **Step 2–4:** Fail → implement → pass; check.sh exit 0.
- [ ] **Step 5:** Commit: `feat(logic): migrations and gather parsing`.

---

### Task 8: Core/Init + Core/DB

**Files:** Modify `Harvestbook/Core/Init.lua`, `Harvestbook/Core/DB.lua`

**Interfaces:**
- Consumes: `ns.Migrate`.
- Produces:
  - `ns.HB = LibStub("AceAddon-3.0"):NewAddon("Harvestbook", "AceEvent-3.0", "AceConsole-3.0", "AceTimer-3.0")`; global `Harvestbook = ns.HB`.
  - `HB.db` (AceDB on `HarvestbookDB`, defaults in DB.lua covering every profile key referenced by later tasks: `modules[name].enabled = true` for all seven, `window = {point, w=840, h=715, page="session"}`, `companion = {shown=true, tabs={session=true, materials=true, log=true}, scale=1, alpha=0.9, locked=false, autoShow=true, hideNoSession=false}`, `session = {autoStart=true, pause={instance=true, mail=true, ah=true, afk=true}, autoResume=true, sortKey="value"}`, `pricing = {order={"override","auctionator","tsm","vendor"}, tsmString="DBMarket"}`, `pins = {world=true, minimap=true, kinds={herb=true, ore=true, skin=true}, minGathers=1, fadeDays=14, size=14}`, `alarms` = AlarmEval defaults, `goals = {list={}}`, `minimap = {hide=false}`, `goldStyle = "gold"`, `debug = false`; `global` defaults per spec §3.1).
  - `HB.char` = `HarvestbookCharDB` (initialized table, `current = nil`).
  - `HB:SafeCall(moduleName, fn, ...)` — `xpcall` wrapper; first error per module per login prints `Harvestbook: <module> error — see /hb debug`; with debug on prints the traceback.
  - `HB:Listen(module, message, handler)` — `module:RegisterMessage(message, function(_, ...) HB:SafeCall(module:GetName(), handler, module, ...) end)`.
  - `HB:SetModuleEnabled(name, enabled)` — persists, calls `EnableModule/DisableModule`, also disables enabled dependents (`MapPins`, `BestSpot` need `NodeLog`; `Records`, `Goals`, `Alarms` need `Session`; `BestSpot` needs `Records`), fires `HB_MODULE_TOGGLED`. `HB.DEPENDS = { MapPins={"NodeLog"}, BestSpot={"NodeLog","Records"}, Records={"Session"}, Goals={"Session"}, Alarms={"Session"} }`.
  - In `OnInitialize`: create db, run `ns.Migrate.Run(HB.db.global, HB.migrations)` (`HB.migrations = {}` for v1), set each module's enabled state from profile via `SetEnabledState` before enable.
  - Slash commands `/hb` and `/harvestbook` routing per spec §7 (`start|pause|resume|stop|reset` → Session module methods if enabled; `companion`, `config`, `prices`, `debug`, `help`; no arg → `HB.UI:Toggle()`). Unknown subcommand prints help.
  - Global `Harvestbook_OnAddonCompartmentClick()` → `HB.UI:Toggle()`.

- [ ] **Step 1:** Implement both files.
- [ ] **Step 2:** Run `bash tools/check.sh` — exit 0.
- [ ] **Step 3:** Add to `docs/testing/manual-checklist.md` (create): "Addon loads with no errors (enable `/console scriptErrors 1`)", "`/hb help` lists commands", "`/hb debug` toggles debug".
- [ ] **Step 4:** Commit: `feat(core): addon init, saved data, module toggling, slash commands`.

---

### Task 9: Core/Pricing + Core/Gather + Core/Options

**Files:** Modify `Harvestbook/Core/Pricing.lua`, `Harvestbook/Core/Gather.lua`, `Harvestbook/Core/Options.lua`

**Interfaces:**
- Consumes: `ns.PriceChain`, `ns.GatherParse`, `HB.db`.
- Produces:
  - `HB.Pricing:Get(itemID, quality, link) -> copper, source` — returns cached `global.prices[itemKey]` if present; otherwise resolves and caches `{value, source, time}`. Sources built from `profile.pricing.order`: `override` → `global.priceOverrides[itemKey]`; `auctionator` → `Auctionator.API.v1.GetAuctionPriceByItemLink("Harvestbook", link)` if link else `ByItemID`; `tsm` → `TSM_API.GetCustomPriceValue(tsmString, TSM_API.ToItemString(link or ("i:"..itemID)))`; `vendor` → `select(11, C_Item.GetItemInfo(itemID))`. Sources whose addon global is absent are skipped.
  - `HB.Pricing:Refresh(itemList)` — re-resolves given `{ {itemID, quality, link} }`, then `SendMessage("HB_PRICES_UPDATED")`.
  - `HB.Pricing:Fn()` → a `priceFn` closure matching Task 2's signature.
  - `HB.Pricing:SetOverride(itemID, quality, copper|nil)`.
  - `Core/Gather.lua`: event flow exactly per spec §2.4 including 5a; payload per Global Constraints; reagent quality via `C_TradeSkillUI.GetItemReagentQualityByItemInfo(link)`; every event arg passed through `issecretvalue` guard (`if issecretvalue and issecretvalue(v) then return end`); matcher from `GatherParse.NewSpellMatcher(GatherParse.KNOWN_SPELLS, C_Spell.GetSpellName)`; gathers inside instances (`C_Map.GetPlayerMapPosition` nil) are dropped; with `profile.debug` prints each payload as one line. Coins (`isCoin`) and currencies (`currencyID`) are excluded from items.
  - `Core/Options.lua`: `HB.options` AceConfig root (type group, childGroups "tab"); `HB:AddOptions(key, groupTable, order)` for modules; registers with `AceConfigRegistry`, `AceConfigDialog:AddToBlizOptions("Harvestbook")`, and `/hb config`. Root holds the module switches (toggle per module, `disabled` when a dependency is off, `desc` "Requires Node Log" etc.), pricing order (select per slot) + TSM string input, auto-pause toggles, minimap button toggle, profiles (`AceDBOptions`), export/import string (AceSerializer `Serialize(profile)` then encode with a simple base64 implemented in Options.lua; import validates and applies with confirm), and "Reset all data" (two StaticPopups).

- [ ] **Step 1:** Implement the three files.
- [ ] **Step 2:** `bash tools/check.sh` — exit 0.
- [ ] **Step 3:** Add to manual checklist: "`/hb debug` then gather an herb, an ore, a skin, with auto-loot ON and OFF — one payload line each, correct kind, objectID/npcID present", "With Auctionator only / TSM only / neither — prices resolve, source shown", "**Verify:** Skinning spell ID 8613 matches; note any Midnight herb/skin spell IDs printed by debug", "**Verify:** reagent quality returns 1/2 for Midnight reagents", "**Verify:** loot source GUID not secret (objectID non-nil)".
- [ ] **Step 4:** Commit: `feat(core): pricing, gather detection, options`.

---

### Task 10: UI/Theme + UI/Widgets

**Files:** Modify `Harvestbook/UI/Theme.lua`, `Harvestbook/UI/Widgets.lua`

**Interfaces:**
- Consumes: `ns.Format`.
- Produces:
  - `ns.Theme`: `COLORS` (Global Constraints values as `{r,g,b,a}`), `FONTS = { title = "Fonts\\MORPHEUS.TTF", body = "Fonts\\FRIZQT__.TTF" }`, `ICONS = { session="Interface\\Icons\\INV_Misc_PocketWatch_01", nodelog="Interface\\Icons\\INV_Misc_Book_09", bestspot="Interface\\Icons\\INV_Misc_Map_01", records="Interface\\Icons\\INV_Misc_Trophy_03", goals="Interface\\Icons\\INV_Misc_Note_01", alarms="Interface\\Icons\\INV_Misc_Bell_01", window="Interface\\Icons\\INV_Misc_Spyglass_03", settings="Interface\\Icons\\Trade_Engineering", herb="Interface\\Icons\\Trade_Herbalism", ore="Interface\\Icons\\Trade_Mining", skin="Interface\\Icons\\INV_Misc_Pelt_Wolf_01" }` (any icon that renders as the green "?" in-game gets swapped during manual testing), `Theme:Backdrop(frame, colorKey, borderColorKey)` using `BackdropTemplate` + `Interface\\Buttons\\WHITE8X8`.
  - `ns.Widgets` (all return frames with documented methods):
    - `SidebarButton(parent, icon, label) -> btn` with `btn:SetSelected(bool)`; 200×44, parchment bg, 32 px icon, dark-brown label; selected = lighter bg + 3 px gold left bar.
    - `RedButton(parent, label, onClick) -> btn` — dark red, gold text, auto width.
    - `Pager(parent, onPrev, onNext) -> pager` with `pager:SetText(str)`; red square `<` `>` buttons, gold centered text.
    - `ColumnList(parent, columns) -> list` — `columns = { {key, title, width, align = "LEFT"|"RIGHT", sortable} }`; gold header row with clickable sortable headers (`list.onSort(key)`); `list:SetRows(rows, cellFn)` where `cellFn(row, key) -> text, iconTexture|nil, qualityAtlas|nil`; FauxScroll/ScrollBox virtualized at 18 px rows; `list.onRowClick(row)`, `list.onRowEnter(row, rowFrame)`.
    - `CoinText(parent) -> fs` with `fs:SetCopper(copper)` using `GetCoinTextureString` (Blizzard coin icons).
    - `ProgressBar(parent) -> bar` with `bar:SetProgress(current, target, label)`.
    - `Heading(parent, text) -> fs` gold, with 1 px gold underline texture below.
    - `Toggle(parent, label, get, set) -> checkbutton`.

- [ ] **Step 1:** Implement both files.
- [ ] **Step 2:** `bash tools/check.sh` — exit 0.
- [ ] **Step 3:** Commit: `feat(ui): theme and widgets`.

---

### Task 11: UI/Box + UI/Companion + minimap button

**Files:** Modify `Harvestbook/UI/Box.lua`, `Harvestbook/UI/Companion.lua`, `Harvestbook/Harvestbook.toc`; Create `Harvestbook/Bindings.xml`

**Interfaces:**
- Consumes: `ns.Theme`, `ns.Widgets`, `HB.db.profile.window`, `HB.db.profile.companion`.
- Produces (`HB.UI`, created in Box.lua):
  - `RegisterPage{ id, title, icon, order, build(frame), refresh(frame) }`, `UnregisterPage(id)`, `ShowPage(id)`, `RefreshPage(id)` (throttled 0.25 s via AceTimer), `Toggle()`, `SetStatus(text, colorKey)`.
  - Layout per spec §5.1/5.2: title bar (icon, `HARVESTBOOK` gold Morpheus 24 pt, right status, red close), decorative gold tab under title bar (double-click collapses to title bar), sidebar left (pages sorted by `order`), content panel right. Movable by title bar, resizable (min 700×500), saves point/size/page; `tinsert(UISpecialFrames, "HarvestbookBox")`. Pages build lazily on first show. Built-in pages registered here: `window` (order 90; companion options as toggles/sliders) and `settings` (order 100; renders module switches with `Widgets.Toggle` and a RedButton "All options…" opening the AceConfig dialog).
  - `RegisterCompanionTab{ id, title, order, build(frame), refresh(frame) }`, `UnregisterCompanionTab(id)`, `RefreshCompanion()`, `ToggleCompanion()`, `SetCompanionState(text)` (in Companion.lua): ~300×230 translucent dark frame, gold `Harvestbook` title, right-aligned state text, underlined tab strip; X hides until next `HB_NODE_GATHERED` (when `autoShow`); obeys scale/alpha/lock/tabs/hideNoSession.
  - Keybindings: create `Harvestbook/Bindings.xml` (add to TOC after `embeds.xml`) with bindings `HARVESTBOOK_TOGGLE` → `Harvestbook.UI:Toggle()` and `HARVESTBOOK_COMPANION` → `Harvestbook.UI:ToggleCompanion()`, header `HARVESTBOOK`, and set `BINDING_HEADER_HARVESTBOOK`, `BINDING_NAME_HARVESTBOOK_TOGGLE = "Toggle Harvestbook"`, `BINDING_NAME_HARVESTBOOK_COMPANION = "Toggle companion"` in Box.lua.
  - LibDataBroker launcher `Harvestbook` + LibDBIcon button (left-click `Toggle`, right-click `ToggleCompanion`, tooltip shows session gold/hr if Session enabled), respecting `profile.minimap.hide`.

- [ ] **Step 1:** Implement both files.
- [ ] **Step 2:** `bash tools/check.sh` — exit 0.
- [ ] **Step 3:** Manual checklist entries: "Box opens via `/hb`, minimap button, Addon Compartment; matches TackleBox layout (compare with screenshot in spec §5.1)", "Drag, resize, close, Escape, reopen restores page/size", "Companion toggles via right-click minimap; scale/alpha/lock from Window page work".
- [ ] **Step 4:** Commit: `feat(ui): main box, companion window, minimap button`.

---

### Task 12: Modules/Session

**Files:** Modify `Harvestbook/Modules/Session.lua`

**Interfaces:**
- Consumes: `ns.SessionMath`, `ns.Format`, `HB.Pricing`, `HB.UI`, `ns.Widgets`, `HB:Listen`.
- Produces: module `Session` with `Start()`, `Pause()`, `Resume()`, `Stop()`, `Reset()`, `GetCurrent() -> session|nil`, `GetValue(session) -> copper`; fires `HB_SESSION_CHANGED(state, session)`; stopped sessions appended to `HB.db.global.sessions` (cap 500, prune oldest).
  - `OnEnable`: `SessionMath.Restore(HB.char.current, time())` if present; listen `HB_NODE_GATHERED` (auto-start if enabled and none running; `AddGather`; save to `HB.char.current`), `HB_PRICES_UPDATED` (refresh); events `PLAYER_ENTERING_WORLD` (instance pause/resume via `IsInInstance()`), `MAIL_SHOW/MAIL_CLOSED`, `AUCTION_HOUSE_SHOW/AUCTION_HOUSE_CLOSED`, `PLAYER_FLAGS_CHANGED` + `UnitIsAFK("player")`, `PLAYER_LOGOUT` (`Checkpoint`). Auto-paused sessions remember the reason and auto-resume only if they were auto-paused and `autoResume` is on. 1 s AceTimer ticker updates status text `Session running · 1:42:10` (green) / `Paused` (grey) / `No session` (grey) via `HB.UI:SetStatus`.
  - Page `session` (order 10): Start/Pause/Resume/Stop RedButtons; totals strip (time, nodes herb/ore/skin, materials, gold, gold/hr, nodes/hr); `ColumnList` columns `icon+name (LEFT, sortable)`, `count`, `per hour`, `price`, `value` (all RIGHT, sortable); quality badge via `C_Texture` atlas `Professions-Icon-Quality-Tier<q>-Small`; row hover shows `GameTooltip:SetHyperlink(link)`, price cell tooltip shows source and age; footer exactly `This session: %d materials of %d kinds, worth %s · %s/hr` (gph `—` when nil); RedButtons **Refresh prices** (calls `HB.Pricing:Refresh`), **Reset** (StaticPopup confirm), **Post to chat** (dropdown party/guild/say; one line `Harvestbook: 214 materials (9 kinds), 3,410g in 1:52:10 — 1,820g/hr`).
  - Companion tabs `session` (time, nodes, gold, gold/hr, materials, last rare from Goals via `HB_GOAL_REACHED`/attempt finds if available) and `materials` (top 8 by value: icon, count, value) and `log` (last 10 gathers: `HH:MM`, node kind icon, top item). Companion state text: `Herbalism`/`Mining`/`Skinning`/`Mixed` from session nodes, or `Paused`.
  - `OnDisable`: unregister everything, `UnregisterPage("session")`, unregister its three companion tabs, cancel ticker; data kept.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** `bash tools/check.sh` — exit 0.
- [ ] **Step 3:** Manual checklist: "Gather 5 nodes → materials list shows counts/per hour/value; footer line matches", "`/reload` mid-session → session continues, offline time not added", "Open mailbox → status Paused; close → resumes", "Stop → appears in Records history", "Toggle Session off → page/tabs vanish; on → session data intact".
- [ ] **Step 4:** Commit: `feat(session): sessions, gold per hour, materials list`.

---

### Task 13: Modules/NodeLog

**Files:** Modify `Harvestbook/Modules/NodeLog.lua`

**Interfaces:**
- Consumes: `ns.NodeGrid`, `HB.Pricing`, `HB.UI`, `ns.Widgets`.
- Produces: module `NodeLog` with `GetZone(mapID) -> zoneTable|nil`, `GetZones() -> { mapID, ... }` (sorted by name), `ForgetSpot(mapID, spotKey)`, `ForgetZone(mapID)`, `ImportGatherMate()`; fires `HB_NODELOG_CHANGED(mapID, spotKey)` after every record/forget.
  - Listens `HB_NODE_GATHERED` regardless of session state (Review Focus #1); copper via `SessionMath.NodeValue(gather, HB.Pricing:Fn())`.
  - Node display names: there is no API that names a GameObject ID, so on each gather store `global.nodeNames[objectID or npcID] = gather.targetName` (when non-nil). Display falls back to `"Node " .. id`.
  - Page `nodelog` (order 20): `Pager` over `GetZones()` starting at current zone, text `Zone name (i/n)` via `C_Map.GetMapInfo(mapID).name`; `ColumnList` columns Node, Count, Share, Avg items, Value/node (from `NodeGrid.Summarize`); click row → second list below with that node type's item breakdown; footer `This zone: %d nodes of %d kinds, worth %s` + RedButton **Forget zone** (StaticPopup).
  - Options group (via `HB:AddOptions`): **Import GatherMate2 nodes** button, disabled unless `GatherMate2` loaded; reads `GatherMate2:GetNodeDB()`-style data — inspect the installed GatherMate2 API at implementation time and record what was used in a comment; uses `NodeGrid.ImportPoint` for Herb Gathering/Mining types.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** `bash tools/check.sh` — exit 0.
- [ ] **Step 3:** Manual checklist: "Node Log shows current zone with node names, counts, share, avg items", "Pager cycles zones", "Forget zone clears it", "GatherMate2 import adds pins with 0 gathers".
- [ ] **Step 4:** Commit: `feat(nodelog): per-node yield log`.

---

### Task 14: Modules/MapPins

**Files:** Modify `Harvestbook/Modules/MapPins.lua`

**Interfaces:**
- Consumes: `NodeLog:GetZone/GetZones/ForgetSpot`, `HB_NODELOG_CHANGED`, HereBeDragons-Pins-2.0, `ns.Rankings.Zones` (zone gold/hr for tooltip), `ns.Theme.ICONS`.
- Produces: module `MapPins`. One pooled pin frame per spot per map type (world, minimap), ref keyed `mapID .. "|" .. spotKey`. World pins via `AddWorldMapIconMap(self, pin, mapID, x, y, HBD_PINS_WORLDMAP_SHOW_PARENT)`; minimap via `AddMinimapIconMap(self, pin, mapID, x, y, true, false)`. Pin texture = kind icon, size `profile.pins.size`, alpha 0.4 if `now - lastSeen > fadeDays*86400`, else 1. Filters: kinds, `minGathers` (imported cells always shown if `minGathers <= 1`).
  - Tooltip (spec §4.3): gold title = most-gathered node's name; `%d gathers here · %s per hour` (zone gph from `Rankings.Zones`, or omit the per-hour part if no data); top 4 items `Name xN`; grey `Shift-right-click to forget this spot`. Shift-right-click → `NodeLog:ForgetSpot`.
  - Rebuild all pins on enable, on `HB_NODELOG_CHANGED` (single pin), on options change; `OnDisable` → `RemoveAllWorldMapIcons(self)`, `RemoveAllMinimapIcons(self)`.
  - Options group: world, minimap, kind filters, min gathers (range 1–50), fade days (range 1–90), pin size (range 8–32).

- [ ] **Step 1:** Implement. **Step 2:** `bash tools/check.sh` — exit 0.
- [ ] **Step 3:** Manual checklist: "Pins on world map + minimap after gathering", "Tooltip matches spec", "Shift-right-click forgets", "Old pins faded (temporarily set fade days to 1 and edit lastSeen via `/run`)", "FarmHud shows pins (if installed)".
- [ ] **Step 4:** Commit: `feat(mappins): world map and minimap pins`.

---

### Task 15: Modules/Records

**Files:** Modify `Harvestbook/Modules/Records.lua`

**Interfaces:**
- Consumes: `HB_SESSION_CHANGED`, `HB_NODE_GATHERED`, `ns.SessionMath`, `ns.Format`, `ns.Widgets`.
- Produces: module `Records` with `GetSessions(filter) -> sessions` (`filter = {mapID?}`), `DeleteSession(id)`.
  - `global.records = { bestGph = {value, sessionID}, biggestNode = {value, time, itemID}, longest = {value, sessionID}, mostNodes = {value, sessionID} }`; bestGph only for sessions with ≥ 600 active seconds. On a new record fire `HB_RECORD_BROKEN(name, value)`.
  - Lifetime: on each gather add item counts to `global.lifetime[itemID]` and `global.lifetimeByChar[charKey][itemID]` (`charKey = UnitName("player") .. "-" .. GetRealmName()`); counted regardless of session state.
  - Page `records` (order 40): records block (4 lines, label gold, value white), lifetime materials `ColumnList` with **Warband / This character** toggle, session history `ColumnList` (Date, Duration, Zones, Gold, Gold/hr); clicking a session opens a read-only materials list built with `SessionMath.Rows` (frozen prices) and a RedButton **Delete session**.

- [ ] **Step 1:** Implement. **Step 2:** `bash tools/check.sh` — exit 0.
- [ ] **Step 3:** Manual checklist: "Stopping a 10+ minute session sets best gold/hr", "Warband toggle switches lifetime list", "Delete session removes it".
- [ ] **Step 4:** Commit: `feat(records): records, lifetime totals, session history`.

---

### Task 16: Modules/BestSpot

**Files:** Modify `Harvestbook/Modules/BestSpot.lua`

**Interfaces:**
- Consumes: `Records:GetSessions()`, `NodeLog:GetZone()`, `ns.Rankings`, `ns.Widgets`.
- Produces: module `BestSpot`. Page `bestspot` (order 30): two dropdowns — scope **Zones** / **Spots in current zone**; metric **Gold per hour** / **Value per node** / **Nodes per hour** (metric dropdown hidden for spots; spots always rank by value per node). `ColumnList` for zones: Zone, Time, Nodes, Gold/hr, Value/node, Nodes/hr; for spots: Spot (`x, y` as `45.2, 61.0`), Kind icon, Gathers, Value/node. Low-data rows grey with `(low data)` suffix. Clicking a spot row → `C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))`, `C_SuperTrack.SetSuperTrackedUserWaypoint(true)`, open world map to that map. Refresh on `HB_SESSION_CHANGED("stopped")` and `HB_NODELOG_CHANGED`.

- [ ] **Step 1:** Implement. **Step 2:** `bash tools/check.sh` — exit 0.
- [ ] **Step 3:** Manual checklist: "Zones ranking after two sessions in different zones", "Spot click sets waypoint and opens map".
- [ ] **Step 4:** Commit: `feat(bestspot): zone and spot rankings`.

---

### Task 17: Modules/Goals

**Files:** Modify `Harvestbook/Modules/Goals.lua`

**Interfaces:**
- Consumes: `ns.GoalEval`, `Session:GetCurrent()`, `HB.Pricing:Fn()`, `HB_NODE_GATHERED`, `HB_SESSION_CHANGED`.
- Produces: module `Goals`; fires `HB_GOAL_REACHED(goal)` (once per goal per session; `reached` set reset on new session) and `HB_RARE_FOUND(itemID, attemptsBeforeFind)`.
  - Goals stored in `profile.goals.list`; attempts in `global.goals.attempts`.
  - Page `goals` (order 50): **Session goals** — list of `ProgressBar`s with delete X; add row: type dropdown (Materials / Gold / Minutes), item input (accepts Shift-clicked link via `ChatEdit_InsertLink` hook when the input has focus; blank = any material), target number, RedButton **Add goal**. **Rare drops** — `ColumnList` (Item, Attempts, Found, Last found `N gathers ago`), add via the same link input + kind dropdown (Any/Herb/Ore/Skin), delete per row.
  - Adds goal bars to the companion `session` tab via `HB.UI:RefreshCompanion()` (Session tab reads `Goals:GetBars()` if Goals enabled → `{ {label, current, target} }`).

- [ ] **Step 1:** Implement (add `Goals:GetBars()` read into Session's companion tab — Task 12 file — guarded by module enabled check).
- [ ] **Step 2:** `bash tools/check.sh` — exit 0.
- [ ] **Step 3:** Manual checklist: "Gold goal bar fills and fires once", "Shift-click item into rare input adds tracker; attempts increment per gather".
- [ ] **Step 4:** Commit: `feat(goals): session goals and rare-drop attempt counters`.

---

### Task 18: Modules/Alarms

**Files:** Modify `Harvestbook/Modules/Alarms.lua`

**Interfaces:**
- Consumes: `ns.AlarmEval`, `HB_NODE_GATHERED`, `HB_GOAL_REACHED`, `HB_RARE_FOUND`, `HB_RECORD_BROKEN`, `Session:GetCurrent()`, LibSharedMedia-3.0 (optional, `LibStub("LibSharedMedia-3.0", true)`).
- Produces: module `Alarms`. For each rule fire: `PlaySound(soundKitID, "Master")` or `PlaySoundFile(lsmPath, "Master")` per rule's chosen sound; text via `RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo["RAID_WARNING"])`; optional screen-edge flash (full-screen gold-tinted texture fading out over 0.6 s). Node alarm ctx uses `SessionMath.NodeValue` and session average (session value ÷ total nodes).
  - Built-in sound list: `{ ["Raid warning"]=8959, ["Ready check"]=8960, ["Coin"]=120, ["Quest complete"]=878, None=nil }`.
  - Page `alarms` (order 60): per rule row — enable toggle, threshold inputs (gold / multiple / min nodes), sound dropdown, flash toggle, **Test** RedButton; global master mute toggle.

- [ ] **Step 1:** Implement. **Step 2:** `bash tools/check.sh` — exit 0.
- [ ] **Step 3:** Manual checklist: "Test button plays each sound and shows text", "Value alarm fires on a high-value node; no repeat within 2 s", "Mute silences all".
- [ ] **Step 4:** Commit: `feat(alarms): value, rare, goal and record alarms`.

---

### Task 19: Final integration pass

**Files:** Modify `docs/testing/manual-checklist.md`; Create `README.md`

- [ ] **Step 1:** Add to checklist the cross-module items: "Toggle each module off/on without `/reload`; dependents grey out and auto-disable (e.g. NodeLog off → MapPins and BestSpot off)", "With all modules off except Session the box shows Session, Window, Settings only", "Settings export string → import on a second character restores settings", "Angler's TackleBox installed alongside → no conflicts, no shared globals (`/dump Harvestbook` only)".
- [ ] **Step 2:** `README.md`: what it is, install (copy `Harvestbook/` to `World of Warcraft/_retail_/Interface/AddOns/`), slash commands from spec §7, module list, how to run tests (`bash tools/check.sh`).
- [ ] **Step 3:** Run `bash tools/check.sh` — exit 0. Run `grep -rnE '\b(setglobal|_G%[)' Harvestbook/{Core,Logic,UI,Modules}` and confirm no globals other than `Harvestbook`, `Harvestbook_OnAddonCompartmentClick`, `HarvestbookBox`, `HarvestbookCompanion`, StaticPopup keys `HARVESTBOOK_*`, and binding globals.
- [ ] **Step 4:** Commit: `docs: README and manual test checklist`.
