local A = SPHelper
local T = A.SpecTemplates

local spec = {
    _fromFile = true,
    meta = { id = "fire_mage", class = "MAGE", specName = "Fire", author = "SPHelper", version = 1 },
    loadConditions = { class = "MAGE", talentTab = 2 },
    helpers = { "CastBar", "Rotation", "RotationEngine", "SpellData", "SpecUI", "Config" },
    constants = { SAFETY = 0.5, timing = { globalWaitThresholdMs = 400, defaultDelayToleranceMs = 600, dotSafeWindowSec = 1.5 } },
    trackedDebuffs = {
        { key = "scorch", spellKey = "Scorch", source = "player", duration = 30, color = "FF", isDot = false },
    },
    settingDefs = {
        use_combustion = { type = "checkbox", label = "Use Combustion", default = true, tooltip = "Use Combustion on cooldown." },
        combustion_classification = { type = "dropdown", label = "Combustion target type", default = "any",
                                       tooltip = "Restrict Combustion to: any, normal, elite, or boss.",
                                       values = { "any", "normal", "elite", "boss" } },
        use_icy_veins = { type = "checkbox", label = "Use Icy Veins", default = true, tooltip = "Stack Icy Veins with Combustion for max burst." },
        icy_veins_classification = { type = "dropdown", label = "Icy Veins target type", default = "any",
                                       tooltip = "Restrict Icy Veins to: any, normal, elite, or boss.",
                                       values = { "any", "normal", "elite", "boss" } },
        use_scorch = { type = "checkbox", label = "Maintain Scorch debuff", default = true, tooltip = "Keep Improved Scorch fire vulnerability debuff up." },
        use_fire_blast = { type = "checkbox", label = "Use Fire Blast", default = true, tooltip = "Use Fire Blast as filler on cooldown." },
        use_flamestrike = { type = "checkbox", label = "Use Flamestrike (AoE)", default = true, tooltip = "Flamestrike when 3+ targets present." },
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
    settingOrder = { "use_combustion", "combustion_classification", "use_icy_veins", "icy_veins_classification", "use_scorch", "use_fire_blast", "use_flamestrike", "suggestPot", "potManaThreshold", "suggestRune", "runeManaThreshold", "use_trinket_1", "trinket_1_classification", "use_trinket_2", "trinket_2_classification" },
    rotation = T.BuildFireMageRotation and T.BuildFireMageRotation(spec),
}

if A.SpecManager then A.SpecManager:RegisterSpec(spec) end
