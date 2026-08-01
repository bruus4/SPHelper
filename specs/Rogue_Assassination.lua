local A = SPHelper
local T = A.SpecTemplates

local spec = {
    _fromFile = true,
    meta = { id = "assassination_rogue", class = "ROGUE", specName = "Assassination", author = "SPHelper", version = 1 },
    loadConditions = { class = "ROGUE", talentTab = 1 },
    helpers = { "CastBar", "Rotation", "RotationEngine", "SpellData", "SpecUI", "Config" },
    constants = { SAFETY = 0.5, timing = { globalWaitThresholdMs = 200, defaultDelayToleranceMs = 400, dotSafeWindowSec = 1.0 } },
    trackedBuffs = {
        { key = "slice_and_dice", name = "Slice and Dice", spellKey = "Slice and Dice" },
    },
    trackedDebuffs = {
        { key = "ea", spellKey = "Expose Armor", source = "player", color = "EA", isDot = false, duration = 30 },
    },
    settingDefs = {
        use_cold_blood = { type = "checkbox", label = "Use Cold Blood", default = true, tooltip = "Cold Blood at 4+ CP." },
        cold_blood_classification = { type = "dropdown", label = "Cold Blood target type", default = "any",
                                      tooltip = "Restrict Cold Blood to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
        use_slice_and_dice = { type = "checkbox", label = "Use Slice and Dice", default = true, tooltip = "Keep Slice and Dice active." },
        use_rupture = { type = "checkbox", label = "Use Rupture", default = true, tooltip = "Rupture at 4+ CP." },
        use_envenom = { type = "checkbox", label = "Use Envenom", default = true, tooltip = "Envenom at 4+ CP." },
        use_mutilate = { type = "checkbox", label = "Use Mutilate", default = true, tooltip = "Mutilate as builder." },
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
    settingOrder = { "use_cold_blood", "cold_blood_classification", "use_slice_and_dice", "use_rupture", "use_envenom", "use_mutilate", "ruptureMinTTD", "use_expose_armor", "use_kick", "suggestPot", "use_trinket_1", "trinket_1_classification", "use_trinket_2", "trinket_2_classification" },
    rotation = T.BuildAssassinationRogueRotation and T.BuildAssassinationRogueRotation(spec),
}

if A.SpecManager then A.SpecManager:RegisterSpec(spec) end
