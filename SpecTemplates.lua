------------------------------------------------------------------------
-- SPHelper - SpecTemplates.lua
-- Shared rotation templates used by spec files.
------------------------------------------------------------------------
local A = SPHelper

A.SpecTemplates = A.SpecTemplates or {}
local T = A.SpecTemplates

local function cloneArray(list)
    local copy = {}
    for i, value in ipairs(list or {}) do
        copy[i] = value
    end
    return copy
end

local function extend(dest, src)
    if not src then return dest end
    for key, value in pairs(src) do
        dest[key] = value
    end
    return dest
end

local function cond(typeName, fields)
    local c = { type = typeName }
    for key, value in pairs(fields or {}) do
        c[key] = value
    end
    return c
end

local function appendConditions(dest, items)
    if not items then return end
    for _, item in ipairs(items) do
        dest[#dest + 1] = item
    end
end

function T.Entry(key, conditions, opts)
    local entry = {
        key = key,
        conditions = cloneArray(conditions),
    }
    return extend(entry, opts)
end

function T.Always() return cond("always") end
function T.TargetValid() return cond("target_valid") end
function T.InCombat() return cond("in_combat") end
function T.NotInCombat() return cond("not_in_combat") end
function T.Precombat() return cond("precombat") end
function T.CatForm() return cond("cat_form") end
function T.BearForm() return cond("bear_form") end
function T.IsStealthed() return cond("is_stealthed") end
function T.NotStealthed() return cond("not_stealthed") end
function T.Clearcasting() return cond("clearcasting") end
function T.HasAggro() return cond("has_aggro") end
function T.NotHasAggro() return cond("not_has_aggro") end
function T.BehindTarget() return cond("behind_target") end
function T.NotBehindTarget() return cond("not_behind_target") end
function T.CooldownReady(spellKey) return cond("cooldown_ready", { spellKey = spellKey }) end
function T.SpecOption(optionKey) return cond("spec_option_enabled", { optionKey = optionKey }) end
function T.SettingCompare(optionKey, op, value) return cond("setting_compare", { optionKey = optionKey, op = op, value = value }) end
function T.StateCompare(subject, op, value) return cond("state_compare", { subject = subject, op = op, value = value }) end
function T.ResourceGte(amount) return cond("resource_gte", { amount = amount }) end
function T.ResourceLt(amount) return cond("resource_lt", { amount = amount }) end
function T.ResourceRequiredGte(amount) return cond("resource_required_gte", { amount = amount }) end
function T.ComboPointsGte(amount) return cond("combo_points_gte", { points = amount }) end
function T.ComboPointsLt(amount) return cond("combo_points_lt", { points = amount }) end
function T.TargetTtdGte(value) return cond("target_ttd_gte", { seconds = value }) end
function T.TargetTtdLt(value) return cond("target_ttd_lt", { seconds = value }) end
function T.DotMissing(spellKey) return cond("dot_missing", { spellKey = spellKey }) end
function T.ProjectedDotTimeLeftLT(spellKey, seconds)
    local fields = { spellKey = spellKey }
    if seconds ~= nil then
        fields.seconds = seconds
    end
    return cond("projected_dot_time_left_lt", fields)
end
function T.DebuffPropertyCompare(spellKey, source, property, op, value)
    return cond("debuff_property_compare", {
        spellKey = spellKey,
        source = source,
        property = property,
        op = op,
        value = value,
    })
end
function T.BuffPropertyCompare(buff, property, op, value)
    return cond("buff_property_compare", {
        buff = buff,
        property = property,
        op = op,
        value = value,
    })
end
function T.BuffStacks(buff, op, value) return T.BuffPropertyCompare(buff, "stacks", op, value) end
function T.BuffRemaining(buff, op, value) return T.BuffPropertyCompare(buff, "remaining", op, value) end
function T.ItemReadyAndOwned(itemId) return cond("item_ready_and_owned", { itemId = itemId }) end
function T.ItemReadyByKey(itemKey) return cond("item_ready_by_key", { itemKey = itemKey }) end
function T.ContentType(contentType) return cond("content_type", { contentType = contentType }) end
function T.OtherTargetsWithDebuffLt(spellKey, count, seconds, minTTD)
    local fields = {
        spellKey = spellKey,
        count = count,
        seconds = seconds,
    }
    if minTTD ~= nil then
        fields.minTTD = minTTD
    end
    return cond("other_targets_with_debuff_lt", fields)
end
function T.SpellCanKillTarget(spellKey, safetyKey)
    local fields = { spellKey = spellKey }
    if safetyKey ~= nil then
        fields.safetyKey = safetyKey
    end
    return cond("spell_can_kill_target", fields)
end
function T.OptionGatedClassification(optionKey, classification)
    return cond("option_gated_classification", {
        optionKey = optionKey,
        classification = classification,
    })
end
function T.UnitCastCompare(unit, op, value) return cond("unit_cast_compare", { unit = unit, op = op, value = value }) end
function T.UnitInterruptible(unit) return cond("unit_interruptible", { unit = unit }) end
function T.NotRecentlyCast(spellKey, window) return cond("not_recently_cast", { spellKey = spellKey, window = window }) end
function T.AnyOf(conditions) return cond("any_of", { conditions = cloneArray(conditions) }) end
function T.AllOf(conditions) return cond("all_of", { conditions = cloneArray(conditions) }) end
function T.Not(condition) return cond("not", { condition = condition }) end

function T.SpellEntry(params)
    params = params or {}
    local conditions = {}

    if params.optionKey then conditions[#conditions + 1] = T.SpecOption(params.optionKey) end
    if params.targetValid then conditions[#conditions + 1] = T.TargetValid() end
    if params.inCombat then conditions[#conditions + 1] = T.InCombat() end
    if params.precombat then conditions[#conditions + 1] = T.Precombat() end
    if params.isStealthed then conditions[#conditions + 1] = T.IsStealthed() end
    if params.notStealthed then conditions[#conditions + 1] = T.NotStealthed() end
    if params.catForm then conditions[#conditions + 1] = T.CatForm() end
    if params.bearForm then conditions[#conditions + 1] = T.BearForm() end
    if params.resourceRequiredGte ~= nil then conditions[#conditions + 1] = T.ResourceRequiredGte(params.resourceRequiredGte) end
    if params.resourceGte ~= nil then conditions[#conditions + 1] = T.ResourceGte(params.resourceGte) end
    if params.resourceLt ~= nil then conditions[#conditions + 1] = T.ResourceLt(params.resourceLt) end
    if params.cooldownSpellKey ~= nil and params.cooldownSpellKey ~= false then
        conditions[#conditions + 1] = T.CooldownReady(params.cooldownSpellKey or params.spellKey or params.key)
    end
    if params.itemKey then conditions[#conditions + 1] = T.ItemReadyByKey(params.itemKey) end
    if params.itemId then conditions[#conditions + 1] = T.ItemReadyAndOwned(params.itemId) end
    appendConditions(conditions, params.extraConditions)

    return T.Entry(params.key or params.spellKey, conditions, params.entryOpts)
end

function T.DotRefreshEntry(params)
    params = params or {}
    local conditions = {}

    if params.optionKey then conditions[#conditions + 1] = T.SpecOption(params.optionKey) end
    if params.targetValid ~= false then conditions[#conditions + 1] = T.TargetValid() end
    if params.notStealthed then conditions[#conditions + 1] = T.NotStealthed() end
    if params.cooldownSpellKey ~= nil and params.cooldownSpellKey ~= false then
        conditions[#conditions + 1] = T.CooldownReady(params.cooldownSpellKey or params.spellKey or params.key)
    end
    conditions[#conditions + 1] = T.ProjectedDotTimeLeftLT(params.spellKey, params.seconds)
    if params.minTTDKey then conditions[#conditions + 1] = T.TargetTtdGte(params.minTTDKey) end
    if params.maxTargetsKey then
        conditions[#conditions + 1] = T.OtherTargetsWithDebuffLt(params.spellKey, params.maxTargetsKey, params.maxTargetsSeconds or 2, params.minTTDKey)
    end
    appendConditions(conditions, params.extraConditions)

    return T.Entry(params.key or params.spellKey, conditions, params.entryOpts)
end

function T.KillSpellEntry(params)
    params = params or {}
    local conditions = {}

    if params.optionKey then conditions[#conditions + 1] = T.SpecOption(params.optionKey) end
    if params.targetValid then conditions[#conditions + 1] = T.TargetValid() end
    if params.cooldownSpellKey ~= nil and params.cooldownSpellKey ~= false then
        conditions[#conditions + 1] = T.CooldownReady(params.cooldownSpellKey or params.spellKey or params.key)
    end
    conditions[#conditions + 1] = T.SpellCanKillTarget(params.spellKey, params.safetyKey)
    appendConditions(conditions, params.extraConditions)

    return T.Entry(params.key or params.spellKey, conditions, params.entryOpts)
end

function T.ContentModeSpellEntry(params)
    params = params or {}
    local conditions = {}
    local blocks = {}
    local modeKeys = params.modeKeys or {}

    if params.optionKey then conditions[#conditions + 1] = T.SpecOption(params.optionKey) end
    if params.targetValid then conditions[#conditions + 1] = T.TargetValid() end
    if params.cooldownSpellKey ~= nil and params.cooldownSpellKey ~= false then
        conditions[#conditions + 1] = T.CooldownReady(params.cooldownSpellKey or params.spellKey or params.key)
    end

    local function AddBlock(contentType, modeKey)
        if not modeKey then return end
        blocks[#blocks + 1] = T.AllOf({
            T.ContentType(contentType),
            T.AnyOf({
                T.SettingCompare(modeKey, "==", "always"),
                T.AllOf({
                    T.SettingCompare(modeKey, "==", "execute"),
                    T.SpellCanKillTarget(params.spellKey, params.safetyKey),
                }),
            }),
        })
    end

    AddBlock("world", modeKeys.world)
    AddBlock("dungeon", modeKeys.dungeon)
    AddBlock("raid", modeKeys.raid)

    if #blocks > 0 then
        conditions[#conditions + 1] = T.AnyOf(blocks)
    end
    appendConditions(conditions, params.extraConditions)

    return T.Entry(params.key or params.spellKey, conditions, params.entryOpts)
end

function T.ChannelFillerEntry(params)
    params = params or {}
    local entry = T.Entry(params.key or params.spellKey, params.conditions or { T.Always() }, params.entryOpts)
    entry.isFiller = true
    if entry.repeatLimit == nil then
        entry.repeatLimit = params.repeatLimit or 2
    end
    if entry.channelPolicy == nil then
        entry.channelPolicy = params.channelPolicy or "keep_current"
    end
    return entry
end

function T.BuilderSplitEntries(params)
    params = params or {}
    local priority = params.priority or 10
    local primaryOptionKey = params.primaryOptionKey or "use_shred"
    local fallbackOptionKey = params.fallbackOptionKey or "use_mangle"
    local primaryResource = params.primaryResource or 42
    local fallbackResource = params.fallbackResource or 40
    local repeatLimit = params.repeatLimit or 4
    local maxComboPoints = params.maxComboPoints or 5

    local primaryExtra = {
        T.ComboPointsLt(maxComboPoints),
        T.NotHasAggro(),
        T.AnyOf({
            T.ResourceGte(primaryResource),
            T.Clearcasting(),
        }),
    }
    appendConditions(primaryExtra, params.primaryExtraConditions)
    local primary = T.SpellEntry({
        key = params.primaryKey or "Shred",
        targetValid = true,
        catForm = true,
        optionKey = primaryOptionKey,
        notStealthed = true,
        extraConditions = primaryExtra,
        entryOpts = extend({ explicitPriority = priority, isFiller = true, repeatLimit = repeatLimit }, params.primaryEntryOpts),
    })

    local fallbackExtra = {
        T.ComboPointsLt(maxComboPoints),
        T.AnyOf({
            T.HasAggro(),
            T.Not(T.SpecOption(primaryOptionKey)),
            T.NotBehindTarget(),
        }),
        T.AnyOf({
            T.ResourceGte(fallbackResource),
            T.Clearcasting(),
        }),
    }
    appendConditions(fallbackExtra, params.fallbackExtraConditions)
    local fallback = T.SpellEntry({
        key = params.fallbackKey or "Mangle (Cat)",
        targetValid = true,
        catForm = true,
        optionKey = fallbackOptionKey,
        notStealthed = true,
        extraConditions = fallbackExtra,
        entryOpts = extend({ explicitPriority = priority, isFiller = true, repeatLimit = repeatLimit }, params.fallbackEntryOpts),
    })

    return primary, fallback
end

function T.PowershiftEntry(params)
    params = params or {}
    local entry = T.Entry(params.key or "Cat Form", {
        T.CatForm(),
        T.NotStealthed(),
        T.SpecOption(params.optionKey or "use_powershift"),
        T.InCombat(),
        T.StateCompare(params.manaSubject or "player_mana_pct", ">", params.minManaKey or "powershift_min_mana_pct"),
        T.Not(T.Clearcasting()),
        T.AnyOf({
            T.AllOf({
                T.HasAggro(),
                T.StateCompare("resource", "<", params.aggroThreshold or 20),
            }),
            T.AllOf({
                T.NotHasAggro(),
                T.StateCompare("resource", "<", params.builderThreshold or 22),
            }),
        }),
    }, params.entryOpts)

    entry.postCast = entry.postCast or params.postCast or {
        resource = params.postResource or "energy",
        compute = params.compute or "ComputePowershiftEnergy",
    }
    return entry
end

function T.BuildShadowPriestRotation(spec)
    return {
        T.KillSpellEntry({
            key = "SWD_EXEC",
            spellKey = "Shadow Word: Death",
            optionKey = "use_SWD",
            cooldownSpellKey = "Shadow Word: Death",
            safetyKey = "swdSafetyPct",
        }),
        T.SpellEntry({
            key = "Inner Focus",
            spellKey = "Inner Focus",
            optionKey = "ifInsert.enabled",
            cooldownSpellKey = "Inner Focus",
            extraConditions = {
                T.OptionGatedClassification("ifInsert.onlyForBoss", "boss"),
                T.BuffStacks("Inner Focus", "==", 0),
            },
            entryOpts = { insertBeforeKey = "ifInsert.before" },
        }),
        T.DotRefreshEntry({
            key = "Vampiric Touch",
            spellKey = "Vampiric Touch",
            targetValid = true,
            extraConditions = {
                T.TargetTtdGte("vtMinTTD"),
                T.OtherTargetsWithDebuffLt("Vampiric Touch", "multidotMaxVTTargets", 2, "vtMinTTD"),
            },
        }),
        T.DotRefreshEntry({
            key = "Shadow Word: Pain",
            spellKey = "Shadow Word: Pain",
            targetValid = true,
            extraConditions = {
                T.TargetTtdGte("swpMinTTD"),
                T.OtherTargetsWithDebuffLt("Shadow Word: Pain", "multidotMaxSWPTargets", 2, "swpMinTTD"),
            },
        }),
        T.SpellEntry({
            key = "Mind Blast",
            spellKey = "Mind Blast",
            cooldownSpellKey = "Mind Blast",
        }),
        T.SpellEntry({
            key = "Shadowfiend",
            spellKey = "Shadowfiend",
            optionKey = "use_SF",
            targetValid = true,
            inCombat = true,
            cooldownSpellKey = "Shadowfiend",
            extraConditions = {
                T.StateCompare("player_mana_pct", "<", "sfManaThreshold"),
            },
        }),
        T.ContentModeSpellEntry({
            key = "Shadow Word: Death",
            spellKey = "Shadow Word: Death",
            optionKey = "use_SWD",
            cooldownSpellKey = "Shadow Word: Death",
            safetyKey = "swdSafetyPct",
            modeKeys = {
                world = "swdWorld",
                dungeon = "swdDungeon",
                raid = "swdRaid",
            },
        }),
        T.SpellEntry({
            key = "Devouring Plague",
            spellKey = "Devouring Plague",
            optionKey = "use_DP",
            cooldownSpellKey = "Devouring Plague",
            extraConditions = {
                T.DebuffPropertyCompare("Devouring Plague", "player", "remaining", "==", 0),
            },
        }),
        T.SpellEntry({
            key = "POTION",
            spellKey = "POTION",
            targetValid = false,
            optionKey = "suggestPot",
            itemKey = "selectedPotionItem",
            extraConditions = {
                T.StateCompare("player_mana_pct", "<", "potManaThreshold"),
            },
        }),
        T.SpellEntry({
            key = "RUNE",
            spellKey = "RUNE",
            targetValid = false,
            optionKey = "suggestRune",
            itemKey = "selectedRuneItem",
            extraConditions = {
                T.StateCompare("player_mana_pct", "<", "runeManaThreshold"),
            },
        }),
        T.ChannelFillerEntry({
            key = "Mind Flay",
            spellKey = "Mind Flay",
            repeatLimit = 2,
            channelPolicy = "keep_current",
            entryOpts = {
                helpers = {
                    fakeQueue = true,
                    clipOverlay = true,
                    tickSound = true,
                    tickFlash = true,
                    tickMarkers = true,
                },
                helperOptions = {
                    clipOverlay = {
                        minDuration = 1.0,
                        clipReasons = { "Vampiric Touch", "Shadow Word: Pain" },
                    },
                    tickMarkers = { mode = "all" },
                    tickSound = { ticks = {} },
                    tickFlash = { ticks = {} },
                },
            },
        }),
    }
end

function T.BuildFeralDruidRotation(spec)
    local shred, mangle = T.BuilderSplitEntries({
        priority = 10,
        primaryEntryOpts = { explicitPriority = 10 },
        fallbackEntryOpts = { explicitPriority = 10 },
    })

    return {
        T.SpellEntry({
            key = "Bear Form",
            spellKey = "Bear Form",
            targetValid = false,
            optionKey = "use_bear_form",
            extraConditions = {
                T.StateCompare("player_hp_pct", "<", "bear_form_hp_pct"),
                T.Not(T.BearForm()),
            },
        }),
        T.SpellEntry({
            key = "Cat Form",
            spellKey = "Cat Form",
            targetValid = false,
            extraConditions = {
                T.BuffStacks("Cat Form", "==", 0),
                T.AnyOf({
                    T.Not(T.SpecOption("use_bear_form")),
                    T.StateCompare("player_hp_pct", ">", "bear_form_hp_pct"),
                }),
                T.Not(T.BearForm()),
            },
        }),
        T.SpellEntry({
            key = "Frenzied Regeneration",
            spellKey = "Frenzied Regeneration",
            targetValid = false,
            bearForm = true,
            resourceGte = 10,
            extraConditions = {
                T.StateCompare("player_hp_pct", "<", "bear_fr_hp_pct"),
            },
        }),
        T.SpellEntry({
            key = "Bash",
            spellKey = "Bash",
            targetValid = true,
            bearForm = true,
            resourceGte = 10,
            extraConditions = {
                T.UnitCastCompare("target", ">", 0),
                T.UnitInterruptible("target"),
            },
        }),
        T.SpellEntry({
            key = "Demoralizing Roar",
            spellKey = "Demoralizing Roar",
            targetValid = true,
            bearForm = true,
            resourceGte = 10,
            extraConditions = {
                T.DebuffPropertyCompare("Demoralizing Roar", "any", "remaining", "<", 4),
            },
        }),
        T.SpellEntry({
            key = "Faerie Fire (Feral)",
            spellKey = "Faerie Fire (Feral)",
            targetValid = true,
            bearForm = true,
            cooldownSpellKey = "Faerie Fire (Feral)",
            extraConditions = {
                T.DebuffPropertyCompare("Faerie Fire (Feral)", "any", "remaining", "<", "faerie_fire_refresh_seconds"),
            },
        }),
        T.SpellEntry({
            key = "Mangle (Bear)",
            spellKey = "Mangle (Bear)",
            targetValid = true,
            bearForm = true,
            cooldownSpellKey = "Mangle (Bear)",
            resourceGte = 20,
        }),
        T.SpellEntry({
            key = "Lacerate",
            spellKey = "Lacerate",
            targetValid = true,
            bearForm = true,
            resourceGte = 15,
            extraConditions = {
                T.AnyOf({
                    T.DebuffPropertyCompare("Lacerate", "player", "stacks", "<", 5),
                    T.DebuffPropertyCompare("Lacerate", "player", "remaining", "<", 4),
                }),
                T.AnyOf({
                    T.ContentType("dungeon"),
                    T.ContentType("raid"),
                }),
            },
        }),
        T.SpellEntry({
            key = "Swipe",
            spellKey = "Swipe",
            targetValid = true,
            bearForm = true,
            resourceGte = 30,
            extraConditions = {
                T.AnyOf({
                    T.ContentType("dungeon"),
                    T.ContentType("raid"),
                }),
            },
        }),
        T.SpellEntry({
            key = "Maul",
            spellKey = "Maul",
            targetValid = true,
            bearForm = true,
            resourceGte = 50,
        }),
        T.SpellEntry({
            key = "Tiger's Fury",
            spellKey = "Tiger's Fury",
            targetValid = false,
            catForm = true,
            precombat = true,
            notStealthed = true,
            resourceRequiredGte = 100,
            cooldownSpellKey = "Tiger's Fury",
            optionKey = "use_tigers_fury",
        }),
        T.SpellEntry({
            key = "Ravage",
            spellKey = "Ravage",
            targetValid = true,
            catForm = true,
            precombat = true,
            isStealthed = true,
            resourceGte = 60,
            extraConditions = {
                T.BehindTarget(),
            },
            entryOpts = { explicitPriority = 200 },
        }),
        T.SpellEntry({
            key = "Pounce",
            spellKey = "Pounce",
            targetValid = true,
            catForm = true,
            precombat = true,
            isStealthed = true,
            resourceGte = 50,
            extraConditions = {
                T.NotBehindTarget(),
            },
            entryOpts = { explicitPriority = 200 },
        }),
        T.SpellEntry({
            key = "Faerie Fire (Feral)",
            spellKey = "Faerie Fire (Feral)",
            targetValid = true,
            catForm = true,
            notStealthed = true,
            optionKey = "use_faerie_fire",
            cooldownSpellKey = "Faerie Fire (Feral)",
            extraConditions = {
                T.DebuffPropertyCompare("Faerie Fire (Feral)", "any", "remaining", "<", "faerie_fire_refresh_seconds"),
            },
        }),
        T.SpellEntry({
            key = "Ferocious Bite",
            spellKey = "Ferocious Bite",
            targetValid = true,
            catForm = true,
            notStealthed = true,
            optionKey = "use_ferocious_bite",
            extraConditions = {
                T.StateCompare("combo_points", ">=", 4),
                T.AnyOf({
                    T.ResourceGte(35),
                    T.Clearcasting(),
                }),
                T.AnyOf({
                    T.StateCompare("target_ttd", "<", "rip_min_ttd"),
                    T.SpellCanKillTarget("Ferocious Bite"),
                }),
            },
        }),
        T.SpellEntry({
            key = "Rip",
            spellKey = "Rip",
            targetValid = true,
            catForm = true,
            notStealthed = true,
            optionKey = "use_rip",
            extraConditions = {
                T.StateCompare("combo_points", ">=", "rip_min_cp"),
                T.TargetTtdGte("rip_min_ttd"),
                T.AnyOf({
                    T.ResourceGte(30),
                    T.Clearcasting(),
                }),
                T.NotRecentlyCast("Rip", 0.6),
                T.DotMissing("Rip"),
            },
        }),
        T.SpellEntry({
            key = "Ferocious Bite",
            spellKey = "Ferocious Bite",
            targetValid = true,
            catForm = true,
            notStealthed = true,
            optionKey = "use_ferocious_bite",
            extraConditions = {
                T.StateCompare("combo_points", ">=", 5),
                T.AnyOf({
                    T.ResourceGte(35),
                    T.Clearcasting(),
                }),
                T.DebuffPropertyCompare("Rip", "player", "remaining", ">=", "ferocious_bite_min_rip_remaining"),
            },
        }),
        T.SpellEntry({
            key = "Mangle (Cat)",
            spellKey = "Mangle (Cat)",
            targetValid = true,
            catForm = true,
            notStealthed = true,
            optionKey = "use_mangle",
            cooldownSpellKey = "Mangle (Cat)",
            extraConditions = {
                T.DebuffPropertyCompare("Mangle (Cat)", "any", "remaining", "<", "mangle_refresh_seconds"),
                T.AnyOf({
                    T.ResourceGte(40),
                    T.Clearcasting(),
                }),
            },
            entryOpts = { explicitPriority = 10 },
        }),
        T.SpellEntry({
            key = "Rake",
            spellKey = "Rake",
            targetValid = true,
            catForm = true,
            notStealthed = true,
            optionKey = "use_rake",
            extraConditions = {
                T.StateCompare("combo_points", "<", 5),
                T.TargetTtdGte("rake_min_ttd"),
                T.AnyOf({
                    T.ResourceGte(35),
                    T.Clearcasting(),
                }),
                T.NotRecentlyCast("Rake", 0.6),
                T.DotMissing("Rake"),
            },
        }),
        shred,
        mangle,
        T.PowershiftEntry({
            key = "Cat Form",
            optionKey = "use_powershift",
            minManaKey = "powershift_min_mana_pct",
        }),
    }
end

return T