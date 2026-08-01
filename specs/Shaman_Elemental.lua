local A = SPHelper
local T = A.SpecTemplates

local spec = {
    _fromFile = true,
    meta = { id = "elemental_shaman", class = "SHAMAN", specName = "Elemental", author = "SPHelper", version = 1 },
    loadConditions = { class = "SHAMAN", talentTab = 1 },
    helpers = { "CastBar", "Rotation", "RotationEngine", "SpellData", "SpecUI", "Config" },
    constants = { SAFETY = 0.5, timing = { globalWaitThresholdMs = 200, defaultDelayToleranceMs = 400, dotSafeWindowSec = 1.0 } },
    trackedDebuffs = {
        { key = "flame_shock", spellKey = "Flame Shock", color = "SWP", isDot = true },
    },
    trackedBuffs = {
        { key = "elemental_mastery", name = "Elemental Mastery", spellKey = "Elemental Mastery" },
        { key = "clearcasting", name = "Clearcasting", spellKey = "Clearcasting" },
    },
    settingDefs = {
        use_elemental_mastery = { type = "checkbox", label = "Use Elemental Mastery", default = true, tooltip = "Elemental Mastery on cooldown." },
        elemental_mastery_classification = { type = "dropdown", label = "Elemental Mastery target type", default = "any",
                                      tooltip = "Restrict Elemental Mastery to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
        use_totem_wrath = { type = "checkbox", label = "Use Totem of Wrath", default = true, tooltip = "Maintain Totem of Wrath (Fire slot)." },
        use_flame_shock = { type = "checkbox", label = "Use Flame Shock", default = true, tooltip = "Keep Flame Shock up." },
        use_chain_lightning = { type = "checkbox", label = "Use Chain Lightning", default = true, tooltip = "Chain Lightning on cooldown." },
        use_earth_shock = { type = "checkbox", label = "Use Earth Shock (movement)", default = true, tooltip = "Earth Shock for instant filler while moving." },
        use_thunderstorm = { type = "checkbox", label = "Use Thunderstorm", default = true, tooltip = "Thunderstorm for mana return." },
        suggestPot        = { type = "checkbox", label = "Suggest mana potion",    default = true,
                              tooltip = "Show mana potion in rotation suggestions when low on mana." },
        potManaThreshold  = { type = "slider",   label = "Potion mana %",         default = 10, min = 5, max = 100, step = 5,
                              tooltip = "Suggest mana potion when mana drops below this percentage." },
        suggestRune       = { type = "checkbox", label = "Suggest dark rune",      default = true,
                              tooltip = "Show dark/demonic rune in rotation suggestions when low on mana." },
        runeManaThreshold = { type = "slider",   label = "Rune mana %",           default = 10, min = 5, max = 100, step = 5,
                              tooltip = "Suggest rune when mana drops below this percentage." },
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
    settingOrder = { "use_elemental_mastery", "elemental_mastery_classification", "use_totem_wrath", "use_flame_shock", "use_chain_lightning", "use_earth_shock", "use_thunderstorm", "suggestPot", "potManaThreshold", "suggestRune", "runeManaThreshold", "use_trinket_1", "trinket_1_classification", "use_trinket_2", "trinket_2_classification" },
    rotation = T.BuildElementalShamanRotation and T.BuildElementalShamanRotation(spec),
}

if A.SpecManager then A.SpecManager:RegisterSpec(spec) end
