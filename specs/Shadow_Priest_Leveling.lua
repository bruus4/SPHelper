------------------------------------------------------------------------
-- SPHelper  –  specs/Shadow_Priest_Leveling.lua
-- Shadow Priest SOLO LEVELING rotation (levels 1–69).
--
-- Based on TBC-era leveling best practices:
--   • Wand DPS outperforms Smite at nearly all levels; wand is primary filler.
--   • Spirit Tap procs on killing blow, doubles spirit for 15s → drink during proc.
--   • Power Word: Shield up before pulling (absorbs damage, reduces healing needs).
--   • Vampiric Embrace threshold: activate when HP ≤60%, expire after fight.
--   • Shadowform blocks Holy spells only; re-entering costs ~15%+ mana.
--   • Fear for utility on elites/dungeons (kiting, interrupting casts).
--
-- Two modes auto-detected via target classification:
--   – Normal mobs: sustainable mana rotation, wand-heavy, rarely drink.
--   – Elites/Dungeons: max DPS + survivability with fear utility.
--
-- This spec is opt-in (like all non-reference specs): enable it via /sph.
-- It activates below level 70 while the Shadow tree has the most points;
-- at 70 the normal Shadow Priest raid spec takes over.
------------------------------------------------------------------------
local A = SPHelper
local T = A.SpecTemplates

local spec = {
    _fromFile = true,
    meta = { id = "shadow_priest_leveling", class = "PRIEST", specName = "Shadow (Leveling)", author = "SPHelper", version = 1 },
    loadConditions = { class = "PRIEST", talentTab = 3, minLevel = 1, maxLevel = 69 },
    helpers = { "CastBar", "DotTracker", "Rotation", "RotationEngine", "SpellData", "SpecUI", "Config" },
    constants = { SAFETY = 0.5, timing = { globalWaitThresholdMs = 400, defaultDelayToleranceMs = 600, dotSafeWindowSec = 1.5 } },

    ------------------------------------------------------------------------
    -- Tracked debuffs (SW:P for uptime monitoring)
    ------------------------------------------------------------------------
    trackedDebuffs = {
        { key = "shadow_word_pain", spellKey = "Shadow Word: Pain", color = "SWP", isDot = true },
    },

    ------------------------------------------------------------------------
    -- Tracked buffs (Spirit Tap, Shield, Shadowform, Inner Fire, VE)
    ------------------------------------------------------------------------
    trackedBuffs = {
        { key = "spirit_tap", name = "Spirit Tap", spellKey = nil },  -- procs on killing blow; no catalog entry needed
        { key = "power_word_shield", name = "Power Word: Shield", spellKey = "Power Word: Shield" },
        { key = "shadowform", name = "Shadowform", spellKey = "Shadowform" },
        { key = "inner_fire", name = "Inner Fire", spellKey = "Inner Fire" },
        { key = "vampiric_embrace", name = "Vampiric Embrace", spellKey = "Vampiric Embrace" },
    },

    ------------------------------------------------------------------------
    -- Settings definitions (General tab)
    ------------------------------------------------------------------------
    settingDefs = {
        -- ── PRE-PULL BUFFS ───────────────────────────────────────────────
        use_shield         = { type = "checkbox", label = "Use Power Word: Shield", default = true, group = "Pre-pull Buffs",
                               tooltip = "Keep Power Word: Shield up before pulling (absorbs damage)." },
        shieldRefreshSeconds = { type = "slider", label = "Shield refresh window", default = 10, min = 5, max = 30, step = 5, group = "Pre-pull Buffs",
                               tooltip = "Recast Shield when it has this many seconds or less remaining." },
        use_inner_fire     = { type = "checkbox", label = "Use Inner Fire (12+)", default = true, group = "Pre-pull Buffs",
                               tooltip = "Keep Inner Fire up for armor (requires level 12)." },
        use_fortitude      = { type = "checkbox", label = "Use Power Word: Fortitude", default = true, group = "Pre-pull Buffs",
                               tooltip = "Keep Power Word: Fortitude up for stamina." },

        -- ── COMBAT BUFFS / FORMS ────────────────────────────────────────
        use_shadowform     = { type = "checkbox", label = "Use Shadowform (40+)", default = true, group = "Combat Buffs & Forms",
                               tooltip = "Enter Shadowform at level 40+ for damage bonus." },
        use_ve             = { type = "checkbox", label = "Use Vampiric Embrace (30+)", default = true, group = "Combat Buffs & Forms",
                               tooltip = "Vampiric Embrace converts shadow damage to healing. Activates when HP is low." },
        veHpPct            = { type = "slider", label = "VE activate HP %", default = 60, min = 30, max = 80, step = 5, group = "Combat Buffs & Forms",
                               tooltip = "Cast Vampiric Embrace when your HP drops below this %." },

        -- ── DoTs ────────────────────────────────────────────────────────
        use_swp            = { type = "checkbox", label = "Use Shadow Word: Pain (4+)", default = true, group = "DoTs",
                               tooltip = "Maintain SW:P on target for damage over time." },

        -- ── DAMAGE SPELLS ───────────────────────────────────────────────
        use_mind_blast     = { type = "checkbox", label = "Use Mind Blast (10+)", default = true, group = "Damage Spells",
                               tooltip = "Cast Mind Blast on cooldown for burst damage." },
        use_smite          = { type = "checkbox", label = "Use Smite (no wand)", default = false, group = "Damage Spells",
                               tooltip = "Use Smite as filler when no wand is equipped. Off by default since wand DPS > Smite." },

        -- ── FILLER / WAND ───────────────────────────────────────────────
        use_wand           = { type = "checkbox", label = "Suggest Wand (when equipped)", default = true, group = "Filler & Mana",
                               tooltip = "Show wand as filler when you have a wand equipped and are out of melee range." },
        wandStartManaPct   = { type = "slider", label = "Wand start mana %", default = 30, min = 10, max = 60, step = 5, group = "Filler & Mana",
                               tooltip = "Switch to wand when mana drops below this %." },
        wandStartHpPct     = { type = "slider", label = "Wand start target HP %", default = 45, min = 20, max = 70, step = 5, group = "Filler & Mana",
                               tooltip = "Switch to wand when target is below this HP % (fight almost over)." },

        -- ── UTILITY / SURVIVAL ──────────────────────────────────────────
        use_fear           = { type = "checkbox", label = "Use Psychic Scream (elite/dungeon)", default = true, group = "Utility & Survival",
                               tooltip = "Suggest Psychic Scream (fear) on elite+ targets for kiting/interrupting casts." },

        -- ── CONSUMABLES ─────────────────────────────────────────────────
        suggestPot         = { type = "checkbox", label = "Suggest mana potion", default = true, group = "Consumables",
                               tooltip = "Show mana potion suggestion when low on mana." },
        potManaThreshold   = { type = "slider", label = "Potion mana %", default = 15, min = 5, max = 40, step = 5, group = "Consumables",
                               tooltip = "Suggest potion when mana below this %." },
    },

    settingOrder = {
        "use_shield", "shieldRefreshSeconds",
        "use_inner_fire", "use_fortitude",
        "use_shadowform", "use_ve", "veHpPct",
        "use_swp",
        "use_mind_blast", "use_smite",
        "use_wand", "wandStartManaPct", "wandStartHpPct",
        "use_fear",
        "suggestPot", "potManaThreshold",
    },

    ------------------------------------------------------------------------
    -- Rotation priorities (data-driven)
    -- Order = priority; first matching entry wins.
    -- Level gating is implicit: cooldown_ready returns false if spell unknown.
    ------------------------------------------------------------------------
    rotation = {
        -- ── PRE-COMBAT BUFFS ─────────────────────────────────────────────

        -- Power Word: Fortitude (pre-pull stamina buff)
        {
            key = "Power Word: Fortitude",
            conditions = {
                T.SpecOption("use_fortitude"),
                T.Precombat(),
                T.BuffMissingOnPlayer("Power Word: Fortitude"),
            },
        },

        -- Inner Fire (pre-pull spell power buff, 40+)
        {
            key = "Inner Fire",
            conditions = {
                T.SpecOption("use_inner_fire"),
                T.Precombat(),
                T.BuffMissingOnPlayer("Inner Fire"),
            },
        },

        -- Power Word: Shield (pre-pull absorb shield)
        {
            key = "Power Word: Shield",
            conditions = {
                T.SpecOption("use_shield"),
                T.Precombat(),
                T.BuffMissingOnPlayer("Power Word: Shield"),
            },
        },

        -- ── COMBAT BUFFS / FORMS (in-combat) ─────────────────────────────

        -- Shadowform on pull (40+)
        {
            key = "Shadowform",
            conditions = {
                T.SpecOption("use_shadowform"),
                T.InCombat(),
                T.TargetValid(),
                T.BuffMissingOnPlayer("Shadowform"),
                T.NotRecentlyCast("Shadowform", 5),  -- don't spam if just lost it
            },
        },

        -- Vampiric Embrace when low HP (30+, elites/dungeons)
        {
            key = "Vampiric Embrace",
            conditions = {
                T.SpecOption("use_ve"),
                T.InCombat(),
                T.TargetValid(),
                T.BuffMissingOnPlayer("Vampiric Embrace"),
                T.StateCompare("player_hp_pct", "<", "veHpPct"),
            },
        },

        -- ── PRE-PULL SHIELD REFRESH (if shield is about to expire) ───────
        {
            key = "Power Word: Shield",
            conditions = {
                T.SpecOption("use_shield"),
                T.TargetValid(),
                T.BuffPropertyCompare("Power Word: Shield", "remaining", "<", "shieldRefreshSeconds"),
            },
        },

        -- ── DoTs ─────────────────────────────────────────────────────────

        -- Shadow Word: Pain (4+, maintain uptime)
        {
            key = "Shadow Word: Pain",
            conditions = {
                T.SpecOption("use_swp"),
                T.TargetValid(),
                T.DotMissing("Shadow Word: Pain"),
                T.StateCompare("target_ttd", ">=", 8),  -- don't waste on dying mobs
            },
        },

        -- ── BURST / HIGH PRIORITY DAMAGE ─────────────────────────────────

        -- Mind Blast on cooldown (10+, highest priority damage)
        {
            key = "Mind Blast",
            conditions = {
                T.SpecOption("use_mind_blast"),
                T.TargetValid(),
                T.CooldownReady("Mind Blast"),
            },
        },

        -- ── UTILITY: Fear on elite+ targets ──────────────────────────────

        -- Fear for kiting/interrupting (elite/dungeon only)
        {
            key = "Psychic Scream",
            conditions = {
                T.SpecOption("use_fear"),
                T.InCombat(),
                T.TargetValid(),
                T.CooldownReady("Psychic Scream"),
                T.AnyOf({
                    { type = "target_classification", classification = "elite" },
                    { type = "target_classification", classification = "boss" },
                }),
            },
        },

        -- ── FILLER: Wand (when equipped and out of melee) ────────────────

        -- Wand filler when mana is low OR target nearly dead OR shield broken
        {
            key = "WAND",
            optional = true,
            conditions = {
                T.SpecOption("use_wand"),
                T.TargetValid(),
                T.WandEquipped(),
                T.NotMeleeRange(),  -- must be out of melee distance to use wand
                T.AnyOf({
                    T.StateCompare("player_mana_pct", "<", "wandStartManaPct"),
                    T.StateCompare("target_hp_pct", "<", "wandStartHpPct"),
                    T.BuffMissingOnPlayer("Power Word: Shield"),  -- shield broken → kite with wand
                }),
            },
        },

        -- ── FILLER: Smite (only if no wand equipped) ─────────────────────

        -- Smite as fallback filler when no wand is available
        {
            key = "Smite",
            conditions = {
                T.SpecOption("use_smite"),
                T.TargetValid(),
                T.NotIsMoving(),  -- can't cast while moving
            },
        },

        -- ── CONSUMABLES ──────────────────────────────────────────────────

        -- Mana potion suggestion
        {
            key = "POTION",
            optional = true,
            conditions = {
                T.SpecOption("suggestPot"),
                T.StateCompare("player_mana_pct", "<", "potManaThreshold"),
                T.ItemReadyByKey("selectedPotionItem"),
            },
        },
    },

    ------------------------------------------------------------------------
    -- SP-style context extension: tracked buff aliases.
    ------------------------------------------------------------------------
    buildContext = function(ctx, spec)
        local castRem = ctx.castRemaining or 0

        -- SW:P remaining alias for conditions
        local swpState = (ctx.trackedDebuffsBySpellKey and ctx.trackedDebuffsBySpellKey["Shadow Word: Pain"])
        if swpState then
            ctx.swpRem   = swpState.remaining or 0
            ctx.swpAfter = math.max((swpState.remaining or 0) - castRem, 0)
        end

        -- Shield remaining alias for conditions
        local shieldBuff = (ctx.trackedBuffsBySpellKey and ctx.trackedBuffsBySpellKey["Power Word: Shield"])
        if shieldBuff then
            ctx.shieldActive = shieldBuff.active or false
        else
            ctx.shieldActive = false
        end

        -- Spirit Tap active alias (checked via UnitBuff scan)
        local spiritTapActive = false
        for i = 1, 40 do
            local bname = UnitBuff("player", i)
            if not bname then break end
            if bname == "Spirit Tap" then
                spiritTapActive = true
                break
            end
        end
        ctx.spiritTapActive = spiritTapActive

        -- Shadowform active alias
        local sfState = (ctx.trackedBuffsBySpellKey and ctx.trackedBuffsBySpellKey["Shadowform"])
        ctx.shadowformActive = (sfState and sfState.active) or false

        -- Inner Fire active alias
        local ifState = (ctx.trackedBuffsBySpellKey and ctx.trackedBuffsBySpellKey["Inner Fire"])
        ctx.innerFireActive = (ifState and ifState.active) or false

        -- Vampiric Embrace active alias
        local veState = (ctx.trackedBuffsBySpellKey and ctx.trackedBuffsBySpellKey["Vampiric Embrace"])
        ctx.veActive = (veState and veState.active) or false
    end,
}

if A.SpecManager then A.SpecManager:RegisterSpec(spec) end
