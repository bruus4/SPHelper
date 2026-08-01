local A = SPHelper
local T = A.SpecTemplates

local spec = {
    _fromFile = true,
    meta = { id = "destruction_warlock", class = "WARLOCK", specName = "Destruction", author = "SPHelper", version = 2 },
    loadConditions = { class = "WARLOCK", talentTab = 3 },
    helpers = { "CastBar", "DotTracker", "Rotation", "RotationEngine", "SpellData", "SpecUI", "Config" },
    constants = { SAFETY = 0.5, timing = { globalWaitThresholdMs = 400, defaultDelayToleranceMs = 600, dotSafeWindowSec = 1.5 } },
    trackedDebuffs = {
        { key = "immolate", spellKey = "Immolate", color = "VT", isDot = true },
        { key = "corruption", spellKey = "Corruption", color = "SWP", isDot = true },
        { key = "cod", spellKey = "Curse of Doom", color = "CoD", isDot = true, source = "any" },
    },
    settingDefs = {
        -- ── BURST ─────────────────────────────────────────────────
        use_conflagrate = { type = "checkbox", label = "Use Conflagrate", default = true, group = "Burst",
                            tooltip = "Conflagrate when Immolate is active (uses the Immolate charge)." },
        use_shadowburn  = { type = "checkbox", label = "Use Shadowburn", default = true, group = "Burst",
                            tooltip = "Shadowburn on cooldown (soul shard cost)." },
        use_soul_fire   = { type = "checkbox", label = "Use Soul Fire", default = true, group = "Burst",
                            tooltip = "Soul Fire on cooldown (soul shard cost)." },
        use_incinerate  = { type = "checkbox", label = "Use Incinerate", default = true, group = "Burst",
                            tooltip = "Incinerate as filler when talented." },
        incinerateMinTTD = { type = "slider", label = "Incinerate min TTD", default = 6, min = 0, max = 15, step = 1, group = "Burst",
                            tooltip = "Min target TTD for Incinerate." },

        -- ── DoTs / CURSES ────────────────────────────────────────
        use_curse_of_doom = { type = "checkbox", label = "Use Curse of Doom", default = true, group = "DoTs & Curses",
                            tooltip = "Use Curse of Doom on long-lived targets (1min+ TTD)." },
        codRefreshSeconds = { type = "slider", label = "Curse of Doom refresh window", default = 2, min = 1, max = 6, step = 1, group = "DoTs & Curses",
                            tooltip = "Refresh CoD when any copy has this many seconds or less remaining." },
        multidotMaxCorruption = { type = "slider", label = "Corruption max targets", default = 3, min = 1, max = 8, step = 1, group = "DoTs & Curses",
                            tooltip = "Max targets to keep Corruption on. 1 = single-target only." },

        -- ── MANA ─────────────────────────────────────────────────
        use_life_tap     = { type = "checkbox", label = "Use Life Tap", default = true, group = "Mana",
                              tooltip = "Life Tap when low on mana." },
        lifeTapManaPct   = { type = "slider", label = "Life Tap mana %", default = 40, min = 10, max = 90, step = 5, group = "Mana",
                              tooltip = "Life Tap when mana below this %." },
        suggestPot       = { type = "checkbox", label = "Suggest mana potion", default = true, group = "Mana",
                              tooltip = "Show mana potion suggestion." },
        potManaThreshold = { type = "slider", label = "Potion mana %", default = 10, min = 5, max = 100, step = 5, group = "Mana",
                              tooltip = "Potion when mana below this %." },
        suggestRune      = { type = "checkbox", label = "Suggest dark rune", default = true, group = "Mana",
                              tooltip = "Show rune suggestion." },
        runeManaThreshold = { type = "slider", label = "Rune mana %", default = 10, min = 5, max = 100, step = 5, group = "Mana",
                              tooltip = "Rune when mana below this %." },

        -- ── TRINKETS ─────────────────────────────────────────────
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
    settingOrder = { "use_conflagrate", "use_shadowburn", "use_soul_fire", "use_incinerate", "incinerateMinTTD", "use_curse_of_doom", "codRefreshSeconds", "multidotMaxCorruption", "use_life_tap", "lifeTapManaPct", "suggestPot", "potManaThreshold", "suggestRune", "runeManaThreshold", "use_trinket_1", "trinket_1_classification", "use_trinket_2", "trinket_2_classification" },
    rotation = T.BuildDestructionWarlockRotation and T.BuildDestructionWarlockRotation(spec),

    -- SP-style context extension: DoT remaining aliases.
    buildContext = function(ctx, spec)
        local hasteMul = ctx.hasteMul or 1
        local castRem  = ctx.castRemaining or 0
        for _, td in ipairs({ "Immolate", "Corruption", "Curse of Doom" }) do
            local st = ctx.trackedDebuffsBySpellKey and ctx.trackedDebuffsBySpellKey[td]
            local alias = td:gsub(" ", ""):lower()
            ctx[alias .. "Rem"]   = (st and st.remaining) or 0
            ctx[alias .. "After"] = math.max((st and st.remaining or 0) - castRem, 0)
        end
        local sbDef = A.GetSpellDefinition and A.GetSpellDefinition("Shadow Bolt")
        ctx.sbCastEff = ((sbDef and sbDef.castTime) or 3.0) / hasteMul
    end,
}

if A.SpecManager then A.SpecManager:RegisterSpec(spec) end
