------------------------------------------------------------------------
-- SPHelper  –  specs/Druid_Balance.lua
-- Balance Druid spec template.
-- This is a starting-point example — fill in rotation entries and
-- conditions to match your playstyle.
------------------------------------------------------------------------
local A = SPHelper
local T = A.SpecTemplates

local spec = {
    _fromFile = true,
    meta = { id = "balance_druid", class = "DRUID", specName = "Balance", author = "SPHelper", version = 1 },
    loadConditions = { class = "DRUID", talentTab = 1 },
    helpers = { "CastBar", "DotTracker", "Rotation", "RotationEngine", "ChannelHelper", "SpellData", "SpecUI", "Config" },
    constants = { SAFETY = 0.5, timing = { globalWaitThresholdMs = 400, defaultDelayToleranceMs = 600, dotSafeWindowSec = 1.5 } },
    trackedDebuffs = {
        { key = "moonfire",     spellKey = "Moonfire",     color = "MF", isDot = true },
        { key = "insect_swarm", spellKey = "Insect Swarm", color = "IS", isDot = true },
        { key = "faerie_fire",  spellKey = "Faerie Fire (Feral)", name = "Faerie Fire", source = "any", duration = 40, color = "FF", isDot = false },
    },
    trackedBuffs = {
        { key = "moonkin_form", name = "Moonkin Form", spellKey = "Moonkin Form" },
        { key = "starfall", name = "Starfall", spellKey = "Starfall" },
    },
    settingDefs = {
        -- Form & defensive group
        use_moonkin_form = { type = "checkbox", label = "Use Moonkin Form", default = true, group = "Form & Defensive", tooltip = "Enter Moonkin Form pre-combat." },
        use_barkskin = { type = "checkbox", label = "Use Barkskin (defensive)", default = true, group = "Form & Defensive", tooltip = "Barkskin when low on health." },
        barkskinHpPct = { type = "slider", label = "Barkskin HP %", default = 35, min = 10, max = 80, step = 5, group = "Form & Defensive", tooltip = "Use Barkskin when below this HP %." },

        -- Cooldowns group
        use_force_of_nature = { type = "checkbox", label = "Use Force of Nature", default = true, group = "Cooldowns", tooltip = "Force of Nature on cooldown for burst damage." },
        force_of_nature_classification = { type = "dropdown", label = "Force of Nature target type", default = "any", values = { "any", "normal", "elite", "boss" }, group = "Cooldowns", tooltip = "Restrict Force of Nature to: any, normal, elite, or boss." },
        use_natures_swiftness = { type = "checkbox", label = "Use Nature's Swiftness (moving)", default = true, group = "Cooldowns", tooltip = "Nature's Swiftness while moving to avoid downtime. Casts an instant Starfire/Wrath." },
        natures_swiftness_classification = { type = "dropdown", label = "Nature's Swiftness target type", default = "any", values = { "any", "normal", "elite", "boss" }, group = "Cooldowns", tooltip = "Restrict Nature's Swiftness to: any, normal, elite, or boss." },

        -- DoTs & debuffs group
        use_faerie_fire = { type = "checkbox", label = "Use Faerie Fire", default = true, group = "DoTs & Debuffs", tooltip = "Maintain armor debuff on target." },
        multidotMaxMF = { type = "slider", label = "Moonfire max targets", default = 3, min = 1, max = 8, step = 1, group = "DoTs & Debuffs", tooltip = "Maximum targets to keep Moonfire on. 1 = single-target only." },

        -- AoE group
        use_hurricane = { type = "checkbox", label = "Use Hurricane (AoE)", default = true, group = "AoE", tooltip = "Hurricane on cooldown in AoE situations." },

        -- Mana management group
        use_innervate = { type = "checkbox", label = "Use Innervate", default = true, group = "Mana Management", tooltip = "Innervate when low on mana (self-cast or cast on another player)." },
        innervateManaPct = { type = "slider", label = "Innervate mana %", default = 25, min = 5, max = 80, step = 5, group = "Mana Management", tooltip = "Use Innervate when mana drops below this percentage." },
        innervate_classification = { type = "dropdown", label = "Innervate target type", default = "any", values = { "any", "normal", "elite", "boss" }, group = "Mana Management", tooltip = "Restrict Innervate to: any, normal, elite, or boss." },
        suggestPot = { type = "checkbox", label = "Suggest mana potion", default = true, group = "Mana Management", tooltip = "Show mana potion suggestion when low on mana." },
        potManaThreshold = { type = "slider", label = "Potion mana %", default = 10, min = 5, max = 100, step = 5, group = "Mana Management", tooltip = "Suggest mana potion when mana drops below this percentage." },
        suggestRune = { type = "checkbox", label = "Suggest dark rune", default = true, group = "Mana Management", tooltip = "Show dark/demonic rune suggestion when low on mana." },
        runeManaThreshold = { type = "slider", label = "Rune mana %", default = 10, min = 5, max = 100, step = 5, group = "Mana Management", tooltip = "Suggest rune when mana drops below this percentage." },

        -- Bonus abilities group (trinkets)
        use_trinket_1            = { type = "checkbox", label = "Use trinket 1 (on-use)", default = true, group = "Bonus Abilities", tooltip = "Activate trinket 1 on cooldown automatically." },
        trinket_1_classification = { type = "dropdown", label = "Trinket 1 target type", default = "any", values = { "any", "normal", "elite", "boss" }, group = "Bonus Abilities", tooltip = "Restrict trinket 1 to: any, normal, elite, or boss." },
        use_trinket_2            = { type = "checkbox", label = "Use trinket 2 (on-use)", default = true, group = "Bonus Abilities", tooltip = "Activate trinket 2 on cooldown automatically." },
        trinket_2_classification = { type = "dropdown", label = "Trinket 2 target type", default = "any", values = { "any", "normal", "elite", "boss" }, group = "Bonus Abilities", tooltip = "Restrict trinket 2 to: any, normal, elite, or boss." },
    },
    settingOrder = {
        -- Form & Defensive
        "use_moonkin_form", "use_barkskin", "barkskinHpPct",
        -- Cooldowns
        "use_force_of_nature", "force_of_nature_classification",
        "use_natures_swiftness", "natures_swiftness_classification",
        -- DoTs & Debuffs
        "use_faerie_fire", "multidotMaxMF",
        -- AoE
        "use_hurricane",
        -- Mana Management
        "use_innervate", "innervateManaPct", "innervate_classification",
        "suggestPot", "potManaThreshold",
        "suggestRune", "runeManaThreshold",
        -- Bonus Abilities
        "use_trinket_1", "trinket_1_classification",
        "use_trinket_2", "trinket_2_classification",
    },
    channelSpells = {
        {
            spellKey = "Hurricane",
            spellName = "Hurricane",
            fakeQueue = true,
            clipOverlay = true,
            tickSound = true,
            tickFlash = true,
            tickMarkers = true,
            tickMarkerMode = "all",
            tickMarkerTicks = {},
        },
    },
    rotation = T.BuildBalanceDruidRotation and T.BuildBalanceDruidRotation(spec),
}

if A.SpecManager then A.SpecManager:RegisterSpec(spec) end
