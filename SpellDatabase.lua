------------------------------------------------------------------------
-- SPHelper  –  SpellDatabase.lua
-- Static spell catalog plus NAG-style spellbook resolution.
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
-- talentUnlock   : {tab, index, minRank} – gated behind this talent; nil = base class spell
-- hasteType      : "spell" (reduces cast time) | "channel" (reduces tick interval)
--                  | "gcd" (reduces GCD only) | "none"
-- critMultiplier : multiplier applied on a critical hit (1.5 typical, 2.0 some)
-- debuffId       : aura ID this spell applies to the enemy
-- buffId         : aura ID this spell applies to self / ally
-- talentModifiers: per-spell array of talent entries that modify this spell
--   { name, tab, index, maxRank, perRank, affects }
--   affects values: duration | damage | cooldown | crit_bonus | hit | ticks
------------------------------------------------------------------------
DB.catalog = {
    ------------------------------------------------------------------------
    -- PRIEST – Shadow
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
        buffId = 14751,
        flags = { cooldown = true, buff = true },
        talentModifiers = {},
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
        talentModifiers = {},
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
    },

    ------------------------------------------------------------------------
    -- DRUID – Feral
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
        flags = { offensive = true, builder = true, requiresBehind = true, requiresCatForm = true },
        coefficients = { attackPower = 1.0 },
        damage = { bonusVsBleeding = 224 },
        talentModifiers = {},
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
        flags = { offensive = true, builder = true, debuff = true, requiresCatForm = true },
        coefficients = { attackPower = 1.0 },
        damage = { bleedBonusFlat = 159 },
        talentModifiers = {},
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
        flags = { offensive = true, bleed = true, finisher = true, requiresCatForm = true },
        comboScaling = { pointsPerComboPoint = 4 },
        talentModifiers = {},
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
        debuffId = 16857,
        flags = { offensive = true, debuff = true, armorReduction = true, requiresForm = true },
        talentModifiers = {},
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
        flags = { offensive = true, finisher = true, requiresCatForm = true, consumesExtraEnergy = true },
        coefficients = { attackPower = 1.0 },
        comboScaling = { pointsPerComboPoint = 36 },
        talentModifiers = {},
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
        flags = { offensive = true, bleed = true, builder = true, requiresCatForm = true },
        talentModifiers = {},
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
        buffId = 5217,
        flags = { buff = true, requiresCatForm = true },
        talentModifiers = {},
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
        flags = { form = true, stance = true },
        talentModifiers = {},
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
        flags = { form = true, stance = true },
        talentModifiers = {},
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
        flags = { form = true, stance = true },
        talentModifiers = {},
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
        critMultiplier = 2.0,
        debuffId = 33876,  -- same debuff aura as Mangle Cat
        flags = { offensive = true, builder = true, debuff = true, requiresBearForm = true },
        talentModifiers = {},
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
        flags = { offensive = true, bleed = true, builder = true, requiresBearForm = true },
        talentModifiers = {},
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
        flags = { offensive = true, builder = true, requiresBearForm = true },
        talentModifiers = {},
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
        flags = { offensive = true, builder = true, requiresBearForm = true },
        talentModifiers = {},
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
        flags = { debuff = true, utility = true, requiresBearForm = true },
        talentModifiers = {},
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
        buffId = 26999,
        flags = { buff = true, cooldown = true, defensive = true, requiresBearForm = true },
        talentModifiers = {},
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
        debuffId = 8983,
        flags = { offensive = true, control = true, cooldown = true, requiresBearForm = true },
        talentModifiers = {},
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
        flags = { offensive = true, control = true, requiresStealth = true, requiresCatForm = true },
        damage = { triggerSpellId = 9007 },
        talentModifiers = {},
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
        flags = { offensive = true, builder = true, requiresStealth = true, requiresBehind = true, requiresCatForm = true },
        coefficients = { attackPower = 1.0 },
        damage = { bonusFlat = 384 },
        talentModifiers = {},
    },

    ------------------------------------------------------------------------
    -- DRUID – Balance
    ------------------------------------------------------------------------
    ["Hurricane"] = {
        class = "DRUID",
        spec = "BALANCE",
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
        talentModifiers = {},
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
        talentModifiers = {
            { name = "Moonfury",    tab = 1, index = 15, maxRank = 5, perRank = 0.02, affects = "damage" },
            { name = "Improved Moonfire", tab = 1, index = 4, maxRank = 2, perRank = 0.05, affects = "crit_bonus" },
        },
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
        talentModifiers = {
            { name = "Improved Insect Swarm",  tab = 1, index = 11, maxRank = 3, perRank = 0.1, affects = "damage" },
        },
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
        flags = { offensive = true, debuff = true, armorReduction = true },
        talentModifiers = {},
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
}

DB.legacyAliasesByCanonical = DB.legacyAliasesByCanonical or {}
for legacyKey, canonicalKey in pairs(DB.legacyKeys) do
    DB.legacyAliasesByCanonical[canonicalKey] = legacyKey
end

DB.byBaseId = {}
DB.byName = {}
DB.sortedKeys = {}
for key, def in pairs(DB.catalog) do
    def.key = key
    DB.byBaseId[def.baseId] = def
    DB.byName[def.name] = def
    local localizedName = A.GetSpellInfoCached and A.GetSpellInfoCached(def.baseId)
    if localizedName then
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