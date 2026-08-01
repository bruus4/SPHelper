local A = SPHelper
local T = A.SpecTemplates

local spec = {
    _fromFile = true,
    meta = { id = "survival_hunter", class = "HUNTER", specName = "Survival", author = "SPHelper", version = 1 },
    loadConditions = { class = "HUNTER", talentTab = 3 },
    helpers = { "CastBar", "Rotation", "RotationEngine", "SpellData", "SpecUI", "Config" },
    constants = { SAFETY = 0.5, timing = { globalWaitThresholdMs = 200, defaultDelayToleranceMs = 400, dotSafeWindowSec = 1.0 } },
    trackedDebuffs = {
        { key = "serpent_sting", spellKey = "Serpent Sting", color = "SWP", isDot = true },
        { key = "hunters_mark", spellKey = "Hunter's Mark", color = "MB", isDot = false },
        { key = "explosive_shot", spellKey = "Explosive Shot", color = "RE", isDot = true },
    },
    trackedBuffs = {
        { key = "aspect_hawk", name = "Aspect of the Hawk", spellKey = "Aspect of the Hawk" },
        { key = "rapid_fire", name = "Rapid Fire", spellKey = "Rapid Fire" },
        { key = "misdirection", name = "Misdirection", spellKey = "Misdirection" },
    },
    settingDefs = {
        use_rapid_fire = { type = "checkbox", label = "Use Rapid Fire", default = true, tooltip = "Rapid Fire on cooldown." },
        rapid_fire_classification = { type = "dropdown", label = "Rapid Fire target type", default = "any",
                                      tooltip = "Restrict Rapid Fire to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
        use_explosive_shot = { type = "checkbox", label = "Use Explosive Shot", default = true, tooltip = "Explosive Shot on cooldown." },
        use_serpent_sting = { type = "checkbox", label = "Use Serpent Sting", default = true, tooltip = "Keep Serpent Sting up." },
        use_arcane_shot = { type = "checkbox", label = "Use Arcane Shot", default = true, tooltip = "Arcane Shot as mana permits." },
        use_multi_shot = { type = "checkbox", label = "Use Multi-Shot", default = true, tooltip = "Multi-Shot on cooldown." },
        use_aspect_hawk = { type = "checkbox", label = "Maintain Aspect of the Hawk", default = true, tooltip = "Keep Aspect of the Hawk active." },
        use_hunters_mark = { type = "checkbox", label = "Use Hunter's Mark", default = true, tooltip = "Mark target." },
        use_misdirection = { type = "checkbox", label = "Use Misdirection", default = true, tooltip = "Cast Misdirection on tank (focus target) before pull." },
        use_call_pet = { type = "checkbox", label = "Auto-call pet", default = true, tooltip = "Call pet and send to attack." },
        pet_attack = { type = "checkbox", label = "Send pet to attack", default = true, tooltip = "Command pet to attack the target." },
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
    settingOrder = { "use_rapid_fire", "rapid_fire_classification", "use_explosive_shot", "use_serpent_sting", "use_arcane_shot", "use_multi_shot", "use_aspect_hawk", "use_hunters_mark", "use_misdirection", "use_call_pet", "pet_attack", "use_trinket_1", "trinket_1_classification", "use_trinket_2", "trinket_2_classification" },
    rotation = T.BuildSurvivalHunterRotation and T.BuildSurvivalHunterRotation(spec),
}

if A.SpecManager then A.SpecManager:RegisterSpec(spec) end
