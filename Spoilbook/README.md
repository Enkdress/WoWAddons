# Spoilbook

Tracks Uncommon+ loot drops per dungeon/raid run: what dropped, whether you looted it (or who won the roll), a lifetime loot table per place, and a wishlist with drop alerts.

Targets the **WoW Forever** client (Interface 16001).

## Usage

- `/spoilbook` — toggle the panel
- `/spoilbook test` — seed fake session data, for testing the UI without a live dungeon run (uses a real item ID so icons/tooltips resolve; doesn't exercise the live loot-detection pipeline)

Minimap button (draggable) also toggles the panel; can be hidden in Settings.

## Known limitations

- No cross-computer sync: session history lives in this client's local SavedVariables (`WTF/Account/<Account>/SavedVariables/Spoilbook.lua`) and isn't shared between machines.
- Can't backfill runs from before the addon was installed — WoW doesn't expose historical loot data to addons.
- Built against an early, evolving client (WoW Forever beta); several Blizzard API calls that exist on retail turned out to be missing here (`GetLootSlotType`, `GetItemQualityColor`, `GetItemIcon`, the bare `GetItemInfo`/`GetItemInfoInstant` globals). Spoilbook works around these, but future client updates could reintroduce similar gaps.
