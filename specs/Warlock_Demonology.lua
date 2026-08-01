local A = SPHelper
local T = A.SpecTemplates

local spec = {
    _fromFile = true,
    meta = { id = "demonology_warlock", class = "WARLOCK", specName = "Demonology", author = "SPHelper", version = 2 },
    loadConditions = { class = "WARLOCK", talentTab = 2 },
    helpers = { "CastBar", "DotTracker", "Rotation", "RotationEngine", "SpellData", "SpecUI", "Config" },
    constants = { SAFETY = 0.5, timing = { globalWaitThresholdMs = 400, defaultDelayToleranceMs = 600, dotSafeWindowSec = 1.5 } },
    trackedDebuffs = {
        { key = "corruption", spellKey = "Corruption", color = "SWP", isDot = true },
        { key = "curse_of_agony", spellKey = "Curse of Agony", color = "VT", isDot = true },
        { key = "coe", spellKey = "Curse of Elements", color = "CoE", isDot = false, duration = 300, source = "any" },
        { key = "cod", spellKey = "Curse of Doom", color = "CoD", isDot = true, source = "any" },
        { key = "immolate", spellKey = "Immolate", color = "IMM", isDot = true },
    },
    settingDefs = {
        use_demonic_sacrifice = { type = "checkbox", label = "Demonic Sacrifice (pre-combat)", default = true, tooltip = "Sacrifice pet for shadow damage buff." },
        use_metamorphosis = { type = "checkbox", label = "Use Metamorphosis", default = true, tooltip = "Metamorphosis on cooldown." },
        metamorphosis_classification = { type = "dropdown", label = "Metamorphosis target type", default = "any",
                                      tooltip = "Restrict Metamorphosis to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
        use_curse_of_agony    = { type = "checkbox", label = "Use Curse of Agony", default = true, group = "Curses",
                                  tooltip = "Maintain Curse of Agony — the Demonology damage curse (one curse per target)." },
        coaRefreshSeconds     = { type = "slider", label = "Curse of Agony refresh window", default = 2, min = 1, max = 6, step = 1, group = "Curses",
                                  tooltip = "Refresh CoA when any copy has this many seconds or less remaining." },
        use_curse_of_elements = { type = "checkbox", label = "Use Curse of the Elements (raid utility)", default = false, group = "Curses",
                                  tooltip = "Apply Curse of the Elements to increase arcane/fire/frost/shadow/nature damage. Raid utility — leave off for solo/dungeon DPS." },
        coeRefreshSeconds = { type = "slider", label = "Curse of Elements refresh window", default = 2, min = 1, max = 6, step = 1, group = "Curses", tooltip = "Refresh CoE when any copy has this many seconds or less remaining." },
        use_curse_of_doom = { type = "checkbox", label = "Use Curse of Doom (long fights)", default = false, group = "Curses", tooltip = "Use Curse of Doom on long-lived targets (1min+ TTD) when no other curse is assigned." },
        codRefreshSeconds = { type = "slider", label = "Curse of Doom refresh window", default = 2, min = 1, max = 6, step = 1, group = "Curses", tooltip = "Refresh CoD when any copy has this many seconds or less remaining." },

        -- ── UTILITY / MANA ────────────────────────────────────────
        use_life_tap     = { type = "checkbox", label = "Use Life Tap", default = true, group = "Utility",
                              tooltip = "Life Tap when low on mana." },
        lifeTapManaPct   = { type = "slider", label = "Life Tap mana %", default = 40, min = 10, max = 90, step = 5, group = "Utility",
                              tooltip = "Life Tap when mana below this %." },
        multidotMaxCorruption = { type = "slider", label = "Corruption max targets", default = 4, min = 1, max = 8, step = 1, group = "DoTs",
                              tooltip = "Max targets to keep Corruption on. 1 = single-target only." },
        suggestPot       = { type = "checkbox", label = "Suggest mana potion", default = true, group = "Utility",
                              tooltip = "Show mana potion suggestion." },
        potManaThreshold = { type = "slider", label = "Potion mana %", default = 10, min = 5, max = 100, step = 5, group = "Utility",
                              tooltip = "Potion when mana below this %." },
        suggestRune      = { type = "checkbox", label = "Suggest dark rune", default = true, group = "Utility",
                              tooltip = "Show rune suggestion." },
        runeManaThreshold = { type = "slider", label = "Rune mana %", default = 10, min = 5, max = 100, step = 5, group = "Utility",
                              tooltip = "Rune when mana below this %." },

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
        use_immolate             = { type = "checkbox", label = "Use Immolate",          default = true,
                                       tooltip = "Maintain Immolate DoT on target." },
        use_drain_life           = { type = "checkbox", label = "Use Drain Life (self-heal)", default = true,
                                        tooltip = "Channel Drain Life to heal yourself when low on health. Heals for 15% of damage dealt." },
        drainLifeHpPct           = { type = "slider",   label = "Drain Life HP %",       default = 30, min = 10, max = 60, step = 5,
                                        tooltip = "Cast Drain Life when your HP drops below this %." },
        use_death_coil           = { type = "checkbox", label = "Use Death Coil",        default = true,
                                       tooltip = "Use Death Coil while moving and for mana recovery." },
        deathCoilManaPct         = { type = "slider",   label = "Death Coil mana %",     default = 30, min = 10, max = 60, step = 5,
                                       tooltip = "Use Death Coil for mana when below this %." },
        use_shadowburn           = { type = "checkbox", label = "Use Shadowburn",        default = true,
                                       tooltip = "Use Shadowburn on targets below 20% HP (execute phase)." },
        use_seed_of_corruption   = { type = "checkbox", label = "Use Seed of Corruption",default = true,
                                       tooltip = "Cast Seed of Corruption for AoE damage." },
        use_hellfire             = { type = "checkbox", label = "Use Hellfire",          default = true,
                                       tooltip = "Cast Hellfire after seeding targets in AoE situations." },
    },
    settingOrder = { "use_demonic_sacrifice", "use_metamorphosis", "metamorphosis_classification", "use_curse_of_agony", "coaRefreshSeconds", "use_curse_of_elements", "coeRefreshSeconds", "use_curse_of_doom", "codRefreshSeconds", "use_immolate", "use_life_tap", "lifeTapManaPct", "multidotMaxCorruption", "suggestPot", "potManaThreshold", "suggestRune", "runeManaThreshold", "use_drain_life", "drainLifeHpPct", "use_death_coil", "deathCoilManaPct", "use_shadowburn", "use_seed_of_corruption", "use_hellfire", "use_trinket_1", "trinket_1_classification", "use_trinket_2", "trinket_2_classification" },
    rotation = T.BuildDemonologyWarlockRotation and T.BuildDemonologyWarlockRotation(spec),

    -- SP-style context extension: per-spell remaining/cooldown aliases.
    buildContext = function(ctx, spec)
        local hasteMul = ctx.hasteMul or 1
        local castRem  = ctx.castRemaining or 0

        for _, td in ipairs({ "Curse of Agony", "Curse of Elements", "Curse of Doom", "Corruption", "Immolate" }) do
            local st = ctx.trackedDebuffsBySpellKey and ctx.trackedDebuffsBySpellKey[td]
            local alias = td:gsub(" ", ""):lower()
            ctx[alias .. "Rem"]   = (st and st.remaining) or 0
            ctx[alias .. "After"] = math.max((st and st.remaining or 0) - castRem, 0)
        end

        -- Haste-adjusted cast time for Shadow Bolt (filler timing)
        local sbDef = A.GetSpellDefinition and A.GetSpellDefinition("Shadow Bolt")
        ctx.sbCastEff = ((sbDef and sbDef.castTime) or 3.0) / hasteMul
    end,
}

if A.SpecManager then A.SpecManager:RegisterSpec(spec) end
