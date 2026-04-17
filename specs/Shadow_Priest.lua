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
        requiredSpells = { 15473 },  -- Shadowform
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
        { key = "swp", spellKey = "SWP", color = "SWP", isDot = true },
        { key = "vt",  spellKey = "VT",  color = "VT",  isDot = true },
        { key = "ms",  spellKey = "MS",  duration = 15, color = "MS",  isDot = false },  -- no DB duration (Mind Soothe is not a standard aura)
        { key = "su",  spellKey = "SU",  color = "SU",  isDot = false },
    },

    uiOptions = {
        -- Rotation behavior
        { key = "sfManaThreshold",    type = "slider",   label = "Shadowfiend mana %", default = 35, min = 5, max = 100, step = 5,
          tooltip = "Suggest Shadowfiend when mana drops below this percentage." },
        { key = "suggestPot",         type = "checkbox", label = "Suggest mana potion", default = true,
          tooltip = "Show mana potion in rotation suggestions when low on mana." },
        { key = "potManaThreshold",   type = "slider",   label = "Potion mana %",       default = 70, min = 5, max = 100, step = 5,
          tooltip = "Suggest mana potion when mana drops below this percentage." },
        { key = "potEarly",           type = "checkbox", label = "Pot before Shadowfiend", default = false,
          tooltip = "Suggest using a potion before Shadowfiend cooldown (pre-pot strategy)." },
        { key = "suggestRune",        type = "checkbox", label = "Suggest dark rune",  default = true,
          tooltip = "Show dark/demonic rune in rotation suggestions when low on mana." },
        { key = "runeManaThreshold",  type = "slider",   label = "Rune mana %",         default = 40, min = 5, max = 100, step = 5,
          tooltip = "Suggest rune when mana drops below this percentage." },
        { key = "vtMinTTD",           type = "slider",   label = "VT min target TTD",   default = 12, min = 0, max = 30, step = 1,
          tooltip = "Only suggest Vampiric Touch when the current target is projected to live at least this many seconds. Set to 0 to disable." },
        { key = "swpMinTTD",          type = "slider",   label = "SW:P min target TTD", default = 8, min = 0, max = 30, step = 1,
          tooltip = "Only suggest Shadow Word: Pain when the current target is projected to live at least this many seconds. Set to 0 to disable." },
        { key = "multidotMaxVTTargets",  type = "slider", label = "VT max targets",     default = 3, min = 1, max = 8, step = 1,
          tooltip = "Maximum total targets to keep Vampiric Touch on while tab-dotting. Set to 1 for single-target only." },
        { key = "multidotMaxSWPTargets", type = "slider", label = "SW:P max targets",   default = 4, min = 1, max = 8, step = 1,
          tooltip = "Maximum total targets to keep Shadow Word: Pain on while tab-dotting. Set to 1 for single-target only." },
        -- SW:D behavior
        { key = "swdWorld",           type = "dropdown", label = "SW:D (world)",        default = "always",  values = {"always","execute","never"},
          tooltip = "When to suggest Shadow Word: Death in open world. 'execute' = below 25% HP only." },
        { key = "swdDungeon",         type = "dropdown", label = "SW:D (dungeon)",      default = "always",  values = {"always","execute","never"},
          tooltip = "When to suggest Shadow Word: Death in dungeons." },
        { key = "swdRaid",            type = "dropdown", label = "SW:D (raid)",         default = "execute", values = {"always","execute","never"},
          tooltip = "When to suggest Shadow Word: Death in raids. 'execute' recommended to avoid self-damage." },
        { key = "swdSafetyPct",       type = "slider",   label = "SW:D safety margin %", default = 10, min = 0, max = 50, step = 1,
          tooltip = "Extra HP margin for SW:D kill prediction. Higher = more conservative." },
        -- Inner Focus
        { key = "ifInsert.enabled",     type = "checkbox", label = "Suggest Inner Focus",    default = true,
          tooltip = "Insert Inner Focus before a spell in the rotation for free crit + mana save." },
        { key = "ifInsert.onlyForBoss", type = "checkbox", label = "Inner Focus bosses only", default = true,
          tooltip = "Only suggest Inner Focus on boss encounters." },
        { key = "ifInsert.before",      type = "dropdown", label = "Inner Focus before",      default = "MB", values = {"MB","SWP","DP"},
          tooltip = "Which spell to cast Inner Focus before. MB is most common." },
        -- Channel / Fake Queue — now configured in CastBar & FQ tab
        -- (These keys are kept here so they appear in General too, and
        --  are read by ChannelHelper/CastBar via SpecVal. The CastBar tab
        --  provides per-spell channel config.)
        -- Per-spell enable toggles (only for optional/situational spells)
        { key = "use_DP",    type = "checkbox", label = "Use Devouring Plague",  default = true,
          tooltip = "Include Devouring Plague in the rotation." },
        { key = "use_SWD",   type = "checkbox", label = "Use Shadow Word: Death",default = true,
          tooltip = "Include Shadow Word: Death in the rotation (see per-content SW:D settings above)." },
        { key = "use_SF",    type = "checkbox", label = "Use Shadowfiend",       default = true,
          tooltip = "Include Shadowfiend in the rotation." },
    },

    -------------------------------------------------------------------
    -- Channel Spells — data-driven list of channeled spells with
    -- per-spell FQ / clip / tick settings. Replaces the hardcoded
    -- KNOWN_CHANNELS table in ChannelHelper.
    -------------------------------------------------------------------
    channelSpells = {
        {
            spellKey    = "MF",
            spellName   = "Mind Flay",
            -- ticks read from SpellDatabase (MF.ticks = 3)
            fakeQueue   = true,   -- enable FQ for this spell
            clipOverlay = true,   -- show green clip zone
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
    -- Rotation — core spells (VT, SWP, MB, MF) are always on.
    -- Optional/situational spells (DP, SWD, SF) have enable toggles.
    -------------------------------------------------------------------
    rotation = {
        _fromFile = true,
        { key = "SWD_EXEC", conditions = {{ type = "predicted_kill" }, { type = "cooldown_ready", spellKey = "SWD" }, { type = "spec_option_enabled", optionKey = "use_SWD" }} },
        { key = "IF",       conditions = {{ type = "spec_option_enabled", optionKey = "ifInsert.enabled" }, { type = "option_gated_classification", optionKey = "ifInsert.onlyForBoss", classification = "boss" }, { type = "cooldown_ready", spellKey = "IF" }, { type = "buff_property_compare", buff = "Inner Focus", property = "stacks", op = "==", value = 0 }}, insertBefore = "MB" },
        { key = "VT",       conditions = {
          { type = "projected_dot_time_left_lt", spellKey = "VT",  seconds = "vtCastEff + vtTravel + SAFETY" },
          { type = "state_compare",              subject = "target_ttd", op = ">=", value = "vtMinTTD" },
          { type = "other_targets_with_debuff_lt", spellKey = "VT", count = "multidotMaxVTTargets", seconds = 2, minTTD = "vtMinTTD" },
        } },
        { key = "SWP",      conditions = {
          { type = "projected_dot_time_left_lt", spellKey = "SWP", seconds = "gcd + swpTravel + SAFETY" },
          { type = "state_compare",              subject = "target_ttd", op = ">=", value = "swpMinTTD" },
          { type = "other_targets_with_debuff_lt", spellKey = "SWP", count = "multidotMaxSWPTargets", seconds = 2, minTTD = "swpMinTTD" },
        } },
        { key = "MB",       conditions = {{ type = "cooldown_ready", spellKey = "MB" }} },
        { key = "SF",       conditions = {{ type = "spec_option_enabled", optionKey = "use_SF" }, { type = "in_combat" }, { type = "target_valid" }, { type = "state_compare", subject = "player_mana_pct", op = "<", value = "sfManaThreshold" }, { type = "cooldown_ready", spellKey = "SF" }} },
        { key = "SWD",      conditions = {{ type = "spec_option_enabled", optionKey = "use_SWD" }, { type = "content_mode_allow", dbKey = "swd" }, { type = "cooldown_ready", spellKey = "SWD" }} },
        { key = "DP",       conditions = {{ type = "spec_option_enabled", optionKey = "use_DP" }, { type = "debuff_property_compare", debuff = "Devouring Plague", source = "player", property = "remaining", op = "==", value = 0 }, { type = "cooldown_ready", spellKey = "DP" }} },
        { key = "POTION",   conditions = {{ type = "spec_option_enabled", optionKey = "suggestPot" }, { type = "state_compare", subject = "player_mana_pct", op = "<", value = "potManaThreshold" }, { type = "item_ready_and_owned" }} },
        { key = "RUNE",     conditions = {{ type = "spec_option_enabled", optionKey = "suggestRune" }, { type = "state_compare", subject = "player_mana_pct", op = "<", value = "runeManaThreshold" }, { type = "item_ready_and_owned" }} },
        { key = "MF",       conditions = {{ type = "always" }} },
    },
}

-- Register with SpecManager
if A.SpecManager then
    A.SpecManager:RegisterSpec(spec)
end
