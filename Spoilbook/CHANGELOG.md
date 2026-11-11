# Changelog

All notable changes to Spoilbook are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/), versioning follows
[Semantic Versioning](https://semver.org/).

## [0.1.0]

Initial release, targeting the WoW Forever client (Interface 16001).

### Added
- Automatic session tracking: entering a dungeon/raid starts a run, leaving ends it (with a grace period so dying/corpse-running doesn't cut a run short); a run with zero drops is discarded automatically.
- Loot capture for Uncommon+ drops (configurable minimum quality), attributed to the most recent boss kill or "Trash & Chests", from your own loot window, group-visible loot chat, and the Need/Greed roll popup (so items you only roll on, never personally loot, still get recorded).
- Tracks whether *you* looted each drop, and who did if someone else won the roll.
- **Places** tab: every instance you've visited, with run count and lifetime seen/looted totals; drill in for a boss-grouped lifetime loot table or that place's own run history, both as collapsible (accordion) sections.
- **Runs** tab: every session across every place, grouped by place, each run drillable into its full drop list.
- **Wishlist**: star any seen item; get an alert banner when it drops, with a dedicated tab showing every wishlisted item's status (owned / seen-not-looted / not seen), grouped by place.
- **Settings**: minimum quality filter, track-dungeons/track-raids toggles, wishlist alerts toggle, minimap button toggle, reset-all-data.
- Minimap button (draggable) and `/spoilbook` slash command to toggle the panel; `/spoilbook test` seeds fake session data for UI testing without needing a live dungeon run.
- Item icons and real WoW tooltips (hover) throughout.
