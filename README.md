# WoWAddons

Personal collection of World of Warcraft addons.

## Addons

| Addon | Description | Version |
| --- | --- | --- |
| [Spoilbook](Spoilbook/) | Tracks Uncommon+ loot drops per dungeon/raid run — what dropped, whether you looted it or who won the roll, a lifetime loot table per place, and a wishlist. | [0.1.0](Spoilbook/CHANGELOG.md) |

## Versioning

Each addon is versioned independently using [Semantic Versioning](https://semver.org/) (`MAJOR.MINOR.PATCH`):

- **MAJOR** — incompatible changes (e.g. SavedVariables format changes that aren't migrated)
- **MINOR** — new functionality, backwards compatible
- **PATCH** — bug fixes only

The current version of each addon lives in its `.toc` file (`## Version:`), and its history is tracked in that addon's own `CHANGELOG.md`.

## Installing an addon

Copy the addon's folder into your WoW installation's `Interface/AddOns/` directory, e.g.:

```
cp -r Spoilbook "/Applications/World of Warcraft/_forever_/Interface/AddOns/"
```

Each addon's own README (if present) has any addon-specific notes (target client, slash commands, known limitations).
