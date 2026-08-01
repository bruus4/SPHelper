local A = SPHelper
local T = A.SpecTemplates

local spec = {
    _fromFile = true,
    meta = { id = "beast_mastery_hunter", class = "HUNTER", specName = "Beast Mastery", author = "SPHelper", version = 1 },
    loadConditions = { class = "HUNTER", talentTab = 1 },
    helpers = { "CastBar", "Rotation", "RotationEngine", "SpellData", "SpecUI", "Config" },
    constants = { SAFETY = 0.5, timing = { globalWaitThresholdMs = 200, defaultDelayToleranceMs = 400, dotSafeWindowSec = 1.0 } },
    trackedDebuffs = {
        { key = "serpent_sting", spellKey = "Serpent Sting", color = "SWP", isDot = true },
        { key = "hunters_mark", spellKey = "Hunter's Mark", color = "MB", isDot = false },
    },
    trackedBuffs = {
        { key = "aspect_hawk", name = "Aspect of the Hawk", spellKey = "Aspect of the Hawk" },
        { key = "rapid_fire", name = "Rapid Fire", spellKey = "Rapid Fire" },
        { key = "bestial_wrath", name = "Bestial Wrath", spellKey = "Bestial Wrath" },
        { key = "misdirection", name = "Misdirection", spellKey = "Misdirection" },
    },
    settingDefs = {
        use_bestial_wrath = { type = "checkbox", label = "Use Bestial Wrath", default = true, tooltip = "Bestial Wrath on cooldown." },
        bestial_wrath_classification = { type = "dropdown", label = "Bestial Wrath target type", default = "any",
                                      tooltip = "Restrict Bestial Wrath to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
        use_rapid_fire = { type = "checkbox", label = "Use Rapid Fire", default = true, tooltip = "Rapid Fire on cooldown." },
        rapid_fire_classification = { type = "dropdown", label = "Rapid Fire target type", default = "any",
                                      tooltip = "Restrict Rapid Fire to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
        use_kill_command = { type = "checkbox", label = "Use Kill Command", default = true, tooltip = "Kill Command on cooldown." },
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
    settingOrder = { "use_bestial_wrath", "bestial_wrath_classification", "use_rapid_fire", "rapid_fire_classification", "use_kill_command", "use_serpent_sting", "use_arcane_shot", "use_multi_shot", "use_aspect_hawk", "use_hunters_mark", "use_misdirection", "use_call_pet", "pet_attack", "use_trinket_1", "trinket_1_classification", "use_trinket_2", "trinket_2_classification" },
    rotation = T.BuildBeastMasteryHunterRotation and T.BuildBeastMasteryHunterRotation(spec),
}

if A.SpecManager then A.SpecManager:RegisterSpec(spec) end
