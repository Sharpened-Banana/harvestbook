# Harvestbook manual test checklist

In-game checks for code that cannot run under the unit test runner.

## Before you start
- [ ] Enable `/console scriptErrors 1` so Lua errors show on screen
- [ ] Optional: install BugSack + BugGrabber to capture errors with stack traces
- [ ] Optional: install Auctionator and/or TradeSkillMaster, GatherMate2 and FarmHud to exercise the integrations

### In-game API verification
Every "Verify:" item below, by section (the original entries stay in their sections):
- Pricing, gather detection, options: Skinning spell ID 8613 matches; note any Midnight herb/skin spell IDs printed by debug
- Pricing, gather detection, options: reagent quality returns 1/2 for Midnight reagents
- Pricing, gather detection, options: loot source GUID not secret (objectID non-nil)
- Session: quality badge atlas `Professions-Icon-Quality-Tier<q>-Small` renders for tier 1/2 reagents
- Session: Post to chat menu greys Party/Guild when not grouped / guildless; Say posts the one-line summary
- Node Log: GatherMate2 `gmdbs[...].__gm2_base_storage` / `GetNodesForZone` / `DecodeLoc` behave as the comment in NodeLog.lua assumes
- Node Log: Forget zone StaticPopup passes the mapID through to OnAccept
- Map Pins: pin texture masks (`Interface\CharacterFrame\TempPortraitAlphaMask`) render a round icon with dark rim on both maps
- Map Pins: Map Pins options (kind filters, min gathers, fade days, size) rebuild pins immediately; toggling Map Pins off removes all pins
- Best Spot: ColumnList renders `|cff9d9d9d` color escapes in cells; Format.Money output also greys with them

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
- [ ] Gather once, then wait 5 min without gathering → session ends on its own, chat says it was saved; its time in Records ends at the last gather
- [ ] Companion appears on the first gather and hides when the session ends
- [ ] Companion Materials tab rows read "Name ◆ x12" (quality badge after the name for tiered reagents, none otherwise); two qualities of one reagent are separate rows; long names truncate before the value
- [ ] Companion Log tab shows the quality badge after each item name
- [ ] Options → Pricing → "Subtract the auction house cut (5%)" on → Auctionator/TSM prices and gold/hr drop 5% at once, vendor prices unchanged; Price tooltip says "after the 5% auction house cut"
- [ ] Gather, log out, log back in → chat says last login's session was saved to history; no session running until the next gather
- [ ] Same with "Keep the session across logouts" on → session continues after login
- [ ] Toggle Session off → page/tabs vanish; on → session data intact
- [ ] **Verify:** Silver and Gold reagents show Midnight's own Silver / Gold badges (from `C_TradeSkillUI.GetItemReagentQualityInfo`) on the Session page and the companion Materials tab
- [ ] **Verify:** Post to chat menu greys Party/Guild when not grouped / guildless; Say posts the one-line summary

## Node Log (Task 13)
- [ ] Node Log shows current zone with node names, counts, share, avg items
- [ ] Pager cycles zones (sorted by name); prev/next grey out at the ends
- [ ] Clicking a node row shows its item breakdown (Item, Count, Per node) below
- [ ] Forget zone asks to confirm, then clears the zone and moves the pager on
- [ ] GatherMate2 import adds pins with 0 gathers (herb and ore only); button greyed without GatherMate2
- [ ] **Verify:** GatherMate2 `gmdbs[...].__gm2_base_storage` / `GetNodesForZone` / `DecodeLoc` behave as the comment in NodeLog.lua assumes
- [ ] **Verify:** Forget zone StaticPopup passes the mapID through to OnAccept

## Venom Clots (Coiled Isle, 12.1)
- [ ] During a Curse Surge, gather a Venomous node, then run into a green puddle → Neutralized Venom Clot appears in the Session materials with its value; the node count does not go up again
- [ ] With `/hb debug` on, the chat shows `HB_BONUS_LOOT ... item=274777`
- [ ] **Verify:** the clot arrives as a "You receive item" loot line (LOOT_ITEM_PUSHED_SELF) within 3 min of the gather; if it arrives later, raise GatherParse.BONUS_WINDOW
- [ ] **Verify:** Overload Infused Deposit / Herb on a Cursed node is counted (it may use an item spell Harvestbook does not recognise yet)

## Map Pins (Task 14)
- [ ] Pins on the world map after gathering; none on the minimap by default (the game's own tracking icons only)
- [ ] Map Pins → "Show on minimap" on → pins appear on the minimap; off → they vanish at once
- [ ] Minimap pins are see-through (60% by default) so the game's own node icons show underneath; the opacity slider changes them at once; world map pins stay solid
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
- [ ] Records page readable at 700x500 (no clipped columns)
- [ ] After Delete session, the page returns to the history list

## Task 16: Best Spot
- [ ] Zones ranking after two sessions in different zones
- [ ] Spot click sets waypoint and opens map
- [ ] Metric dropdown re-sorts zones and is hidden for the Spots scope; scope/metric persist across /reload
- [ ] Rows under 15 min (zones) or 5 gathers (spots) are grey with "(low data)" and sort last
- [ ] Empty zone shows "No spots recorded in this zone yet."
- [ ] Best Spot readable at 700×500
- [ ] **Verify:** ColumnList renders `|cff9d9d9d` color escapes in cells; Format.Money output also greys with them

## Routes
- [ ] Routes appears in the sidebar under Best Spot and in the Settings module toggles; the sidebar still fits at 700x500
- [ ] Pager opens on the current zone; after paging it stays put across a zone change, otherwise it follows the player
- [ ] Herbs / Ore / Skinning and Minimum gathers change which spots Build uses; no match prints a chat notice and keeps the current route
- [ ] Build shows the stop count and the stops in order (number, node name, gathers); at most 30 stops
- [ ] World map shows numbered stops and small dots along every leg, including the leg back to stop 1; no pins on the minimap
- [ ] **Verify:** stop numbers draw above Map Pins at the same position, and Map Pins tooltips and shift-right-click still work through route pins and dots
- [ ] **Verify:** `Ability_Hunter_Pathfinding` icon shows in the sidebar
- [ ] Next stop sets a waypoint on stop 1, then 2, and wraps to 1 after the last; the map does not open; status line shows the stop
- [ ] Route and waypoint position survive /reload; pins are back without opening the page
- [ ] `/run HarvestbookCharDB.route = "junk"` then /reload shows no route and no error
- [ ] Clear route removes all route pins; Map Pins stay
- [ ] Turning Routes off removes its pins and page; on again restores the route. Node Log off also turns Routes off
- [ ] Reset all data removes the route and its pins, even when choosing "Later" on the reload prompt
- [ ] Routes page readable at 700x500

## Gear Comparison
- [ ] Gear appears in the sidebar after Gold and in the Settings module toggles (as Gear Comparison); the sidebar still fits at 700x500
- [ ] With no sessions, the page shows the empty message and the grey note; the dropdown offers only All zones
- [ ] Start a session: `/dump Harvestbook.char.current.gear` shows a `sig` and your equipped profession tool and accessories (slots 20-25) with links
- [ ] Pause and resume, or `/reload` during a session: `gear` is not replaced, even after swapping gear
- [ ] A session with nothing in the profession slots gets an empty `sig` and shows as "No profession gear"
- [ ] Finish a session over a minute: it appears as a row; label is the tool's name plus "+N" for the rest
- [ ] Hover a row: the tooltip lists the set's items, and it hides on leaving the row
- [ ] Finish sessions with two gear sets: best gold/hr is first and says "Best", the other shows a negative percent; gold/hr matches total value over total time
- [ ] A session under a minute is not counted; sessions saved before this version show as "N sessions: no gear data"
- [ ] Zone dropdown shows map names of zones in the data; choosing one keeps only sessions mostly gathered there, including the no gear data count
- [ ] Delete the only session of the chosen zone in Records: the filter goes back to All zones
- [ ] Turning the module off removes the page and new sessions get no `gear`; on again, old sets are still there. Session off also turns it off
- [ ] Page readable at 700x500: columns not clipped, note fits on two lines, list starts below it

## Trends
- [ ] Trends appears in the sidebar after Gear and in the Settings module toggles; the sidebar still fits at 700x500
- [ ] With no history, the chart area says no prices are recorded yet, the list is empty and the grey note shows
- [ ] With Auctionator or TSM: gather a node, then `/dump Harvestbook.db.global.priceHistory` shows `itemID:quality` with today's date and the price; bonus loot is recorded too
- [ ] Recorded price equals `/dump Harvestbook.db.global.prices["itemID:quality"].value`, with the auction house cut on and off
- [ ] An item priced only by a vendor or by a manual override gets no history entry
- [ ] With no price addon, or while it has not initialised (`prices` has no entry for the item), nothing is recorded and nothing errors
- [ ] Gather the same item twice on a day with a changed price (`/hb prices` between): one entry, the last price
- [ ] A cached price from an earlier day (edit `prices[...].time`) is recorded under that day, not today
- [ ] One day of data: the chart says it needs two days and shows no line or labels, the row shows grey dashes for both changes
- [ ] Edit saved variables to give an item 40 days: line drawn left to right, oldest date lower left, newest lower right, highest and lowest price labels correct, gaps wide where days are missing, dots on each recorded day
- [ ] A flat history draws a level line mid-height with equal min and max labels
- [ ] Changes: rises green with "+", falls red with "-", no data a grey dash; click each header: sorts, click again reverses, dashes stay last
- [ ] Default selection is the item with the most history; click a row: its name turns gold and the chart switches
- [ ] Item column shows the icon and quality badge; a not-yet-loaded name fills in on its own
- [ ] Resize the window with a chart showing: the line redraws to fit, no stray segments
- [ ] Turning the module off removes the page and gathers add nothing; on again, the history is still there
- [ ] Reset all data empties the page, even when choosing "Later" on the reload prompt, and `priceHistory` is `{}`
- [ ] Page readable at 700x500: columns not clipped, note fits on two lines, list has several rows, money labels not overlapping the plot

## Shopping
- [ ] Shopping appears in the sidebar after Routes and in the Settings module toggles; the sidebar and the Settings page still fit at 700x500
- [ ] Empty list: the page shows the empty text and the grey note; Remove and Clear all are disabled
- [ ] Focus the item box and Shift-click an item in your bags: the link fills the box, with the Goals module on and off; enter a target, press Add: the row appears and the boxes clear
- [ ] Type an item ID instead: added the same way, with icon and quality badge; a not-yet-loaded name fills in on its own
- [ ] Bad input gets a chat message and adds nothing: empty item box, "abc", an item ID that does not exist, target empty, 0, -5, "1e5", "2.5", "250k"
- [ ] Adding a listed item again changes its target, no second row; a 31st item is refused with a message, while changing a target on the full list still works
- [ ] Have equals your bags + bank + reagent bank + warband bank; a stack only in the bank or warband bank is counted (bank closed too, after a /reload)
- [ ] A Have value updates within a second of looting, banking, or a gather, with the page showing
- [ ] Best zone: an item logged in two zones shows the higher average once each has 5+ gathers of its node; with fewer everywhere, the most-gathered zone; never gathered shows grey dashes
- [ ] Nodes shows remaining / average rounded up (compare with Node Log's "Per node"); finished rows show a green Done and sort below unfinished rows, each group by name
- [ ] Forget the best zone on the Node Log page: the zone column moves on or dashes out
- [ ] Click a row: its name turns gold and Remove enables; Remove takes that row and disables again
- [ ] Clear all asks first; Cancel keeps the list, Yes empties it
- [ ] Notice: with the page closed, loot your way past a target: one chat line, once, within a second; more of the item prints nothing
- [ ] Spend below the target and gather back past it: one more line
- [ ] No notice for items already done at login or /reload (wait 10 s after it), for a target lowered to below Have, or for adding an item you already have enough of. A target raised above Have, then gathered past, does notify
- [ ] The list is the same on a second character (same warband); that character's Have shows its own counts plus the warband bank
- [ ] `/hb shopping` opens the page; with the module off it says so and opens nothing
- [ ] Turning the module off removes the page and stops notices; on again, the list is still there and no notice fires for what was done meanwhile
- [ ] Reset all data empties the page, even when choosing "Later" on the reload prompt
- [ ] Page readable at 700x500: columns not clipped, note fits on two lines, list has several rows

## Alarms (Task 18)
- [ ] Test button plays each sound and shows text
- [ ] Value alarm fires on a high-value node; no repeat within 2 s
- [ ] Mute silences all
- [ ] Alarms page usable at 700×500

## Cross-module (Task 19)
- [ ] Toggle each module off/on without `/reload`; dependents grey out and auto-disable (e.g. Node Log off -> Map Pins and Best Spot off)
- [ ] With all modules off except Session the box shows Session, Window, Settings only
- [ ] Settings export string -> import on a second character restores settings
- [ ] Resize to 700×500 and visit every page — no clipped columns or text past the window edge.
- [ ] Angler's TackleBox installed alongside -> no conflicts, no shared globals (`/dump Harvestbook` only)

## CSV export
- [ ] Records page at 700×500: Export button sits right of "Lifetime materials", overlaps nothing, and does not cover the list below
- [ ] Export button and `/hb export` both open the window, text highlighted and focused; Ctrl+C / Cmd+C then paste into a spreadsheet gives one row per line with correct columns
- [ ] Dropdown switches Sessions / Materials / Gold above the window (menu not hidden behind it), and the new text is highlighted and focused
- [ ] Gold exports the period chosen on the Gold page
- [ ] Typing, pasting, Enter and Ctrl+X in the box all restore the data
- [ ] Escape closes the window with the box focused and after clicking outside it; Close closes it; chat typing works afterwards
- [ ] Window drags by its background, stays on screen, and scrolling with the wheel and scroll bar reaches the last row
- [ ] A large history (up to 500 sessions) opens without a noticeable hang
- [ ] A zone or item name with a comma stays in one cell; a name starting with `=` shows as text
- [ ] Records off: `/hb export` prints the notice, an open export window closes

## Translations

Switch the client language in the Battle.net launcher, or test with the `SET textLocale` line in `Config.wtf`.

- [ ] deDE, frFR, esES/esMX, ptBR, itIT: every page's headers, buttons and dropdowns are translated and fit (Session totals, Alarms threshold row, Routes kind toggles, sidebar).
- [ ] ruRU: titles, headings, body text, buttons and the companion show Cyrillic, no blanks or squares; the title font is the game's standard font.
- [ ] koKR or zhCN: everything shows in English and the addon loads with no error.
- [ ] `/hb help` lists translated text with the commands themselves unchanged, and each command still works.
- [ ] Alarms: Test on each rule shows translated text; a sound chosen before switching language is still selected and plays; a real rare/goal/record alarm reads correctly.
- [ ] Records > Export: the CSV headers and the gold "Week of" labels stay English while the dropdown text is translated.
- [ ] Post to chat sends the translated line; settings Import failure shows a translated reason.
- [ ] Settings panel (All options) names and descriptions are translated; profile export/import between languages keeps all settings.
