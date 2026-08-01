local A = SPHelper
local T = A.SpecTemplates

local spec = {
    _fromFile = true,
    meta = { id = "enhancement_shaman", class = "SHAMAN", specName = "Enhancement", author = "SPHelper", version = 1 },
    loadConditions = { class = "SHAMAN", talentTab = 2 },
    helpers = { "CastBar", "Rotation", "RotationEngine", "SpellData", "SpecUI", "Config" },
    constants = { SAFETY = 0.5, timing = { globalWaitThresholdMs = 200, defaultDelayToleranceMs = 400, dotSafeWindowSec = 1.0 } },
    trackedDebuffs = {
        { key = "flame_shock", spellKey = "Flame Shock", color = "SWP", isDot = true },
    },
    trackedBuffs = {
        { key = "shamanistic_rage", name = "Shamanistic Rage", spellKey = "Shamanistic Rage" },
        { key = "windfury_weapon", name = "Windfury Weapon", spellKey = "Windfury Weapon", isWeaponEnchantment = true },
    },
    settingDefs = {
        use_shamanistic_rage = { type = "checkbox", label = "Use Shamanistic Rage", default = true, tooltip = "Shamanistic Rage for mana and damage." },
        shamanistic_rage_classification = { type = "dropdown", label = "Shamanistic Rage target type", default = "any",
                                      tooltip = "Restrict Shamanistic Rage to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
        use_stormstrike = { type = "checkbox", label = "Use Stormstrike", default = true, tooltip = "Stormstrike on cooldown." },
        use_earth_shock = { type = "checkbox", label = "Use Earth Shock", default = true, tooltip = "Earth Shock as filler." },
        use_flame_shock = { type = "checkbox", label = "Use Flame Shock", default = true, tooltip = "Keep Flame Shock up." },
        use_fire_nova = { type = "checkbox", label = "Use Fire Nova", default = true, tooltip = "Fire Nova on Flame Shock target." },
        use_magma_totem = { type = "checkbox", label = "Use Magma Totem", default = true, tooltip = "Maintain Magma Totem (Fire slot)." },
        use_windfury_totem = { type = "checkbox", label = "Use Windfury Totem", default = true, tooltip = "Maintain Windfury Totem (Air slot)." },
        use_strength_totem = { type = "checkbox", label = "Use Strength of Earth Totem", default = true, tooltip = "Maintain Strength of Earth Totem (Earth slot fallback)." },
        use_bloodlust = { type = "checkbox", label = "Use Bloodlust", default = true, tooltip = "Use Bloodlust / Heroism on cooldown." },
        bloodlust_classification = { type = "dropdown", label = "Bloodlust target type", default = "any",
                                      tooltip = "Restrict Bloodlust to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
        use_grace_air_totem = { type = "checkbox", label = "Use Grace of Air Totem", default = true, tooltip = "Use Grace of Air Totem for totem twisting with Windfury." },
        use_wind_shear = { type = "checkbox", label = "Use Wind Shear (interrupt)", default = true, tooltip = "Use Wind Shear to interrupt enemy casts." },
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
    settingOrder = { "use_shamanistic_rage", "shamanistic_rage_classification", "use_stormstrike", "use_earth_shock", "use_flame_shock", "use_fire_nova", "use_magma_totem", "use_windfury_totem", "use_strength_totem", "use_bloodlust", "bloodlust_classification", "use_grace_air_totem", "use_wind_shear", "use_trinket_1", "trinket_1_classification", "use_trinket_2", "trinket_2_classification" },
    rotation = T.BuildEnhancementShamanRotation and T.BuildEnhancementShamanRotation(spec),
}

if A.SpecManager then A.SpecManager:RegisterSpec(spec) end
