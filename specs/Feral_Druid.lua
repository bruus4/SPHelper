------------------------------------------------------------------------
-- SPHelper  –  specs/Feral_Druid.lua
-- Unified Feral Druid spec (Cat DPS + Bear Tank) for TBC Anniversary.
--
-- Mode selection:
--   • feral_mode = "cat_dps"    → default form is Cat Form; bear form only as emergency fallback.
--   • feral_mode = "bear_tank"  → default form is Dire Bear Form; cat form available for DPS.
--
-- Rotation outline (Cat DPS):
--   1. Emergency Bear Form when HP drops below threshold.
--   2. Cat stealth opener and pre-pull Tiger's Fury.
--   3. Armor/debuff maintenance.
--   4. Finishers: Rip on sustainable targets, Ferocious Bite on execute/dying.
--   5. Builder pair: Shred when ideal, Mangle as the paired fallback.
--   6. Powershift only when no builder/finisher is currently castable.
--
-- Rotation outline (Bear Tank):
--   1. Form safety - ensure Dire Bear Form is active.
--   2. Pre-pull Enrage for rage generation on pull.
--   3. Defensive cooldowns when health drops low.
--   4. Debuff maintenance: Mangle (Bear) vulnerability, Lacerate stacks.
--   5. AoE threat: Swipe when multiple targets present.
--   6. Single-target threat/damage: Maul as primary rage spender.
--   7. On-use trinkets on cooldown during combat.
------------------------------------------------------------------------
local A = SPHelper

local spec = {
    _fromFile = true,

    meta = {
        id       = "feral_druid",
        class    = "DRUID",
        specName = "Feral Druid (Cat DPS / Bear Tank)",
        author   = "SPHelper",
        version  = 2,
    },

    -- Setting version tracking
    settingVersion = 1,
    settingChanges = {
        -- [2] = { defaults = {}, migrate = {}, removed = {} },
    },

    loadConditions = {
        class     = "DRUID",
        talentTab = 2,           -- Feral talent tree (tab 2)
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
        -- Cat DPS debuffs
        { key = "rip",          spellKey = "Rip",          color = "SWP", isDot = true  },
        { key = "mangle_cat",   spellKey = "Mangle (Cat)", name = "Mangle (Cat)", source = "any", color = "MB",  isDot = false },
        -- Bear Tank debuffs
        { key = "mangle_bear",  spellKey = "Mangle (Bear)", source = "any", color = "MB", isDot = false },
        { key = "lacerate",     spellKey = "Lacerate",      source = "player", color = "SWP", isDot = true },
        -- Shared debuffs
        { key = "faerie_fire",  spellKey = "Faerie Fire (Feral)", name = "Faerie Fire", source = "any", duration = 40, color = "FF", isDot = false },
    },

    trackedBuffs = {
        { key = "clearcasting",     name = "Clearcasting",     spellKey = "Clearcasting" },
        { key = "enrage",           name = "Enrage",           spellKey = "Enrage" },
        { key = "cat_form",         name = "Cat Form",         spellKey = "Cat Form" },
        { key = "bear_form",        name = "Bear Form",        spellKey = "Bear Form" },
        { key = "dire_bear_form",   name = "Dire Bear Form",   spellKey = "Dire Bear Form" },
        { key = "stealth",          name = "Prowl",            spellKey = "Prowl" },
    },

    settingDefs = {
        -- ── MODE SELECTION ─────────────────────────────────────────
        feral_mode = { type = "dropdown", label = "Default form mode", default = "cat_dps", values = { "cat_dps", "bear_tank" },
                       tooltip = "Choose Cat Form (DPS) or Dire Bear Form (Tank) as your default form when out of combat." },

        -- ── CAT DPS SETTINGS ───────────────────────────────────────
        use_rip                    = { type = "checkbox", label = "[Cat] Use Rip",                default = true,
                                       tooltip = "Apply Rip as the primary sustained finisher when the target will live long enough." },
        use_mangle                 = { type = "checkbox", label = "[Cat] Use Mangle",             default = true,
                                       tooltip = "Maintain Mangle debuff on target for 30% physical bonus." },
        use_shred                  = { type = "checkbox", label = "[Cat] Use Shred",              default = true,
                                       tooltip = "Use Shred as primary combo-point generator." },
        fade_primary_icon          = { type = "checkbox", label = "[Cat] Fade primary icon",      default = true,
                                       tooltip = "Crossfade the top two ready recommendations when they share the same explicitPriority bucket." },
        use_faerie_fire            = { type = "checkbox", label = "[Cat] Use Faerie Fire",        default = true,
                                       tooltip = "Maintain Faerie Fire (Feral) when the armor debuff is missing or about to expire." },
        faerie_fire_refresh_seconds= { type = "slider",   label = "[Cat] Faerie Fire refresh window",  default = 2, min = 1, max = 6, step = 1,
                                       tooltip = "Refresh Faerie Fire when any armor-reduction debuff copy has this many seconds or less remaining." },
        use_ferocious_bite         = { type = "checkbox", label = "[Cat] Use Ferocious Bite",     default = true,
                                       tooltip = "Use Ferocious Bite when target is dying fast or for trash/execute." },
        use_tigers_fury            = { type = "checkbox", label = "[Cat] Use Tiger's Fury",       default = true,
                                       tooltip = "Use Tiger's Fury as a pre-pull opener when starting out of stealth and at full energy." },
        use_powershift             = { type = "checkbox", label = "[Cat] Suggest powershift",     default = true,
                                       tooltip = "Suggest Cat Form again when energy is low enough to justify a powershift." },
        powershift_min_mana_pct    = { type = "slider",   label = "[Cat] Powershift minimum mana %",   default = 0, min = 0, max = 100, step = 1,
                                       tooltip = "Only suggest powershift when player mana percent is above this value (0 = disabled)." },
        powershift_energy_after    = { type = "slider",   label = "[Cat] Powershift energy after shift", default = 40, min = 0, max = 100, step = 5,
                                       tooltip = "Energy expected immediately after a powershift (Furor 5/5 = 40, +20 with Wolfshead Helm = 60)." },

        -- ── BEAR TANK SETTINGS ─────────────────────────────────────
        use_dire_bear_form     = { type = "checkbox", label = "[Bear] Use Dire Bear Form",         default = true,
                                   tooltip = "Enter Dire Bear Form pre-combat or when out of bear form." },
        use_enrage             = { type = "checkbox", label = "[Bear] Use Enrage (pre-pull)",      default = true,
                                   tooltip = "Cast Enrage before combat for rage generation on pull." },
        use_frenzied_regen     = { type = "checkbox", label = "[Bear] Use Frenzied Regeneration",  default = true,
                                   tooltip = "Emergency heal when health drops low in bear form." },
        frenzied_regen_hp_pct  = { type = "slider",   label = "[Bear] Frenzied Regen HP %",        default = 35, min = 10, max = 80, step = 5,
                                   tooltip = "Use Frenzied Regeneration when health drops below this percentage." },
        use_mangle_bear        = { type = "checkbox", label = "[Bear] Use Mangle (Bear)",          default = true,
                                   tooltip = "Maintain Mangle vulnerability debuff on target." },
        mangle_refresh_seconds = { type = "slider",   label = "[Bear] Mangle refresh window",      default = 2, min = 1, max = 6, step = 1,
                                   tooltip = "Refresh Mangle when the debuff has this many seconds or less remaining." },
        use_lacerate           = { type = "checkbox", label = "[Bear] Use Lacerate (5-stack)",     default = true,
                                   tooltip = "Maintain 5 stacks of Lacerate for bleed damage and armor reduction." },
        lacerate_refresh_seconds = { type = "slider", label = "[Bear] Lacerate refresh window",    default = 4, min = 2, max = 8, step = 1,
                                     tooltip = "Refresh Lacerate when remaining duration drops below this value (at full stacks)." },
        use_swipe              = { type = "checkbox", label = "[Bear] Use Swipe (AoE)",            default = true,
                                   tooltip = "Swipe for AoE threat when multiple targets are present." },
        swipe_min_targets      = { type = "slider",   label = "[Bear] Swipe minimum targets",      default = 2, min = 1, max = 8, step = 1,
                                   tooltip = "Only suggest Swipe when this many or more enemies are nearby. Set to 1 for single-target use." },
        use_maul               = { type = "checkbox", label = "[Bear] Use Maul",                   default = true,
                                   tooltip = "Maul as primary single-target threat/damage spender." },

        -- ── SHARED SETTINGS ────────────────────────────────────────
        use_bear_form              = { type = "checkbox", label = "Emergency Bear Form",    default = true,
                                       tooltip = "Suggest Bear Form when health drops below the bear threshold (applies in cat_dps mode)." },
        bear_form_hp_pct           = { type = "slider",   label = "Bear Form health threshold",   default = 35, min = 5, max = 100, step = 1,
                                       tooltip = "Switch to Bear Form when player health drops below this percentage." },

        -- ── TRINKETS (shared) ──────────────────────────────────────
        use_trinket_1            = { type = "checkbox", label = "Use trinket 1 (on-use)",  default = true,
                                     tooltip = "Activate trinket 1 on cooldown automatically." },
        trinket_1_classification = { type = "dropdown", label = "Trinket 1 target type",   default = "any",
                                     values = { "any", "normal", "elite", "boss" },
                                     tooltip = "Restrict trinket 1 to: any, normal, elite, or boss." },
        use_trinket_2            = { type = "checkbox", label = "Use trinket 2 (on-use)",  default = true,
                                     tooltip = "Activate trinket 2 on cooldown automatically." },
        trinket_2_classification = { type = "dropdown", label = "Trinket 2 target type",   default = "any",
                                     values = { "any", "normal", "elite", "boss" },
                                     tooltip = "Restrict trinket 2 to: any, normal, elite, or boss." },

        -- ── CONSUMABLES (shared) ───────────────────────────────────
        suggestPot             = { type = "checkbox", label = "Suggest mana potion",        default = true,
                                   tooltip = "Show mana potion suggestion when low on mana." },
        potManaThreshold       = { type = "slider",   label = "Potion mana %",              default = 15, min = 5, max = 100, step = 5,
                                   tooltip = "Suggest mana potion when mana drops below this percentage." },

        -- ── CAT DPS ADVANCED SETTINGS ──────────────────────────────
        rip_min_cp                 = { type = "slider",   label = "[Cat] Rip minimum combo points",    default = 4, min = 3, max = 5, step = 1,
                                       tooltip = "Minimum combo points required before applying Rip." },
        rip_min_ttd                = { type = "slider",   label = "[Cat] Rip minimum target TTD",      default = 10, min = 0, max = 20, step = 1,
                                       tooltip = "Only suggest Rip when the target is expected to live at least this many seconds. 0 = disabled." },
        dying_fast_pct             = { type = "slider",   label = "[Cat] Dying fast threshold (%HP/sec)", default = 5, min = 1, max = 20, step = 1,
                                       tooltip = "Use Ferocious Bite instead of Rip when target loses this % HP per second." },
        ferocious_bite_hp_threshold= { type = "slider",   label = "[Cat] Ferocious Bite HP threshold (absolute)", default = 0, min = 0, max = 100000, step = 1,
                                       tooltip = "Suggest Ferocious Bite when target HP is <= this absolute amount (0 = disabled)." },
    },

    generalSettings = {
        "fade_primary_icon",
    },

    castBarOptions = {},

    channelSpells = {},

    -- ---------------------------------------------------------------
    -- Rotation (ordered priority list)
    -- Each entry is evaluated top-to-bottom; the first entry where ALL
    -- conditions pass becomes the suggested spell.
    -- ---------------------------------------------------------------
    rotation = {

        -- ── EMERGENCY BEAR FORM (always highest priority when low HP) ──
        -- Emergency Bear Form fallback when health drops and the mode is enabled.
        {
            key        = "Bear Form",
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_bear_form" },
                { type = "state_compare",       subject = "player_hp_pct", op = "<", value = "bear_form_hp_pct" },
                { type = "not", condition = { type = "bear_form" } },
            },
        },

        -- ── FORM SAFETY: DEFAULT FORM BASED ON MODE ───────────────────
        -- When mode is bear_tank and not in bear form → suggest Dire Bear Form.
        {
            key        = "Dire Bear Form",
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_dire_bear_form" },
                { type = "state_compare",       subject = "feral_mode", op = "==", value = "bear_tank" },
                { type = "buff_property_compare", buff = "Dire Bear Form", property = "stacks", op = "==", value = 0 },
                { type = "not", condition = { type = "cat_form" } },
            },
        },

        -- When mode is cat_dps and not in cat form → suggest Cat Form.
        {
            key        = "Cat Form",
            conditions = {
                { type = "state_compare",       subject = "feral_mode", op = "==", value = "cat_dps" },
                { type = "buff_property_compare", buff = "Cat Form", property = "stacks", op = "==", value = 0 },
                { type = "not", condition = { type = "bear_form" } },
            },
        },

        -- ── BEAR TANK ROTATION ───────────────────────────────────────
        -- All bear tank entries require being in bear form.

        -- Pre-pull Enrage for rage generation on pull.
        {
            key        = "Enrage",
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_enrage" },
                { type = "bear_form" },
                { type = "precombat" },
                { type = "cooldown_ready", spellKey = "Enrage" },
                { type = "buff_property_compare", buff = "Enrage", property = "stacks", op = "==", value = 0 },
            },
        },

        -- Frenzied Regeneration when health drops critically low.
        {
            key        = "Frenzied Regeneration",
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_frenzied_regen" },
                { type = "bear_form" },
                { type = "in_combat" },
                { type = "state_compare", subject = "player_hp_pct", op = "<", value = "frenzied_regen_hp_pct" },
                { type = "resource_gte", amount = 10 },
            },
        },

        -- On-use trinkets in bear form.
        {
            key        = "TRINKET1",
            optional   = true,
            conditions = {
                { type = "spec_option_enabled",       optionKey = "use_trinket_1" },
                { type = "bear_form" },
                { type = "target_valid" },
                { type = "trinket_ready",             slot      = 13 },
                { type = "classification_any_target", settingKey = "trinket_1_classification" },
            },
        },
        {
            key        = "TRINKET2",
            optional   = true,
            conditions = {
                { type = "spec_option_enabled",       optionKey = "use_trinket_2" },
                { type = "bear_form" },
                { type = "target_valid" },
                { type = "trinket_ready",             slot      = 14 },
                { type = "classification_any_target", settingKey = "trinket_2_classification" },
            },
        },

        -- Mangle (Bear) - maintain vulnerability debuff. High priority to keep up.
        {
            key        = "Mangle (Bear)",
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_mangle_bear" },
                { type = "bear_form" },
                { type = "target_valid" },
                { type = "cooldown_ready", spellKey = "Mangle (Bear)" },
                { type = "debuff_property_compare", debuff = "Mangle (Bear)", source = "any", property = "remaining", op = "<", value = "mangle_refresh_seconds" },
                { type = "resource_gte", amount = 20 },
            },
        },

        -- Lacerate - maintain 5 stacks for bleed damage and armor reduction.
        {
            key        = "Lacerate",
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_lacerate" },
                { type = "bear_form" },
                { type = "target_valid" },
                { type = "any_of", conditions = {
                    -- Below 5 stacks: build up
                    { type = "debuff_property_compare", debuff = "Lacerate", source = "player", property = "stacks", op = "<", value = 5 },
                    -- At 5 stacks but duration running low
                    { type = "all_of", conditions = {
                        { type = "debuff_property_compare", debuff = "Lacerate", source = "player", property = "stacks", op = ">=", value = 5 },
                        { type = "debuff_property_compare", debuff = "Lacerate", source = "player", property = "remaining", op = "<", value = "lacerate_refresh_seconds" },
                    }},
                }},
                { type = "resource_gte", amount = 15 },
            },
        },

        -- Faerie Fire (Feral) - maintain armor debuff.
        {
            key        = "Faerie Fire (Feral)",
            conditions = {
                { type = "bear_form" },
                { type = "target_valid" },
                { type = "cooldown_ready", spellKey = "Faerie Fire (Feral)" },
                { type = "debuff_property_compare", spellKey = "Faerie Fire (Feral)", debuff = "Faerie Fire", source = "any", property = "remaining", op = "<", value = "faerie_fire_refresh_seconds" },
            },
        },

        -- Swipe for AoE threat when multiple targets are present.
        {
            key        = "Swipe",
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_swipe" },
                { type = "bear_form" },
                { type = "target_valid" },
                { type = "state_compare", subject = "tracked_target_count", op = ">=", value = "swipe_min_targets" },
                { type = "resource_gte", amount = 30 },
            },
        },

        -- Maul as primary rage spender for single-target threat.
        {
            key        = "Maul",
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_maul" },
                { type = "bear_form" },
                { type = "target_valid" },
                { type = "resource_gte", amount = 50 },
            },
        },

        -- ── CAT DPS ROTATION ────────────────────────────────────────
        -- All cat DPS entries require being in cat form.

        -- Pre-pull Tiger's Fury when starting visible and energy-capped.
        {
            key        = "Tiger's Fury",
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_tigers_fury" },
                { type = "cat_form" },
                { type = "precombat" },
                { type = "not_stealthed" },
                { type = "resource_required_gte",        amount = 100 },
                { type = "cooldown_ready",      spellKey  = "Tiger's Fury" },
            },
        },

        -- Ravage – stealth opener when behind target (60 energy cost)
        {
            key        = "Ravage",
            explicitPriority = 200,
            conditions = {
                { type = "cat_form" },
                { type = "target_valid" },
                { type = "precombat" },
                { type = "is_stealthed" },
                { type = "behind_target" },
                { type = "resource_gte", amount = 60 },
            },
        },

        -- Pounce – stealth opener when not behind target (50 energy cost)
        {
            key        = "Pounce",
            explicitPriority = 200,
            conditions = {
                { type = "cat_form" },
                { type = "target_valid" },
                { type = "precombat" },
                { type = "is_stealthed" },
                { type = "not_behind_target" },
                { type = "resource_gte", amount = 50 },
            },
        },

        -- Maintain Faerie Fire using any-source debuff timing.
        {
            key        = "Faerie Fire (Feral)",
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_faerie_fire" },
                { type = "cat_form" },
                { type = "not_stealthed" },
                { type = "target_valid" },
                { type = "cooldown_ready", spellKey = "Faerie Fire (Feral)" },
                { type = "debuff_property_compare", spellKey = "Faerie Fire (Feral)", debuff = "Faerie Fire", source = "any", property = "remaining", op = "<", value = "faerie_fire_refresh_seconds" },
            },
        },

        -- On-use trinkets in cat form.
        {
            key        = "TRINKET1",
            optional   = true,
            conditions = {
                { type = "spec_option_enabled",       optionKey = "use_trinket_1" },
                { type = "cat_form" },
                { type = "not_stealthed" },
                { type = "trinket_ready",             slot      = 13 },
                { type = "classification_any_target", settingKey = "trinket_1_classification" },
            },
        },
        {
            key        = "TRINKET2",
            optional   = true,
            conditions = {
                { type = "spec_option_enabled",       optionKey = "use_trinket_2" },
                { type = "cat_form" },
                { type = "not_stealthed" },
                { type = "trinket_ready",             slot      = 14 },
                { type = "classification_any_target", settingKey = "trinket_2_classification" },
            },
        },

        -- ── CAT FINISHERS ───────────────────────────────────────────
        -- Ferocious Bite: execute-phase dump for fast-dying targets.
        {
            key        = "Ferocious Bite",
            conditions = {
                { type = "cat_form" },
                { type = "target_valid" },
                { type = "not_stealthed" },
                { type = "spec_option_enabled", optionKey = "use_ferocious_bite" },
                { type = "state_compare", subject = "combo_points", op = ">=", value = 3 },
                { type = "any_of", conditions = {
                    { type = "target_dying_fast",   pctPerSec = "dying_fast_pct", direction = "faster" },
                    { type = "state_compare", subject = "target_hp", op = "<=", value = "ferocious_bite_hp_threshold" },
                }},
            },
        },

        -- Rip on targets that will live long enough to justify it. Never clip; suppress immediate re-suggest after a cast.
        -- Priority above Ferocious Bite so a fresh 5-CP target gets Rip first (matches logged rotation).
        {
            key        = "Rip",
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
                { type = "not_recently_cast", spellKey = "Rip", window = 0.6 },
                { type = "dot_missing",         spellKey  = "Rip" },
            },
        },

        -- Ferocious Bite: regular energy dump at 5 CP, only when Rip is already
        -- healthy (or Rip is disabled / target won't live long enough for Rip).
        -- Matches the logged rotation: Shred to 5 CP → Rip → Shred → Ferocious Bite.
        {
            key        = "Ferocious Bite",
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
                    -- Rip healthy: dump combo points into Ferocious Bite.
                    { type = "debuff_property_compare", debuff = "Rip", source = "player", property = "remaining", op = ">=", value = 8 },
                    -- Rip disabled in settings: Bite is the finisher.
                    { type = "not", condition = { type = "spec_option_enabled", optionKey = "use_rip" } },
                    -- Target too short-lived for Rip: spend points on Bite instead.
                    { type = "state_compare", subject = "target_ttd", op = "<", value = "rip_min_ttd" },
                }},
            },
        },

        -- Refresh Mangle before dropping the debuff.
        {
            key        = "Mangle (Cat)",
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

        -- ── CAT BUILDERS ────────────────────────────────────────────
        -- Split builder pair: Shred is the preferred builder; Mangle is the paired fallback.
        {
            key        = "Shred",
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
            key        = "Mangle (Cat)",
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
            key        = "Cat Form",
            postCast   = { resource = "energy", set = "powershift_energy_after" },
            conditions = {
                { type = "cat_form" },
                { type = "not_stealthed" },
                { type = "spec_option_enabled", optionKey = "use_powershift" },
                { type = "in_combat" },
                { type = "buff_property_compare", buff = "Cat Form", property = "stacks", op = ">", value = 0 },
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

        -- ── CONSUMABLES (shared) ────────────────────────────────────
        -- Mana potion suggestion when mana is low.
        {
            key        = "POTION",
            conditions = {
                { type = "spec_option_enabled", optionKey = "suggestPot" },
                { type = "state_compare", subject = "player_mana_pct", op = "<", value = "potManaThreshold" },
                { type = "item_ready_and_owned" },
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
