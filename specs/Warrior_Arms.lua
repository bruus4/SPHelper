local A = SPHelper
local T = A.SpecTemplates

local spec = {
    _fromFile = true,
    meta = { id = "arms_warrior", class = "WARRIOR", specName = "Arms", author = "SPHelper", version = 1 },
    loadConditions = { class = "WARRIOR", talentTab = 1 },
    helpers = { "CastBar", "Rotation", "RotationEngine", "SpellData", "SpecUI", "Config" },
    constants = { SAFETY = 0.5, timing = { globalWaitThresholdMs = 200, defaultDelayToleranceMs = 400, dotSafeWindowSec = 1.0 } },
    trackedDebuffs = {
        { key = "rend", spellKey = "Rend", color = "SWP", isDot = true },
        { key = "mortal_strike", spellKey = "Mortal Strike", duration = 10, color = "MB", isDot = false },
    },
    trackedBuffs = {
        { key = "battle_shout", name = "Battle Shout", spellKey = "Battle Shout" },
        { key = "sweeping_strikes", name = "Sweeping Strikes", spellKey = "Sweeping Strikes" },
    },
    settingDefs = {
        use_death_wish = { type = "checkbox", label = "Use Death Wish", default = true, tooltip = "Death Wish on cooldown." },
        death_wish_classification = { type = "dropdown", label = "Death Wish target type", default = "any",
                                      tooltip = "Restrict Death Wish to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
        use_sweeping_strikes = { type = "checkbox", label = "Use Sweeping Strikes", default = true, tooltip = "Sweeping Strikes on cooldown." },
        sweeping_strikes_classification = { type = "dropdown", label = "Sweeping Strikes target type", default = "any",
                                      tooltip = "Restrict Sweeping Strikes to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
        use_bloodrage = { type = "checkbox", label = "Use Bloodrage", default = true, tooltip = "Bloodrage on cooldown." },
        use_rend = { type = "checkbox", label = "Use Rend", default = true, tooltip = "Keep Rend up on target." },
        use_overpower = { type = "checkbox", label = "Use Overpower", default = true, tooltip = "Overpower when it procs." },
        use_slam = { type = "checkbox", label = "Use Slam", default = true, tooltip = "Slam as filler when talented." },
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
    settingOrder = { "use_death_wish", "death_wish_classification", "use_sweeping_strikes", "sweeping_strikes_classification", "use_bloodrage", "use_rend", "use_overpower", "use_slam", "use_battle_shout", "use_hamstring", "use_pummel", "use_trinket_1", "trinket_1_classification", "use_trinket_2", "trinket_2_classification" },
    rotation = T.BuildArmsWarriorRotation and T.BuildArmsWarriorRotation(spec),
}

if A.SpecManager then A.SpecManager:RegisterSpec(spec) end
