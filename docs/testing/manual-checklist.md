# Harvestbook manual test checklist

In-game checks for code that cannot run under the unit test runner.

## Core (Task 8)
- [ ] Addon loads with no errors (enable `/console scriptErrors 1`)
- [ ] `/hb help` lists commands
- [ ] `/hb debug` toggles debug

## Pricing, gather detection, options (Task 9)
- [ ] `/hb debug` then gather an herb, an ore, a skin, with auto-loot ON and OFF — one payload line each, correct kind, objectID/npcID present
- [ ] With Auctionator only / TSM only / neither — prices resolve, source shown
- [ ] **Verify:** Skinning spell ID 8613 matches; note any Midnight herb/skin spell IDs printed by debug
- [ ] **Verify:** reagent quality returns 1/2 for Midnight reagents
- [ ] **Verify:** loot source GUID not secret (objectID non-nil)
- [ ] Gathering inside an instance prints "dropped: no map position" in debug and fires nothing
- [ ] `/hb config` and Esc → Options → AddOns → Harvestbook both show General / Data / Profiles tabs
- [ ] Turning Node Log off greys out Map Pins and Best Spot ("Requires Node Log")
- [ ] Price source slots: choosing a source swaps it with the slot; all four always remain
- [ ] Export string → Import on another profile → confirm popup → settings applied
- [ ] Reset all data: two confirmations, then reload prompt; after reload Node Log / sessions empty

## Box, companion, minimap button (Task 11)
- [ ] Box opens via `/hb`, minimap button, Addon Compartment; matches TackleBox layout (compare with screenshot in spec §5.1)
- [ ] Drag, resize, close, Escape, reopen restores page/size
- [ ] Companion toggles via right-click minimap; scale/alpha/lock from Window page work
- [ ] Keybindings (Esc → Options → Keybindings → AddOns → Harvestbook) toggle the box and companion
- [ ] Double-clicking the gold tab under the title bar collapses to the title bar and expands again
- [ ] Settings page: turning Node Log off greys Map Pins / Best Spot with "Requires Node Log"; "All options…" opens the options dialog
- [ ] Companion X hides it; with "Show automatically when gathering" on, the next gather shows it again
- [ ] "Hide when no session is active": companion hides after `/hb stop`, shows on next session start
- [ ] Minimap tooltip shows Gold/hr while a session exists; "Show minimap button" option hides/shows it

## Session (Task 12)
- [ ] Gather 5 nodes → materials list shows counts/per hour/value; footer line matches
- [ ] `/reload` mid-session → session continues, offline time not added
- [ ] Open mailbox → status Paused; close → resumes
- [ ] Stop → appears in Records history
- [ ] Toggle Session off → page/tabs vanish; on → session data intact
- [ ] **Verify:** quality badge atlas `Professions-Icon-Quality-Tier<q>-Small` renders for tier 1/2 reagents
- [ ] **Verify:** Post to chat menu greys Party/Guild when not grouped / guildless; Say posts the one-line summary

## Node Log (Task 13)
- [ ] Node Log shows current zone with node names, counts, share, avg items
- [ ] Pager cycles zones (sorted by name); prev/next grey out at the ends
- [ ] Clicking a node row shows its item breakdown (Item, Count, Per node) below
- [ ] Forget zone asks to confirm, then clears the zone and moves the pager on
- [ ] GatherMate2 import adds pins with 0 gathers (herb and ore only); button greyed without GatherMate2
- [ ] **Verify:** GatherMate2 `gmdbs[...].__gm2_base_storage` / `GetNodesForZone` / `DecodeLoc` behave as the comment in NodeLog.lua assumes
- [ ] **Verify:** Forget zone StaticPopup passes the mapID through to OnAccept

## Map Pins (Task 14)
- [ ] Pins on world map + minimap after gathering
- [ ] Tooltip matches spec (gold node name, "N gathers here · Xg per hour", top 4 items, grey hint; imported cells say "Imported from GatherMate2")
- [ ] Shift-right-click forgets (pin disappears from world map and minimap)
- [ ] Old pins faded (temporarily set fade days to 1 and edit lastSeen via `/run`)
- [ ] FarmHud shows pins (if installed)
- [ ] **Verify:** pin texture masks (`Interface\CharacterFrame\TempPortraitAlphaMask`) render a round icon with dark rim on both maps
- [ ] **Verify:** Map Pins options (kind filters, min gathers, fade days, size) rebuild pins immediately; toggling Map Pins off removes all pins

## Task 15: Records
- [ ] Stopping a 10+ minute session sets best gold/hr
- [ ] Warband toggle switches lifetime list
- [ ] Delete session removes it
- [ ] Clicking a history row opens its frozen-price materials list; "< Back" returns
- [ ] Beating an existing record (not the first value) fires an alarm/HB_RECORD_BROKEN
