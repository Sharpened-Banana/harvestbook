# Changelog

## 1.1.0

New:

- **Gold page**: your all-time gold earned with a goal bar (type `5m` for 5 million) and an alarm when you reach it, plus gold per day, per daily reset or per weekly reset. Your existing session history is counted the first time. It's the estimated value of what you gathered, on all characters.
- **Routes**: builds a farming loop for a zone from your own node log, with numbered stops on the world map and a Next stop waypoint button.
- **Shopping list**: "I need 200 of this", with progress, your best zone for it and how many nodes are left.
- **Gear comparison**: gold per hour for each set of profession gear you've used, across real sessions.
- **Price trends**: records the price of what you gather and charts it, with 7-day and 30-day changes.
- **CSV export**: copy sessions, materials or gold into a spreadsheet with `/hb export`.
- **Translations**: German, French, Spanish, Brazilian Portuguese, Italian and Russian. These are machine-written, so corrections are welcome.
- Harvestbook's own icon in the addon list.

Fixed:

- A session now carries on after a disconnect or a relog within 15 minutes.
- Item names load on their own instead of staying "Item 12345".
- Gather detection no longer depends on spell names being loaded at your first cast.
- Goal boxes reject values like `1e5` and accept `250k` or `5m` for gold.
- Deleting a session recalculates any record it held.
- Neutralized Venom Clots are always counted, even during pure venom farming with no other gathers nearby, and one can start a session.
- Neutralized Venom Clots no longer count as extra nodes in zone stats. Sessions saved before this update keep their old counts.
- The sidebar fits the smallest window size.

## 1.0.0

First release.

- **Session window** in the style of Angler's TackleBox: every material gathered with its quality, count, per hour and value, plus total gold and gold per hour.
- **Sessions run themselves**: they start on your first gather and end after 5 minutes without one (adjustable). Their time ends at your last gather, so idle minutes don't lower gold/hr. A session left open at logout is saved to history at your next login.
- **Companion window** with Session, Materials and Log tabs; it shows while you gather and hides when the session ends.
- **Prices** from Auctionator, TradeSkillMaster or vendor, in the order you choose, with an optional 5% auction house cut.
- **Node Log** per zone, with GatherMate2 import.
- **World map pins** with gold/hr tooltips; minimap pins are optional and see-through.
- **Best Spot** rankings, **Records**, **Goals** and **Alarms**.
- Midnight's Silver and Gold reagent qualities.
- Neutralized Venom Clots from Venomous nodes on the Coiled Isle are counted with the gather.
