local A = SPHelper
local T = A.SpecTemplates

local spec = {
    _fromFile = true,
    meta = { id = "affliction_warlock", class = "WARLOCK", specName = "Affliction", author = "SPHelper", version = 2 },
    loadConditions = { class = "WARLOCK", talentTab = 1 },
    helpers = { "CastBar", "DotTracker", "Rotation", "RotationEngine", "SpellData", "SpecUI", "Config" },
    constants = { SAFETY = 0.5, timing = { globalWaitThresholdMs = 400, defaultDelayToleranceMs = 600, dotSafeWindowSec = 1.5 } },
    trackedDebuffs = {
        { key = "corruption", spellKey = "Corruption", color = "SWP", isDot = true },
        { key = "curse_of_agony", spellKey = "Curse of Agony", color = "VT", isDot = true },
        { key = "siphon_life", spellKey = "Siphon Life", color = "DP", isDot = true },
        { key = "unstable_affliction", spellKey = "Unstable Affliction", color = "MB", isDot = true },
        { key = "immolate", spellKey = "Immolate", color = "MF", isDot = true },
        { key = "coe", spellKey = "Curse of Elements", color = "CoE", isDot = false, duration = 300, source = "any" },
        { key = "cod", spellKey = "Curse of Doom", color = "CoD", isDot = true, source = "any" },
    },
    settingDefs = {
        -- ── CURSES ─────────────────────────────────────────────────
        use_curse_of_agony    = { type = "checkbox", label = "Use Curse of Agony", default = true, group = "Curses",
                                   tooltip = "Maintain Curse of Agony — the Affliction damage curse (one curse per target)." },
        coaRefreshSeconds     = { type = "slider", label = "Curse of Agony refresh window", default = 2, min = 1, max = 6, step = 1, group = "Curses",
                                   tooltip = "Refresh CoA when any copy has this many seconds or less remaining." },
        use_curse_of_elements = { type = "checkbox", label = "Use Curse of the Elements (raid utility)", default = false, group = "Curses",
                                   tooltip = "Apply Curse of the Elements to increase arcane/fire/frost/shadow/nature damage. Raid utility — leave off for solo/dungeon DPS." },
        coeRefreshSeconds     = { type = "slider", label = "Curse of Elements refresh window", default = 2, min = 1, max = 6, step = 1, group = "Curses",
                                   tooltip = "Refresh CoE when any copy has this many seconds or less remaining." },
        use_curse_of_doom     = { type = "checkbox", label = "Use Curse of Doom (long fights)", default = false, group = "Curses",
                                   tooltip = "Use Curse of Doom on long-lived targets (1min+ TTD) when no other curse is assigned." },
        codRefreshSeconds     = { type = "slider", label = "Curse of Doom refresh window", default = 2, min = 1, max = 6, step = 1, group = "Curses",
                                   tooltip = "Refresh CoD when any copy has this many seconds or less remaining." },

        -- ── DoTs ──────────────────────────────────────────────────
        use_unstable_affliction = { type = "checkbox", label = "Use Unstable Affliction", default = true, group = "DoTs",
                                   tooltip = "Maintain Unstable Affliction DoT (dispelling it punishes the dispeller)." },
        use_siphon_life         = { type = "checkbox", label = "Use Siphon Life", default = true, group = "DoTs",
                                   tooltip = "Maintain Siphon Life DoT (also heals you)." },
        multidotMaxCorruption   = { type = "slider", label = "Corruption max targets", default = 4, min = 1, max = 8, step = 1, group = "DoTs",
                                   tooltip = "Max targets to keep Corruption on. 1 = single-target only." },

        -- ── UTILITY / MANA ────────────────────────────────────────
        use_death_coil   = { type = "checkbox", label = "Use Death Coil", default = true, group = "Utility",
                              tooltip = "Death Coil while moving (instant damage, heals pet, restores mana)." },
        use_life_tap     = { type = "checkbox", label = "Use Life Tap", default = true, group = "Utility",
                              tooltip = "Life Tap when low on mana." },
        lifeTapManaPct   = { type = "slider", label = "Life Tap mana %", default = 40, min = 10, max = 90, step = 5, group = "Utility",
                              tooltip = "Life Tap when mana below this %." },
        suggestPot       = { type = "checkbox", label = "Suggest mana potion", default = true, group = "Utility",
                              tooltip = "Show mana potion suggestion." },
        potManaThreshold = { type = "slider", label = "Potion mana %", default = 10, min = 5, max = 100, step = 5, group = "Utility",
                              tooltip = "Potion when mana below this %." },
        suggestRune      = { type = "checkbox", label = "Suggest dark rune", default = true, group = "Utility",
                              tooltip = "Show rune suggestion." },
        runeManaThreshold = { type = "slider", label = "Rune mana %", default = 10, min = 5, max = 100, step = 5, group = "Utility",
                              tooltip = "Rune when mana below this %." },

        -- ── TRINKETS ──────────────────────────────────────────────
        use_trinket_1            = { type = "checkbox", label = "Use trinket 1 (on-use)",  default = true, group = "Trinkets",
                                      tooltip = "Activate trinket 1 on cooldown automatically." },
        use_trinket_2            = { type = "checkbox", label = "Use trinket 2 (on-use)",  default = true, group = "Trinkets",
                                      tooltip = "Activate trinket 2 on cooldown automatically." },
        trinket_1_classification = { type = "dropdown", label = "Trinket 1 target type",   default = "any", group = "Trinkets",
                                      tooltip = "Restrict trinket 1 to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
        trinket_2_classification = { type = "dropdown", label = "Trinket 2 target type",   default = "any", group = "Trinkets",
                                      tooltip = "Restrict trinket 2 to: any, normal, elite, or boss.",
                                      values = { "any", "normal", "elite", "boss" } },
    },
    settingOrder = { "use_curse_of_agony", "coaRefreshSeconds", "use_curse_of_elements", "coeRefreshSeconds", "use_curse_of_doom", "codRefreshSeconds", "use_unstable_affliction", "use_siphon_life", "multidotMaxCorruption", "use_death_coil", "use_life_tap", "lifeTapManaPct", "suggestPot", "potManaThreshold", "suggestRune", "runeManaThreshold", "use_trinket_1", "trinket_1_classification", "use_trinket_2", "trinket_2_classification" },
    rotation = T.BuildAfflictionWarlockRotation and T.BuildAfflictionWarlockRotation(spec),

    -- SP-style context extension: per-spell remaining/cooldown aliases for the
    -- condition evaluators and the SpecUI debug panel.
    buildContext = function(ctx, spec)
        local constants = (spec and spec.constants) or {}
        local hasteMul  = ctx.hasteMul or 1
        local castRem   = ctx.castRemaining or 0

        -- DoT remaining-time aliases (projected past the current cast)
        for _, td in ipairs({ "Curse of Agony", "Curse of Elements", "Curse of Doom", "Corruption", "Unstable Affliction", "Siphon Life" }) do
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
