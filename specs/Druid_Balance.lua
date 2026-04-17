------------------------------------------------------------------------
-- SPHelper  –  specs/Druid_Balance.lua
-- Balance Druid spec template.
-- This is a starting-point example — fill in rotation entries and
-- conditions to match your playstyle.
------------------------------------------------------------------------
local A = SPHelper

local spec = {
    _fromFile = true,

    meta = {
        id       = "balance_druid",
        class    = "DRUID",
        specName = "Balance",
        author   = "SPHelper",
        version  = 1,
    },

    loadConditions = {
        class          = "DRUID",
        talentTab      = 1,            -- Balance talent tree
        -- requiredSpells = { 24858 },  -- Moonkin Form (uncomment if required)
    },

    helpers = {
        "CastBar",
        "ChannelHelper",
        "SpecUI",
        "Config",
    },

    constants = {
        SAFETY = 0.5,
        timing = {
            globalWaitThresholdMs   = 400,
            defaultDelayToleranceMs = 600,
            dotSafeWindowSec        = 1.5,
        },
    },

    trackedDebuffs = {
        -- Example: track Moonfire and Insect Swarm
        -- { key = "mf",  spellKey = "MOONFIRE",     duration = 12, color = "VT",  isDot = true },
        -- { key = "is",  spellKey = "INSECT_SWARM", duration = 12, color = "SWP", isDot = true },
    },

    uiOptions = {
        -- Example options:
        -- { key = "innervateThreshold", type = "slider", label = "Innervate mana %", default = 30, min = 5, max = 80, step = 5 },
    },

    channelSpells = {
        {
            spellKey = "HURRICANE",
            spellName = "Hurricane",
            -- ticks read from SpellDatabase (HURRICANE.ticks = 10)
            fakeQueue = true,
            clipOverlay = true,
            tickSound = true,
            tickFlash = true,
            tickMarkers = true,
            tickMarkerMode = "all",
            tickMarkerTicks = {},
        },
    },

    rotation = {
        _fromFile = true,
        -- Example entries:
        -- { key = "MOONFIRE",     conditions = {{ type = "dot_missing", spellKey = "MOONFIRE" }},     explicitPriority = 90 },
        -- { key = "INSECT_SWARM", conditions = {{ type = "dot_missing", spellKey = "INSECT_SWARM" }}, explicitPriority = 85 },
        -- { key = "STARFIRE",     conditions = {{ type = "always" }},                                  explicitPriority = 10 },
    },
}

-- Register with SpecManager
if A.SpecManager then
    A.SpecManager:RegisterSpec(spec)
end
