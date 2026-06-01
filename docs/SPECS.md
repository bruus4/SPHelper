# SPHelper Spec Authoring Guide

## Overview

SPHelper uses a spec-driven architecture. Each class/spec is defined in a
standalone Lua file under `specs/`. The addon core provides helpers (CastBar,
DotTracker, Rotation, RotationEngine, ChannelHelper, Config, SpecUI) that
are activated only when a matching spec is loaded.

## Quick Start

1. Create `specs/YourClass_YourSpec.lua`
2. Add it to `SPHelper.toc` after `SpecValidator.lua`
3. Define your spec table and call `SPHelper.SpecManager:RegisterSpec(spec)`
4. `/reload` — if your class/talents match, the spec activates automatically

## Spec Table Schema

```lua
local spec = {
    _fromFile = true,  -- required for file-based specs using function conditions

    meta = {
        id       = "shadow_priest",      -- unique identifier (lowercase, underscores)
        class    = "PRIEST",             -- uppercase English class token
        specName = "Shadow",             -- display name
        author   = "YourName",
        version  = 1,                    -- schema version (currently 1)
    },

    loadConditions = {
        class          = "PRIEST",       -- match UnitClass() token
        talentTab      = 3,              -- talent tab with most points (1-based)
        minLevel       = 10,             -- optional minimum level
        requiredSpells = { 15473 },      -- optional spell IDs player must know
    },

    helpers = {                          -- list of helper modules to activate
        "CastBar",
        "DotTracker",
        "Rotation",
        "RotationEngine",
        "ChannelHelper",
        "SpecUI",
        "Config",
    },

    constants = {                        -- timing and spell constants
        VT_CAST_TIME     = 1.5,
        MF_CAST_TIME     = 3.0,
        SAFETY           = 0.5,
        timing = {
            globalWaitThresholdMs   = 400,
            fakeQueueMaxMs          = 189,
            clipMarginMs            = 50,
        },
    },

    trackedDebuffs = {                   -- debuffs for DotTracker module
        { key = "swp", spellKey = "SWP", duration = 18, color = "SWP", isDot = true },
        { key = "vt",  spellKey = "VT",  duration = 15, color = "VT",  isDot = true },
    },

    uiOptions = {                        -- per-spec settings (shown in SpecUI General tab)
        { key = "myToggle",   type = "checkbox", label = "Enable feature",    default = true },
        { key = "mySlider",   type = "slider",   label = "Threshold %",       default = 50, min = 0, max = 100, step = 5 },
        { key = "myDropdown", type = "dropdown",  label = "Mode",             default = "always", values = {"always","never"} },
    },

    rotation = {                         -- ordered rotation entries
        _fromFile = true,
        { key = "MB", conditions = {{ type = "cooldown_ready", spellKey = "MB" }}, explicitPriority = 80 },
        { key = "MF", conditions = {{ type = "always" }}, explicitPriority = 10 },
    },
}

SPHelper.SpecManager:RegisterSpec(spec)
```

## Condition Types Reference

| Type | Description | Fields |
|------|-------------|--------|
| `always` | Always true | — |
| `target_valid` | Has attackable target | — |
| `in_combat` | Player in combat | — |
| `channeling` | Player is channeling | — |
| `cooldown_ready` | Spell off cooldown | `spellKey` |
| `cooldown_lt` | Spell CD < N seconds | `spellKey`, `seconds` |
| `spell_usable` | Spell usable (mana ok) | `spellKey` |
| `dot_missing` | DoT not on target | `spellKey` |
| `dot_time_left_lt` | DoT remaining < N sec | `spellKey`, `seconds` |
| `projected_dot_time_left_lt` | DoT remaining after cast < N | `spellKey`, `seconds` |
| `state_compare` | Generic numeric compare for shared state values | `subject`, `op`, `value`, optional `resource`, `unit`, `minTTD` |
| `spell_property_compare` | Compare spell timing data | `spellKey`, `property`, `op`, `value` |
| `buff_property_compare` | Compare player buff remaining/stacks | `buff`, `property`, `op`, `value` |
| `debuff_property_compare` | Compare target debuff remaining/stacks | `debuff`, `source`, `property`, `op`, `value` |
| `unit_cast_compare` | Compare cast/channel time left on a unit | `unit`, `op`, `value` |
| `unit_interruptible` | Unit is casting something interruptible | `unit` |
| `resource_pct_lt` | Resource below % | `resource` (mana/hp/energy/rage), `pct` |
| `resource_pct_gt` | Resource above % | `resource`, `pct` |
| `target_hp_pct_lt` | Target HP below % | `pct` |
| `target_hp_pct_gt` | Target HP above % | `pct` |
| `player_hp_pct_lt` | Player HP below % | `pct` |
| `predicted_kill` | SWD can kill target | — |
| `content_mode_allow` | Content mode check | `dbKey` |
| `target_classification` | Target is boss/elite/normal | `classification` |
| `buff_on_player` | Player has buff | `buff` |
| `buff_stacks_gte` | Buff stacks >= N | `buff`, `stacks` |
| `not_buff_on_player` | Player lacks buff | `buff` |
| `not_debuff_on_target` | Target lacks debuff | `debuff` |
| `item_ready_and_owned` | Item off CD and owned | `itemId` |
| `not_recently_cast` | Not cast within window | `spellName` or `spellKey`, `window` |
| `spec_option_enabled` | Spec uiOption is truthy | `optionKey` |
| `spec_option_value` | Spec uiOption = value | `optionKey`, `value` |
| `group_size_gte` | Group has N+ members | `size` |

`state_compare` subjects currently include `resource_pct`, `player_hp_pct`, `player_hp`, `target_hp_pct`, `target_hp`, `player_mana_pct`, `player_base_mana_pct`, `combo_points`, `target_ttd`, `resource`, `resource_at_gcd`, `next_power_tick_with_gcd`, `threat_pct`, `tracked_target_count`, `tracked_targets_with_ttd`, `channel_tick_interval`, `channel_ticks_remaining`, and `channel_time_to_next_tick`.

`spell_property_compare` supports `time_to_ready`, `cast_time`, `travel_time`, `dot_base_duration`, `dot_tick_frequency`, and `channel_tick_interval`. `buff_property_compare` and `debuff_property_compare` support `remaining` and `stacks`.

Expression-based thresholds can reference live timing tokens such as `vtTravel`, `swpTravel`, `mbTravel`, `swdTravel`, `channelTickInterval`, `channelToNextTick`, and `channelTicksRemaining`.

Legacy one-off conditions such as `resource_pct_lt`, `combo_points_gte`, and `target_ttd_lt` are still supported for compatibility, but new specs can usually prefer the compare-family above.

## Rotation Entry Fields

| Field | Required | Description |
|-------|----------|-------------|
| `key` | Yes | Spell key matching `A.SPELLS` (e.g., `"MB"`, `"VT"`) |
| `conditions` | Yes | Array of condition objects (all must pass) |
| `explicitPriority` | No | Optional split-priority bucket; if the first two ready recommendations share it, the primary icon auto-splits in list order |
| `insertBefore` | No | Key name — entry is placed before this key in results |

## Slash Commands

| Command | Description |
|---------|-------------|
| `/sph` | Open settings panel |
| `/sph spec` | Open spec & rotation editor |
| `/sph visuals` | Open visual layout options |
| `/sph debug` | List or toggle module debug logging |
| `/sph lock` | Lock frame positions |
| `/sph unlock` | Unlock frames |
| `/sph scale N` | Set UI scale (0.5-3.0) |
| `/sph macros` | Print Fake Queue macro templates |
| `/sph reset` | Reset all settings |

## Helper Modules

Each helper registers via `SpecManager:RegisterHelper(name, obj, opts)`:

- **CastBar** — Cast/channel bar with tick markers and clip detection
- **DotTracker** — Multi-target debuff tracker (reads `spec.trackedDebuffs`)
- **Rotation** — Legacy rotation display with icon frames
- **RotationEngine** — Data-driven rotation evaluator
- **ChannelHelper** — Channel tick tracking, clip window, Fake Queue
- **SpecUI** — Per-spec settings panel and rotation editor
- **Config** — Global settings panel and slash commands
