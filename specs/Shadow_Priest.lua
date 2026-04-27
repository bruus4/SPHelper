------------------------------------------------------------------------
-- SPHelper  –  specs/Shadow_Priest.lua
-- Shadow Priest spec definition.
-- Registers with SpecManager and declares helpers, constants,
-- UI options, and rotation priorities.
------------------------------------------------------------------------
local A = SPHelper

local spec = {
    _fromFile = true,  -- allows function-valued conditions in file specs

    meta = {
        id       = "shadow_priest",
        class    = "PRIEST",
        specName = "Shadow",
        author   = "SPHelper",
        version  = 1,
    },

    loadConditions = {
        class          = "PRIEST",
        talentTab      = 3,          -- Shadow talent tree
    },

    helpers = {
        "CastBar",
        "DotTracker",
        "Rotation",
        "RotationEngine",
        "ChannelHelper",
        "SpellData",
        "SpecUI",
        "Config",
    },

    constants = {
        MIN_MF_DURATION  = 1.0,
        SAFETY           = 0.5,
        timing = {
            globalWaitThresholdMs   = 400,
            defaultDelayToleranceMs = 600,
            dotSafeWindowSec        = 1.5,
          fakeQueueMaxMs          = 150,
            clipMarginMs            = 50,
            fqFireOffsetMs          = 30,  -- safety buffer on top of baked-in lat compensation
        },
    },

    -- Debuffs tracked by the DotTracker module
    trackedDebuffs = {
      { key = "shadow_word_pain", spellKey = "Shadow Word: Pain", color = "SWP", isDot = true },
      { key = "vampiric_touch",    spellKey = "Vampiric Touch", color = "VT",  isDot = true },
      { key = "mind_soothe",       spellKey = "Mind Soothe", duration = 15, color = "MS", isDot = false },  -- no DB duration (Mind Soothe is not a standard aura)
      { key = "shackle_undead",    spellKey = "Shackle Undead", color = "SU",  isDot = false },
    },

    trackedBuffs = {
      { key = "clearcasting", name = "Clearcasting", spellKey = "Clearcasting" },
    },

    -------------------------------------------------------------------
    -- Settings definitions (keyed dictionary).
    -- Each key is a setting identifier used in conditions via optionKey
    -- references, setting_compare, or string-valued numeric fields.
    -- The General tab is auto-generated from these definitions in the
    -- order they are first referenced in the rotation, followed by any
    -- remaining settings in settingOrder.
    -------------------------------------------------------------------
    settingDefs = {
        use_SWD           = { type = "checkbox", label = "Use Shadow Word: Death", default = true,
                              tooltip = "Include Shadow Word: Death in the rotation (see per-content SW:D settings below)." },
        use_DP            = { type = "checkbox", label = "Use Devouring Plague",   default = true,
                              tooltip = "Include Devouring Plague in the rotation." },
        use_SF            = { type = "checkbox", label = "Use Shadowfiend",        default = true,
                              tooltip = "Include Shadowfiend in the rotation." },
        sfManaThreshold   = { type = "slider",   label = "Shadowfiend mana %",    default = 35, min = 5, max = 100, step = 5,
                              tooltip = "Suggest Shadowfiend when mana drops below this percentage." },
        suggestPot        = { type = "checkbox", label = "Suggest mana potion",    default = true,
                              tooltip = "Show mana potion in rotation suggestions when low on mana." },
        potManaThreshold  = { type = "slider",   label = "Potion mana %",         default = 70, min = 5, max = 100, step = 5,
                              tooltip = "Suggest mana potion when mana drops below this percentage." },
        suggestRune       = { type = "checkbox", label = "Suggest dark rune",      default = true,
                              tooltip = "Show dark/demonic rune in rotation suggestions when low on mana." },
        runeManaThreshold = { type = "slider",   label = "Rune mana %",           default = 40, min = 5, max = 100, step = 5,
                              tooltip = "Suggest rune when mana drops below this percentage." },
        vtMinTTD          = { type = "slider",   label = "Vampiric Touch min target TTD",  default = 12, min = 0, max = 30, step = 1,
                              tooltip = "Only suggest Vampiric Touch when the target will live at least this many seconds. 0 = disabled." },
        swpMinTTD         = { type = "slider",   label = "Shadow Word: Pain min target TTD", default = 8, min = 0, max = 30, step = 1,
                              tooltip = "Only suggest Shadow Word: Pain when the target will live at least this many seconds. 0 = disabled." },
        multidotMaxVTTargets  = { type = "slider", label = "Vampiric Touch max targets",     default = 3, min = 1, max = 8, step = 1,
                              tooltip = "Maximum targets to keep Vampiric Touch on. 1 = single-target only." },
        multidotMaxSWPTargets = { type = "slider", label = "Shadow Word: Pain max targets",   default = 4, min = 1, max = 8, step = 1,
                              tooltip = "Maximum targets to keep Shadow Word: Pain on. 1 = single-target only." },
        swdWorld          = { type = "dropdown", label = "Shadow Word: Death (world)",   default = "always",  values = {"always","execute","never"},
                              tooltip = "When to suggest SW:D in open world. 'execute' = below kill threshold only." },
        swdDungeon        = { type = "dropdown", label = "Shadow Word: Death (dungeon)", default = "always",  values = {"always","execute","never"},
                              tooltip = "When to suggest SW:D in dungeons." },
        swdRaid           = { type = "dropdown", label = "Shadow Word: Death (raid)",    default = "execute", values = {"always","execute","never"},
                              tooltip = "When to suggest SW:D in raids. 'execute' recommended to avoid self-damage." },
        swdSafetyPct      = { type = "slider",   label = "SW:D safety margin %",        default = 10, min = 0, max = 50, step = 1,
                              tooltip = "Extra HP margin for SW:D kill prediction. Higher = more conservative." },
        ["ifInsert.enabled"]     = { type = "checkbox", label = "Suggest Inner Focus",    default = true,
                              tooltip = "Insert Inner Focus before a spell for free crit + mana save." },
        ["ifInsert.onlyForBoss"] = { type = "checkbox", label = "Inner Focus bosses only", default = true,
                              tooltip = "Only suggest Inner Focus on boss encounters." },
        ["ifInsert.before"]      = { type = "dropdown", label = "Inner Focus before",      default = "Mind Blast",
                              values = {"Mind Blast","Shadow Word: Pain","Devouring Plague"},
                              tooltip = "Which spell to cast Inner Focus before." },
    },

    -- Preferred rendering order for settings that aren't rotation-referenced.
    settingOrder = {
        "use_SWD", "use_DP", "use_SF",
        "sfManaThreshold",
        "suggestPot", "potManaThreshold",
        "suggestRune", "runeManaThreshold",
        "vtMinTTD", "swpMinTTD",
        "multidotMaxVTTargets", "multidotMaxSWPTargets",
        "swdWorld", "swdDungeon", "swdRaid", "swdSafetyPct",
        "ifInsert.enabled", "ifInsert.onlyForBoss", "ifInsert.before",
    },

    -------------------------------------------------------------------
    -- Channel Spells — data-driven list of channeled spells with
    -- per-spell FQ / clip / tick settings. Replaces the hardcoded
    -- KNOWN_CHANNELS table in ChannelHelper.
    -------------------------------------------------------------------
    channelSpells = {
        {
        spellKey    = "Mind Flay",
            spellName   = "Mind Flay",
            -- ticks read from SpellDatabase (Mind Flay.ticks = 3)
            fakeQueue   = true,   -- enable FQ for this spell
            clipOverlay = true,   -- show green clip zone
        minDuration = 1.0,    -- minimum channel duration required before clipping
        clipReasons = { "Mind Blast", "Vampiric Touch", "Shadow Word: Pain" },
            tickSound   = true,   -- tick sound feedback
            tickFlash   = true,   -- tick flash feedback
            tickMarkers = true,   -- show tick markers on bar
            tickMarkerMode = "all",  -- "all", "remaining", "none", "specific"
            tickMarkerTicks = {},    -- for "specific": which ticks to show, e.g. {2}
        },
    },

    -------------------------------------------------------------------
    -- CastBar & FQ global options — rendered in the CastBar tab.
    -- These are the defaults; user overrides stored in DB via SpecVal.
    -------------------------------------------------------------------
    castBarOptions = {
        { key = "channelFakeQueue",     type = "checkbox", label = "Enable Fake Queue (clip assist)", default = true,
          tooltip = "Hold spell input until the last channeled tick completes. Requires FQ macros." },
        { key = "fakeQueueMaxMs",       type = "slider",   label = "FQ max hold (ms)",     default = 150, min = 50, max = 150, step = 1,
          tooltip = "Maximum milliseconds FQ will busy-wait inside a macro. SPHelper caps this at 150ms because longer /run holds can hit the Anniversary client script limit and break action buttons until /reload." },
        { key = "fqFireOffsetMs",       type = "slider",   label = "FQ safety buffer (ms)", default = 30, min = -150, max = 150, step = 5,
          tooltip = "Extra milliseconds added after latency compensation before releasing the cast.\nNegative values pre-compensate latency (release earlier); this is risky and may cause clipping.\n0 = release exactly when cast would arrive at server tick (boundary, may clip on jitter).\n30 = release 30ms later than necessary, cast arrives 30ms after tick (recommended).\nAuto-tune will adjust this automatically when enabled." },
        { key = "fqAllowNegative",       type = "checkbox", label = "Allow negative FQ offset", default = false,
          tooltip = "Enable negative values for the FQ safety buffer. Negative offsets release earlier (pre-compensate latency) but increase the risk of clipping; use with caution." },
        { key = "fqDiag",               type = "checkbox", label = "FQ timing diagnostics", default = true,
          tooltip = "Print per-tick timing diagnostics after each FQ activation. Shows delta from FQ exit to tick CLEU, running average, and ideal target for tuning fqFireOffsetMs." },
        { key = "fqAutoAdjust",          type = "checkbox", label = "[EXPERIMENTAL] FQ auto-adjust offset", default = false,
          tooltip = "Automatically nudge fqFireOffsetMs toward a latency-compensated target using conservative tuning (warmup 8 samples, gain ≈15%, deadband 5ms, max step 10ms). Requires FQ timing diagnostics (fqDiag) to see adjustments. Value is saved after each adjustment. Enable 'Allow negative FQ offset' to permit negative values (use with caution)." },
        { key = "channelClipCues",      type = "checkbox", label = "Show clip zone on cast bar", default = true,
          tooltip = "Draw a green overlay on the cast bar indicating when it is safe to clip the channel." },
        { key = "tickSound",            type = "dropdown", label = "Tick sound",           default = "click",
          values = {"none","click","tap","pop","snap","blip","coin","beep","ping","chime","ding","bell","alert"},
          tooltip = "Sound played on each channel tick. Helps confirm ticks registered." },
        { key = "tickFlash",            type = "dropdown", label = "Tick flash effect",    default = "green",
          values = {"none","green","purple","shadow","white","red","green_top","purple_top","shadow_top","white_top","red_top","green_sides","purple_sides","shadow_sides","white_sides","red_sides"},
          tooltip = "Screen flash effect on channel ticks. Helps visually confirm ticks." },
        { key = "tickFeedbackOffsetMs", type = "slider",   label = "Tick feedback offset (ms)", default = 0, min = 0, max = 300, step = 10,
          tooltip = "Fire tick sound/flash this many ms BEFORE the predicted tick. 0 = on actual tick. Higher values give earlier audio/visual cue." },
    },

    -------------------------------------------------------------------
    -- Rotation — core spells (Vampiric Touch, Shadow Word: Pain, Mind Blast, Mind Flay) are always on.
    -- Optional/situational spells (Devouring Plague, Shadow Word: Death, Shadowfiend) have enable toggles.
    -------------------------------------------------------------------
    rotation = {
        _fromFile = true,
        { key = "SWD_EXEC", conditions = {{ type = "spell_can_kill_target", spellKey = "Shadow Word: Death", safetyKey = "swdSafetyPct" }, { type = "cooldown_ready", spellKey = "Shadow Word: Death" }, { type = "spec_option_enabled", optionKey = "use_SWD" }} },
        { key = "Inner Focus",       conditions = {{ type = "spec_option_enabled", optionKey = "ifInsert.enabled" }, { type = "option_gated_classification", optionKey = "ifInsert.onlyForBoss", classification = "boss" }, { type = "cooldown_ready", spellKey = "Inner Focus" }, { type = "buff_property_compare", buff = "Inner Focus", property = "stacks", op = "==", value = 0 }}, insertBeforeKey = "ifInsert.before" },
        { key = "Vampiric Touch",       conditions = {
          { type = "projected_dot_time_left_lt", spellKey = "Vampiric Touch" },
          { type = "state_compare",              subject = "target_ttd", op = ">=", value = "vtMinTTD" },
          { type = "other_targets_with_debuff_lt", spellKey = "Vampiric Touch", count = "multidotMaxVTTargets", seconds = 2, minTTD = "vtMinTTD" },
        } },
        { key = "Shadow Word: Pain",      conditions = {
          { type = "projected_dot_time_left_lt", spellKey = "Shadow Word: Pain" },
          { type = "state_compare",              subject = "target_ttd", op = ">=", value = "swpMinTTD" },
          { type = "other_targets_with_debuff_lt", spellKey = "Shadow Word: Pain", count = "multidotMaxSWPTargets", seconds = 2, minTTD = "swpMinTTD" },
        } },
        { key = "Mind Blast",       conditions = {{ type = "cooldown_ready", spellKey = "Mind Blast" }} },
        { key = "Shadowfiend",       conditions = {{ type = "spec_option_enabled", optionKey = "use_SF" }, { type = "in_combat" }, { type = "target_valid" }, { type = "state_compare", subject = "player_mana_pct", op = "<", value = "sfManaThreshold" }, { type = "cooldown_ready", spellKey = "Shadowfiend" }} },
        { key = "Shadow Word: Death",      conditions = {
          { type = "spec_option_enabled", optionKey = "use_SWD" },
          { type = "cooldown_ready", spellKey = "Shadow Word: Death" },
          { type = "any_of", conditions = {
            -- World: check swdWorld setting
            { type = "all_of", conditions = {
              { type = "content_type", contentType = "world" },
              { type = "any_of", conditions = {
                { type = "setting_compare", optionKey = "swdWorld", op = "==", value = "always" },
                { type = "all_of", conditions = {
                  { type = "setting_compare", optionKey = "swdWorld", op = "==", value = "execute" },
                  { type = "spell_can_kill_target", spellKey = "Shadow Word: Death", safetyKey = "swdSafetyPct" },
                }},
              }},
            }},
            -- Dungeon: check swdDungeon setting
            { type = "all_of", conditions = {
              { type = "content_type", contentType = "dungeon" },
              { type = "any_of", conditions = {
                { type = "setting_compare", optionKey = "swdDungeon", op = "==", value = "always" },
                { type = "all_of", conditions = {
                  { type = "setting_compare", optionKey = "swdDungeon", op = "==", value = "execute" },
                  { type = "spell_can_kill_target", spellKey = "Shadow Word: Death", safetyKey = "swdSafetyPct" },
                }},
              }},
            }},
            -- Raid: check swdRaid setting
            { type = "all_of", conditions = {
              { type = "content_type", contentType = "raid" },
              { type = "any_of", conditions = {
                { type = "setting_compare", optionKey = "swdRaid", op = "==", value = "always" },
                { type = "all_of", conditions = {
                  { type = "setting_compare", optionKey = "swdRaid", op = "==", value = "execute" },
                  { type = "spell_can_kill_target", spellKey = "Shadow Word: Death", safetyKey = "swdSafetyPct" },
                }},
              }},
            }},
          }},
        } },
        { key = "Devouring Plague",       conditions = {{ type = "spec_option_enabled", optionKey = "use_DP" }, { type = "debuff_property_compare", debuff = "Devouring Plague", source = "player", property = "remaining", op = "==", value = 0 }, { type = "cooldown_ready", spellKey = "Devouring Plague" }} },
        { key = "POTION",   conditions = {{ type = "spec_option_enabled", optionKey = "suggestPot" }, { type = "state_compare", subject = "player_mana_pct", op = "<", value = "potManaThreshold" }, { type = "item_ready_and_owned" }} },
        { key = "RUNE",     conditions = {{ type = "spec_option_enabled", optionKey = "suggestRune" }, { type = "state_compare", subject = "player_mana_pct", op = "<", value = "runeManaThreshold" }, { type = "item_ready_and_owned" }} },
        { key = "Mind Flay",       conditions = {{ type = "always" }} },
    },

    -------------------------------------------------------------------
    -- Class-specific context extension for the rotation engine.
    -- Populates Shadow Priest fields used by condition evaluators and
    -- the SpecUI debug panel. Called by RE:BuildContext after the
    -- generic fields are built, so ctx.trackedDebuffs etc. are ready.
    -------------------------------------------------------------------
    buildContext = function(ctx, spec)
        local constants = (spec and spec.constants) or {}
        local hasteMul  = ctx.hasteMul or 1
        local castRem   = ctx.castRemaining or 0

        -- Convenience short-name aliases for tracked debuffs
        local vtState  = ctx.trackedDebuffsBySpellKey and ctx.trackedDebuffsBySpellKey["Vampiric Touch"]
        local swpState = ctx.trackedDebuffsBySpellKey and ctx.trackedDebuffsBySpellKey["Shadow Word: Pain"]
        ctx.vtRem    = (vtState  and vtState.remaining)  or 0
        ctx.swpRem   = (swpState and swpState.remaining) or 0
        ctx.vtAfter  = math.max(ctx.vtRem  - castRem, 0)
        ctx.swpAfter = math.max(ctx.swpRem - castRem, 0)

        -- Per-spell cooldowns (projected past current cast)
        local function CooldownProj(spellKey)
            local spell = A.SPELLS and A.SPELLS[spellKey]
            if not spell or not spell.id then return 999 end
            if not (A.KnowsSpell and A.KnowsSpell(spell.id)) then return 999 end
            return math.max((A.GetSpellCDReal and A.GetSpellCDReal(spell.id) or 0) - castRem, 0)
        end
        ctx.mbCD  = CooldownProj("Mind Blast")
        ctx.swdCD = CooldownProj("Shadow Word: Death")
        ctx.sfCD  = CooldownProj("Shadowfiend")
        ctx.dpCD  = CooldownProj("Devouring Plague")

        -- Clearcasting (from generic trackedBuffs already built in ctx)
        local ccState    = ctx.trackedBuffs and ctx.trackedBuffs["clearcasting"]
        ctx.clearcasting = (ccState and ccState.active) or false

        -- Haste-adjusted cast times for key spells
        local VT_CAST_TIME = constants.VT_CAST_TIME
            or (A.GetSpellDefinition and A.GetSpellDefinition("Vampiric Touch")
                and A.GetSpellDefinition("Vampiric Touch").castTime)
            or 1.5
        local MF_CAST_TIME = constants.MF_CAST_TIME
            or (A.GetSpellDefinition and A.GetSpellDefinition("Mind Flay")
                and A.GetSpellDefinition("Mind Flay").castTime)
            or 3.0
        ctx.vtCastEff = VT_CAST_TIME / hasteMul
        ctx.mfCastEff = MF_CAST_TIME / hasteMul
        ctx.minMfEff  = (constants.MIN_MF_DURATION or 1.0) / hasteMul

        -- Talent-adjusted SWP duration (Improved Shadow Word: Pain: tab 3, index 4)
        local rank = 0
        if A.RotationEngine and A.RotationEngine.GetTalentRank then
            rank = A.RotationEngine.GetTalentRank(3, 4)
        end
        ctx.swpDuration = 18 + rank * 3
    end,
}

-- Register with SpecManager
if A.SpecManager then
    A.SpecManager:RegisterSpec(spec)
end
