------------------------------------------------------------------------
-- SPHelper  –  specs/Warlock_Demonology_Leveling.lua
-- Demonology Warlock SOLO LEVELING rotation (levels 10–69).
--
-- Based on the standard TBC solo-leveling rotation:
--   1. Keep Demon Armor up (pre-combat buff).
--   2. Amplify Curse on cooldown, then Curse of Agony.
--   3. Maintain Corruption (+ optional Immolate) while the pet tanks.
--   4. Drain Soul on low-HP mobs (soul shards + Improved Drain Soul mana).
--   5. Shadow Bolt as the filler.
--   6. Drain Life to self-heal, Life Tap to convert health into mana.
--
-- This spec is opt-in (like all non-reference specs): enable it via /sph.
-- It activates below level 70 while the Demonology tree has the most points;
-- at 70 the normal Demonology raid spec takes over.
------------------------------------------------------------------------
local A = SPHelper
local T = A.SpecTemplates

local spec = {
    _fromFile = true,
    meta = { id = "demonology_warlock_leveling", class = "WARLOCK", specName = "Demonology (Leveling)", author = "SPHelper", version = 1 },
    loadConditions = { class = "WARLOCK", talentTab = 2, minLevel = 10, maxLevel = 69 },
    helpers = { "CastBar", "DotTracker", "Rotation", "RotationEngine", "SpellData", "SpecUI", "Config" },
    constants = { SAFETY = 0.5, timing = { globalWaitThresholdMs = 400, defaultDelayToleranceMs = 600, dotSafeWindowSec = 1.5 } },
    trackedDebuffs = {
        { key = "corruption", spellKey = "Corruption", color = "SWP", isDot = true },
        { key = "curse_of_agony", spellKey = "Curse of Agony", color = "VT", isDot = true },
        { key = "immolate", spellKey = "Immolate", color = "IMM", isDot = true },
    },
    trackedBuffs = {
        { key = "demon_armor", name = "Demon Armor", spellKey = "Demon Armor" },
        { key = "amplify_curse", name = "Amplify Curse", spellKey = "Amplify Curse" },
    },
    settingDefs = {
        -- ── BUFFS / CURSES ─────────────────────────────────────────
        use_demon_armor  = { type = "checkbox", label = "Use Demon Armor", default = true, group = "Buffs & Curses",
                              tooltip = "Keep Demon Armor up (armor + shadow resistance while leveling)." },
        use_amplify_curse = { type = "checkbox", label = "Use Amplify Curse", default = true, group = "Buffs & Curses",
                              tooltip = "Amplify Curse on cooldown, then apply the amplified Curse of Agony." },
        use_curse_of_agony = { type = "checkbox", label = "Use Curse of Agony", default = true, group = "Buffs & Curses",
                              tooltip = "Maintain Curse of Agony — the solo-leveling damage curse." },
        coaRefreshSeconds  = { type = "slider", label = "Curse of Agony refresh window", default = 2, min = 1, max = 6, step = 1, group = "Buffs & Curses",
                              tooltip = "Refresh CoA when any copy has this many seconds or less remaining." },

        -- ── DoTs ───────────────────────────────────────────────────
        use_corruption = { type = "checkbox", label = "Use Corruption", default = true, group = "DoTs",
                           tooltip = "Maintain Corruption (instant with Improved Corruption)." },
        use_immolate   = { type = "checkbox", label = "Use Immolate", default = false, group = "DoTs",
                           tooltip = "Also maintain Immolate for extra damage. Off by default to save mana while leveling." },

        -- ── SURVIVAL / MANA ────────────────────────────────────────
        use_drain_life  = { type = "checkbox", label = "Use Drain Life (self-heal)", default = true, group = "Survival & Mana",
                            tooltip = "Channel Drain Life to heal when low on health; also sustains mana with Fel Concentration." },
        drainLifeHpPct  = { type = "slider", label = "Drain Life HP %", default = 35, min = 10, max = 80, step = 5, group = "Survival & Mana",
                            tooltip = "Cast Drain Life when your HP drops below this %." },
        use_drain_soul  = { type = "checkbox", label = "Use Drain Soul (soul shards)", default = true, group = "Survival & Mana",
                            tooltip = "Drain Soul on low-HP mobs for soul shards and mana return (Improved Drain Soul)." },
        drainSoulHpPct  = { type = "slider", label = "Drain Soul HP %", default = 25, min = 10, max = 40, step = 5, group = "Survival & Mana",
                            tooltip = "Use Drain Soul when the target is below this HP % (it deals bonus damage under 25%)." },
        use_life_tap    = { type = "checkbox", label = "Use Life Tap", default = true, group = "Survival & Mana",
                            tooltip = "Life Tap when low on mana." },
        lifeTapManaPct  = { type = "slider", label = "Life Tap mana %", default = 40, min = 10, max = 90, step = 5, group = "Survival & Mana",
                            tooltip = "Life Tap when mana below this %." },
        suggestPot      = { type = "checkbox", label = "Suggest mana potion", default = true, group = "Survival & Mana",
                            tooltip = "Show mana potion suggestion." },
        potManaThreshold = { type = "slider", label = "Potion mana %", default = 10, min = 5, max = 100, step = 5, group = "Survival & Mana",
                            tooltip = "Potion when mana below this %." },
        suggestRune     = { type = "checkbox", label = "Suggest dark rune", default = true, group = "Survival & Mana",
                            tooltip = "Show rune suggestion." },
        runeManaThreshold = { type = "slider", label = "Rune mana %", default = 10, min = 5, max = 100, step = 5, group = "Survival & Mana",
                            tooltip = "Rune when mana below this %." },

        -- ── TRINKETS ───────────────────────────────────────────────
        use_trinket_1            = { type = "checkbox", label = "Use trinket 1 (on-use)",  default = true, group = "Trinkets",
                                      tooltip = "Activate trinket 1 on cooldown automatically." },
        use_trinket_2            = { type = "checkbox", label = "Use trinket 2 (on-use)",  default = true, group = "Trinkets",
                                      tooltip = "Activate trinket 2 on cooldown automatically." },
        trinket_1_classification = { type = "dropdown", label = "Trinket 1 target type",   default = "any", group = "Trinkets",
                                      tooltip = "Restrict trinket 1 to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
        trinket_2_classification = { type = "dropdown", label = "Trinket 2 target type",   default = "any", group = "Trinkets",
                                      tooltip = "Restrict trinket 2 to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
    },
    settingOrder = {
        "use_demon_armor", "use_amplify_curse", "use_curse_of_agony", "coaRefreshSeconds",
        "use_corruption", "use_immolate",
        "use_drain_life", "drainLifeHpPct", "use_drain_soul", "drainSoulHpPct",
        "use_life_tap", "lifeTapManaPct", "suggestPot", "potManaThreshold", "suggestRune", "runeManaThreshold",
        "use_trinket_1", "trinket_1_classification", "use_trinket_2", "trinket_2_classification",
    },
    rotation = {
        -- ── PRE-COMBAT BUFF ─────────────────────────────────────────
        {
            key = "Demon Armor",
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_demon_armor" },
                { type = "precombat" },
                { type = "buff_property_compare", buff = "Demon Armor", property = "stacks", op = "==", value = 0 },
            },
        },

        -- ── AMPLIFY CURSE + CoA ─────────────────────────────────────
        -- Amplify Curse on cooldown so the next Curse of Agony hits harder.
        {
            key = "Amplify Curse",
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_amplify_curse" },
                { type = "spec_option_enabled", optionKey = "use_curse_of_agony" },
                { type = "in_combat" },
                { type = "target_valid" },
                { type = "cooldown_ready", spellKey = "Amplify Curse" },
                { type = "buff_property_compare", buff = "Amplify Curse", property = "stacks", op = "==", value = 0 },
            },
        },
        -- Curse of Agony: the leveling damage curse.
        {
            key = "Curse of Agony",
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_curse_of_agony" },
                { type = "target_valid" },
                { type = "cooldown_ready", spellKey = "Curse of Agony" },
                { type = "state_compare", subject = "target_ttd", op = ">=", value = 8 },
                { type = "debuff_property_compare", spellKey = "Curse of Agony", debuff = "Curse of Agony", source = "any", property = "remaining", op = "<", value = "coaRefreshSeconds" },
            },
        },

        -- ── DoTs ────────────────────────────────────────────────────
        {
            key = "Corruption",
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_corruption" },
                { type = "target_valid" },
                { type = "state_compare", subject = "target_ttd", op = ">=", value = 8 },
                { type = "dot_missing", spellKey = "Corruption" },
            },
        },
        {
            key = "Immolate",
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_immolate" },
                { type = "target_valid" },
                { type = "state_compare", subject = "target_ttd", op = ">=", value = 8 },
                { type = "dot_missing", spellKey = "Immolate" },
            },
        },

        -- ── DRAIN SOUL (shards + mana on dying mobs) ────────────────
        {
            key = "Drain Soul",
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_drain_soul" },
                { type = "in_combat" },
                { type = "target_valid" },
                { type = "state_compare", subject = "target_hp_pct", op = "<", value = "drainSoulHpPct" },
                { type = "state_compare", subject = "target_ttd", op = "<", value = 10 },
                { type = "not_recently_cast", spellKey = "Drain Soul", window = 1.5 },
            },
        },

        -- ── FILLER ──────────────────────────────────────────────────
        {
            key = "Shadow Bolt",
            conditions = {
                { type = "target_valid" },
                { type = "not_is_moving" },
            },
        },

        -- ── SELF-HEAL / MANA ────────────────────────────────────────
        {
            key = "Drain Life",
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_drain_life" },
                { type = "in_combat" },
                { type = "target_valid" },
                { type = "state_compare", subject = "player_hp_pct", op = "<", value = "drainLifeHpPct" },
            },
        },
        {
            key = "Life Tap",
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_life_tap" },
                { type = "state_compare", subject = "player_mana_pct", op = "<", value = "lifeTapManaPct" },
            },
        },

        -- ── CONSUMABLES / TRINKETS ──────────────────────────────────
        {
            key = "POTION",
            optional = true,
            conditions = {
                { type = "spec_option_enabled", optionKey = "suggestPot" },
                { type = "state_compare", subject = "player_mana_pct", op = "<", value = "potManaThreshold" },
                { type = "item_ready_and_owned" },
            },
        },
        {
            key = "RUNE",
            optional = true,
            conditions = {
                { type = "spec_option_enabled", optionKey = "suggestRune" },
                { type = "state_compare", subject = "player_mana_pct", op = "<", value = "runeManaThreshold" },
                { type = "item_ready_and_owned" },
            },
        },
        {
            key = "TRINKET1",
            optional = true,
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_trinket_1" },
                { type = "target_valid" },
                { type = "trinket_ready", slot = 13 },
                { type = "classification_any_target", settingKey = "trinket_1_classification" },
            },
        },
        {
            key = "TRINKET2",
            optional = true,
            conditions = {
                { type = "spec_option_enabled", optionKey = "use_trinket_2" },
                { type = "target_valid" },
                { type = "trinket_ready", slot = 14 },
                { type = "classification_any_target", settingKey = "trinket_2_classification" },
            },
        },
    },

    -- SP-style context extension: DoT remaining aliases.
    buildContext = function(ctx, spec)
        local castRem = ctx.castRemaining or 0
        for _, td in ipairs({ "Curse of Agony", "Corruption", "Immolate" }) do
            local st = ctx.trackedDebuffsBySpellKey and ctx.trackedDebuffsBySpellKey[td]
            local alias = td:gsub(" ", ""):lower()
            ctx[alias .. "Rem"]   = (st and st.remaining) or 0
            ctx[alias .. "After"] = math.max((st and st.remaining or 0) - castRem, 0)
        end
    end,
}

if A.SpecManager then A.SpecManager:RegisterSpec(spec) end
