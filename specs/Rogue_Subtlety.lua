local A = SPHelper
local T = A.SpecTemplates

local spec = {
    _fromFile = true,
    meta = { id = "subtlety_rogue", class = "ROGUE", specName = "Subtlety", author = "SPHelper", version = 1 },
    loadConditions = { class = "ROGUE", talentTab = 3 },
    helpers = { "CastBar", "Rotation", "RotationEngine", "SpellData", "SpecUI", "Config" },
    constants = { SAFETY = 0.5, timing = { globalWaitThresholdMs = 200, defaultDelayToleranceMs = 400, dotSafeWindowSec = 1.0 } },
    trackedBuffs = {
        { key = "slice_and_dice", name = "Slice and Dice", spellKey = "Slice and Dice" },
        { key = "stealth", name = "Stealth", spellKey = "Stealth" },
    },
    trackedDebuffs = {
        { key = "ea", spellKey = "Expose Armor", source = "player", color = "EA", isDot = false, duration = 30 },
    },
    settingDefs = {
        use_premeditation = { type = "checkbox", label = "Use Premeditation", default = true, tooltip = "Premeditation on cooldown." },
        premeditation_classification = { type = "dropdown", label = "Premeditation target type", default = "any",
                                      tooltip = "Restrict Premeditation to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
        use_slice_and_dice = { type = "checkbox", label = "Use Slice and Dice", default = true, tooltip = "Keep Slice and Dice active." },
        use_rupture = { type = "checkbox", label = "Use Rupture", default = true, tooltip = "Rupture at 4+ CP." },
        use_hemorrhage = { type = "checkbox", label = "Use Hemorrhage", default = true, tooltip = "Hemo as builder behind target." },
        use_preparation = { type = "checkbox", label = "Use Preparation", default = true, tooltip = "Reset Vanish/other cooldowns." },
        preparation_classification = { type = "dropdown", label = "Preparation target type", default = "any",
                                      tooltip = "Restrict Preparation to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
        use_vanish = { type = "checkbox", label = "Use Vanish", default = true, tooltip = "Vanish for extra CP from Ambush." },
        vanish_classification = { type = "dropdown", label = "Vanish target type", default = "any",
                                      tooltip = "Restrict Vanish to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
        ruptureMinTTD = { type = "slider", label = "Rupture min TTD", default = 10, min = 3, max = 30, step = 1, tooltip = "Min target TTD for Rupture." },
        use_expose_armor = { type = "checkbox", label = "Use Expose Armor", default = false, tooltip = "Apply Expose Armor debuff for raid armor reduction (5 CP recommended)." },
        use_kick = { type = "checkbox", label = "Use Kick (interrupt)", default = true, tooltip = "Suggest Kick for interrupts." },
        suggestPot = { type = "checkbox", label = "Suggest potion", default = true, tooltip = "Show potion suggestion." },
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
    settingOrder = { "use_premeditation", "premeditation_classification", "use_slice_and_dice", "use_rupture", "use_hemorrhage", "use_preparation", "preparation_classification", "use_vanish", "vanish_classification", "ruptureMinTTD", "use_expose_armor", "use_kick", "suggestPot", "use_trinket_1", "trinket_1_classification", "use_trinket_2", "trinket_2_classification" },
    rotation = T.BuildSubtletyRogueRotation and T.BuildSubtletyRogueRotation(spec),
}

if A.SpecManager then A.SpecManager:RegisterSpec(spec) end
