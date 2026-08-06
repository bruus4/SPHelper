------------------------------------------------------------------------
-- SPHelper  â€“  SpellDatabase.lua
-- Static spell catalog plus ID-first spellbook resolution.
-- The catalog stores stable low-rank/base spell IDs and useful non-API
-- metadata; runtime entries resolve to the player's effective known rank.
------------------------------------------------------------------------
local A = SPHelper

A.SpellDatabase = A.SpellDatabase or {}
local DB = A.SpellDatabase

local ipairs = ipairs
local pairs = pairs
local sort = table.sort
local type = type
local tonumber = tonumber

local function RawIsSpellKnown(spellId)
    if type(spellId) ~= "number" then return false end
    if IsSpellKnown and IsSpellKnown(spellId) then
        return true
    end
    if type(IsPlayerSpell) == "function" then
        return IsPlayerSpell(spellId) and true or false
    end
    return false
end

local function GetRankNumber(rankText)
    if type(rankText) ~= "string" or rankText == "" then
        return nil
    end
    local numberText = rankText:match("(%d+)")
    return numberText and tonumber(numberText) or nil
end

------------------------------------------------------------------------
-- Schema notes
-- minLevel       : required character level to train/use the spell
-- talentUnlock   : {tab, index, minRank} â€“ gated behind this talent; nil = base class spell
-- hasteType      : "spell" (reduces cast time) | "channel" (reduces tick interval)
--                  | "gcd" (reduces GCD only) | "none"
-- gcd            : "none" = this spell does NOT trigger the global cooldown
--                  (e.g. Inner Focus, trinkets).  Omitted = triggers GCD.
-- critMultiplier : multiplier applied on a critical hit (1.5 typical, 2.0 some)
-- threatMultiplier: threat generated per unit of damage/healing done.
--   TBC Classic rules: direct damage = 1x; DoT ticks = 1.3x per tick;
--   channeled spells = 1x per tick; healing = 0.5x heal amount.
-- debuffId       : aura ID this spell applies to the enemy
-- buffId         : aura ID this spell applies to self / ally
-- talentModifiers: per-spell array of talent entries that modify this spell
--   { name, tab, index, maxRank, perRank, affects }
--   affects values: duration | damage | cooldown | crit_bonus | hit | ticks
-- debuffAura     : exact in-game aura/debuff name shown on target (for API matching)
-- debuffExclusive: true if only one variant of this debuff can be active at a time
-- debuffSiblings : array of sibling spell keys that share the same exclusive aura slot
-- debuffMutuallyExclusive: array of spell keys that are mutually exclusive with this debuff.
--   Used for curse checking (each warlock has one curse slot), armor reduction debuffs, etc.
--   If ANY of these is active from THIS player on target, don't apply this debuff.
-- debuffStackingMode: how this debuff stacks across multiple players/sources.
--   Values:
--     "per_player"         - Each player applies their own copy; damage/effects stack (e.g., VT, SWP)
--     "single_any_source"  - Only one copy matters regardless of source; check any source (Faerie Fire variants)
--     "single_curse_slot"  - Warlock curse: each warlock has one slot per target; effect doesn't stack across locks
--     "stacks_damage_only" - Multiple sources apply but only damage stacks, not secondary effects (CoA, CoD)
--     "strongest_wins"     - Only strongest version active; check any source (Hunter's Mark)
------------------------------------------------------------------------
DB.catalog = {
    ------------------------------------------------------------------------
    -- PRIEST â€“ Shadow
    ------------------------------------------------------------------------
    ["Vampiric Touch"] = {
        class = "PRIEST",
        spec = "SHADOW",
        name = "Vampiric Touch",
        baseId = 34914,
        minLevel = 70,
        talentUnlock = { tab = 3, index = 22, minRank = 1 },
        school = "shadow",
        schoolMask = 32,
        castType = "cast",
        castTime = 1.5,
        hasteType = "spell",
        duration = 15,
        ticks = 5,
        tickInterval = 3,
        range = 30,
        critMultiplier = 1.5,
        debuffId = 34914,
        flags = { offensive = true, dot = true, magical = true },
        coefficients = { spellPower = 1.0 },
        damage = { estimateBase = 650, perTickBase = 130 },
        threatMultiplier = 1.3, -- DoT ticks: 1.3x per tick (TBC Classic)
        manaCost = 425, -- TBC max rank (34917)
        debuffStackingMode = "per_player", -- Each priest applies own VT; damage stacks across priests
        talentModifiers = {},
    },
    ["Shadow Word: Pain"] = {
        class = "PRIEST",
        spec = "SHADOW",
        name = "Shadow Word: Pain",
        baseId = 589,
        minLevel = 4,
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "none",
        duration = 18,
        ticks = 6,
        tickInterval = 3,
        range = 30,
        critMultiplier = 1.5,
        debuffId = 589,
        flags = { offensive = true, dot = true, magical = true },
        coefficients = { spellPower = 1.10 },
        damage = { estimateBase = 1236, perTickBase = 206 },
        threatMultiplier = 1.3, -- DoT ticks: 1.3x per tick (TBC Classic)
        manaCost = 510, -- TBC max rank (25367)
        debuffStackingMode = "per_player", -- Each priest applies own SWP; damage stacks across priests
        talentModifiers = {
            { name = "Improved Shadow Word: Pain",  tab = 3, index = 4,  maxRank = 2, perRank = 3,    affects = "duration" },
        },
    },
    ["Mind Blast"] = {
        class = "PRIEST",
        spec = "SHADOW",
        name = "Mind Blast",
        baseId = 8092,
        minLevel = 10,
        school = "shadow",
        schoolMask = 32,
        castType = "cast",
        castTime = 1.5,
        hasteType = "spell",
        range = 30,
        critMultiplier = 1.5,
        flags = { offensive = true, direct = true, magical = true, cooldown = true },
        coefficients = { spellPower = 0.429 },
        damage = { estimateBase = 731 },
        threatMultiplier = 1.0, -- Direct damage: 1x (TBC Classic)
        manaCost = 350, -- TBC max rank (10947)
        talentModifiers = {
            { name = "Improved Mind Blast",   tab = 3, index = 12, maxRank = 5, perRank = -0.5,  affects = "cooldown" },
            { name = "Shadow Power",  tab = 3, index = 20, maxRank = 5, perRank = 0.03,  affects = "crit_bonus" },
        },
    },
    ["Mind Flay"] = {
        class = "PRIEST",
        spec = "SHADOW",
        name = "Mind Flay",
        baseId = 15407,
        minLevel = 20,
        talentUnlock = { tab = 3, index = 11, minRank = 1 },
        school = "shadow",
        schoolMask = 32,
        castType = "channel",
        castTime = 3.0,
        hasteType = "channel",
        duration = 3,
        ticks = 3,
        tickInterval = 1,
        allowClipping = true,
        range = 20,
        critMultiplier = 1.5,
        debuffId = 15407,
        flags = { offensive = true, channel = true, dot = true, magical = true },
        coefficients = { spellPower = 0.57 },
        damage = { estimateBase = 528, perTickBase = 176 },
        debuffStackingMode = "per_player", -- Each priest channels own Mind Flay; damage stacks across priests
        threatMultiplier = 1.0, -- Channeled: 1x per tick (TBC Classic)
        manaCost = 230, -- TBC max rank (25387)
        talentModifiers = {
            { name = "Shadow Power",  tab = 3, index = 20, maxRank = 5, perRank = 0.03,  affects = "crit_bonus" },
        },
    },
    ["Shadow Word: Death"] = {
        class = "PRIEST",
        spec = "SHADOW",
        name = "Shadow Word: Death",
        baseId = 32379,
        minLevel = 62,
        talentUnlock = { tab = 3, index = 19, minRank = 1 },
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        range = 30,
        critMultiplier = 1.5,
        flags = { offensive = true, direct = true, magical = true },
        coefficients = { spellPower = 0.429 },
        damage = { estimateBase = 572 },
        threatMultiplier = 1.0, -- Direct instant: 1x (TBC Classic)
        manaCost = 309, -- TBC max rank (32996)
        talentModifiers = {
            { name = "Shadow Power",  tab = 3, index = 20, maxRank = 5, perRank = 0.03,  affects = "crit_bonus" },
        },
    },
    ["Devouring Plague"] = {
        class = "PRIEST",
        spec = "SHADOW",
        name = "Devouring Plague",
        baseId = 2944,
        minLevel = 20,
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "none",
        duration = 24,
        ticks = 8,
        tickInterval = 3,
        range = 30,
        critMultiplier = 1.5,
        debuffId = 2944,
        flags = { offensive = true, dot = true, magical = true },
        coefficients = { spellPower = 0.80 },
        damage = { estimateBase = 1216, perTickBase = 152 },
        threatMultiplier = 1.3, -- DoT ticks: 1.3x per tick (TBC Classic)
        manaCost = 1145, -- TBC max rank (25467)
        debuffStackingMode = "per_player", -- Each priest applies own Devouring Plague; damage stacks across priests
        talentModifiers = {},
    },
    ["Shadowfiend"] = {
        class = "PRIEST",
        spec = "SHADOW",
        name = "Shadowfiend",
        baseId = 34433,
        minLevel = 66,
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        range = 30,
        critMultiplier = 1.5,
        flags = { cooldown = true, summon = true, offensive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
        manaCostPct = 0.06, -- 6% of base mana (TBC Classic)
    },
    ["Vampiric Embrace"] = {
        class = "PRIEST",
        spec = "SHADOW",
        name = "Vampiric Embrace",
        baseId = 15286,
        minLevel = 30,
        talentUnlock = { tab = 3, index = 7, minRank = 1 },
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        duration = -1,
        buffId = 15286,
        flags = { buff = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
        manaCostPct = 0.02, -- 2% of base mana (TBC Classic)
    },
    ["Shadowform"] = {
        class = "PRIEST",
        spec = "SHADOW",
        name = "Shadowform",
        baseId = 15473,
        minLevel = 40,
        talentUnlock = { tab = 3, index = 14, minRank = 1 },
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        duration = -1,
        buffId = 15473,
        flags = { form = true, buff = true },
        talentModifiers = {
            { name = "Shadow Weaving", tab = 3, index = 15, maxRank = 5, perRank = 0.02, affects = "damage" },
            { name = "Darkness",       tab = 3, index = 16, maxRank = 5, perRank = 0.02, affects = "damage" },
        },
        threatMultiplier = 1.0,  -- Direct damage / default
        manaCostPct = 0.32, -- 32% of base mana (TBC Classic)
    },
    ["Inner Focus"] = {
        class = "PRIEST",
        spec = "DISCIPLINE",
        name = "Inner Focus",
        baseId = 14751,
        minLevel = 20,
        talentUnlock = { tab = 1, index = 5, minRank = 1 },
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        gcd = "none", -- Inner Focus does NOT trigger the global cooldown
        buffId = 14751,
        flags = { cooldown = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
        manaCost = 0, -- no mana cost (free buff)
    },
    ["Mind Soothe"] = {
        class = "PRIEST",
        spec = "DISCIPLINE",
        name = "Mind Soothe",
        baseId = 453,
        minLevel = 20,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        range = 20,
        debuffId = 453,
        flags = { utility = true, debuff = true },
        debuffStackingMode = "single_any_source", -- Only one instance matters; check any source regardless of who cast it
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Shackle Undead"] = {
        class = "PRIEST",
        spec = "DISCIPLINE",
        name = "Shackle Undead",
        baseId = 9484,
        minLevel = 20,
        school = "holy",
        schoolMask = 2,
        castType = "cast",
        castTime = 1.5,
        hasteType = "spell",
        duration = 50,
        range = 30,
        critMultiplier = 1.5,
        debuffId = 9484,
        flags = { control = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    -- Priest class-wide utility
    ["Dispel Magic"] = {
        class = "PRIEST",
        spec = nil,
        name = "Dispel Magic",
        baseId = 527,
        minLevel = 18,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        range = 30,
        flags = { utility = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Fade"] = {
        class = "PRIEST",
        spec = nil,
        name = "Fade",
        baseId = 586,
        minLevel = 10,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 10,
        buffId = 586,
        flags = { defensive = true, utility = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
        manaCost = 330, -- TBC max rank (25429)
    },

    ------------------------------------------------------------------------
    -- PRIEST – Leveling / Utility spells (used by Shadow_Priest_Leveling spec)
    ------------------------------------------------------------------------
    ["Smite"] = {
        class = "PRIEST",
        spec = nil,
        name = "Smite",
        baseId = 585,
        minLevel = 1,
        school = "holy",
        schoolMask = 2,
        castType = "cast",
        castTime = 1.5,
        hasteType = "spell",
        range = 40,
        critMultiplier = 1.5,
        flags = { offensive = true, direct = true, magical = true },
        coefficients = { spellPower = 0.67 },
        damage = { estimateBase = 280 },
        threatMultiplier = 1.0,
        manaCost = 385, -- TBC max rank (25364)
        talentModifiers = {},
    },
    ["Power Word: Shield"] = {
        class = "PRIEST",
        spec = nil,
        name = "Power Word: Shield",
        baseId = 17,
        minLevel = 6,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        range = 40,
        buffId = 17,
        flags = { defensive = true, magical = true },
        coefficients = { spellPower = 0.38 },
        threatMultiplier = 1.0,
        manaCost = 600, -- TBC max rank (25218)
        talentModifiers = {},
    },
    ["Psychic Scream"] = {
        class = "PRIEST",
        spec = nil,
        name = "Psychic Scream",
        baseId = 8122,
        minLevel = 14,
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        duration = 8,
        range = 8,
        debuffId = 8122,
        flags = { control = true, magical = true },
        threatMultiplier = 1.0,
        manaCost = 180, -- TBC max rank (10888)
        talentModifiers = {},
    },
    ["Inner Fire"] = {
        class = "PRIEST",
        spec = nil,
        name = "Inner Fire",
        baseId = 588,
        minLevel = 12,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 600,
        buffId = 588,
        flags = { buff = true, magical = true },
        threatMultiplier = 1.0,
        manaCost = 375, -- TBC max rank (25431)
        talentModifiers = {},
    },
    ["Power Word: Fortitude"] = {
        class = "PRIEST",
        spec = nil,
        name = "Power Word: Fortitude",
        baseId = 1243,
        minLevel = 1,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 1800,
        range = 40,
        buffId = 1243,
        flags = { buff = true, magical = true },
        threatMultiplier = 1.0,
        manaCost = 700, -- TBC max rank (25389, Rank 7): 700 mana post-2.3 (was 2080 pre-2.3)
        talentModifiers = {},
    },

    ------------------------------------------------------------------------
    -- DRUID â€" Feral
    ------------------------------------------------------------------------
    ["Shred"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Shred",
        baseId = 5221,
        minLevel = 22,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        critMultiplier = 2.0,
        resourceCost = 42,
        comboPointsGenerated = 1,
        flags = { offensive = true, builder = true, requiresBehind = true, requiresCatForm = true },
        coefficients = { attackPower = 1.0 },
        damage = { bonusVsBleeding = 224 },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Mangle (Cat)"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Mangle (Cat)",
        baseId = 33876,
        minLevel = 62,
        talentUnlock = { tab = 2, index = 17, minRank = 1 },
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 12,
        critMultiplier = 2.0,
        debuffId = 33876,
        debuffAura = "Mangle (Cat)",         -- exact in-game debuff name shown on target
        debuffExclusive = true,              -- only one Mangle debuff can be active at a time
        debuffSiblings = { "Mangle (Bear)" },  -- Bear form Mangle shares same aura slot
        debuffStackingMode = "single_any_source", -- Only one Mangle aura matters; check any source regardless of who cast it
        resourceCost = 40,
        comboPointsGenerated = 1,
        flags = { offensive = true, builder = true, debuff = true, requiresCatForm = true },
        coefficients = { attackPower = 1.0 },
        damage = { bleedBonusFlat = 159 },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Rip"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Rip",
        baseId = 1079,
        minLevel = 20,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 12,
        ticks = 6,
        tickInterval = 2,
        critMultiplier = 2.0,
        debuffId = 1079,
        resourceCost = 30,
        comboPointsConsumed = "all",
        flags = { offensive = true, bleed = true, finisher = true, requiresCatForm = true },
        comboScaling = { pointsPerComboPoint = 4 },
        debuffStackingMode = "per_player", -- Each druid applies own Rip; damage stacks across druids
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Faerie Fire (Feral)"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Faerie Fire (Feral)",
        baseId = 16857,
        minLevel = 10,
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        hasteType = "gcd",
        duration = 40,
        cooldown = 6,
        debuffId = 16857,
        debuffAura = "Faerie Fire",          -- actual aura name on target; "(Feral)" is only the spellbook label
        debuffExclusive = true,              -- only one Faerie Fire variant can be active
        debuffSiblings = { "Faerie Fire" },  -- Balance version is mutually exclusive
        debuffStackingMode = "single_any_source", -- Only one FF variant ever; check any source regardless of who cast it
        flags = { offensive = true, debuff = true, armorReduction = true, requiresForm = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Ferocious Bite"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Ferocious Bite",
        baseId = 22568,
        minLevel = 32,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        critMultiplier = 2.0,
        resourceCost = 35,
        comboPointsConsumed = "all",
        flags = { offensive = true, finisher = true, requiresCatForm = true, consumesExtraEnergy = true },
        -- Rank 9 (level 70): base damage range 357-514; use conservative floor for kill prediction.
        damage = { estimateBase = 357 },
        coefficients = { attackPower = 0.07 },  -- AP coefficient ~0.07 per combo point (Ã—CP applied in evaluator)
        comboScaling = { pointsPerComboPoint = 36 },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Rake"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Rake",
        baseId = 1822,
        minLevel = 14,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 9,
        ticks = 3,
        tickInterval = 3,
        critMultiplier = 2.0,
        debuffId = 1822,
        resourceCost = 35,
        comboPointsGenerated = 1,
        flags = { offensive = true, bleed = true, builder = true, requiresCatForm = true },
        debuffStackingMode = "per_player", -- Each druid applies own Rake; damage stacks across druids
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Tiger's Fury"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Tiger's Fury",
        baseId = 5217,
        minLevel = 30,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 6,
        resourceCost = 30,
        buffId = 5217,
        flags = { buff = true, requiresCatForm = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Clearcasting"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Clearcasting",
        baseId = 16870,
        school = "nature",
        schoolMask = 8,
        castType = "passive",
        hasteType = "none",
        buffId = 16870,
        flags = { buff = true, proc = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Cat Form"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Cat Form",
        baseId = 768,
        minLevel = 20,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = -1,
        buffId = 768,
        grantsFormKey = "cat_form",          -- simulation: activates this form buff key
        removesFormKeys = { "bear_form", "dire_bear_form", "stealth" },
        flags = { form = true, stance = true },
        talentModifiers = {},
        -- How much energy is restored when shifting into Cat Form.
        -- Base = 0; each rank of Furor adds 8 energy (Restoration tree tab 3,
        -- talent index 2, 5 ranks max = 40 energy).  Equipping Wolfshead Helm
        -- (item ID 8345, head slot 1) adds a further 20 energy.
        -- A.ComputePowershiftEnergy() reads this table at runtime.
        powershiftCalc = {
            base = 0,
            talentModifiers = {
                {
                    talentName    = "Furor",
                    tab           = 3,       -- Restoration tree
                    index         = 2,       -- second talent in tier 1
                    energyPerRank = 8,       -- 8 energy per rank, 5 ranks max = 40
        threatMultiplier = 1.0,  -- Direct damage / default
                },
            },
            itemModifiers = {
                {
                    description = "Wolfshead Helm",
                    slot        = 1,         -- head slot
                    itemId      = 8345,
                    bonus       = 20,
                },
            },
        },
    },
    ["Bear Form"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Bear Form",
        baseId = 5487,
        minLevel = 10,
        resolveIds = { 9634, 5487 },
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = -1,
        buffId = 5487,
        grantsFormKey = "bear_form",
        removesFormKeys = { "cat_form", "dire_bear_form", "stealth" },
        flags = { form = true, stance = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Dire Bear Form"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Dire Bear Form",
        baseId = 9634,
        minLevel = 40,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = -1,
        buffId = 9634,
        grantsFormKey = "dire_bear_form",
        removesFormKeys = { "cat_form", "bear_form", "stealth" },
        flags = { form = true, stance = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Mangle (Bear)"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Mangle (Bear)",
        baseId = 33987,
        minLevel = 62,
        talentUnlock = { tab = 2, index = 17, minRank = 1 },
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 12,
        cooldown = 6,
        critMultiplier = 2.0,
        debuffId = 33876,
        debuffAura = "Mangle (Cat)",         -- same in-game debuff aura as Mangle (Cat)
        debuffExclusive = true,              -- only one Mangle debuff can be active at a time
        debuffSiblings = { "Mangle (Cat)" },  -- Cat form Mangle shares same aura slot
        debuffStackingMode = "single_any_source", -- Only one Mangle aura matters; check any source regardless of who cast it
        resourceCost = 20,
        flags = { offensive = true, builder = true, debuff = true, requiresBearForm = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Lacerate"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Lacerate",
        baseId = 33745,
        minLevel = 66,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 15,
        ticks = 5,
        tickInterval = 3,
        critMultiplier = 2.0,
        debuffId = 33745,
        resourceCost = 15,
        flags = { offensive = true, bleed = true, builder = true, requiresBearForm = true },
        debuffStackingMode = "per_player", -- Each druid applies own Lacerate stacks (up to 5); damage stacks across druids
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Swipe"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Swipe",
        baseId = 26997,
        minLevel = 16,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        critMultiplier = 2.0,
        resourceCost = 20,
        flags = { offensive = true, builder = true, requiresBearForm = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Maul"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Maul",
        baseId = 26996,
        minLevel = 10,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        critMultiplier = 2.0,
        resourceCost = 10,
        flags = { offensive = true, builder = true, requiresBearForm = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Demoralizing Roar"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Demoralizing Roar",
        baseId = 26998,
        minLevel = 10,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        debuffId = 26998,
        resourceCost = 10,
        flags = { debuff = true, utility = true, requiresBearForm = true },
        debuffStackingMode = "strongest_wins", -- Only strongest Demoralizing Roar active; check any source regardless of who cast it
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Enrage"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Enrage",
        baseId = 5229,
        minLevel = 12,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 10,
        cooldown = 60,
        buffId = 5229,
        flags = { buff = true, cooldown = true, requiresBearForm = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Frenzied Regeneration"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Frenzied Regeneration",
        baseId = 26999,
        minLevel = 22,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 10,
        cooldown = 180,
        resourceCost = 10,
        buffId = 26999,
        flags = { buff = true, cooldown = true, defensive = true, requiresBearForm = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Bash"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Bash",
        baseId = 8983,
        minLevel = 26,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 4,
        cooldown = 60,
        debuffId = 8983,
        resourceCost = 10,
        flags = { offensive = true, control = true, cooldown = true, requiresBearForm = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Innervate"] = {
        class = "DRUID",
        spec = nil,
        name = "Innervate",
        baseId = 29166,
        minLevel = 40,
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        hasteType = "gcd",
        duration = 20,
        buffId = 29166,
        flags = { buff = true, cooldown = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Prowl"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Prowl",
        baseId = 5215,
        minLevel = 20,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = -1,
        buffId = 5215,
        flags = { stealth = true, buff = true, requiresCatForm = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Pounce"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Pounce",
        baseId = 9005,
        minLevel = 28,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 3,
        debuffId = 9005,
        resourceCost = 50,
        comboPointsGenerated = 1,
        flags = { offensive = true, control = true, requiresStealth = true, requiresCatForm = true },
        damage = { triggerSpellId = 9007 },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Ravage"] = {
        class = "DRUID",
        spec = "FERAL",
        name = "Ravage",
        baseId = 6785,
        minLevel = 34,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        critMultiplier = 2.0,
        resourceCost = 60,
        comboPointsGenerated = 1,
        flags = { offensive = true, builder = true, requiresStealth = true, requiresBehind = true, requiresCatForm = true },
        coefficients = { attackPower = 1.0 },
        damage = { bonusFlat = 384 },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- DRUID â€“ Balance
    ------------------------------------------------------------------------
    ["Hurricane"] = {
        class = "DRUID",
        spec = nil,
        name = "Hurricane",
        baseId = 16914,
        minLevel = 40,
        school = "nature",
        schoolMask = 8,
        castType = "channel",
        castTime = 10.0,
        hasteType = "channel",
        duration = 10,
        ticks = 10,
        tickInterval = 1,
        range = 30,
        critMultiplier = 1.5,
        flags = { offensive = true, channel = true, dot = true, magical = true },
        coefficients = { spellPower = 0.571 },
        damage = { estimateBase = 1140, perTickBase = 114 },
        debuffStackingMode = "per_player", -- Each druid channels own Hurricane; damage stacks across druids
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Moonfire"] = {
        class = "DRUID",
        spec = "BALANCE",
        name = "Moonfire",
        baseId = 8921,
        minLevel = 4,
        school = "arcane",
        schoolMask = 64,
        castType = "instant",
        hasteType = "gcd",
        duration = 12,
        ticks = 4,
        tickInterval = 3,
        range = 30,
        critMultiplier = 1.5,
        debuffId = 8921,
        flags = { offensive = true, dot = true, direct = true, magical = true },
        coefficients = { spellPower = 0.15 },  -- direct hit portion; DoT portion ~0.52
        damage = { estimateBase = 876, perTickBase = 115 },
        debuffStackingMode = "per_player", -- Each druid applies own Moonfire; damage stacks across druids
        talentModifiers = {
            { name = "Moonfury",    tab = 1, index = 15, maxRank = 5, perRank = 0.02, affects = "damage" },
            { name = "Improved Moonfire", tab = 1, index = 4, maxRank = 2, perRank = 0.05, affects = "crit_bonus" },
        },
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Insect Swarm"] = {
        class = "DRUID",
        spec = "BALANCE",
        name = "Insect Swarm",
        baseId = 5570,
        minLevel = 20,
        talentUnlock = { tab = 1, index = 10, minRank = 1 },
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        hasteType = "none",
        duration = 12,
        ticks = 6,
        tickInterval = 2,
        range = 30,
        critMultiplier = 1.5,
        debuffId = 5570,
        flags = { offensive = true, dot = true, magical = true, debuff = true },
        coefficients = { spellPower = 0.122 },
        damage = { estimateBase = 444, perTickBase = 74 },
        debuffStackingMode = "per_player", -- Each druid applies own Insect Swarm; damage stacks across druids
        talentModifiers = {
            { name = "Improved Insect Swarm",  tab = 1, index = 11, maxRank = 3, perRank = 0.1, affects = "damage" },
        },
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Starfire"] = {
        class = "DRUID",
        spec = "BALANCE",
        name = "Starfire",
        baseId = 2912,
        minLevel = 20,
        school = "arcane",
        schoolMask = 64,
        castType = "cast",
        castTime = 3.5,
        hasteType = "spell",
        range = 30,
        critMultiplier = 1.5,
        flags = { offensive = true, direct = true, magical = true },
        coefficients = { spellPower = 1.0 },
        damage = { estimateBase = 1025 },
        talentModifiers = {
            { name = "Moonfury",      tab = 1, index = 15, maxRank = 5, perRank = 0.02, affects = "damage" },
            { name = "Starlightening",tab = 1, index = 16, maxRank = 3, perRank = 0.02, affects = "crit_bonus" },
        threatMultiplier = 1.0,  -- Direct damage / default
        },
    },
    ["Wrath"] = {
        class = "DRUID",
        spec = "BALANCE",
        name = "Wrath",
        baseId = 5176,
        minLevel = 1,
        school = "nature",
        schoolMask = 8,
        castType = "cast",
        castTime = 2.0,
        hasteType = "spell",
        range = 30,
        critMultiplier = 1.5,
        flags = { offensive = true, direct = true, magical = true },
        coefficients = { spellPower = 0.571 },
        damage = { estimateBase = 476 },
        talentModifiers = {
            { name = "Moonfury",   tab = 1, index = 15, maxRank = 5, perRank = 0.02, affects = "damage" },
        threatMultiplier = 1.0,  -- Direct damage / default
        },
    },
    ["Faerie Fire"] = {
        class = "DRUID",
        spec = "BALANCE",
        name = "Faerie Fire",
        baseId = 770,
        minLevel = 18,
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        hasteType = "gcd",
        range = 30,
        duration = 40,
        debuffId = 770,
        debuffAura = "Faerie Fire",          -- exact in-game debuff name on target
        debuffExclusive = true,              -- only one Faerie Fire variant can be active
        debuffSiblings = { "Faerie Fire (Feral)" },  -- Feral version is mutually exclusive
        debuffStackingMode = "single_any_source", -- Only one FF variant ever; check any source regardless of who cast it
        flags = { offensive = true, debuff = true, armorReduction = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Moonkin Form"] = {
        class = "DRUID",
        spec = "BALANCE",
        name = "Moonkin Form",
        baseId = 24858,
        minLevel = 40,
        talentUnlock = { tab = 1, index = 14, minRank = 1 },
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        hasteType = "gcd",
        duration = -1,
        buffId = 24858,
        flags = { form = true, stance = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Barkskin"] = {
        class = "DRUID",
        spec = nil,
        name = "Barkskin",
        baseId = 22812,
        minLevel = 44,
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        hasteType = "gcd",
        duration = 12,
        buffId = 22812,
        flags = { buff = true, cooldown = true, defensive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Nature's Swiftness"] = {
        class = "DRUID",
        spec = nil,
        name = "Nature's Swiftness",
        baseId = 17116,
        minLevel = 30,
        talentUnlock = { tab = 3, index = 11, minRank = 1 },
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        hasteType = "gcd",
        buffId = 17116,
        flags = { buff = true, cooldown = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Entangling Roots"] = {
        class = "DRUID",
        spec = nil,
        name = "Entangling Roots",
        baseId = 339,
        minLevel = 8,
        school = "nature",
        schoolMask = 8,
        castType = "cast",
        castTime = 1.5,
        hasteType = "spell",
        duration = 27,
        range = 30,
        debuffId = 339,
        flags = { control = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Force of Nature"] = {
        class = "DRUID",
        spec = "BALANCE",
        name = "Force of Nature",
        baseId = 33831,
        minLevel = 70,
        talentUnlock = { tab = 1, index = 20, minRank = 1 },
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        hasteType = "gcd",
        flags = { cooldown = true, summon = true, offensive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- MAGE â€“ Base class
    ------------------------------------------------------------------------
    ["Fireball"] = {
        class = "MAGE",
        name = "Fireball",
        baseId = 133,
        school = "fire",
        schoolMask = 4,
        castType = "cast",
        castTime = 3.5,
        hasteType = "spell",
        range = 35,
        flags = { offensive = true, direct = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Frostbolt"] = {
        class = "MAGE",
        name = "Frostbolt",
        baseId = 116,
        school = "frost",
        schoolMask = 16,
        castType = "cast",
        castTime = 3.0,
        hasteType = "spell",
        range = 35,
        flags = { offensive = true, direct = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Blizzard"] = {
        class = "MAGE",
        name = "Blizzard",
        baseId = 10,
        school = "frost",
        schoolMask = 16,
        castType = "channel",
        castTime = 8.0,
        hasteType = "channel",
        duration = 8,
        ticks = 8,
        tickInterval = 1,
        range = 35,
        flags = { offensive = true, channel = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Flamestrike"] = {
        class = "MAGE",
        name = "Flamestrike",
        baseId = 2120,
        school = "fire",
        schoolMask = 4,
        castType = "cast",
        castTime = 3.0,
        hasteType = "spell",
        duration = 8,
        ticks = 4,
        tickInterval = 2,
        range = 35,
        flags = { offensive = true, direct = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Arcane Explosion"] = {
        class = "MAGE",
        name = "Arcane Explosion",
        baseId = 1449,
        school = "arcane",
        schoolMask = 64,
        castType = "instant",
        hasteType = "gcd",
        range = 10,
        flags = { offensive = true, direct = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Cone of Cold"] = {
        class = "MAGE",
        name = "Cone of Cold",
        baseId = 120,
        school = "frost",
        schoolMask = 16,
        castType = "instant",
        hasteType = "gcd",
        range = 15,
        flags = { offensive = true, direct = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Frost Nova"] = {
        class = "MAGE",
        name = "Frost Nova",
        baseId = 122,
        school = "frost",
        schoolMask = 16,
        castType = "instant",
        hasteType = "gcd",
        duration = 8,
        range = 15,
        flags = { control = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Counterspell"] = {
        class = "MAGE",
        name = "Counterspell",
        baseId = 2139,
        school = "arcane",
        schoolMask = 64,
        castType = "instant",
        hasteType = "gcd",
        range = 35,
        flags = { utility = true, interrupt = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Mana Shield"] = {
        class = "MAGE",
        name = "Mana Shield",
        baseId = 1463,
        school = "arcane",
        schoolMask = 64,
        castType = "instant",
        hasteType = "gcd",
        flags = { buff = true, defensive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Evocation"] = {
        class = "MAGE",
        name = "Evocation",
        baseId = 12051,
        school = "arcane",
        schoolMask = 64,
        castType = "channel",
        castTime = 8.0,
        hasteType = "channel",
        cooldown = 480,
        flags = { cooldown = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Summon Water Elemental"] = {
        class = "MAGE",
        name = "Summon Water Elemental",
        baseId = 31687,
        school = "frost",
        schoolMask = 16,
        castType = "instant",
        hasteType = "gcd",
        cooldown = 180,
        duration = 45,
        flags = { cooldown = true, summon = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Remove Lesser Curse"] = {
        class = "MAGE",
        name = "Remove Lesser Curse",
        baseId = 475,
        school = "arcane",
        schoolMask = 64,
        castType = "instant",
        hasteType = "gcd",
        range = 35,
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.3,   -- DoT: 1.3x per tick in TBC
    },
    ["Amplify Magic"] = {
        class = "MAGE",
        name = "Amplify Magic",
        baseId = 1008,
        school = "arcane",
        schoolMask = 64,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        flags = { buff = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Dampen Magic"] = {
        class = "MAGE",
        name = "Dampen Magic",
        baseId = 604,
        school = "arcane",
        schoolMask = 64,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        flags = { buff = true, defensive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ------------------------------------------------------------------------
    -- MAGE â€“ Arcane
    ------------------------------------------------------------------------
    ["Arcane Blast"] = {
        class = "MAGE",
        spec = "ARCANE",
        name = "Arcane Blast",
        baseId = 30451,
        school = "arcane",
        schoolMask = 64,
        castType = "cast",
        castTime = 2.5,
        hasteType = "spell",
        range = 35,
        flags = { offensive = true, direct = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Arcane Missiles"] = {
        class = "MAGE",
        spec = "ARCANE",
        name = "Arcane Missiles",
        baseId = 5143,
        school = "arcane",
        schoolMask = 64,
        castType = "channel",
        castTime = 5.0,
        hasteType = "channel",
        duration = 5,
        ticks = 5,
        tickInterval = 1,
        range = 35,
        flags = { offensive = true, channel = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Arcane Power"] = {
        class = "MAGE",
        spec = "ARCANE",
        name = "Arcane Power",
        baseId = 12042,
        school = "arcane",
        schoolMask = 64,
        castType = "instant",
        hasteType = "gcd",
        duration = 15,
        cooldown = 180,
        flags = { cooldown = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Presence of Mind"] = {
        class = "MAGE",
        spec = "ARCANE",
        name = "Presence of Mind",
        baseId = 12043,
        school = "arcane",
        schoolMask = 64,
        castType = "instant",
        hasteType = "gcd",
        cooldown = 180,
        flags = { cooldown = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ------------------------------------------------------------------------
    -- MAGE â€“ Fire
    ------------------------------------------------------------------------
    ["Scorch"] = {
        class = "MAGE",
        spec = "FIRE",
        name = "Scorch",
        baseId = 2948,
        school = "fire",
        schoolMask = 4,
        castType = "cast",
        castTime = 1.5,
        hasteType = "spell",
        range = 35,
        flags = { offensive = true, direct = true, magical = true },
        debuffStackingMode = "stacks_damage_only", -- Improved Scorch stacks are shared across all mages; only one stack pool per target (TBC Classic)
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Fire Blast"] = {
        class = "MAGE",
        spec = "FIRE",
        name = "Fire Blast",
        baseId = 2136,
        school = "fire",
        schoolMask = 4,
        castType = "instant",
        hasteType = "gcd",
        range = 20,
        cooldown = 8,
        flags = { offensive = true, direct = true, magical = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Blast Wave"] = {
        class = "MAGE",
        spec = "FIRE",
        name = "Blast Wave",
        baseId = 11113,
        school = "fire",
        schoolMask = 4,
        castType = "instant",
        hasteType = "gcd",
        range = 15,
        cooldown = 45,
        flags = { offensive = true, direct = true, magical = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Dragon's Breath"] = {
        class = "MAGE",
        spec = "FIRE",
        name = "Dragon's Breath",
        baseId = 31661,
        school = "fire",
        schoolMask = 4,
        castType = "instant",
        hasteType = "gcd",
        duration = 5,
        range = 15,
        cooldown = 20,
        flags = { offensive = true, control = true, magical = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Combustion"] = {
        class = "MAGE",
        spec = "FIRE",
        name = "Combustion",
        baseId = 11129,
        school = "fire",
        schoolMask = 4,
        castType = "instant",
        hasteType = "gcd",
        cooldown = 180,
        flags = { cooldown = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Living Bomb"] = {
        class = "MAGE",
        spec = "FIRE",
        name = "Living Bomb",
        baseId = 44457,
        school = "fire",
        schoolMask = 4,
        castType = "cast",
        castTime = 1.5,
        hasteType = "spell",
        duration = 12,
        ticks = 4,
        tickInterval = 3,
        range = 35,
        flags = { offensive = true, direct = true, magical = true, dot = true },
        debuffStackingMode = "per_player", -- Each mage applies own Living Bomb; damage stacks across mages
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ------------------------------------------------------------------------
    -- MAGE â€“ Frost
    ------------------------------------------------------------------------
    ["Ice Lance"] = {
        class = "MAGE",
        spec = "FROST",
        name = "Ice Lance",
        baseId = 30455,
        school = "frost",
        schoolMask = 16,
        castType = "instant",
        hasteType = "gcd",
        range = 30,
        flags = { offensive = true, direct = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Icy Veins"] = {
        class = "MAGE",
        spec = "FROST",
        name = "Icy Veins",
        baseId = 12472,
        school = "frost",
        schoolMask = 16,
        castType = "instant",
        hasteType = "gcd",
        duration = 20,
        cooldown = 180,
        flags = { cooldown = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Cold Snap"] = {
        class = "MAGE",
        spec = "FROST",
        name = "Cold Snap",
        baseId = 11958,
        school = "frost",
        schoolMask = 16,
        castType = "instant",
        hasteType = "gcd",
        cooldown = 480,
        flags = { cooldown = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- WARLOCK â€“ Base class
    ------------------------------------------------------------------------
    ["Shadow Bolt"] = {
        class = "WARLOCK",
        spec = nil,
        name = "Shadow Bolt",
        baseId = 686,
        school = "shadow",
        schoolMask = 32,
        castType = "cast",
        castTime = 3.0,
        hasteType = "spell",
        range = 30,
        flags = { offensive = true, direct = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Immolate"] = {
        class = "WARLOCK",
        spec = nil,
        name = "Immolate",
        baseId = 348,
        school = "fire",
        schoolMask = 4,
        castType = "cast",
        castTime = 1.5,
        hasteType = "spell",
        duration = 15,
        ticks = 5,
        tickInterval = 3,
        range = 30,
        flags = { offensive = true, dot = true, direct = true, magical = true },
        debuffStackingMode = "per_player", -- Each warlock applies own Immolate; damage stacks across locks
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Life Tap"] = {
        class = "WARLOCK",
        spec = nil,
        name = "Life Tap",
        baseId = 1454,
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Amplify Curse"] = {
        class = "WARLOCK",
        spec = nil,
        name = "Amplify Curse",
        baseId = 18288,
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        cooldown = 180,          -- 3 min in TBC
        flags = { utility = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,
    },
    ["Demon Armor"] = {
        class = "WARLOCK",
        spec = nil,
        name = "Demon Armor",
        baseId = 706,
        resolveIds = { 706, 1086, 11733, 11734, 11735, 27260 },  -- All TBC ranks
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        duration = 1800,          -- 30 min
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,
    },
    ["Drain Life"] = {
        class = "WARLOCK",
        spec = nil,
        name = "Drain Life",
        baseId = 689,
        school = "shadow",
        schoolMask = 32,
        castType = "channel",
        castTime = 5.0,
        hasteType = "channel",
        duration = 5,
        ticks = 5,
        tickInterval = 1,
        range = 30,
        flags = { offensive = true, channel = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Fear"] = {
        class = "WARLOCK",
        spec = nil,
        name = "Fear",
        baseId = 5782,
        school = "shadow",
        schoolMask = 32,
        castType = "cast",
        castTime = 1.5,
        hasteType = "spell",
        duration = 20,
        range = 30,
        flags = { control = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Hellfire"] = {
        class = "WARLOCK",
        spec = nil,
        name = "Hellfire",
        baseId = 1949,
        minLevel = 30,
        school = "fire",
        schoolMask = 4,
        castType = "channel",
        duration = 15,
        ticks = 15,
        tickInterval = 1,
        flags = { offensive = true, channel = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Ritual of Summoning"] = {
        class = "WARLOCK",
        spec = nil,
        name = "Ritual of Summoning",
        baseId = 698,
        school = "shadow",
        schoolMask = 32,
        castType = "cast",
        castTime = 5.0,
        hasteType = "none",
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Create Healthstone"] = {
        class = "WARLOCK",
        spec = nil,
        name = "Create Healthstone",
        baseId = 6201,
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Create Soulstone"] = {
        class = "WARLOCK",
        spec = nil,
        name = "Create Soulstone",
        baseId = 20707,
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Soulshatter"] = {
        class = "WARLOCK",
        spec = nil,
        name = "Soulshatter",
        baseId = 29858,
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        cooldown = 300,
        flags = { cooldown = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Ritual of Souls"] = {
        class = "WARLOCK",
        spec = nil,
        name = "Ritual of Souls",
        baseId = 29893,
        school = "shadow",
        schoolMask = 32,
        castType = "cast",
        castTime = 3.0,
        hasteType = "none",
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- WARLOCK â€“ Affliction
    ------------------------------------------------------------------------
    ["Corruption"] = {
        class = "WARLOCK",
        spec = "AFFLICTION",
        name = "Corruption",
        baseId = 172,
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        duration = 18,
        ticks = 6,
        tickInterval = 3,
        range = 30,
        flags = { offensive = true, dot = true, magical = true },
        debuffStackingMode = "per_player", -- Each warlock applies own Corruption; damage stacks across locks
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Curse of Agony"] = {
        class = "WARLOCK",
        spec = "AFFLICTION",
        name = "Curse of Agony",
        baseId = 980,
        resolveIds = { 980, 1014, 6217, 11711, 11712 },   -- All TBC ranks
        debuffAuraIds = { 980, 1014, 6217, 11711, 11712 }, -- Aura spell IDs for ID-based debuff matching
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        duration = 24,
        ticks = 12,
        tickInterval = 2,
        range = 30,
        flags = { offensive = true, dot = true, magical = true },
        debuffStackingMode = "stacks_damage_only", -- Multiple warlocks can apply; damage stacks but it's a curse slot spell
        debuffMutuallyExclusive = { "Curse of Elements", "Curse of Doom", "Curse of Tongues", "Curse of Weakness" }, -- All curses share per-warlock curse slot
        talentModifiers = {},
        threatMultiplier = 1.3,   -- DoT: 1.3x per tick in TBC
    },
    ["Curse of Elements"] = {
        class = "WARLOCK",
        spec = "AFFLICTION",
        name = "Curse of the Elements",   -- Real in-game name on the TBC/Anniversary client
        debuffAura = "Curse of the Elements", -- Exact in-game aura name shown on target
        aliasNames = { "Curse of Elements" }, -- Retired name so old lookups still resolve
        baseId = 1490,
        resolveIds = { 1490, 11721, 11722, 27228 },   -- All TBC ranks
        debuffAuraIds = { 1490, 11721, 11722, 27228 }, -- Aura spell IDs for ID-based debuff matching
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        duration = 300,
        range = 30,
        flags = { debuff = true, magical = true },
        debuffStackingMode = "single_curse_slot", -- Each warlock has one curse slot; effect doesn't stack across locks. Check any source.
        debuffMutuallyExclusive = { "Curse of Agony", "Curse of Doom", "Curse of Tongues", "Curse of Weakness" }, -- All curses share per-warlock curse slot
        talentModifiers = {},
        threatMultiplier = 1.3,   -- DoT: 1.3x per tick in TBC
    },
    ["Curse of Doom"] = {
        class = "WARLOCK",
        spec = "AFFLICTION",
        name = "Curse of Doom",
        baseId = 603,
        resolveIds = { 603, 30910 },        -- All TBC ranks
        debuffAuraIds = { 603, 30910 },       -- Aura spell IDs for ID-based debuff matching
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        duration = 60,
        range = 30,
        flags = { offensive = true, dot = true, magical = true },
        debuffStackingMode = "stacks_damage_only", -- Multiple warlocks can apply; damage stacks. It's a curse slot spell.
        debuffMutuallyExclusive = { "Curse of Agony", "Curse of Elements", "Curse of Tongues", "Curse of Weakness" }, -- All curses share per-warlock curse slot
        talentModifiers = {},
        threatMultiplier = 1.3,   -- DoT: 1.3x per tick in TBC
    },
    ["Siphon Life"] = {
        class = "WARLOCK",
        spec = "AFFLICTION",
        name = "Siphon Life",
        baseId = 18265,
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        ticks = 10,
        tickInterval = 3,
        range = 30,
        flags = { offensive = true, dot = true, magical = true },
        debuffStackingMode = "per_player", -- Each warlock applies own Siphon Life; damage stacks across locks
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Unstable Affliction"] = {
        class = "WARLOCK",
        spec = "AFFLICTION",
        name = "Unstable Affliction",
        baseId = 30108,
        school = "shadow",
        schoolMask = 32,
        castType = "cast",
        castTime = 1.5,
        hasteType = "spell",
        duration = 18,
        ticks = 6,
        tickInterval = 3,
        range = 30,
        flags = { offensive = true, dot = true, magical = true },
        debuffStackingMode = "per_player", -- Each warlock applies own Unstable Affliction; damage stacks across locks
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Seed of Corruption"] = {
        class = "WARLOCK",
        spec = "AFFLICTION",
        name = "Seed of Corruption",
        baseId = 27243,
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        duration = 18,
        range = 30,
        flags = { offensive = true, dot = true, magical = true },
        debuffStackingMode = "per_player", -- Each warlock applies own Seed of Corruption; damage stacks across locks
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Death Coil"] = {
        class = "WARLOCK",
        spec = "AFFLICTION",
        name = "Death Coil",
        baseId = 6789,
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        duration = 3,
        range = 30,
        cooldown = 120,
        flags = { offensive = true, control = true, magical = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Curse of Tongues"] = {
        class = "WARLOCK",
        spec = "AFFLICTION",
        name = "Curse of Tongues",
        baseId = 1714,
        resolveIds = { 1714, 11719 },        -- All TBC ranks
        debuffAuraIds = { 1714, 11719 },       -- Aura spell IDs for ID-based debuff matching
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        range = 30,
        flags = { debuff = true, magical = true },
        debuffStackingMode = "single_any_source", -- Effect doesn't stack across locks; only one instance matters regardless of source. Single curse slot per warlock.
        debuffMutuallyExclusive = { "Curse of Agony", "Curse of Elements", "Curse of Doom", "Curse of Weakness" }, -- All curses share per-warlock curse slot
        talentModifiers = {},
        threatMultiplier = 1.3,   -- DoT: 1.3x per tick in TBC
    },
    ["Curse of Weakness"] = {
        class = "WARLOCK",
        spec = "AFFLICTION",
        name = "Curse of Weakness",
        baseId = 702,
        resolveIds = { 702, 1108, 6205, 7646, 11707, 11708, 27224, 30909 },  -- All TBC ranks
        debuffAuraIds = { 702, 1108, 6205, 7646, 11707, 11708, 27224, 30909 }, -- Aura spell IDs for ID-based debuff matching
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        duration = 120,
        range = 30,
        flags = { debuff = true, magical = true },
        debuffStackingMode = "single_any_source", -- Effect doesn't stack across locks; only one instance matters regardless of source. Single curse slot per warlock.
        debuffMutuallyExclusive = { "Curse of Agony", "Curse of Elements", "Curse of Doom", "Curse of Tongues" }, -- All curses share per-warlock curse slot
        talentModifiers = {},
        threatMultiplier = 1.3,   -- DoT: 1.3x per tick in TBC
    },
    ["Drain Soul"] = {
        class = "WARLOCK",
        spec = "AFFLICTION",
        name = "Drain Soul",
        baseId = 1120,
        school = "shadow",
        schoolMask = 32,
        castType = "channel",
        castTime = 15.0,
        hasteType = "channel",
        duration = 15,
        ticks = 15,
        tickInterval = 1,
        range = 30,
        flags = { offensive = true, channel = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Howl of Terror"] = {
        class = "WARLOCK",
        spec = "AFFLICTION",
        name = "Howl of Terror",
        baseId = 5484,
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        duration = 4,
        cooldown = 40,
        flags = { control = true, magical = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- WARLOCK â€“ Demonology
    ------------------------------------------------------------------------
    ["Summon Imp"] = {
        class = "WARLOCK",
        spec = "DEMONOLOGY",
        name = "Summon Imp",
        baseId = 688,
        school = "shadow",
        schoolMask = 32,
        castType = "cast",
        castTime = 5.0,
        hasteType = "none",
        flags = { summon = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Summon Voidwalker"] = {
        class = "WARLOCK",
        spec = "DEMONOLOGY",
        name = "Summon Voidwalker",
        baseId = 697,
        school = "shadow",
        schoolMask = 32,
        castType = "cast",
        castTime = 5.0,
        hasteType = "none",
        flags = { summon = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Summon Succubus"] = {
        class = "WARLOCK",
        spec = "DEMONOLOGY",
        name = "Summon Succubus",
        baseId = 712,
        school = "shadow",
        schoolMask = 32,
        castType = "cast",
        castTime = 5.0,
        hasteType = "none",
        flags = { summon = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Summon Felhunter"] = {
        class = "WARLOCK",
        spec = "DEMONOLOGY",
        name = "Summon Felhunter",
        baseId = 691,
        school = "shadow",
        schoolMask = 32,
        castType = "cast",
        castTime = 5.0,
        hasteType = "none",
        flags = { summon = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Summon Felguard"] = {
        class = "WARLOCK",
        spec = "DEMONOLOGY",
        name = "Summon Felguard",
        baseId = 30146,
        school = "shadow",
        schoolMask = 32,
        castType = "cast",
        castTime = 5.0,
        hasteType = "none",
        flags = { summon = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Demonic Sacrifice"] = {
        class = "WARLOCK",
        spec = "DEMONOLOGY",
        name = "Demonic Sacrifice",
        baseId = 18788,
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        flags = { buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Soul Link"] = {
        class = "WARLOCK",
        spec = "DEMONOLOGY",
        name = "Soul Link",
        baseId = 25228,
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        flags = { buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Fel Domination"] = {
        class = "WARLOCK",
        spec = "DEMONOLOGY",
        name = "Fel Domination",
        baseId = 18708,
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        cooldown = 900,
        flags = { cooldown = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Master Summoner"] = {
        class = "WARLOCK",
        spec = "DEMONOLOGY",
        name = "Master Summoner",
        baseId = 18710,
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "none",
        flags = { passive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Metamorphosis"] = {
        class = "WARLOCK",
        spec = "DEMONOLOGY",
        name = "Metamorphosis",
        baseId = 59672,
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        cooldown = 180,
        flags = { cooldown = true, buff = true, form = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Demonic Frenzy"] = {
        class = "WARLOCK",
        spec = "DEMONOLOGY",
        name = "Demonic Frenzy",
        baseId = 32851,
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        flags = { buff = true, proc = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- WARLOCK â€“ Destruction
    ------------------------------------------------------------------------
    ["Incinerate"] = {
        class = "WARLOCK",
        spec = "DESTRUCTION",
        name = "Incinerate",
        baseId = 29722,
        school = "fire",
        schoolMask = 4,
        castType = "cast",
        castTime = 2.5,
        hasteType = "spell",
        range = 30,
        flags = { offensive = true, direct = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Conflagrate"] = {
        class = "WARLOCK",
        spec = "DESTRUCTION",
        name = "Conflagrate",
        baseId = 17962,
        school = "fire",
        schoolMask = 4,
        castType = "instant",
        hasteType = "gcd",
        range = 30,
        cooldown = 15,
        flags = { offensive = true, direct = true, magical = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Searing Pain"] = {
        class = "WARLOCK",
        spec = "DESTRUCTION",
        name = "Searing Pain",
        baseId = 5676,
        school = "fire",
        schoolMask = 4,
        castType = "cast",
        castTime = 1.5,
        hasteType = "spell",
        range = 30,
        flags = { offensive = true, direct = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Shadowburn"] = {
        class = "WARLOCK",
        spec = "DESTRUCTION",
        name = "Shadowburn",
        baseId = 17877,
        school = "shadow",
        schoolMask = 32,
        castType = "instant",
        hasteType = "gcd",
        range = 30,
        cooldown = 15,
        flags = { offensive = true, direct = true, magical = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.3,   -- DoT: 1.3x per tick in TBC
    },
    ["Soul Fire"] = {
        class = "WARLOCK",
        spec = "DESTRUCTION",
        name = "Soul Fire",
        baseId = 6353,
        school = "fire",
        schoolMask = 4,
        castType = "cast",
        castTime = 6.0,
        hasteType = "spell",
        range = 30,
        cooldown = 60,
        flags = { offensive = true, direct = true, magical = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Rain of Fire"] = {
        class = "WARLOCK",
        spec = "DESTRUCTION",
        name = "Rain of Fire",
        baseId = 5740,
        school = "fire",
        schoolMask = 4,
        castType = "channel",
        castTime = 6.0,
        hasteType = "channel",
        duration = 6,
        ticks = 6,
        tickInterval = 1,
        range = 30,
        flags = { offensive = true, channel = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- ROGUE â€“ Base class
    ------------------------------------------------------------------------
    ["Sinister Strike"] = {
        class = "ROGUE",
        spec = nil,
        name = "Sinister Strike",
        baseId = 1752,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        flags = { offensive = true, direct = true, builder = true, requiresMelee = true },
        comboPointsGenerated = 1,
        resourceCost = 40,
        resource = "energy",
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Backstab"] = {
        class = "ROGUE",
        spec = nil,
        name = "Backstab",
        baseId = 53,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        flags = { offensive = true, direct = true, builder = true, requiresMelee = true, requiresBehind = true },
        comboPointsGenerated = 1,
        resourceCost = 60,
        resource = "energy",
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Eviscerate"] = {
        class = "ROGUE",
        spec = nil,
        name = "Eviscerate",
        baseId = 2098,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        flags = { offensive = true, direct = true, finisher = true, requiresMelee = true },
        resourceCost = 35,
        resource = "energy",
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Slice and Dice"] = {
        class = "ROGUE",
        spec = nil,
        name = "Slice and Dice",
        baseId = 5171,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        flags = { buff = true, finisher = true },
        resourceCost = 25,
        resource = "energy",
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Rupture"] = {
        class = "ROGUE",
        spec = nil,
        name = "Rupture",
        baseId = 1943,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 16,
        ticks = 8,
        tickInterval = 2,
        range = 5,
        flags = { offensive = true, bleed = true, finisher = true, requiresMelee = true },
        resourceCost = 25,
        resource = "energy",
        debuffStackingMode = "per_player", -- Each rogue applies own Rupture; damage stacks across rogues
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Kick"] = {
        class = "ROGUE",
        spec = nil,
        name = "Kick",
        baseId = 1766,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        cooldown = 10,
        flags = { interrupt = true, requiresMelee = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Gouge"] = {
        class = "ROGUE",
        spec = nil,
        name = "Gouge",
        baseId = 1776,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 4,
        range = 5,
        cooldown = 10,
        flags = { control = true, requiresMelee = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Sprint"] = {
        class = "ROGUE",
        spec = nil,
        name = "Sprint",
        baseId = 2983,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 15,
        cooldown = 180,
        flags = { cooldown = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Stealth"] = {
        class = "ROGUE",
        spec = nil,
        name = "Stealth",
        baseId = 1784,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        flags = { stealth = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Pick Pocket"] = {
        class = "ROGUE",
        spec = nil,
        name = "Pick Pocket",
        baseId = 921,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Sap"] = {
        class = "ROGUE",
        spec = nil,
        name = "Sap",
        baseId = 6770,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 60,
        range = 5,
        flags = { control = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Distract"] = {
        class = "ROGUE",
        spec = nil,
        name = "Distract",
        baseId = 1725,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 30,
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Vanish"] = {
        class = "ROGUE",
        spec = nil,
        name = "Vanish",
        baseId = 1856,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        cooldown = 300,
        flags = { cooldown = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Evasion"] = {
        class = "ROGUE",
        spec = nil,
        name = "Evasion",
        baseId = 5277,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 15,
        cooldown = 300,
        flags = { cooldown = true, defensive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Feint"] = {
        class = "ROGUE",
        spec = nil,
        name = "Feint",
        baseId = 1966,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 6,
        cooldown = 10,
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Detect Traps"] = {
        class = "ROGUE",
        spec = nil,
        name = "Detect Traps",
        baseId = 2836,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Pick Lock"] = {
        class = "ROGUE",
        spec = nil,
        name = "Pick Lock",
        baseId = 1804,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Safe Falling"] = {
        class = "ROGUE",
        spec = nil,
        name = "Safe Falling",
        baseId = 1860,
        school = "physical",
        schoolMask = 1,
        castType = "passive",
        flags = { passive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Deadly Throw"] = {
        class = "ROGUE",
        spec = nil,
        name = "Deadly Throw",
        baseId = 26679,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 30,
        cooldown = 15,
        flags = { offensive = true, direct = true, finisher = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Throw"] = {
        class = "ROGUE",
        spec = nil,
        name = "Throw",
        baseId = 2764,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 30,
        flags = { offensive = true, direct = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Shoot"] = {
        class = "ROGUE",
        spec = nil,
        name = "Shoot",
        baseId = 3018,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 30,
        flags = { offensive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- ROGUE â€“ Assassination
    ------------------------------------------------------------------------
    ["Mutilate"] = {
        class = "ROGUE",
        spec = "ASSASSINATION",
        name = "Mutilate",
        baseId = 1329,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        flags = { offensive = true, direct = true, builder = true, requiresMelee = true },
        comboPointsGenerated = 2,
        resourceCost = 60,
        resource = "energy",
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Envenom"] = {
        class = "ROGUE",
        spec = "ASSASSINATION",
        name = "Envenom",
        baseId = 32645,
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        flags = { offensive = true, direct = true, finisher = true, requiresMelee = true },
        resourceCost = 35,
        resource = "energy",
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Cold Blood"] = {
        class = "ROGUE",
        spec = "ASSASSINATION",
        name = "Cold Blood",
        baseId = 14177,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        cooldown = 180,
        flags = { cooldown = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Garrote"] = {
        class = "ROGUE",
        spec = "ASSASSINATION",
        name = "Garrote",
        baseId = 703,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 18,
        ticks = 6,
        tickInterval = 3,
        range = 5,
        flags = { offensive = true, bleed = true, requiresMelee = true, requiresStealth = true },
        resourceCost = 40,
        resource = "energy",
        debuffStackingMode = "per_player", -- Each rogue applies own Garrote; damage stacks across rogues
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Ambush"] = {
        class = "ROGUE",
        spec = "ASSASSINATION",
        name = "Ambush",
        baseId = 8676,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        flags = { offensive = true, direct = true, builder = true, requiresMelee = true, requiresStealth = true },
        comboPointsGenerated = 2,
        resourceCost = 60,
        resource = "energy",
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Expose Armor"] = {
        class = "ROGUE",
        spec = "ASSASSINATION",
        name = "Expose Armor",
        baseId = 8647,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        range = 5,
        flags = { debuff = true, finisher = true, armorReduction = true, requiresMelee = true },
        resourceCost = 25,
        resource = "energy",
        debuffStackingMode = "single_any_source", -- Only strongest Expose/Sunder active; check any source. Exclusive with Sunder Armor.
        debuffMutuallyExclusive = { "Sunder Armor" }, -- Expose Armor and Sunder Armor share the same armor reduction slot (TBC Classic)
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- ROGUE â€“ Combat
    ------------------------------------------------------------------------
    ["Blade Flurry"] = {
        class = "ROGUE",
        spec = "COMBAT",
        name = "Blade Flurry",
        baseId = 13877,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 15,
        cooldown = 120,
        flags = { cooldown = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Adrenaline Rush"] = {
        class = "ROGUE",
        spec = "COMBAT",
        name = "Adrenaline Rush",
        baseId = 13750,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 15,
        cooldown = 180,
        flags = { cooldown = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Riposte"] = {
        class = "ROGUE",
        spec = "COMBAT",
        name = "Riposte",
        baseId = 14251,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 6,
        cooldown = 5,
        flags = { offensive = true, defensive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Killing Spree"] = {
        class = "ROGUE",
        spec = "COMBAT",
        name = "Killing Spree",
        baseId = 51690,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        cooldown = 120,
        flags = { cooldown = true, offensive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- ROGUE â€“ Subtlety
    ------------------------------------------------------------------------
    ["Hemorrhage"] = {
        class = "ROGUE",
        spec = "SUBTLETY",
        name = "Hemorrhage",
        baseId = 16511,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        duration = 10,
        flags = { offensive = true, direct = true, builder = true, debuff = true, requiresMelee = true },
        comboPointsGenerated = 1,
        resourceCost = 35,
        resource = "energy",
        debuffStackingMode = "per_player", -- Each rogue applies own Hemorrhage stacks (up to 5); damage increase stacks across rogues
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Premeditation"] = {
        class = "ROGUE",
        spec = "SUBTLETY",
        name = "Premeditation",
        baseId = 14183,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        cooldown = 60,
        flags = { cooldown = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Preparation"] = {
        class = "ROGUE",
        spec = "SUBTLETY",
        name = "Preparation",
        baseId = 14185,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        cooldown = 600,
        flags = { cooldown = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Cheap Shot"] = {
        class = "ROGUE",
        spec = "SUBTLETY",
        name = "Cheap Shot",
        baseId = 1833,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 4,
        range = 5,
        flags = { control = true, requiresStealth = true, requiresMelee = true },
        comboPointsGenerated = 1,
        resourceCost = 40,
        resource = "energy",
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Shadowstep"] = {
        class = "ROGUE",
        spec = "SUBTLETY",
        name = "Shadowstep",
        baseId = 36554,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        cooldown = 30,
        flags = { cooldown = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Ghostly Strike"] = {
        class = "ROGUE",
        spec = "SUBTLETY",
        name = "Ghostly Strike",
        baseId = 14278,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        duration = 7,
        flags = { offensive = true, direct = true, builder = true, requiresMelee = true },
        comboPointsGenerated = 1,
        resourceCost = 40,
        resource = "energy",
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- WARRIOR â€“ Base class
    ------------------------------------------------------------------------
    ["Heroic Strike"] = {
        class = "WARRIOR",
        name = "Heroic Strike",
        baseId = 78,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        resourceCost = 15,
        resource = "rage",
        flags = { offensive = true, direct = true, requiresMelee = true, nextMeleeAbility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Battle Shout"] = {
        class = "WARRIOR",
        name = "Battle Shout",
        baseId = 6673,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 120,
        resourceCost = 10,
        resource = "rage",
        flags = { buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Charge"] = {
        class = "WARRIOR",
        name = "Charge",
        baseId = 100,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 25,
        cooldown = 15,
        resourceCost = 0,
        resource = "rage",
        generatesRage = 15,
        flags = { offensive = true, utility = true, movement = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Rend"] = {
        class = "WARRIOR",
        name = "Rend",
        baseId = 772,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 15,
        ticks = 5,
        tickInterval = 3,
        range = 5,
        resourceCost = 10,
        resource = "rage",
        flags = { offensive = true, bleed = true, requiresMelee = true },
        debuffStackingMode = "per_player", -- Each warrior applies own Rend; damage stacks across warriors
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Sunder Armor"] = {
        class = "WARRIOR",
        spec = nil,
        name = "Sunder Armor",
        baseId = 7389,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 40,
        range = 5,
        resourceCost = 10,
        resource = "rage",
        flags = { offensive = true, debuff = true, armorReduction = true, requiresMelee = true },
        debuffStackingMode = "single_any_source", -- Only strongest Sunder/Expose active; check any source. Exclusive with Expose Armor.
        debuffMutuallyExclusive = { "Expose Armor" }, -- Expose Armor and Sunder Armor share the same armor reduction slot (TBC Classic)
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Thunder Clap"] = {
        class = "WARRIOR",
        name = "Thunder Clap",
        baseId = 6343,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        range = 8,
        cooldown = 6,
        resourceCost = 20,
        resource = "rage",
        flags = { offensive = true, debuff = true },
        debuffStackingMode = "strongest_wins", -- Only strongest Thunder Clap active; check any source regardless of who cast it
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Hamstring"] = {
        class = "WARRIOR",
        name = "Hamstring",
        baseId = 1715,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 15,
        range = 5,
        resourceCost = 10,
        resource = "rage",
        flags = { offensive = true, control = true, requiresMelee = true },
        debuffStackingMode = "strongest_wins", -- Only strongest Hamstring active; check any source regardless of who cast it
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Intimidating Shout"] = {
        class = "WARRIOR",
        name = "Intimidating Shout",
        baseId = 5246,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 8,
        cooldown = 120,
        resourceCost = 10,
        resource = "rage",
        flags = { control = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Demoralizing Shout"] = {
        class = "WARRIOR",
        name = "Demoralizing Shout",
        baseId = 1160,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        resourceCost = 10,
        resource = "rage",
        flags = { debuff = true, utility = true },
        debuffStackingMode = "strongest_wins", -- Only strongest Demoralizing Shout active; check any source regardless of who cast it
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Piercing Howl"] = {
        class = "WARRIOR",
        name = "Piercing Howl",
        baseId = 12323,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 6,
        resourceCost = 10,
        resource = "rage",
        flags = { offensive = true, control = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Execute"] = {
        class = "WARRIOR",
        name = "Execute",
        baseId = 5308,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        resourceCost = 15,
        resource = "rage",
        flags = { offensive = true, direct = true, requiresMelee = true, execute = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Overpower"] = {
        class = "WARRIOR",
        name = "Overpower",
        baseId = 7384,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        resourceCost = 5,
        resource = "rage",
        flags = { offensive = true, direct = true, requiresMelee = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Revenge"] = {
        class = "WARRIOR",
        name = "Revenge",
        baseId = 6572,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        resourceCost = 5,
        resource = "rage",
        flags = { offensive = true, direct = true, requiresMelee = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Shield Bash"] = {
        class = "WARRIOR",
        name = "Shield Bash",
        baseId = 72,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        cooldown = 12,
        resourceCost = 10,
        resource = "rage",
        flags = { interrupt = true, requiresShield = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Shield Block"] = {
        class = "WARRIOR",
        name = "Shield Block",
        baseId = 2565,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 5,
        cooldown = 5,
        resourceCost = 10,
        resource = "rage",
        flags = { defensive = true, requiresShield = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Bloodrage"] = {
        class = "WARRIOR",
        name = "Bloodrage",
        baseId = 2687,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 10,
        cooldown = 60,
        flags = { cooldown = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Berserker Rage"] = {
        class = "WARRIOR",
        name = "Berserker Rage",
        baseId = 18499,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 10,
        cooldown = 30,
        resourceCost = 0,
        resource = "rage",
        flags = { cooldown = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- WARRIOR â€“ Arms
    ------------------------------------------------------------------------
    ["Mortal Strike"] = {
        class = "WARRIOR",
        spec = "ARMS",
        name = "Mortal Strike",
        baseId = 12294,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        duration = 10,
        cooldown = 6,
        resourceCost = 30,
        resource = "rage",
        flags = { offensive = true, direct = true, requiresMelee = true, cooldown = true },
        debuffStackingMode = "single_any_source", -- Only one Mortal Strike healing reduction matters; check any source regardless of who cast it
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Sweeping Strikes"] = {
        class = "WARRIOR",
        spec = "ARMS",
        name = "Sweeping Strikes",
        baseId = 12328,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 15,
        cooldown = 120,
        resourceCost = 30,
        resource = "rage",
        flags = { cooldown = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Slam"] = {
        class = "WARRIOR",
        spec = "ARMS",
        name = "Slam",
        baseId = 1464,
        school = "physical",
        schoolMask = 1,
        castType = "cast",
        castTime = 1.5,
        hasteType = "spell",
        range = 5,
        resourceCost = 15,
        resource = "rage",
        flags = { offensive = true, direct = true, requiresMelee = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Retaliation"] = {
        class = "WARRIOR",
        spec = "ARMS",
        name = "Retaliation",
        baseId = 20230,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 15,
        cooldown = 300,
        resourceCost = 10,
        resource = "rage",
        flags = { cooldown = true, defensive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Tactical Mastery"] = {
        class = "WARRIOR",
        spec = "ARMS",
        name = "Tactical Mastery",
        baseId = 12295,
        school = "physical",
        schoolMask = 1,
        castType = "passive",
        flags = { passive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Improved Overpower"] = {
        class = "WARRIOR",
        spec = "ARMS",
        name = "Improved Overpower",
        baseId = 12290,
        school = "physical",
        schoolMask = 1,
        castType = "passive",
        flags = { passive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Deep Wounds"] = {
        class = "WARRIOR",
        spec = "ARMS",
        name = "Deep Wounds",
        baseId = 12834,
        school = "physical",
        schoolMask = 1,
        castType = "passive",
        flags = { passive = true, bleed = true },
        debuffStackingMode = "per_player", -- Each warrior applies own Deep Wounds stacks; damage stacks across warriors
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Impale"] = {
        class = "WARRIOR",
        spec = "ARMS",
        name = "Impale",
        baseId = 16493,
        school = "physical",
        schoolMask = 1,
        castType = "passive",
        flags = { passive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- WARRIOR â€“ Fury
    ------------------------------------------------------------------------
    ["Bloodthirst"] = {
        class = "WARRIOR",
        spec = "FURY",
        name = "Bloodthirst",
        baseId = 23881,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        cooldown = 6,
        resourceCost = 30,
        resource = "rage",
        flags = { offensive = true, direct = true, requiresMelee = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Whirlwind"] = {
        class = "WARRIOR",
        spec = "FURY",
        name = "Whirlwind",
        baseId = 1680,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 8,
        cooldown = 6,
        resourceCost = 25,
        resource = "rage",
        flags = { offensive = true, direct = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Death Wish"] = {
        class = "WARRIOR",
        spec = "FURY",
        name = "Death Wish",
        baseId = 12328,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        cooldown = 180,
        talentUnlock = { tab = 2, index = 10, minRank = 1 },
        flags = { cooldown = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Recklessness"] = {
        class = "WARRIOR",
        spec = "FURY",
        name = "Recklessness",
        baseId = 1719,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 15,
        cooldown = 1800,
        resourceCost = 10,
        resource = "rage",
        flags = { cooldown = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Cleave"] = {
        class = "WARRIOR",
        spec = "FURY",
        name = "Cleave",
        baseId = 845,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        resourceCost = 20,
        resource = "rage",
        flags = { offensive = true, direct = true, requiresMelee = true, cleave = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Pummel"] = {
        class = "WARRIOR",
        spec = "FURY",
        name = "Pummel",
        baseId = 6552,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        cooldown = 10,
        flags = { interrupt = true, requiresMelee = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- HUNTER â€“ Base class
    ------------------------------------------------------------------------
    ["Auto Shot"] = {
        class = "HUNTER",
        name = "Auto Shot",
        baseId = 75,
        school = "physical",
        schoolMask = 1,
        castType = "cast",
        castTime = 2.0,
        hasteType = "ranged",
        range = 35,
        flags = { offensive = true, direct = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Hunter's Mark"] = {
        class = "HUNTER",
        name = "Hunter's Mark",
        baseId = 1130,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 120,
        range = 50,
        flags = { debuff = true, utility = true },
        debuffStackingMode = "strongest_wins", -- Only strongest Hunter's Mark active; check any source regardless of who cast it
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Misdirection"] = {
        class = "HUNTER",
        name = "Misdirection",
        baseId = 34477,
        minLevel = 70,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        cooldown = 120,
        range = 100,
        buffId = 34477,
        manaCostPct = 0.09, -- 9% of base mana (TBC Classic)
        flags = { buff = true, cooldown = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Serpent Sting"] = {
        class = "HUNTER",
        name = "Serpent Sting",
        baseId = 1978,
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        hasteType = "gcd",
        duration = 15,
        ticks = 5,
        tickInterval = 3,
        range = 35,
        flags = { offensive = true, dot = true, nature = true },
        debuffStackingMode = "per_player", -- Each hunter applies own Serpent Sting; damage stacks across hunters
        debuffMutuallyExclusive = { "Scorpid Sting", "Viper Sting" }, -- Only one sting per hunter can be active on any target (TBC Classic)
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Arcane Shot"] = {
        class = "HUNTER",
        name = "Arcane Shot",
        baseId = 3044,
        school = "arcane",
        schoolMask = 64,
        castType = "instant",
        hasteType = "gcd",
        range = 35,
        cooldown = 6,
        flags = { offensive = true, direct = true, magical = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Multi-Shot"] = {
        class = "HUNTER",
        name = "Multi-Shot",
        baseId = 2643,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 35,
        cooldown = 10,
        flags = { offensive = true, direct = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Aspect of the Hawk"] = {
        class = "HUNTER",
        name = "Aspect of the Hawk",
        baseId = 13165,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 180,
        flags = { buff = true, aspect = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Aspect of the Viper"] = {
        class = "HUNTER",
        name = "Aspect of the Viper",
        baseId = 34074,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 180,
        flags = { buff = true, aspect = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Aspect of the Cheetah"] = {
        class = "HUNTER",
        name = "Aspect of the Cheetah",
        baseId = 5118,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 15,
        flags = { buff = true, aspect = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Aspect of the Wild"] = {
        class = "HUNTER",
        name = "Aspect of the Wild",
        baseId = 20043,
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        hasteType = "gcd",
        duration = 15,
        flags = { buff = true, aspect = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Disengage"] = {
        class = "HUNTER",
        name = "Disengage",
        baseId = 781,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        cooldown = 30,
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Trueshot Aura"] = {
        class = "HUNTER",
        name = "Trueshot Aura",
        baseId = 19506,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 180,
        cooldown = 180,
        talentUnlock = { tab = 2, index = 15, minRank = 1 },
        flags = { cooldown = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Volley"] = {
        class = "HUNTER",
        name = "Volley",
        baseId = 1510,
        school = "arcane",
        schoolMask = 64,
        castType = "channel",
        castTime = 4.0,
        hasteType = "channel",
        duration = 4,
        ticks = 4,
        tickInterval = 1,
        range = 35,
        flags = { offensive = true, channel = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Scare Beast"] = {
        class = "HUNTER",
        name = "Scare Beast",
        baseId = 1513,
        school = "physical",
        schoolMask = 1,
        castType = "cast",
        castTime = 1.5,
        hasteType = "spell",
        duration = 20,
        range = 30,
        flags = { control = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Mend Pet"] = {
        class = "HUNTER",
        name = "Mend Pet",
        baseId = 136,
        school = "physical",
        schoolMask = 1,
        castType = "channel",
        castTime = 10.0,
        hasteType = "channel",
        duration = 10,
        ticks = 5,
        tickInterval = 2,
        range = 30,
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Revive Pet"] = {
        class = "HUNTER",
        name = "Revive Pet",
        baseId = 982,
        school = "physical",
        schoolMask = 1,
        castType = "channel",
        castTime = 10.0,
        hasteType = "channel",
        duration = 10,
        range = 30,
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Call Pet"] = {
        class = "HUNTER",
        name = "Call Pet",
        baseId = 883,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Dismiss Pet"] = {
        class = "HUNTER",
        name = "Dismiss Pet",
        baseId = 2641,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Feed Pet"] = {
        class = "HUNTER",
        name = "Feed Pet",
        baseId = 6991,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Scorpion Sting"] = {
        class = "HUNTER",
        name = "Scorpion Sting",
        baseId = 3043,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 20,
        range = 35,
        flags = { debuff = true },
        debuffStackingMode = "strongest_wins", -- Only strongest Scorpion Sting active; check any source regardless of who cast it
        debuffMutuallyExclusive = { "Serpent Sting", "Scorpid Sting", "Viper Sting" }, -- Only one sting per hunter can be active on any target (TBC Classic)
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Scorpid Sting"] = {
        class = "HUNTER",
        name = "Scorpid Sting",
        baseId = 3043,
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        hasteType = "gcd",
        duration = 20,
        range = 35,
        flags = { debuff = true },
        debuffStackingMode = "strongest_wins", -- Only strongest Scorpid Sting active; check any source regardless of who cast it
        debuffMutuallyExclusive = { "Serpent Sting", "Viper Sting" }, -- Only one sting per hunter can be active on any target (TBC Classic)
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Viper Sting"] = {
        class = "HUNTER",
        name = "Viper Sting",
        baseId = 3034,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 8,
        range = 35,
        flags = { debuff = true, utility = true },
        debuffStackingMode = "strongest_wins", -- Only strongest Viper Sting active; check any source regardless of who cast it
        debuffMutuallyExclusive = { "Serpent Sting", "Scorpid Sting" }, -- Only one sting per hunter can be active on any target (TBC Classic)
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Wyvern Sting"] = {
        class = "HUNTER",
        name = "Wyvern Sting",
        baseId = 19386,
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        range = 35,
        cooldown = 60,
        flags = { control = true, cooldown = true },
        debuffStackingMode = "per_player", -- Each hunter applies own Wyvern Sting; damage stacks across hunters
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Freezing Trap"] = {
        class = "HUNTER",
        name = "Freezing Trap",
        baseId = 1499,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 60,
        flags = { control = true },
        debuffStackingMode = "single_any_source", -- Only one Freezing Trap matters; check any source regardless of who cast it
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Immolation Trap"] = {
        class = "HUNTER",
        name = "Immolation Trap",
        baseId = 13795,
        school = "fire",
        schoolMask = 4,
        castType = "instant",
        hasteType = "gcd",
        duration = 15,
        ticks = 15,
        tickInterval = 1,
        flags = { offensive = true, dot = true, fire = true },
        debuffStackingMode = "per_player", -- Each hunter applies own Immolation Trap; damage stacks across hunters
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Explosive Trap"] = {
        class = "HUNTER",
        name = "Explosive Trap",
        baseId = 13812,
        school = "fire",
        schoolMask = 4,
        castType = "instant",
        hasteType = "gcd",
        duration = 15,
        cooldown = 15,
        flags = { offensive = true, direct = true, fire = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Frost Trap"] = {
        class = "HUNTER",
        name = "Frost Trap",
        baseId = 13809,
        school = "frost",
        schoolMask = 16,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        flags = { control = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Rapid Fire"] = {
        class = "HUNTER",
        name = "Rapid Fire",
        baseId = 3045,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 15,
        cooldown = 300,
        flags = { cooldown = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- HUNTER â€“ Beast Mastery
    ------------------------------------------------------------------------
    ["Steady Shot"] = {
        class = "HUNTER",
        spec = "BEAST_MASTERY",
        name = "Steady Shot",
        baseId = 34120,
        school = "physical",
        schoolMask = 1,
        castType = "cast",
        castTime = 1.5,
        hasteType = "ranged",
        range = 35,
        flags = { offensive = true, direct = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Kill Command"] = {
        class = "HUNTER",
        spec = "BEAST_MASTERY",
        name = "Kill Command",
        baseId = 34026,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 35,
        cooldown = 5,
        flags = { cooldown = true, offensive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Bestial Wrath"] = {
        class = "HUNTER",
        spec = "BEAST_MASTERY",
        name = "Bestial Wrath",
        baseId = 19574,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 18,
        cooldown = 120,
        flags = { cooldown = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Intimidation"] = {
        class = "HUNTER",
        spec = "BEAST_MASTERY",
        name = "Intimidation",
        baseId = 19577,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 3,
        cooldown = 60,
        flags = { cooldown = true, control = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Eyes of the Beast"] = {
        class = "HUNTER",
        spec = "BEAST_MASTERY",
        name = "Eyes of the Beast",
        baseId = 1002,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["The Beast Within"] = {
        class = "HUNTER",
        spec = "BEAST_MASTERY",
        name = "The Beast Within",
        baseId = 34471,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 18,
        cooldown = 120,
        flags = { cooldown = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- HUNTER â€“ Marksmanship
    ------------------------------------------------------------------------
    ["Aimed Shot"] = {
        class = "HUNTER",
        spec = "MARKSMANSHIP",
        name = "Aimed Shot",
        baseId = 19434,
        school = "physical",
        schoolMask = 1,
        castType = "cast",
        castTime = 3.0,
        hasteType = "ranged",
        range = 35,
        cooldown = 6,
        flags = { offensive = true, direct = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Readiness"] = {
        class = "HUNTER",
        spec = "MARKSMANSHIP",
        name = "Readiness",
        baseId = 23989,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        cooldown = 360,
        flags = { cooldown = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Silencing Shot"] = {
        class = "HUNTER",
        spec = "MARKSMANSHIP",
        name = "Silencing Shot",
        baseId = 34490,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 35,
        cooldown = 20,
        flags = { interrupt = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Scatter Shot"] = {
        class = "HUNTER",
        spec = "MARKSMANSHIP",
        name = "Scatter Shot",
        baseId = 19503,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 35,
        cooldown = 30,
        flags = { control = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- HUNTER â€“ Survival
    ------------------------------------------------------------------------
    ["Explosive Shot"] = {
        class = "HUNTER",
        spec = "SURVIVAL",
        name = "Explosive Shot",
        baseId = 53301,
        school = "fire",
        schoolMask = 4,
        castType = "instant",
        hasteType = "gcd",
        duration = 2,
        ticks = 3,
        tickInterval = 1,
        range = 35,
        cooldown = 6,
        flags = { offensive = true, dot = true, fire = true, cooldown = true },
        debuffStackingMode = "per_player", -- Each hunter applies own Explosive Shot; damage stacks across hunters
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Trap Launcher"] = {
        class = "HUNTER",
        spec = "SURVIVAL",
        name = "Trap Launcher",
        baseId = 62505,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        cooldown = 30,
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Expose Weakness"] = {
        class = "HUNTER",
        spec = "SURVIVAL",
        name = "Expose Weakness",
        baseId = 34500,
        school = "physical",
        schoolMask = 1,
        castType = "passive",
        flags = { passive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Survival Instincts"] = {
        class = "HUNTER",
        spec = "SURVIVAL",
        name = "Survival Instincts",
        baseId = 34494,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        cooldown = 120,
        flags = { cooldown = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- PALADIN â€“ Base class
    ------------------------------------------------------------------------
    ["Seal of Command"] = {
        class = "PALADIN",
        name = "Seal of Command",
        baseId = 20375,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        flags = { buff = true, seal = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Seal of Righteousness"] = {
        class = "PALADIN",
        name = "Seal of Righteousness",
        baseId = 21084,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        flags = { buff = true, seal = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Seal of Blood"] = {
        class = "PALADIN",
        name = "Seal of Blood",
        baseId = 31892,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        flags = { buff = true, seal = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Seal of the Crusader"] = {
        class = "PALADIN",
        name = "Seal of the Crusader",
        baseId = 21082,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        flags = { buff = true, seal = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Seal of Vengeance"] = {
        class = "PALADIN",
        name = "Seal of Vengeance",
        baseId = 31801,
        minLevel = 64,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        buffId = 31801,
        flags = { buff = true, seal = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Seal of Wisdom"] = {
        class = "PALADIN",
        name = "Seal of Wisdom",
        baseId = 20166,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        flags = { buff = true, seal = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Seal of Light"] = {
        class = "PALADIN",
        name = "Seal of Light",
        baseId = 20165,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        flags = { buff = true, seal = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Seal of Justice"] = {
        class = "PALADIN",
        name = "Seal of Justice",
        baseId = 20164,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        flags = { buff = true, seal = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Judgement"] = {
        class = "PALADIN",
        name = "Judgement",
        baseId = 20271,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        range = 10,
        cooldown = 10,
        flags = { offensive = true, direct = true, magical = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Judgement of the Crusader"] = {
        class = "PALADIN",
        name = "Judgement of the Crusader",
        baseId = 20300,
        minLevel = 4,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 20,
        range = 10,
        debuffId = 20300,
        flags = { debuff = true, utility = true },
        debuffStackingMode = "single_any_source", -- Only one Judgement of the Crusader matters; check any source regardless of who cast it
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Righteous Fury"] = {
        class = "PALADIN",
        name = "Righteous Fury",
        baseId = 25780,
        minLevel = 16,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 1800,
        buffId = 25780,
        manaCostPct = 0.24, -- 24% of base mana (TBC Classic)
        flags = { buff = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Judgement of Wisdom"] = {
        class = "PALADIN",
        spec = nil,
        name = "Judgement of Wisdom",
        baseId = 20925,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 180,
        range = 10,
        flags = { debuff = true, utility = true },
        debuffStackingMode = "single_any_source", -- Only one Judgement of Wisdom matters; check any source regardless of who cast it
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Judgement of Light"] = {
        class = "PALADIN",
        spec = nil,
        name = "Judgement of Light",
        baseId = 20927,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 180,
        range = 10,
        flags = { debuff = true, utility = true },
        debuffStackingMode = "single_any_source", -- Only one Judgement of Light matters; check any source regardless of who cast it
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Consecration"] = {
        class = "PALADIN",
        name = "Consecration",
        baseId = 26573,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 8,
        ticks = 4,
        tickInterval = 2,
        cooldown = 8,
        resourceCost = 95,
        resource = "mana",
        flags = { offensive = true, magical = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Blessing of Might"] = {
        class = "PALADIN",
        name = "Blessing of Might",
        baseId = 19740,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 900,
        range = 30,
        flags = { buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Blessing of Kings"] = {
        class = "PALADIN",
        name = "Blessing of Kings",
        baseId = 20217,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 900,
        range = 30,
        flags = { buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Blessing of Wisdom"] = {
        class = "PALADIN",
        name = "Blessing of Wisdom",
        baseId = 19742,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 900,
        range = 30,
        flags = { buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Blessing of Salvation"] = {
        class = "PALADIN",
        name = "Blessing of Salvation",
        baseId = 1038,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 900,
        range = 30,
        flags = { buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Blessing of Sanctuary"] = {
        class = "PALADIN",
        name = "Blessing of Sanctuary",
        baseId = 20911,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 900,
        range = 30,
        flags = { buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Divine Protection"] = {
        class = "PALADIN",
        name = "Divine Protection",
        baseId = 498,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 12,
        cooldown = 300,
        flags = { cooldown = true, defensive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Divine Shield"] = {
        class = "PALADIN",
        name = "Divine Shield",
        baseId = 642,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 12,
        cooldown = 300,
        flags = { cooldown = true, defensive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Lay on Hands"] = {
        class = "PALADIN",
        name = "Lay on Hands",
        baseId = 633,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        range = 40,
        cooldown = 3600,
        flags = { cooldown = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Hammer of Wrath"] = {
        class = "PALADIN",
        name = "Hammer of Wrath",
        baseId = 24275,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        range = 30,
        cooldown = 6,
        resourceCost = 10,
        resource = "mana",
        flags = { offensive = true, direct = true, magical = true, cooldown = true, execute = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Exorcism"] = {
        class = "PALADIN",
        name = "Exorcism",
        baseId = 879,
        school = "holy",
        schoolMask = 2,
        castType = "cast",
        castTime = 1.5,
        hasteType = "spell",
        range = 30,
        resourceCost = 30,
        resource = "mana",
        flags = { offensive = true, direct = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Holy Wrath"] = {
        class = "PALADIN",
        name = "Holy Wrath",
        baseId = 2812,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        range = 10,
        cooldown = 15,
        resourceCost = 50,
        resource = "mana",
        flags = { offensive = true, direct = true, magical = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Turn Undead"] = {
        class = "PALADIN",
        name = "Turn Undead",
        baseId = 2878,
        school = "holy",
        schoolMask = 2,
        castType = "cast",
        castTime = 1.5,
        hasteType = "spell",
        duration = 20,
        range = 30,
        flags = { control = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Sense Undead"] = {
        class = "PALADIN",
        name = "Sense Undead",
        baseId = 5502,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Purify"] = {
        class = "PALADIN",
        name = "Purify",
        baseId = 1152,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        range = 40,
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Cleanse"] = {
        class = "PALADIN",
        name = "Cleanse",
        baseId = 4987,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        range = 40,
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Redemption"] = {
        class = "PALADIN",
        name = "Redemption",
        baseId = 7328,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        range = 30,
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Divine Intervention"] = {
        class = "PALADIN",
        name = "Divine Intervention",
        baseId = 19752,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        range = 30,
        cooldown = 3600,
        flags = { cooldown = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- PALADIN â€“ Retribution
    ------------------------------------------------------------------------
    ["Crusader Strike"] = {
        class = "PALADIN",
        spec = "RETRIBUTION",
        name = "Crusader Strike",
        baseId = 35395,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        cooldown = 6,
        flags = { offensive = true, direct = true, requiresMelee = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Avenging Wrath"] = {
        class = "PALADIN",
        spec = "RETRIBUTION",
        name = "Avenging Wrath",
        baseId = 31884,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 20,
        cooldown = 120,
        flags = { cooldown = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Sanctity Aura"] = {
        class = "PALADIN",
        spec = "RETRIBUTION",
        name = "Sanctity Aura",
        baseId = 20218,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 180,
        flags = { buff = true, aura = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Repentance"] = {
        class = "PALADIN",
        spec = "RETRIBUTION",
        name = "Repentance",
        baseId = 20066,
        school = "holy",
        schoolMask = 2,
        castType = "instant",
        hasteType = "gcd",
        duration = 10,
        range = 20,
        cooldown = 60,
        flags = { control = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["The Art of War"] = {
        class = "PALADIN",
        spec = "RETRIBUTION",
        name = "The Art of War",
        baseId = 31890,
        school = "holy",
        schoolMask = 2,
        castType = "passive",
        flags = { passive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Vengeance"] = {
        class = "PALADIN",
        spec = "RETRIBUTION",
        name = "Vengeance",
        baseId = 20049,
        school = "holy",
        schoolMask = 2,
        castType = "passive",
        flags = { passive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Two-Handed Weapon Specialization"] = {
        class = "PALADIN",
        spec = "RETRIBUTION",
        name = "Two-Handed Weapon Specialization",
        baseId = 20061,
        school = "holy",
        schoolMask = 2,
        castType = "passive",
        flags = { passive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- SHAMAN â€“ Base class
    ------------------------------------------------------------------------
    ["Bloodlust"] = {
        class = "SHAMAN",
        name = "Bloodlust",
        baseId = 2825,
        minLevel = 70,
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        hasteType = "gcd",
        duration = 40,
        cooldown = 600,
        buffId = 2825,
        flags = { buff = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Lightning Bolt"] = {
        class = "SHAMAN",
        name = "Lightning Bolt",
        baseId = 403,
        school = "nature",
        schoolMask = 8,
        castType = "cast",
        castTime = 3.0,
        hasteType = "spell",
        range = 30,
        flags = { offensive = true, direct = true, nature = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Chain Lightning"] = {
        class = "SHAMAN",
        name = "Chain Lightning",
        baseId = 421,
        school = "nature",
        schoolMask = 8,
        castType = "cast",
        castTime = 2.5,
        hasteType = "spell",
        range = 30,
        cooldown = 6,
        flags = { offensive = true, direct = true, nature = true, magical = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Healing Wave"] = {
        class = "SHAMAN",
        name = "Healing Wave",
        baseId = 331,
        school = "nature",
        schoolMask = 8,
        castType = "cast",
        castTime = 3.0,
        hasteType = "spell",
        range = 40,
        flags = { heal = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Lesser Healing Wave"] = {
        class = "SHAMAN",
        name = "Lesser Healing Wave",
        baseId = 8004,
        school = "nature",
        schoolMask = 8,
        castType = "cast",
        castTime = 1.5,
        hasteType = "spell",
        range = 40,
        flags = { heal = true, magical = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Earth Shock"] = {
        class = "SHAMAN",
        name = "Earth Shock",
        baseId = 8042,
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        hasteType = "gcd",
        range = 30,
        cooldown = 6,
        flags = { offensive = true, direct = true, nature = true, magical = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Flame Shock"] = {
        class = "SHAMAN",
        name = "Flame Shock",
        baseId = 8050,
        school = "fire",
        schoolMask = 4,
        castType = "instant",
        hasteType = "gcd",
        duration = 12,
        ticks = 4,
        tickInterval = 3,
        range = 30,
        cooldown = 6,
        flags = { offensive = true, dot = true, fire = true, magical = true, cooldown = true },
        debuffStackingMode = "per_player", -- Each shaman applies own Flame Shock; damage stacks across shamans
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Frost Shock"] = {
        class = "SHAMAN",
        name = "Frost Shock",
        baseId = 8056,
        school = "frost",
        schoolMask = 16,
        castType = "instant",
        hasteType = "gcd",
        duration = 8,
        range = 30,
        cooldown = 6,
        flags = { offensive = true, direct = true, frost = true, magical = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Purge"] = {
        class = "SHAMAN",
        name = "Purge",
        baseId = 370,
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        hasteType = "gcd",
        range = 30,
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Water Breathing"] = {
        class = "SHAMAN",
        name = "Water Breathing",
        baseId = 131,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 600,
        range = 30,
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Water Walking"] = {
        class = "SHAMAN",
        name = "Water Walking",
        baseId = 546,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 600,
        range = 30,
        flags = { utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Reincarnation"] = {
        class = "SHAMAN",
        name = "Reincarnation",
        baseId = 20608,
        school = "physical",
        schoolMask = 1,
        castType = "passive",
        flags = { passive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Astral Recall"] = {
        class = "SHAMAN",
        name = "Astral Recall",
        baseId = 556,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        cooldown = 900,
        flags = { utility = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Totem of Wrath"] = {
        class = "SHAMAN",
        name = "Totem of Wrath",
        baseId = 30706,
        school = "fire",
        schoolMask = 4,
        castType = "instant",
        hasteType = "gcd",
        duration = 180,
        cooldown = 60,
        flags = { totem = true, buff = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Searing Totem"] = {
        class = "SHAMAN",
        name = "Searing Totem",
        baseId = 3599,
        school = "fire",
        schoolMask = 4,
        castType = "instant",
        hasteType = "gcd",
        duration = 60,
        cooldown = 15,
        flags = { totem = true, offensive = true, fire = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Magma Totem"] = {
        class = "SHAMAN",
        name = "Magma Totem",
        baseId = 8190,
        school = "fire",
        schoolMask = 4,
        castType = "instant",
        hasteType = "gcd",
        duration = 20,
        ticks = 10,
        tickInterval = 2,
        cooldown = 30,
        flags = { totem = true, offensive = true, fire = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Fire Nova Totem"] = {
        class = "SHAMAN",
        name = "Fire Nova Totem",
        baseId = 11307,
        school = "fire",
        schoolMask = 4,
        castType = "instant",
        hasteType = "gcd",
        duration = 5,
        cooldown = 15,
        flags = { totem = true, offensive = true, fire = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Strength of Earth Totem"] = {
        class = "SHAMAN",
        name = "Strength of Earth Totem",
        baseId = 8075,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 180,
        cooldown = 15,
        flags = { totem = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Grace of Air Totem"] = {
        class = "SHAMAN",
        name = "Grace of Air Totem",
        baseId = 8835,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 180,
        cooldown = 15,
        flags = { totem = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Windfury Totem"] = {
        class = "SHAMAN",
        name = "Windfury Totem",
        baseId = 8512,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 180,
        cooldown = 15,
        flags = { totem = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Mana Spring Totem"] = {
        class = "SHAMAN",
        name = "Mana Spring Totem",
        baseId = 5677,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 180,
        cooldown = 15,
        flags = { totem = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Healing Stream Totem"] = {
        class = "SHAMAN",
        name = "Healing Stream Totem",
        baseId = 5394,
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        hasteType = "gcd",
        duration = 60,
        cooldown = 15,
        flags = { totem = true, heal = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Earth Elemental Totem"] = {
        class = "SHAMAN",
        name = "Earth Elemental Totem",
        baseId = 2062,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 120,
        cooldown = 1200,
        flags = { totem = true, cooldown = true, defensive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Fire Elemental Totem"] = {
        class = "SHAMAN",
        name = "Fire Elemental Totem",
        baseId = 2894,
        school = "fire",
        schoolMask = 4,
        castType = "instant",
        hasteType = "gcd",
        duration = 120,
        cooldown = 600,
        flags = { totem = true, cooldown = true, offensive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Tremor Totem"] = {
        class = "SHAMAN",
        name = "Tremor Totem",
        baseId = 8143,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 180,
        cooldown = 15,
        flags = { totem = true, utility = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Wind Shear"] = {
        class = "SHAMAN",
        name = "Wind Shear",
        baseId = 57994,
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        hasteType = "gcd",
        range = 30,
        cooldown = 6,
        flags = { interrupt = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- SHAMAN â€“ Elemental
    ------------------------------------------------------------------------
    ["Elemental Mastery"] = {
        class = "SHAMAN",
        spec = "ELEMENTAL",
        name = "Elemental Mastery",
        baseId = 16166,
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        hasteType = "gcd",
        duration = 15,
        cooldown = 180,
        flags = { cooldown = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Lightning Overload"] = {
        class = "SHAMAN",
        spec = "ELEMENTAL",
        name = "Lightning Overload",
        baseId = 30675,
        school = "nature",
        schoolMask = 8,
        castType = "passive",
        flags = { passive = true, proc = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Storm Reach"] = {
        class = "SHAMAN",
        spec = "ELEMENTAL",
        name = "Storm Reach",
        baseId = 30679,
        school = "nature",
        schoolMask = 8,
        castType = "passive",
        flags = { passive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Call of Thunder"] = {
        class = "SHAMAN",
        spec = "ELEMENTAL",
        name = "Call of Thunder",
        baseId = 16035,
        school = "nature",
        schoolMask = 8,
        castType = "passive",
        flags = { passive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },

    ------------------------------------------------------------------------
    -- SHAMAN â€“ Enhancement
    ------------------------------------------------------------------------
    ["Stormstrike"] = {
        class = "SHAMAN",
        spec = "ENHANCEMENT",
        name = "Stormstrike",
        baseId = 17364,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        range = 5,
        cooldown = 8,
        flags = { offensive = true, direct = true, requiresMelee = true, cooldown = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Windfury Weapon"] = {
        class = "SHAMAN",
        spec = "ENHANCEMENT",
        name = "Windfury Weapon",
        baseId = 8232,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        hasteType = "gcd",
        duration = 30,
        flags = { buff = true, weaponEnchant = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Shamanistic Rage"] = {
        class = "SHAMAN",
        spec = "ENHANCEMENT",
        name = "Shamanistic Rage",
        baseId = 30823,
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        hasteType = "gcd",
        duration = 15,
        cooldown = 120,
        flags = { cooldown = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Dual Wield"] = {
        class = "SHAMAN",
        spec = "ENHANCEMENT",
        name = "Dual Wield",
        baseId = 30798,
        school = "physical",
        schoolMask = 1,
        castType = "passive",
        flags = { passive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Mental Quickness"] = {
        class = "SHAMAN",
        spec = "ENHANCEMENT",
        name = "Mental Quickness",
        baseId = 30812,
        school = "physical",
        schoolMask = 1,
        castType = "passive",
        flags = { passive = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
    ["Unleashed Rage"] = {
        class = "SHAMAN",
        spec = "ENHANCEMENT",
        name = "Unleashed Rage",
        baseId = 30802,
        school = "physical",
        schoolMask = 1,
        castType = "passive",
        flags = { passive = true, buff = true },
        talentModifiers = {},
        threatMultiplier = 1.0,  -- Direct damage / default
    },
}

DB.legacyKeys = DB.legacyKeys or {
    VT = "Vampiric Touch",
    SWP = "Shadow Word: Pain",
    MB = "Mind Blast",
    MF = "Mind Flay",
    SWD = "Shadow Word: Death",
    DP = "Devouring Plague",
    SF = "Shadowfiend",
    VE = "Vampiric Embrace",
    SFORM = "Shadowform",
    IF = "Inner Focus",
    MS = "Mind Soothe",
    SU = "Shackle Undead",
    DISPEL_MAGIC = "Dispel Magic",
    FADE = "Fade",
    SHRED = "Shred",
    MANGLE_CAT = "Mangle (Cat)",
    RIP = "Rip",
    FAERIE_FIRE = "Faerie Fire (Feral)",
    FEROCIOUS_BITE = "Ferocious Bite",
    RAKE = "Rake",
    TIGERS_FURY = "Tiger's Fury",
    CLEARCASTING = "Clearcasting",
    CAT_FORM = "Cat Form",
    BEAR_FORM = "Bear Form",
    DIRE_BEAR_FORM = "Dire Bear Form",
    MANGLE_BEAR = "Mangle (Bear)",
    LACERATE = "Lacerate",
    SWIPE_BEAR = "Swipe",
    MAUL = "Maul",
    DEMORALIZING_ROAR = "Demoralizing Roar",
    FRENZIED_REGENERATION = "Frenzied Regeneration",
    BASH = "Bash",
    INNERVATE = "Innervate",
    PROWL = "Prowl",
    POUNCE = "Pounce",
    RAVAGE = "Ravage",
    HURRICANE = "Hurricane",
    MOONFIRE = "Moonfire",
    INSECT_SWARM = "Insect Swarm",
    STARFIRE = "Starfire",
    WRATH = "Wrath",
    FAERIE_FIRE_BALANCE = "Faerie Fire",
    MOONKIN_FORM = "Moonkin Form",
    BARKSKIN = "Barkskin",
    NATURE_SWIFTNESS = "Nature's Swiftness",
    ENTANGLING_ROOTS = "Entangling Roots",
    FORCE_OF_NATURE = "Force of Nature",
    FIREBALL = "Fireball",
    FROSTBOLT = "Frostbolt",
    ARCANE_BLAST = "Arcane Blast",
    ARCANE_MISSILES = "Arcane Missiles",
    SCORCH = "Scorch",
    FIRE_BLAST = "Fire Blast",
    BLAST_WAVE = "Blast Wave",
    DRAGONS_BREATH = "Dragon's Breath",
    COMBUSTION = "Combustion",
    ICE_LANCE = "Ice Lance",
    ICY_VEINS = "Icy Veins",
    COLD_SNAP = "Cold Snap",
    ARCANE_POWER = "Arcane Power",
    PRESENCE_OF_MIND = "Presence of Mind",
    EVOCATION = "Evocation",
    SUMMON_WATER_ELEMENTAL = "Summon Water Elemental",
    ARCANE_EXPLOSION = "Arcane Explosion",
    BLIZZARD = "Blizzard",
    FLAMESTRIKE = "Flamestrike",
    CONE_OF_COLD = "Cone of Cold",
    LIVING_BOMB = "Living Bomb",
    -- WARLOCK
    SHADOW_BOLT = "Shadow Bolt",
    IMMOLATE = "Immolate",
    LIFE_TAP = "Life Tap",
    CORRUPTION = "Corruption",
    CURSE_OF_AGONY = "Curse of Agony",
    CURSE_OF_ELEMENTS = "Curse of Elements",
    CURSE_OF_DOOM = "Curse of Doom",
    SIPHON_LIFE = "Siphon Life",
    UNSTABLE_AFFLICTION = "Unstable Affliction",
    SEED_OF_CORRUPTION = "Seed of Corruption",
    DEATH_COIL = "Death Coil",
    INCINERATE = "Incinerate",
    CONFLAGRATE = "Conflagrate",
    SHADOWBURN = "Shadowburn",
    SOUL_FIRE = "Soul Fire",
    DRAIN_SOUL = "Drain Soul",
    SEARING_PAIN = "Searing Pain",
    DRAIN_LIFE = "Drain Life",
    SUMMON_FELGUARD = "Summon Felguard",
    DEMONIC_SACRIFICE = "Demonic Sacrifice",
    SOUL_LINK = "Soul Link",
    -- ROGUE
    SINISTER_STRIKE = "Sinister Strike",
    BACKSTAB = "Backstab",
    EVISCERATE = "Eviscerate",
    SLICE_AND_DICE = "Slice and Dice",
    RUPTURE = "Rupture",
    MUTILATE = "Mutilate",
    ENVENOM = "Envenom",
    COLD_BLOOD = "Cold Blood",
    GARROTE = "Garrote",
    AMBUSH = "Ambush",
    HEMORRHAGE = "Hemorrhage",
    BLADE_FLURRY = "Blade Flurry",
    ADRENALINE_RUSH = "Adrenaline Rush",
    PREMEDITATION = "Premeditation",
    PREPARATION = "Preparation",
    KICK = "Kick",
    VANISH = "Vanish",
    EVASION = "Evasion",
    EXPOSE_ARMOR = "Expose Armor",
    DEADLY_THROW = "Deadly Throw",
    -- WARRIOR
    HEROIC_STRIKE = "Heroic Strike",
    BATTLE_SHOUT = "Battle Shout",
    REND = "Rend",
    MORTAL_STRIKE = "Mortal Strike",
    SWEEPING_STRIKES = "Sweeping Strikes",
    SLAM = "Slam",
    BLOODTHIRST = "Bloodthirst",
    WHIRLWIND = "Whirlwind",
    DEATH_WISH = "Death Wish",
    EXECUTE = "Execute",
    OVERPOWER = "Overpower",
    CHARGE = "Charge",
    BLOODRAGE = "Bloodrage",
    BERSERKER_RAGE = "Berserker Rage",
    CLEAVE = "Cleave",
    PUMMEL = "Pummel",
    HAMSTRING = "Hamstring",
    RECKLESSNESS = "Recklessness",
    DEMORALIZING_SHOUT = "Demoralizing Shout",
    THUNDER_CLAP = "Thunder Clap",
    INTIMIDATING_SHOUT = "Intimidating Shout",
    -- HUNTER
    STEADY_SHOT = "Steady Shot",
    KILL_COMMAND = "Kill Command",
    BESTIAL_WRATH = "Bestial Wrath",
    HUNTERS_MARK = "Hunter's Mark",
    SERPENT_STING = "Serpent Sting",
    ARCANE_SHOT = "Arcane Shot",
    MULTI_SHOT = "Multi-Shot",
    AIMED_SHOT = "Aimed Shot",
    RAPID_FIRE = "Rapid Fire",
    ASPECT_HAWK = "Aspect of the Hawk",
    ASPECT_VIPER = "Aspect of the Viper",
    TRUESHOT_AURA = "Trueshot Aura",
    READINESS = "Readiness",
    EXPLOSIVE_SHOT = "Explosive Shot",
    DISENGAGE = "Disengage",
    FREEZING_TRAP = "Freezing Trap",
    IMMOLATION_TRAP = "Immolation Trap",
    -- PALADIN
    CRUSADER_STRIKE = "Crusader Strike",
    JUDGEMENT = "Judgement",
    CONSECRATION = "Consecration",
    SEAL_OF_COMMAND = "Seal of Command",
    SEAL_OF_BLOOD = "Seal of Blood",
    SEAL_OF_THE_CRUSADER = "Seal of the Crusader",
    AVENGING_WRATH = "Avenging Wrath",
    EXORCISM = "Exorcism",
    HAMMER_OF_WRATH = "Hammer of Wrath",
    HOLY_WRATH = "Holy Wrath",
    SANCTITY_AURA = "Sanctity Aura",
    BLESSING_OF_MIGHT = "Blessing of Might",
    BLESSING_OF_KINGS = "Blessing of Kings",
    BLESSING_OF_WISDOM = "Blessing of Wisdom",
    SEAL_OF_RIGHTEOUSNESS = "Seal of Righteousness",
    SEAL_OF_WISDOM = "Seal of Wisdom",
    -- SHAMAN
    LIGHTNING_BOLT = "Lightning Bolt",
    CHAIN_LIGHTNING = "Chain Lightning",
    STORMSTRIKE = "Stormstrike",
    FLAME_SHOCK = "Flame Shock",
    EARTH_SHOCK = "Earth Shock",
    FROST_SHOCK = "Frost Shock",
    WINDFURY_WEAPON = "Windfury Weapon",
    SHAMANISTIC_RAGE = "Shamanistic Rage",
    ELEMENTAL_MASTERY = "Elemental Mastery",
    SEARING_TOTEM = "Searing Totem",
    MAGMA_TOTEM = "Magma Totem",
    FIRE_ELEMENTAL_TOTEM = "Fire Elemental Totem",
    STRENGTH_OF_EARTH_TOTEM = "Strength of Earth Totem",
    GRACE_OF_AIR_TOTEM = "Grace of Air Totem",
    WINDFURY_TOTEM = "Windfury Totem",
    MANA_SPRING_TOTEM = "Mana Spring Totem",
    TOTEM_OF_WRATH = "Totem of Wrath",
    WIND_SHEAR = "Wind Shear",
    HEALING_WAVE = "Healing Wave",
}

DB.legacyAliasesByCanonical = DB.legacyAliasesByCanonical or {}
for legacyKey, canonicalKey in pairs(DB.legacyKeys) do
    DB.legacyAliasesByCanonical[canonicalKey] = legacyKey
end

-- Pseudo-keys: rotation-entry keys that do not map 1:1 to a catalog spell.
-- SWD_EXEC is a variant of a real spell (execution-gated SW:D); the rest are
-- item actions (trinkets, potions, runes, wand).  These are NOT catalog
-- entries (so they never pollute byBaseId/byName), but RebuildSpellCatalog
-- gives each one an A.SPELLS record so the rotation editor, icons, and
-- cooldown projection all resolve them like a normal spell.
--   label    : display name shown in the rotation editor and pickers
--   spellKey : canonical spell this pseudo-key aliases (nil for item actions)
DB.pseudoKeys = DB.pseudoKeys or {
    -- SWD_EXEC's label matches the base spell so the rotation editor shows
    -- both SWD entries as the same ability ("Shadow Word: Death"); the
    -- picker dedupes it against the real spell (see SpellData.GetPlayerSpells).
    SWD_EXEC = { label = "Shadow Word: Death", spellKey = "Shadow Word: Death" },
    TRINKET1 = { label = "Trinket 1 (on-use)", spellKey = nil },
    TRINKET2 = { label = "Trinket 2 (on-use)", spellKey = nil },
    POTION   = { label = "Mana Potion",        spellKey = nil },
    RUNE     = { label = "Dark Rune",          spellKey = nil },
    WAND     = { label = "Wand",               spellKey = nil },
    ["Seal of Command (twist)"] = { label = "Seal of Command (twist)", spellKey = "Seal of Command" },
    ["Seal of Blood (return)"]  = { label = "Seal of Blood (return)",  spellKey = "Seal of Blood" },
}

DB.byBaseId = {}
DB.byName = {}
DB.sortedKeys = {}
for key, def in pairs(DB.catalog) do
    def.key = key
    DB.byBaseId[def.baseId] = def
    DB.byName[def.name] = def
    if def.aliasNames then
        for _, aliasName in ipairs(def.aliasNames) do
            DB.byName[aliasName] = DB.byName[aliasName] or def
        end
    end
    local localizedName = A.GetSpellInfoCached and A.GetSpellInfoCached(def.baseId)
    if localizedName and not DB.byName[localizedName] then
        DB.byName[localizedName] = def
    end
    DB.sortedKeys[#DB.sortedKeys + 1] = key
end
sort(DB.sortedKeys, function(leftKey, rightKey)
    local left = DB.catalog[leftKey]
    local right = DB.catalog[rightKey]
    if left.name == right.name then
        return left.key < right.key
    end
    return left.name < right.name
end)

DB.spellbook = DB.spellbook or {
    byId = {},
    byName = {},
    dirty = true,
    scannedAt = 0,
}

local function SetSpellbookEntry(spellId)
    local name, rank, icon = A.GetSpellInfoCached(spellId)
    if not name then return end

    local entry = {
        id = spellId,
        name = name,
        rank = rank or "",
        rankNumber = GetRankNumber(rank) or -1,
        icon = icon,
    }

    DB.spellbook.byId[spellId] = entry

    local current = DB.spellbook.byName[name]
    if not current
        or entry.rankNumber > current.rankNumber
        or (entry.rankNumber == current.rankNumber and entry.id > current.id)
    then
        DB.spellbook.byName[name] = entry
    end
end

local function ScanPlayerSpellbook(force)
    if not force and not DB.spellbook.dirty and DB.spellbook.scannedAt > 0 then
        return
    end

    DB.spellbook.byId = {}
    DB.spellbook.byName = {}

    local numTabs = GetNumSpellTabs and GetNumSpellTabs() or 0
    for tabIndex = 1, numTabs do
        local _, _, offset, numEntries = GetSpellTabInfo(tabIndex)
        for index = 1, (numEntries or 0) do
            local spellBookIndex = (offset or 0) + index
            local spellType, spellId = GetSpellBookItemInfo(spellBookIndex, BOOKTYPE_SPELL)
            if spellType == "SPELL" and spellId then
                SetSpellbookEntry(spellId)
            end
        end
    end

    DB.spellbook.dirty = false
    DB.spellbook.scannedAt = GetTime and GetTime() or 0
end

local function ResolveKnownSpell(def)
    if not def then return nil end

    local resolveIds = def.resolveIds
    if resolveIds then
        for _, spellId in ipairs(resolveIds) do
            local entry = DB.spellbook.byId[spellId]
            if entry then
                return entry
            end
            if RawIsSpellKnown(spellId) then
                local name, rank, icon = A.GetSpellInfoCached(spellId)
                if name then
                    return {
                        id = spellId,
                        name = name,
                        rank = rank or "",
                        icon = icon,
                    }
                end
            end
        end
    end

    local names = {}
    local seen = {}

    local apiName = def.baseId and A.GetSpellInfoCached(def.baseId)
    if apiName then
        names[#names + 1] = apiName
        seen[apiName] = true
    end

    if def.resolveNames then
        for _, name in ipairs(def.resolveNames) do
            if name and not seen[name] then
                names[#names + 1] = name
                seen[name] = true
            end
        end
    end

    if def.name and not seen[def.name] then
        names[#names + 1] = def.name
        seen[def.name] = true
    end

    for _, name in ipairs(names) do
        local entry = DB.spellbook.byName[name]
        if entry then
            return entry
        end
    end

    local fallbackId = def.baseId
    if fallbackId then
        local name, rank, icon = A.GetSpellInfoCached(fallbackId)
        if name or def.name then
            return {
                id = fallbackId,
                name = name or def.name,
                rank = rank or "",
                icon = icon,
            }
        end
    end

    return nil
end

local function ResolveCatalogKey(spellRef)
    if type(spellRef) ~= "string" then
        return spellRef
    end
    return DB.legacyKeys[spellRef] or spellRef
end

function A.GetSpellDefinition(spellRef)
    if spellRef == nil then return nil end

    if type(spellRef) == "table" then
        if spellRef.key then
            local canonicalKey = ResolveCatalogKey(spellRef.key)
            if DB.catalog[canonicalKey] then
                return DB.catalog[canonicalKey]
            end
        end
        if spellRef.meta then
            return spellRef.meta
        end
        spellRef = spellRef.baseId or spellRef.id or spellRef.spellId
    end

    if type(spellRef) == "string" then
        local canonicalKey = ResolveCatalogKey(spellRef)
        local direct = DB.catalog[canonicalKey]
        if direct then
            return direct
        end

        local spell = A.SPELLS and (A.SPELLS[canonicalKey] or A.SPELLS[spellRef])
        if spell and spell.meta then
            return spell.meta
        end

        local numeric = tonumber(spellRef)
        if numeric then
            spellRef = numeric
        else
            return DB.byName[spellRef]
        end
    end

    if type(spellRef) == "number" then
        local direct = DB.byBaseId[spellRef]
        if direct then
            return direct
        end

        local spellName = A.GetSpellInfoCached(spellRef)
        if spellName then
            return DB.byName[spellName]
        end
    end

    return nil
end

function A.ResolveSpellID(spellRef)
    if spellRef == nil then return nil end

    if type(spellRef) == "table" then
        if spellRef.id then return A.ResolveSpellID(spellRef.id) end
        if spellRef.baseId then return A.ResolveSpellID(spellRef.baseId) end
        if spellRef.key then return A.ResolveSpellID(spellRef.key) end
        return nil
    end

    if type(spellRef) == "string" then
        local canonicalKey = ResolveCatalogKey(spellRef)
        local spell = A.SPELLS and (A.SPELLS[canonicalKey] or A.SPELLS[spellRef])
        if spell then
            return spell.id or spell.baseId
        end

        local numeric = tonumber(spellRef)
        if numeric then
            spellRef = numeric
        else
            local def = DB.byName[spellRef] or DB.byName[canonicalKey]
            if not def then return nil end
            ScanPlayerSpellbook(false)
            local resolved = ResolveKnownSpell(def)
            return resolved and resolved.id or def.baseId
        end
    end

    if type(spellRef) == "number" then
        if RawIsSpellKnown(spellRef) then
            return spellRef
        end
        local def = A.GetSpellDefinition(spellRef)
        if def then
            ScanPlayerSpellbook(false)
            local resolved = ResolveKnownSpell(def)
            return resolved and resolved.id or def.baseId
        end
        return spellRef
    end

    return nil
end

function A.RebuildSpellCatalog()
    A.SPELLS = A.SPELLS or {}
    local spellAliases = {}

    for _, key in ipairs(DB.sortedKeys) do
        local def = DB.catalog[key]
        local resolved = ResolveKnownSpell(def)
        local spell = A.SPELLS[key] or {}
        local resolvedId = resolved and resolved.id or def.baseId

        spell.key = key
        spell.baseId = def.baseId
        spell.id = resolvedId
        spell.name = (resolved and resolved.name) or (A.GetSpellInfoCached(def.baseId)) or def.name
        spell.label = def.name
        spell.rank = resolved and resolved.rank or ""
        spell.icon = (resolved and resolved.icon) or A.GetSpellIconCached(def.baseId)
        spell.known = RawIsSpellKnown(resolvedId) or (DB.spellbook.byId[resolvedId] ~= nil)
        spell.class = def.class
        spell.spec = def.spec
        spell.meta = def

        A.SPELLS[key] = spell

        local legacyKey = DB.legacyAliasesByCanonical and DB.legacyAliasesByCanonical[key] or nil
        if legacyKey and A.COLORS and A.COLORS[legacyKey] then
            A.COLORS[key] = A.COLORS[legacyKey]
        end
        if def.name then
            spellAliases[def.name] = spell
            if A.COLORS and A.COLORS[key] then
                A.COLORS[def.name] = A.COLORS[key]
            end
        end
        if spell.name and spell.name ~= def.name then
            spellAliases[spell.name] = spell
            if A.COLORS and A.COLORS[key] then
                A.COLORS[spell.name] = A.COLORS[key]
            end
        end
        if legacyKey then
            spellAliases[legacyKey] = spell
        end
    end

    -- Pseudo-key spell records (SWD_EXEC, trinkets, potions, runes, wand).
    -- Each mirrors its base spell where one exists so icons, cooldowns, mana,
    -- and safety checks resolve correctly; item actions stay spell-less.
    for pseudoKey, pdef in pairs(DB.pseudoKeys) do
        local base = pdef.spellKey and A.SPELLS[pdef.spellKey] or nil
        local spell = A.SPELLS[pseudoKey] or {}
        spell.key    = pseudoKey
        spell.baseId = base and base.baseId or nil
        spell.id     = base and base.id or nil
        spell.name   = (base and base.name) or pdef.label
        spell.label  = pdef.label
        spell.rank   = base and base.rank or ""
        spell.icon   = base and base.icon or nil
        spell.known  = base and base.known or false
        spell.class  = base and base.class or nil
        spell.spec   = base and base.spec or nil
        spell.meta   = base and base.meta or nil
        spell.pseudo = true
        A.SPELLS[pseudoKey] = spell
    end

    A.SPELLS_BY_NAME = spellAliases
    local spellMeta = getmetatable(A.SPELLS)
    if not spellMeta then
        spellMeta = {}
        setmetatable(A.SPELLS, spellMeta)
    end
    spellMeta.__index = spellAliases

    if A.SpellData and A.SpellData.RebuildCoefficientIndex then
        A.SpellData:RebuildCoefficientIndex()
    end
end

function A.RefreshSpellCatalog(force)
    DB.spellbook.dirty = true
    ScanPlayerSpellbook(force)
    A.RebuildSpellCatalog()
end

local refreshFrame = CreateFrame("Frame")
refreshFrame:RegisterEvent("PLAYER_LOGIN")
refreshFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
refreshFrame:RegisterEvent("SPELLS_CHANGED")
pcall(function() refreshFrame:RegisterEvent("LEARNED_SPELL_IN_TAB") end)
refreshFrame:SetScript("OnEvent", function()
    A.RefreshSpellCatalog(true)
end)

A.RebuildSpellCatalog()
if IsLoggedIn and IsLoggedIn() then
    A.RefreshSpellCatalog(true)
end
