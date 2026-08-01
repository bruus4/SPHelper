local A = SPHelper
local T = A.SpecTemplates

local spec = {
    _fromFile = true,
    meta = { id = "frost_mage", class = "MAGE", specName = "Frost", author = "SPHelper", version = 1 },
    loadConditions = { class = "MAGE", talentTab = 3 },
    helpers = { "CastBar", "Rotation", "RotationEngine", "SpellData", "SpecUI", "Config" },
    constants = { SAFETY = 0.5, timing = { globalWaitThresholdMs = 400, defaultDelayToleranceMs = 600, dotSafeWindowSec = 1.5 } },
    settingDefs = {
        use_water_elemental = { type = "checkbox", label = "Summon Water Elemental", default = true, tooltip = "Summon Water Elemental pre-combat." },
        summon_water_elemental_classification = { type = "dropdown", label = "Summon Water Elemental target type", default = "any",
                                      tooltip = "Restrict Summon Water Elemental to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
        use_icy_veins = { type = "checkbox", label = "Use Icy Veins", default = true, tooltip = "Use Icy Veins on cooldown." },
        icy_veins_classification = { type = "dropdown", label = "Icy Veins target type", default = "any",
                                      tooltip = "Restrict Icy Veins to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
        use_cold_snap = { type = "checkbox", label = "Use Cold Snap", default = true, tooltip = "Reset Icy Veins and Water Elemental." },
        cold_snap_classification = { type = "dropdown", label = "Cold Snap target type", default = "any",
                                      tooltip = "Restrict Cold Snap to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
        use_ice_lance = { type = "checkbox", label = "Use Ice Lance", default = true, tooltip = "Ice Lance filler when moving." },
        use_blizzard = { type = "checkbox", label = "Use Blizzard (AoE)", default = true, tooltip = "Blizzard when 3+ targets present." },
        suggestPot = { type = "checkbox", label = "Suggest mana potion", default = true, tooltip = "Show mana potion suggestion." },
        potManaThreshold = { type = "slider", label = "Potion mana %", default = 10, min = 5, max = 100, step = 5, tooltip = "Potion when mana below this %." },
        suggestRune = { type = "checkbox", label = "Suggest dark rune", default = true, tooltip = "Show rune suggestion." },
        runeManaThreshold = { type = "slider", label = "Rune mana %", default = 10, min = 5, max = 100, step = 5, tooltip = "Rune when mana below this %." },
        use_trinket_1            = { type = "checkbox", label = "Use trinket 1 (on-use)",  default = true,
                                      tooltip = "Activate trinket 1 on cooldown automatically." },
        use_trinket_2            = { type = "checkbox", label = "Use trinket 2 (on-use)",  default = true,
                                      tooltip = "Activate trinket 2 on cooldown automatically." },
        trinket_1_classification = { type = "dropdown", label = "Trinket 1 target type",   default = "any",
                                      tooltip = "Restrict trinket 1 to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
        trinket_2_classification = { type = "dropdown", label = "Trinket 2 target type",   default = "any",
                                      tooltip = "Restrict trinket 2 to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
    },
    settingOrder = { "use_water_elemental", "summon_water_elemental_classification", "use_icy_veins", "icy_veins_classification", "use_cold_snap", "cold_snap_classification", "use_ice_lance", "use_blizzard", "suggestPot", "potManaThreshold", "suggestRune", "runeManaThreshold", "use_trinket_1", "trinket_1_classification", "use_trinket_2", "trinket_2_classification" },
    rotation = T.BuildFrostMageRotation and T.BuildFrostMageRotation(spec),
}

if A.SpecManager then A.SpecManager:RegisterSpec(spec) end
