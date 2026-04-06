# SPHelper — Shadow Priest HUD for TBC Classic Anniversary

SPHelper is a lightweight World of Warcraft addon that provides Shadow Priest
players with a compact HUD: a cast/channel bar with Mind Flay tick indicators,
an efficient multi-target DoT/debuff tracker, and a simple rotation advisor
that highlights the next recommended spell.

Built for TBC Classic Anniversary, SPHelper aims to surface important combat
information clearly and unobtrusively.

## Key Features

- Cast Bar with Mind Flay ticks: shows channel ticks, a visible "clip" hint.
- Multi-target DoT tracker: monitors player-applied debuffs (SW:P, VT, Mind
  Soothe, Shackle Undead) across multiple targets, with sortable rows.
- Rotation Advisor: displays the top-priority spell and a short next-up queue;
  includes configurable behavior for Shadow Word: Death suggestions.

## Installation

1. Copy the `SPHelper` folder to your TBC client's AddOns directory:

   <WoW TBC Folder>\Interface\AddOns\SPHelper\

2. Start the game or use `/reload` in-game. The addon prints a load message and
   `/sph` opens the configuration UI.

## Configuration & Commands

Open the settings with `/sph`. Common commands:

- `/sph` — Open configuration
- `/sph lock` — Lock frames
- `/sph unlock` — Unlock frames for moving
- `/sph scale <value>` — Set global UI scale (0.5–3.0)
- `/sph swd <always|execute|never>` — Shadow Word: Death suggestion mode
- `/sph reset` — Reset saved settings

## File Overview

- `SPHelper.toc` — Addon manifest
- `Core.lua` — Shared data, spell IDs and helper utilities
- `CastBar.lua` — Cast/channel UI and Mind Flay tick handling
- `DotTracker.lua` — Multi-target debuff scanning and UI rows
- `Rotation.lua` — Next-spell advisor logic
- `Config.lua` — Settings panel and slash commands

## Notes

- DoT tracking combines combat log events with `UnitDebuff` to read accurate
  durations for player-applied debuffs.
- Click-to-target uses secure buttons and only updates macros outside combat to
  comply with the secure environment.
- Settings are saved per-character in `SPHelperDB`.

