------------------------------------------------------------------------
-- SPHelper  –  specs/Feral_Druid.lua
-- Feral Druid Cat DPS spec definition (TBC Anniversary).
--
-- Rotation outline:
--   1. Form safety and emergency Bear fallback.
--   2. Cat stealth opener and pre-pull Tiger's Fury.
--   3. Bear-form survival and dungeon/raid threat priorities.
--   4. Armor/debuff maintenance.
--   5. Finishers: Bite only on execute/dying targets, Rip on sustainable targets.
--   6. Builder pair: Shred when ideal, Mangle as the paired fallback.
--   7. Powershift only when no builder/finisher is currently castable.
--
-- Notes:
--   • Rip snapshots AP — do NOT recast while still active (resets timer).
--   • Entries that share an explicitPriority bucket can crossfade the
--     primary icon automatically.
--   • Positional gating is intentionally omitted so the fade icon can
--     represent those paired choices directly.
------------------------------------------------------------------------
local A = SPHelper

local spec = {
    _fromFile = true,

    meta = {
        id       = "feral_druid",
        class    = "DRUID",
        specName = "Feral Cat DPS",
        author   = "SPHelper",
        version  = 1,
    },

    loadConditions = {
        class    = "DRUID",
        talentTab = 2,           -- Feral talent tree (tab 2)
        -- Require Mangle (Cat) talent – tab 2, index ~16 in TBC layout:
        -- Mangle is a 41-pt talent in the Feral tree.
        -- The SpecValidator will only hard-fail if requiredTalents is set,
        -- so we use talentTab for detection and leave requiredTalents as
        -- an optional refinement (commented below).
        -- requiredTalents = {
        --     { tab = 2, index = 16, minRank = 1 },  -- Mangle (Cat) tier 8
        -- },
    },

    helpers = {
        "Rotation",
        "RotationEngine",
        "SpecUI",
        "Config",
    },

    constants = {
        SAFETY = 0.5,
        timing = {
            globalWaitThresholdMs   = 200,
            defaultDelayToleranceMs = 400,
        },
    },

    trackedDebuffs = {
        { key = "rip",    spellKey = "RIP",       color = "SWP", isDot = true  },  -- duration from SpellDatabase (RIP.duration = 12)
        { key = "mangle", spellKey = "MANGLE_CAT", color = "MB",  isDot = false },  -- duration from SpellDatabase (MANGLE_CAT.duration = 12)
    },

    uiOptions = {
        {
            key     = "use_rip",
            type    = "checkbox",
            label   = "Use Rip",
            default = true,
            tooltip = "Apply Rip as the primary sustained finisher when the target will live long enough.",
        },
        {
            key     = "use_mangle",
            type    = "checkbox",
            label   = "Use Mangle",
            default = true,
            tooltip = "Maintain Mangle debuff on target for 30% physical bonus.",
        },
        {
            key     = "use_shred",
            type    = "checkbox",
            label   = "Use Shred",
            default = true,
            tooltip = "Use Shred as primary combo-point generator.",
        },
        {
            key     = "fade_primary_icon",
            type    = "checkbox",
            label   = "Fade primary icon",
            default = true,
            tooltip = "Crossfade the top two ready recommendations when they share the same explicitPriority bucket.",
        },
        {
            key     = "use_faerie_fire",
            type    = "checkbox",
            label   = "Use Faerie Fire",
            default = true,
            tooltip = "Maintain Faerie Fire (Feral) when the armor debuff is missing or about to expire.",
        },
        {
            key     = "faerie_fire_refresh_seconds",
            type    = "slider",
            label   = "Faerie Fire refresh window",
            min     = 1,
            max     = 6,
            step    = 1,
            default = 2,
            tooltip = "Refresh Faerie Fire when any armor-reduction debuff copy has this many seconds or less remaining.",
        },
        {
            key     = "use_ferocious_bite",
            type    = "checkbox",
            label   = "Use Ferocious Bite",
            default = true,
            tooltip = "Use Ferocious Bite when target is dying fast or for trash/execute.",
        },
        {
            key     = "use_tigers_fury",
            type    = "checkbox",
            label   = "Use Tiger's Fury",
            default = true,
            tooltip = "Use Tiger's Fury as a pre-pull opener when starting out of stealth and at full energy.",
        },
        {
            key     = "use_powershift",
            type    = "checkbox",
            label   = "Suggest powershift",
            default = true,
            tooltip = "Suggest Cat Form again when energy is low enough to justify a powershift.",
        },
        {
            key     = "powershift_min_mana_pct",
            type    = "slider",
            label   = "Powershift minimum mana %",
            min     = 0,
            max     = 100,
            step    = 1,
            default = 0,
            tooltip = "Only suggest powershift when player mana percent is above this value (0 = disabled).",
        },
        {
            key     = "use_bear_form",
            type    = "checkbox",
            label   = "Emergency Bear Form",
            default = true,
            tooltip = "Suggest Bear Form when health drops below the bear threshold.",
        },
        {
            key     = "bear_form_hp_pct",
            type    = "slider",
            label   = "Bear Form health threshold",
            min     = 5,
            max     = 100,
            step    = 1,
            default = 35,
            tooltip = "Switch to Bear Form when player health drops below this percentage.",
        },
        {
            key     = "bear_fr_hp_pct",
            type    = "slider",
            label   = "Frenzied Regen health threshold",
            min     = 10,
            max     = 100,
            step    = 1,
            default = 55,
            tooltip = "Use Frenzied Regeneration when in Bear Form and health drops below this percentage.",
        },
        {
            key     = "rip_min_cp",
            type    = "slider",
            label   = "Rip minimum combo points",
            min     = 3,
            max     = 5,
            step    = 1,
            default = 4,
            tooltip = "Minimum combo points required before applying Rip.",
        },
        {
            key     = "rip_min_ttd",
            type    = "slider",
            label   = "Rip minimum target TTD",
            min     = 0,
            max     = 20,
            step    = 1,
            default = 10,
            tooltip = "Only suggest Rip when the target is expected to live at least this many seconds. Set to 0 to disable.",
        },
        {
            key     = "mangle_refresh_seconds",
            type    = "slider",
            label   = "Mangle refresh window",
            min     = 1,
            max     = 6,
            step    = 1,
            default = 2,
            tooltip = "Refresh Mangle when the debuff has this many seconds or less remaining.",
        },
        {
            key     = "dying_fast_pct",
            type    = "slider",
            label   = "Dying fast threshold (%HP/sec)",
            min     = 1,
            max     = 20,
            step    = 1,
            default = 5,
            tooltip = "Use Ferocious Bite instead of Rip when target loses this % HP per second.",
        },
        {
            key     = "ferocious_bite_hp_threshold",
            type    = "slider",
            label   = "Ferocious Bite HP threshold (absolute)",
            min     = 0,
            max     = 100000,
            step    = 1,
            default = 0,
            tooltip = "Suggest Ferocious Bite when target HP is <= this absolute amount (0 = disabled).",
        },
    },

    castBarOptions = {},

    channelSpells = {},

    -- ---------------------------------------------------------------
    -- Rotation (ordered priority list)
    -- Each entry is evaluated top-to-bottom; the first entry where ALL
    -- conditions pass becomes the suggested spell.
    -- ---------------------------------------------------------------
    rotation = {

        -- Emergency Bear Form fallback when health drops and the mode is enabled.
        {
            key        = "BEAR_FORM",
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_bear_form" },
                { type = "state_compare",       subject = "player_hp_pct", op = "<", value = "bear_form_hp_pct" },
                { type = "not", condition = { type = "bear_form" } },
            },
        },

        -- ── Ensure Cat Form ───────────────────────────────────────
        -- Suggest Cat Form when the player is not currently in Cat Form.
        {
            key        = "CAT_FORM",
            conditions = {
                { type = "buff_property_compare", buff = (A.SPELLS and A.SPELLS.CAT_FORM and A.SPELLS.CAT_FORM.name) or "Cat Form", property = "stacks", op = "==", value = 0 },
                { type = "any_of", conditions = {
                    { type = "not", condition = { type = "spec_option_enabled", optionKey = "use_bear_form" } },
                    { type = "state_compare", subject = "player_hp_pct", op = ">", value = "bear_form_hp_pct" },
                }},
                { type = "not", condition = { type = "bear_form" } },
            },
        },

        -- ── BEAR FORM ────────────────────────────────────────────
        -- When already in bear form, keep the suggestions on self-sustain for solo play or on threat tools for dungeon/raid tanking.
        {
            key        = "FRENZIED_REGENERATION",
            conditions = {
                { type = "bear_form" },
                { type = "state_compare", subject = "player_hp_pct", op = "<", value = "bear_fr_hp_pct" },
                { type = "resource_gte", amount = 10 },
            },
        },

        {
            key        = "BASH",
            conditions = {
                { type = "bear_form" },
                { type = "target_valid" },
                { type = "resource_gte", amount = 10 },
                { type = "unit_cast_compare", unit = "target", op = ">", value = 0 },
                { type = "unit_interruptible", unit = "target" },
            },
        },

        {
            key        = "DEMORALIZING_ROAR",
            conditions = {
                { type = "bear_form" },
                { type = "target_valid" },
                { type = "resource_gte", amount = 10 },
                { type = "debuff_property_compare", debuff = "Demoralizing Roar", source = "any", property = "remaining", op = "<", value = 4 },
            },
        },

        {
            key        = "FAERIE_FIRE",
            conditions = {
                { type = "bear_form" },
                { type = "target_valid" },
                { type = "cooldown_ready", spellKey = "FAERIE_FIRE" },
                { type = "debuff_property_compare", debuff = (A.SPELLS and A.SPELLS.FAERIE_FIRE and A.SPELLS.FAERIE_FIRE.name) or "Faerie Fire (Feral)", source = "any", property = "remaining", op = "<", value = "faerie_fire_refresh_seconds" },
            },
        },

        {
            key        = "MANGLE_BEAR",
            conditions = {
                { type = "bear_form" },
                { type = "target_valid" },
                { type = "cooldown_ready", spellKey = "MANGLE_BEAR" },
                { type = "resource_gte", amount = 20 },
            },
        },

        {
            key        = "LACERATE",
            conditions = {
                { type = "bear_form" },
                { type = "target_valid" },
                { type = "any_of", conditions = {
                    { type = "debuff_property_compare", debuff = "Lacerate", source = "player", property = "stacks", op = "<", value = 5 },
                    { type = "debuff_property_compare", debuff = "Lacerate", source = "player", property = "remaining", op = "<", value = 4 },
                }},
                { type = "any_of", conditions = {
                    { type = "content_type", contentType = "dungeon" },
                    { type = "content_type", contentType = "raid" },
                }},
                { type = "resource_gte", amount = 15 },
            },
        },

        {
            key        = "SWIPE_BEAR",
            conditions = {
                { type = "bear_form" },
                { type = "target_valid" },
                { type = "any_of", conditions = {
                    { type = "content_type", contentType = "dungeon" },
                    { type = "content_type", contentType = "raid" },
                }},
                { type = "resource_gte", amount = 30 },
            },
        },

        {
            key        = "MAUL",
            conditions = {
                { type = "bear_form" },
                { type = "target_valid" },
                { type = "resource_gte", amount = 50 },
            },
        },

        -- ── PRE-PULL / MAINTENANCE ────────────────────────────────
        -- Pre-pull Tiger's Fury when starting visible and energy-capped.
        {
            key        = "TIGERS_FURY",
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_tigers_fury" },
                { type = "cat_form" },
                { type = "precombat" },
                { type = "not_stealthed" },
                { type = "resource_required_gte",        amount = 100 },
                { type = "cooldown_ready",      spellKey  = "TIGERS_FURY" },
            },
        },

        -- 2. Ravage – stealth opener when behind target
        {
            key        = "RAVAGE",
            explicitPriority = 200,
            conditions = {
                { type = "cat_form" },
                { type = "target_valid" },
                { type = "precombat" },
                { type = "is_stealthed" },
                { type = "behind_target" },
            },
        },

        -- 3. Pounce – stealth opener when not behind target
        {
            key        = "POUNCE",
            explicitPriority = 200,
            conditions = {
                { type = "cat_form" },
                { type = "target_valid" },
                { type = "precombat" },
                { type = "is_stealthed" },
                { type = "not_behind_target" },
            },
        },

        -- Maintain Faerie Fire using any-source debuff timing so we do not reapply over another druid's copy.
        {
            key        = "FAERIE_FIRE",
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_faerie_fire" },
                { type = "cat_form" },
                { type = "not_stealthed" },
                { type = "target_valid" },
                { type = "cooldown_ready", spellKey = "FAERIE_FIRE" },
                { type = "debuff_property_compare", debuff = (A.SPELLS and A.SPELLS.FAERIE_FIRE and A.SPELLS.FAERIE_FIRE.name) or "Faerie Fire (Feral)", source = "any", property = "remaining", op = "<", value = "faerie_fire_refresh_seconds" },
            },
        },

        -- ── FINISHERS ─────────────────────────────────────────────
        -- Ferocious Bite only when the target is dying fast / within execute rules, and only when Bite is actually castable.
        {
            key        = "FEROCIOUS_BITE",
            conditions = {
                { type = "cat_form" },
                { type = "target_valid" },
                { type = "not_stealthed" },
                { type = "spec_option_enabled", optionKey = "use_ferocious_bite" },
                { type = "state_compare", subject = "combo_points", op = ">=", value = 5 },
                { type = "any_of", conditions = {
                    { type = "state_compare", subject = "resource", op = ">=", value = 35 },
                    { type = "clearcasting" },
                }},
                { type = "any_of", conditions = {
                    { type = "target_dying_fast",   pctPerSec = "dying_fast_pct", direction = "faster" },
                    { type = "state_compare", subject = "target_hp", op = "<=", value = "ferocious_bite_hp_threshold" },
                }},
            },
        },

        -- 4 CP Bite fallback on dying targets.
        {
            key        = "FEROCIOUS_BITE",
            conditions = {
                { type = "cat_form" },
                { type = "target_valid" },
                { type = "not_stealthed" },
                { type = "spec_option_enabled", optionKey = "use_ferocious_bite" },
                { type = "state_compare", subject = "combo_points", op = ">=", value = 4 },
                { type = "any_of", conditions = {
                    { type = "state_compare", subject = "resource", op = ">=", value = 35 },
                    { type = "clearcasting" },
                }},
                { type = "any_of", conditions = {
                    { type = "target_dying_fast",   pctPerSec = "dying_fast_pct", direction = "faster" },
                    { type = "state_compare", subject = "target_hp", op = "<=", value = "ferocious_bite_hp_threshold" },
                }},
            },
        },

        -- Rip on targets that will live long enough to justify it. Never clip; suppress immediate re-suggest after a cast.
        {
            key        = "RIP",
            conditions = {
                { type = "cat_form" },
                { type = "target_valid" },
                { type = "spec_option_enabled", optionKey = "use_rip" },
                { type = "not_stealthed" },
                { type = "state_compare", subject = "combo_points", op = ">=", value = "rip_min_cp" },
                { type = "state_compare", subject = "target_ttd", op = ">=", value = "rip_min_ttd" },
                { type = "any_of", conditions = {
                    { type = "state_compare", subject = "resource", op = ">=", value = 30 },
                    { type = "clearcasting" },
                }},
                { type = "not_recently_cast", spellKey = "RIP", window = 0.6 },
                { type = "dot_missing",         spellKey  = "RIP" },
            },
        },

        -- Refresh Mangle before dropping the debuff.
        {
            key        = "MANGLE_CAT",
            conditions = {
                { type = "cat_form" },
                { type = "target_valid" },
                { type = "spec_option_enabled", optionKey = "use_mangle" },
                { type = "not_stealthed" },
                { type = "debuff_property_compare", debuff = "Mangle (Cat)", source = "any", property = "remaining", op = "<", value = "mangle_refresh_seconds" },
                { type = "any_of", conditions = {
                    { type = "state_compare", subject = "resource", op = ">=", value = 40 },
                    { type = "clearcasting" },
                }},
            },
        },

        -- ── BUILDERS ──────────────────────────────────────────────
        -- Split builder pair: Shred is the preferred builder; Mangle is the paired fallback when Shred is not the practical choice.
        {
            key        = "SHRED",
            explicitPriority = 10,
            conditions = {
                { type = "cat_form" },
                { type = "target_valid" },
                { type = "spec_option_enabled", optionKey = "use_shred" },
                { type = "not_stealthed" },
                { type = "any_of", conditions = {
                    { type = "state_compare", subject = "resource", op = ">=", value = 42 },
                    { type = "clearcasting" },
                }},
            },
        },

        {
            key        = "MANGLE_CAT",
            explicitPriority = 10,
            conditions = {
                { type = "cat_form" },
                { type = "target_valid" },
                { type = "spec_option_enabled", optionKey = "use_mangle" },
                { type = "not_stealthed" },
                { type = "any_of", conditions = {
                    { type = "state_compare", subject = "resource", op = ">=", value = 40 },
                    { type = "clearcasting" },
                }},
            },
        },

        -- Powershift only when we are still in Cat Form, have mana to spare, and do not currently have a free cast.
        {
            key        = "CAT_FORM",
            conditions = {
                { type = "cat_form" },
                { type = "not_stealthed" },
                { type = "spec_option_enabled", optionKey = "use_powershift" },
                { type = "in_combat" },
                { type = "buff_property_compare", buff = (A.SPELLS and A.SPELLS.CAT_FORM and A.SPELLS.CAT_FORM.name) or "Cat Form", property = "stacks", op = ">", value = 0 },
                { type = "state_compare", subject = "player_base_mana_pct", op = ">", value = "powershift_min_mana_pct" },
                { type = "not", condition = { type = "clearcasting" } },
                { type = "any_of", conditions = {
                    { type = "state_compare", subject = "resource_at_gcd", op = "<", value = 10 },
                    { type = "all_of", conditions = {
                        { type = "state_compare", subject = "resource_at_gcd", op = "<", value = 22 },
                        { type = "state_compare", subject = "resource_at_gcd", op = ">", value = 10 },
                        { type = "state_compare", subject = "next_power_tick_with_gcd", op = ">", value = 1.0 },
                    }},
                }},
            },
        },

    },  -- end rotation
}

------------------------------------------------------------------------
-- Register
------------------------------------------------------------------------
if A.SpecManager then
    A.SpecManager:RegisterSpec(spec)
end
