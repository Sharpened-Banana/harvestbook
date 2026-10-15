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
