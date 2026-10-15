# Harvestbook

An all-in-one gathering addon for World of Warcraft Retail (12.1.x) covering herbalism, mining and skinning. Its window is modelled on Angler's TackleBox: one tabbed box plus an optional small companion window.

**Status:** v1 - not yet verified in-game; see `docs/testing/manual-checklist.md`.

## Features

Every module can be toggled in Settings. Disabling a module never deletes its data, and modules that depend on another grey out automatically.

- **Session** - gold per hour and a materials list (counts, per hour, value). Auto-pauses at the mailbox, auction house, when AFK and in instances; survives `/reload`.
- **Node Log** - per-zone log of every node gathered: names, counts, share and average items, with an item breakdown per node.
- **Map Pins** - pins on the world map and minimap for logged nodes, with gold/hr tooltips and fading for old pins.
- **Best Spot** - ranks zones and individual spots by gold/hr or other metrics; click a spot to set a waypoint.
- **Records** - best sessions, lifetime totals (per character or warband) and session history.
- **Goals** - session goals (materials, gold, minutes) and rare-drop attempt counters.
- **Alarms** - sound and text alerts for valuable nodes, goals and broken records.

## Install

Copy the `Harvestbook/` folder into `World of Warcraft/_retail_/Interface/AddOns/`, then restart the game or `/reload`.

## Slash commands

`/harvestbook` works as an alias for `/hb`.

| Command | Action |
|---|---|
| `/hb` | Toggle the window |
| `/hb start` / `pause` / `resume` / `stop` | Control the current session |
| `/hb reset` | Reset the session (asks for confirmation) |
| `/hb companion` | Toggle the companion window |
| `/hb config` | Open all options |
| `/hb prices` | Refresh prices for the current session |
| `/hb debug` | Toggle debug output (prints every gather payload) |
| `/hb help` | List commands (any unrecognised command also shows it) |

Session commands print a notice if the Session module is disabled.

## Optional integrations

All are optional and detected at runtime.

- **Auctionator** or **TradeSkillMaster** - item prices (price source order is configurable).
- **GatherMate2** - one-click import of herb and ore locations into the Node Log (0 gathers).
- **LibSharedMedia** - extra alarm sounds.
- **FarmHud** - pins appear on it via HereBeDragons.

## Development

- `bash tools/check.sh` - Lua syntax check, TOC check and the unit tests (`luajit tests/run.lua`).
- `bash tools/fetch-libs.sh` - refresh the vendored libraries in `Harvestbook/libs/`.

Layout under `Harvestbook/`:

- `Logic/` - pure Lua with no WoW API access (session math, node grid, price chain, rankings, goal/alarm evaluation, migrations); fully unit-tested in `tests/`.
- `Core/` - addon object, saved variables, gather detection, pricing, options, slash commands.
- `UI/` - theme, widgets, the main box and the companion.
- `Modules/` - Session, NodeLog, MapPins, BestSpot, Records, Goals, Alarms.

Design spec: `docs/superpowers/specs/2026-10-15-harvestbook-v1-design.md`.
