# SPHelper — Shadow Priest HUD Addon (TBC Classic Anniversary)

A standalone WoW addon for TBC Classic Anniversary (2.5.5) Shadow Priests. No WeakAuras required.

## Features

### 1. Cast Bar with Mind Flay Clip Indicator
- Shadow-themed progress bar for all casts/channels.
- When channelling **Mind Flay**, three tick markers appear on the bar immediately
  (OVERLAY layer, always visible on top of the bar fill).
- Markers are positioned for channel direction (right→left): tick 1 at 2/3,
  tick 2 at 1/3, tick 3 at the left edge.
- Tick markers turn green as each tick lands.
- A **"CLIP"** label appears when it's safe to cancel the channel.
- Bar colour changes per spell (purple MF, blue MB, red SW:P, etc.).

### 2. Multi-Target DoT / Debuff Tracker
- Tracks **Shadow Word: Pain** (18s), **Vampiric Touch** (15s),
  **Mind Soothe** (15s), and **Shackle Undead** (50s) on every target
  you debuff (up to 8 by default, configurable up to 16).
- Each row shows target name + color-coded countdown timer bars per debuff.
- **Raid marker icons** (skull, star, moon, etc.) shown on each row if the target has one.
- **Click any row to target that mob** (out of combat).
- Auto-sorts by shortest remaining debuff.
- Scans real debuff durations via `UnitDebuff` with `"PLAYER"` filter.
- Discovers debuffs on non-targeted mobs via combat log events (CLEU).
- Stale entries are cleaned on combat drop.

### 3. Rotation Advisor ("What to Cast Next")
- Shows the **#1 priority spell** as a large icon.
- Up to 3 smaller queue icons show the next priorities with ETAs.
- **GCD-aware**: spells only on GCD still appear as priorities.
- **SW:D mode setting**: choose when Shadow Word: Death is suggested:
  - `always` — always suggest when off CD (default)
  - `execute` — only suggest when target HP ≤ threshold %
  - `never` — never suggest

### TBC Shadow Priest Priority Order
1. **Vampiric Touch** — refresh if missing or < 1.5s + latency remaining
2. **Shadow Word: Pain** — refresh if missing or about to expire (< 1 GCD)
3. **Shadowfiend** — when mana < 35% and off CD
4. **Mind Blast** — on cooldown
5. **Shadow Word: Death** — on cooldown (if HP > 20%, subject to SW:D mode)
6. **Devouring Plague** — if known (Undead race) and off CD
7. **Mind Flay** — filler (clip after tick 2 when MB is coming up)

## Installation

1. Copy the `SPHelper` folder into your TBC client's AddOns directory:
   ```
   <WoW TBC Folder>\Interface\AddOns\SPHelper\
   ```

2. Launch the game (or `/reload`). You should see:
   ```
   SPHelper loaded.  /sph to configure.
   ```

3. Drag any frame to reposition while unlocked.

## Settings Panel

Type `/sph` to open the settings panel. It includes:

| Section | Controls |
|---------|----------|
| **General** | Global scale (0.5–3.0), Lock frames |
| **Cast Bar** | Enable/disable, Width, Height |
| **DoT Tracker** | Enable/disable, Row width, Max targets |
| **Rotation Advisor** | Enable/disable, Icon size |
| **SW:D** | Mode (always / execute / never), Execute threshold % |

## Slash Commands

| Command | Description |
|---------|-------------|
| `/sph` | Open/close settings panel |
| `/sph lock` | Lock all frame positions |
| `/sph unlock` | Unlock frames for dragging |
| `/sph scale 1.2` | Set global UI scale (0.5–3.0) |
| `/sph swd always` | SW:D mode: always / execute / never |
| `/sph reset` | Reset all saved settings |

## Files

| File | Purpose |
|------|---------|
| `SPHelper.toc` | Addon manifest |
| `Core.lua` | Shared constants, utilities, spell data |
| `CastBar.lua` | Cast/channel bar with MF tick markers |
| `DotTracker.lua` | Multi-target SW:P, VT, Mind Soothe, Shackle Undead tracker |
| `Rotation.lua` | Next-spell rotation advisor |
| `Config.lua` | Settings panel + slash commands |

## Notes

- The DoT tracker uses `COMBAT_LOG_EVENT_UNFILTERED` via
  `CombatLogGetCurrentEventInfo()` with the standard 8.0+ CLEU format
  (same engine used by TBC Classic Anniversary 2.5.5).
- Settings panel uses the modern `Settings.RegisterCanvasLayoutCategory` API
  with automatic fallback to `InterfaceOptions_AddCategory` for older clients.
- All UI elements are created manually — no deprecated templates used.
- Click-to-target uses `SecureActionButtonTemplate` with `/targetexact` macros.
  Macro text is only updated outside combat lockdown.
- The rotation advisor uses `GetSpellCDReal()` which ignores the 1.5s GCD when
  checking spell cooldowns, so MB/SW:D show as "ready" even during the GCD after
  casting another instant.
- Settings are saved per-character in `SPHelperDB`.
