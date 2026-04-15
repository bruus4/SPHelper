# SPHelper — Shadow Priest HUD for TBC Classic Anniversary

SPHelper is a lightweight World of Warcraft addon for Shadow Priest players on
TBC Classic Anniversary. It provides a compact HUD: a cast/channel bar with
Mind Flay tick indicators, a multi-target DoT tracker, and a small rotation
advisor that highlights the next recommended spell. SPHelper is designed to be
unobtrusive and highly configurable.

## Quickstart

- Install: Copy the `SPHelper` folder to your AddOns directory:

  <WoW TBC Folder>\Interface\AddOns\SPHelper\
- Reload UI: run `/reload` in-game
- Open settings: run `/sph`

## Key Features

- Cast bar with Mind Flay tick markers and a visible "clip" hint.
- Multi-target DoT tracker for player-applied debuffs across multiple targets.
- Rotation advisor showing the top-priority spell and a short next-up queue.
- Configurable behavior for Shadow Word: Death suggestions, scaling, locking,
  and per-module debug logging.

## Requirements

- World of Warcraft: The Burning Crusade Classic (Anniversary)
- No external libraries required

## Installation

1. Copy the `SPHelper` folder into your client's AddOns folder:

   <WoW TBC Folder>\Interface\AddOns\SPHelper\

2. Launch the game or run `/reload` to load the addon.

## Usage & Commands

Open the configuration with `/sph` or use these commands:

- `/sph` — Open configuration UI
- `/sph debug` — Toggle or list debug logging for modules
- `/sph lock` — Lock frames
- `/sph unlock` — Unlock frames for moving
- `/sph scale <value>` — Set UI scale (0.5–3.0)
- `/sph swd <always|execute|never>` — Shadow Word: Death suggestion mode
- `/sph reset` — Restore default settings

## Configuration

Settings are saved per-character in `SPHelperDB`. The configuration panel
exposes options for visibility and placement of frames, scaling and locking,
rotation advisor preferences, and module-specific debug toggles.

## File Overview

- `SPHelper.toc` — Addon manifest
- `Core.lua` — Shared data, spell IDs and helper utilities
- `CastBar.lua` — Cast/channel UI and Mind Flay tick handling
- `DotTracker.lua` — Multi-target debuff scanning and UI rows
- `Rotation.lua` — Next-spell advisor logic
- `Config.lua` — Settings panel and slash commands
- Other supporting files: spec files, rotation engine, and spell database

## Docs & Development

- Design notes and spec files live in the `docs/` and `specs/` folders.
- See docs/SPECS.md for an overview of spec files.

## Troubleshooting

- If DoTs are not tracked correctly, ensure combat logging is enabled and try
  `/reload`.
- If frames are missing, verify the addon loaded on login and check for
  conflicting addons.

## Contributing

Bug reports and feature requests: open an issue or submit a pull request. Keep
changes focused and include testing notes.

## License

SPHelper is released under the terms in the `LICENSE` file.

## Credits

Maintained by the SPHelper authors. See any AUTHORS or CONTRIBUTORS files for
details.

