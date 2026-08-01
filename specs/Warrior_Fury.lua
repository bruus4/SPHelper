local A = SPHelper
local T = A.SpecTemplates

local spec = {
    _fromFile = true,
    meta = { id = "fury_warrior", class = "WARRIOR", specName = "Fury", author = "SPHelper", version = 1 },
    loadConditions = { class = "WARRIOR", talentTab = 2 },
    helpers = { "CastBar", "Rotation", "RotationEngine", "SpellData", "SpecUI", "Config" },
    constants = { SAFETY = 0.5, timing = { globalWaitThresholdMs = 200, defaultDelayToleranceMs = 400, dotSafeWindowSec = 1.0 } },
    trackedBuffs = {
        { key = "battle_shout", name = "Battle Shout", spellKey = "Battle Shout" },
        { key = "death_wish", name = "Death Wish", spellKey = "Death Wish" },
        { key = "berserker_rage", name = "Berserker Rage", spellKey = "Berserker Rage" },
    },
    settingDefs = {
        use_death_wish = { type = "checkbox", label = "Use Death Wish", default = true, tooltip = "Death Wish on cooldown." },
        death_wish_classification = { type = "dropdown", label = "Death Wish target type", default = "any",
                                      tooltip = "Restrict Death Wish to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
        use_recklessness = { type = "checkbox", label = "Use Recklessness", default = true, tooltip = "Recklessness on cooldown." },
        recklessness_classification = { type = "dropdown", label = "Recklessness target type", default = "any",
                                      tooltip = "Restrict Recklessness to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
        use_bloodrage = { type = "checkbox", label = "Use Bloodrage", default = true, tooltip = "Bloodrage on cooldown." },
        use_berserker_rage = { type = "checkbox", label = "Use Berserker Rage", default = true, tooltip = "Berserker Rage for rage generation." },
        use_cleave = { type = "checkbox", label = "Use Cleave (AoE)", default = true, tooltip = "Cleave when multiple targets." },
        use_battle_shout = { type = "checkbox", label = "Maintain Battle Shout", default = true, tooltip = "Keep Battle Shout active." },
        use_hamstring = { type = "checkbox", label = "Use Hamstring (movement)", default = true, tooltip = "Hamstring to apply cripple while moving." },
        use_pummel = { type = "checkbox", label = "Use Pummel (interrupt)", default = true, tooltip = "Suggest Pummel for interrupts." },
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
    settingOrder = { "use_death_wish", "death_wish_classification", "use_recklessness", "recklessness_classification", "use_bloodrage", "use_berserker_rage", "use_cleave", "use_battle_shout", "use_hamstring", "use_pummel", "use_trinket_1", "trinket_1_classification", "use_trinket_2", "trinket_2_classification" },
    rotation = T.BuildFuryWarriorRotation and T.BuildFuryWarriorRotation(spec),
}

if A.SpecManager then A.SpecManager:RegisterSpec(spec) end
