# Known issues

Small issues set aside during development. None of them block normal use. They were recorded while 1.0.0 was being built and have not all been rechecked since, so file and line references may be out of date.

## Since 1.1.0

- Venomous nodes aren't logged as gathers or counted as nodes; only their Neutralized Venom Clots are counted.
- Gear comparison groups sets by item ID, so a better crafted quality of the same item doesn't count as new gear.
- Sessions saved before 1.1.0 keep inflated Coiled Isle zone node counts from Venom Clots.
- Translations are machine-written, and whether they fit their columns and buttons hasn't been fully checked.
- Unlisted items are looked up again on every price read while TSM or Auctionator is loaded.
- `ToggleCompanion` misbehaves when the companion has no tabs.
- The `4g 3c` money format has no test.

## From the 1.0.0 build

- run.lua describe-throw doesn't unwind stack/befores (run.lua:415-421)
- has_error ignores message; can't distinguish assertion vs typo errors
- spec discovery via io.popen("ls")
- check.sh TOC lines not trimmed (trailing spaces → false MISSING)
- check.sh doesn't syntax-check tests/*.lua
- LibDBIcon fetched from mutable SVN trunk, not pinned to r166
- GoldPerHour/perHour divide-before-multiply float drift (SessionMath.lua:220,236) — use value*3600/active
- time before first gather not attributed to any zone; Restore zoneSince when currentMap nil (SessionMath.lua:160-164)
- nil quality stored under "id:0" — Rows consumers must tolerate nil quality
- perHour nil <60s — Session UI must render "—"
- test gaps: Summary, Rows perHour/link, name sort, Resume/Checkpoint zone, Stop-from-paused, Money(0,"full")
- Summarize row kind nondeterministic if same id under two kinds (NodeGrid.lua:77-80)
- forgetting plain cell while ":kind" sibling remains → next gather creates plain spot beside it
- x or y == 1.0 → cell 50 (theoretical)
- no tests for suffixed ImportPoint or real gather clearing imported flag
- src.fn read outside pcall — nil/non-table entry in sources throws (PriceChain.lua:20-21)
- no test for inf
- minSeconds/minGathers no defaults (Rankings.lua:53,68); spot.copper not nil-guarded
- nil-ordering only tested for gph
- AlarmEval ctx.label/state/now unguarded; v.gold assumed non-nil (AlarmEval.lua:22-45)
- minutes goal progress fractional — UI must format
- Migrate.Run has no pcall — failing migration propagates (DB.lua caller must know); redundant schemaVersion write
- no tests for schemaVersion > #migrations or throwing migration
- enabling a dependency doesn't bring back profile-enabled dependents until reload/profile change (Init.lua:269-283) — consider ApplyModuleStates() after enable
- cascade skips runtime-inactive dependents; profile flag stays true (Init.lua:286-290)
- pricing.order list in AceDB defaults — removed entries come back (carry to Task 9: Options must only reorder, never remove)
- debugstack(2) level cosmetic
- Reset all data swaps global tables under live modules if user chooses Later; resets active profile only (Options.lua:254-262)
- import type-checks top-level keys only (Options.lua:228-234)
- Auctionator ByItemLink nil → no ByItemID fallback
- pending w/o castGUID could be cleared by an old cast's FAILED (unlikely); verify FAILED/INTERRUPTED arg order + castGUID stability in-game
- 16 px dead strip when scrollbar hidden (Widgets.lua:346)
- SetRows/Refresh recreate wrappers → hover leave/enter churn (Widgets.lua:358-361)
- ProgressBar fill covers 1 px border; "0/0" text on empty bar
- hardcoded header highlight color (Widgets.lua:321)
- Box.lua 742 lines — split Window/Settings pages + slider + launcher into UI/Pages.lua (Box.lua:449-712)
- re-registering the shown page bounces to first page (Box.lua:363,375-393)
- ToggleCompanion while hidden by hideNoSession can't toggle off (Companion.lua:278-289) — toggle on db().shown
- companion opacity fades text too (Companion.lua:200)
- retired frames orphaned when build differs; companion scale change moves frame
- auto-pause only reacts to condition start; session started inside an instance/AFK isn't paused (Session.lua:243-269)
- no C_ChatInfo.InChatMessagingLockdown check before Post to chat (Session.lua:537-545)
- price tooltip reads global.prices directly instead of HB.Pricing:GetCached (Session.lua:393)
- Session.lua 751 lines — companion tabs (:568-695) could move to own file
- sort direction not persisted; status "" after OnDisable
- footer total from valuePerNode*count float (off-by-1c); HB_PRICES_UPDATED refresh is wasted work; ForgetZone resets pager to player zone
- fade evaluated only on update; (mapID,nil) triggers full rebuild
- world map hook not retried if WorldMapFrame absent at first enable (Blizzard_WorldMap is load-on-demand in some builds — verify in-game)
- detailID persists across page hide/show (Records.lua:24)
- vertical fit at 700×500 unverified (records block + 120 px lifetime + history stacked); narrower columns may truncate
- "(low data)" suffix clips in 125 px zone column (BestSpot.lua:40,54); ZONE_CHANGED_NEW_AREA callback not SafeCall-wrapped (:238)
- Goals HB_NODE_GATHERED may evaluate before Session adds the gather (order undefined) → goal fires up to 5 s late
- item box visible for gold/minutes goals
- disable→re-enable Goals mid-session: goals met while disabled fire once (sessionID matches, no seeding)
- long LSM dropdown; gold goal label "Gold goal (Ng)"
- README omits keybindings/compartment; checklist prefix repetition
