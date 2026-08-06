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
function T.ShouldApplyDebuff(spellKey) return cond("should_apply_debuff", { spellKey = spellKey }) end
function T.DebuffTimeLeftLt(debuffName, seconds) return cond("debuff_time_left_lt", { debuff = debuffName, seconds = seconds }) end
function T.CooldownRemaining(spellKey, op, value) return cond("cooldown_lt", { spellKey = spellKey, seconds = value or 0 }) end
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
function T.PlayerHasDebuff(spellKey)
    -- Returns true if THIS player has the given debuff on target.
    -- Used for mutual exclusivity checks (e.g., warlock curse slot: don't cast Curse X if we already have Curse Y).
    return cond("player_has_debuff", { spellKey = spellKey })
end
function T.BuffMissingOnPlayer(buffName)
    return cond("not_buff_on_player", { buff = buffName })
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
function T.GroupSizeGte(count) return cond("group_size_gte", { size = count or 1 }) end
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
function T.ClassificationFromSetting(settingKey)
    return cond("classification_from_setting", { settingKey = settingKey })
end
function T.ClassificationFromAnyTarget(settingKey)
    return cond("classification_any_target", { settingKey = settingKey })
end
function T.TargetClassification(classification) return cond("target_classification", { classification = classification }) end
function T.TrinketReady(slot) return cond("trinket_ready", { slot = slot }) end
function T.UnitCastCompare(unit, op, value) return cond("unit_cast_compare", { unit = unit, op = op, value = value }) end
function T.UnitInterruptible(unit) return cond("unit_interruptible", { unit = unit }) end
function T.NotRecentlyCast(spellKey, window) return cond("not_recently_cast", { spellKey = spellKey, window = window }) end
function T.NextPowerTickLt(seconds) return cond("next_power_tick_with_gcd_lt", { seconds = seconds }) end
function T.IsMoving() return cond("is_moving") end
function T.NotIsMoving() return cond("not_is_moving") end
function T.MeleeRange() return cond("melee_range") end
function T.NotMeleeRange() return cond("not_melee_range") end
function T.WandEquipped() return cond("wand_equipped") end
function T.PetAlive() return cond("pet_alive") end
function T.PetAttacking() return cond("pet_attacking") end
function T.CreatureType(typeName) return cond("creature_type", { typeName = typeName }) end
function T.TotemActive(slot) return cond("totem_active", { slot = slot }) end
function T.TotemRemainingLt(slot, seconds) return cond("totem_remaining_lt", { slot = slot, seconds = seconds }) end
function T.TotemName(slot, totemName) return cond("totem_name", { slot = slot, name = totemName }) end
function T.SwingTimeRemaining(hand, op, seconds)
    local fields = { hand = hand or "mh", seconds = seconds }
    if op then fields.op = op end
    return cond("swing_time_remaining", fields)
end

-- Filler entry for movement: marks a spell as usable while moving.
-- Used by e.g. Balance Druid (Starfire → Moonfire filler when moving).
function T.MovementFillerEntry(params)
    params = params or {}
    local conditions = {}

    if not params.noTargetCheck then
        conditions[#conditions + 1] = T.TargetValid()
    end
    if params.inCombat then conditions[#conditions + 1] = T.InCombat() end
    conditions[#conditions + 1] = T.IsMoving()
    if params.extraConditions then
        appendConditions(conditions, params.extraConditions)
    end

    local entry = T.Entry(params.key, conditions, params.entryOpts)
    -- Flag instant-cast spells usable while moving so Rotation.lua can surface
    -- them in a bonus slot (they are castable during the movement GCD).  Only
    -- entries explicitly marked isInstant are flagged.
    if params.entryOpts and params.entryOpts.isInstant then
        entry.instantWhileMoving = true
    end
    return entry
end

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
    if params.classificationSetting then
        if params.offensive == false then
            conditions[#conditions + 1] = T.ClassificationFromAnyTarget(params.classificationSetting)
        else
            conditions[#conditions + 1] = T.ClassificationFromSetting(params.classificationSetting)
        end
    end
    appendConditions(conditions, params.extraConditions)

    local entry = T.Entry(params.key or params.spellKey, conditions, params.entryOpts)
    -- Trinkets are bonus-slot actions for every spec: show them in the
    -- dedicated bonus slot (left of the primary icon) instead of the main
    -- queue.  Rotation.lua routes `optional` entries to the bonus slots.
    local entryKey = params.key or params.spellKey
    if (entryKey == "TRINKET1" or entryKey == "TRINKET2") and entry.optional == nil then
        entry.optional = true
    end
    return entry
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
        T.SpellEntry({
            key = "Shadowform",
            spellKey = "Shadowform",
            optionKey = "use_shadowform",
            extraConditions = {
                T.NotInCombat(),
                T.BuffStacks("Shadowform", "==", 0),
            },
        }),
        T.KillSpellEntry({
            key = "Shadow Word: Death",
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
                T.ClassificationFromAnyTarget("if_classification"),
                T.BuffStacks("Inner Focus", "==", 0),
            },
            entryOpts = { insertBeforeKey = "ifInsert.before" },
        }),
        T.SpellEntry({
            key = "Vampiric Embrace",
            spellKey = "Vampiric Embrace",
            optionKey = "use_VE",
            inCombat = true,
            cooldownSpellKey = "Vampiric Embrace",
            classificationSetting = "vampiric_embrace_classification", offensive = false,
            extraConditions = {
                T.BuffPropertyCompare("Vampiric Embrace", "stacks", "==", 0),
            },
        }),
        T.SpellEntry({
            key = "TRINKET1",
            targetValid = true,
            optionKey = "use_trinket_1",
            extraConditions = {
                T.TrinketReady(13),
                T.ClassificationFromAnyTarget("trinket_1_classification"),
            },
        }),
        T.SpellEntry({
            key = "TRINKET2",
            targetValid = true,
            optionKey = "use_trinket_2",
            extraConditions = {
                T.TrinketReady(14),
                T.ClassificationFromAnyTarget("trinket_2_classification"),
            },
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
            classificationSetting = "shadowfiend_classification", offensive = false,
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
            classificationSetting = "devouring_plague_classification",
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

function T.BuildBalanceDruidRotation(spec)
    return {
        -- ── FORM ──────────────────────────────────────────────────
        T.SpellEntry({
            key = "Moonkin Form",
            spellKey = "Moonkin Form",
            optionKey = "use_moonkin_form",
            extraConditions = {
                T.NotInCombat(),
                T.BuffStacks("Moonkin Form", "==", 0),
            },
        }),
        -- ── DEFENSIVE ─────────────────────────────────────────────
        T.SpellEntry({
            key = "Barkskin",
            spellKey = "Barkskin",
            optionKey = "use_barkskin",
            inCombat = true,
            cooldownSpellKey = "Barkskin",
            extraConditions = {
                T.StateCompare("player_hp_pct", "<", "barkskinHpPct"),
            },
        }),
        -- ── COOLDOWNS ─────────────────────────────────────────────
        T.SpellEntry({
            key = "Force of Nature",
            spellKey = "Force of Nature",
            optionKey = "use_force_of_nature",
            targetValid = true,
            inCombat = true,
            cooldownSpellKey = "Force of Nature",
            classificationSetting = "force_of_nature_classification", offensive = false,
        }),
        T.SpellEntry({
            key = "Nature's Swiftness",
            spellKey = "Nature's Swiftness",
            optionKey = "use_natures_swiftness",
            targetValid = true,
            inCombat = true,
            cooldownSpellKey = "Nature's Swiftness",
            classificationSetting = "natures_swiftness_classification", offensive = false,
            extraConditions = {
                T.IsMoving(),
            },
        }),
        -- ── DEBUFF ────────────────────────────────────────────────
        T.SpellEntry({
            key = "Faerie Fire",
            spellKey = "Faerie Fire",
            optionKey = "use_faerie_fire",
            targetValid = true,
            inCombat = true,
            extraConditions = {
                T.ShouldApplyDebuff("Faerie Fire"),  -- Respects debuffStackingMode=single_any_source and debuffSiblings (FF Feral)
            },
        }),
        -- ── DoTs ──────────────────────────────────────────────────
        T.DotRefreshEntry({
            key = "Moonfire",
            spellKey = "Moonfire",
            targetValid = true,
            minTTDKey = 6,
            maxTargetsKey = "multidotMaxMF",
        }),
        -- ── MAIN NUKE ─────────────────────────────────────────────
        T.SpellEntry({
            key = "Starfire",
            spellKey = "Starfire",
            targetValid = true,
            extraConditions = {
                T.NotIsMoving(),
            },
        }),
        -- ── MOVEMENT FILLER ───────────────────────────────────────
        -- Insect Swarm only while moving and not on target
        T.MovementFillerEntry({
            key = "Insect Swarm",
            targetValid = true,
            inCombat = true,
            extraConditions = {
                T.DotMissing("Insect Swarm"),
                T.TargetTtdGte(8),
            },
            entryOpts = { isFiller = true, repeatLimit = 1 },
        }),
        -- Wrath as movement filler when IS is already up
        T.MovementFillerEntry({
            key = "Wrath",
            targetValid = true,
            inCombat = true,
            entryOpts = { isFiller = true, repeatLimit = 3 },
        }),
        -- ── AoE ───────────────────────────────────────────────────
        T.SpellEntry({
            key = "Hurricane",
            spellKey = "Hurricane",
            optionKey = "use_hurricane",
            targetValid = true,
            inCombat = true,
            cooldownSpellKey = "Hurricane",
            extraConditions = {
                T.StateCompare("target_hp_pct", ">", 20),
            },
        }),
        -- ── INNERVATE ─────────────────────────────────────────────
        T.SpellEntry({
            key = "Innervate",
            spellKey = "Innervate",
            optionKey = "use_innervate",
            inCombat = true,
            cooldownSpellKey = "Innervate",
            classificationSetting = "innervate_classification", offensive = false,
            extraConditions = {
                T.StateCompare("player_mana_pct", "<", "innervateManaPct"),
            },
        }),
        -- ── CONSUMABLES ───────────────────────────────────────────
        T.SpellEntry({
            key = "POTION",
            spellKey = "POTION",
            optionKey = "suggestPot",
            targetValid = false,
            itemKey = "selectedPotionItem",
            extraConditions = {
                T.StateCompare("player_mana_pct", "<", "potManaThreshold"),
            },
        }),
        T.SpellEntry({
            key = "RUNE",
            spellKey = "RUNE",
            optionKey = "suggestRune",
            targetValid = false,
            itemKey = "selectedRuneItem",
            extraConditions = {
                T.StateCompare("player_mana_pct", "<", "runeManaThreshold"),
            },
        }),
        -- On-use trinkets.
        T.SpellEntry({
            key = "TRINKET1",
            targetValid = true,
            optionKey = "use_trinket_1",
            extraConditions = {
                T.TrinketReady(13),
                T.ClassificationFromAnyTarget("trinket_1_classification"),
            },
        }),
        T.SpellEntry({
            key = "TRINKET2",
            targetValid = true,
            optionKey = "use_trinket_2",
            extraConditions = {
                T.TrinketReady(14),
                T.ClassificationFromAnyTarget("trinket_2_classification"),
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
        -- ── FORM SAFETY ───────────────────────────────────────────
        -- Emergency Bear Form when HP drops below threshold.
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
        -- Switch back to Cat Form when HP is safe and not already in cat.
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

        -- ── BEAR TANK ROTATION ────────────────────────────────────
        -- Frenzied Regeneration – defensive cooldown.
        T.SpellEntry({
            key = "Frenzied Regeneration",
            spellKey = "Frenzied Regeneration",
            targetValid = false,
            bearForm = true,
            cooldownSpellKey = "Frenzied Regeneration",
            resourceGte = 10,
            extraConditions = {
                T.StateCompare("player_hp_pct", "<", "bear_fr_hp_pct"),
            },
        }),
        -- Bash – interrupt.
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
        -- Demoralizing Roar – maintain AP debuff.
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
        -- Faerie Fire (Feral) – maintain armour debuff if no Boomkin.
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
        -- Mangle (Bear) – on cooldown, highest TPR.
        T.SpellEntry({
            key = "Mangle (Bear)",
            spellKey = "Mangle (Bear)",
            targetValid = true,
            bearForm = true,
            cooldownSpellKey = "Mangle (Bear)",
            resourceGte = 20,
        }),
        -- Lacerate – stack to 5 and refresh.
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
            },
        }),
        -- Swipe – filler when Lacerate is at 5 and not expiring.
        T.SpellEntry({
            key = "Swipe",
            spellKey = "Swipe",
            targetValid = true,
            bearForm = true,
            resourceGte = 20,
            extraConditions = {
                T.DebuffPropertyCompare("Lacerate", "player", "stacks", ">=", 5),
                T.DebuffPropertyCompare("Lacerate", "player", "remaining", ">=", 4),
            },
        }),
        -- Maul – rage dump.
        T.SpellEntry({
            key = "Maul",
            spellKey = "Maul",
            targetValid = true,
            bearForm = true,
            resourceGte = 50,
        }),

        -- ── CAT PRE-PULL / OPENER ─────────────────────────────────
        -- Tiger's Fury pre-pull when energy-capped.
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
        -- Ravage from stealth when behind target.
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
        -- Pounce from stealth when not behind target.
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

        -- ── CAT MAINTENANCE ───────────────────────────────────────
        -- Faerie Fire in Cat Form.
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
        -- On-use trinkets.
        T.SpellEntry({
            key = "TRINKET1",
            targetValid = true,
            catForm = true,
            notStealthed = true,
            optionKey = "use_trinket_1",
            extraConditions = {
                T.TrinketReady(13),
                T.ClassificationFromAnyTarget("trinket_1_classification"),
            },
        }),
        T.SpellEntry({
            key = "TRINKET2",
            targetValid = true,
            catForm = true,
            notStealthed = true,
            optionKey = "use_trinket_2",
            extraConditions = {
                T.TrinketReady(14),
                T.ClassificationFromAnyTarget("trinket_2_classification"),
            },
        }),

        -- ── CAT FINISHERS ─────────────────────────────────────────
        -- Rip on bosses – always 5 CP.
        T.SpellEntry({
            key = "Rip",
            spellKey = "Rip",
            targetValid = true,
            catForm = true,
            notStealthed = true,
            optionKey = "use_rip",
            extraConditions = {
                T.TargetClassification("boss"),
                T.StateCompare("combo_points", ">=", 5),
                T.TargetTtdGte("rip_min_ttd"),
                T.AnyOf({
                    T.ResourceGte(30),
                    T.Clearcasting(),
                }),
                T.NotRecentlyCast("Rip", 0.6),
                T.DotMissing("Rip"),
            },
        }),
        -- Rip on non-bosses – configurable minimum CP.
        T.SpellEntry({
            key = "Rip",
            spellKey = "Rip",
            targetValid = true,
            catForm = true,
            notStealthed = true,
            optionKey = "use_rip",
            extraConditions = {
                T.Not(T.TargetClassification("boss")),
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
        -- Ferocious Bite – execute when target will die.
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
        -- Ferocious Bite – Bite Weave: 5 CP with Rip healthy.
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

        -- ── CAT DEBUFF UPKEEP ─────────────────────────────────────
        -- Mangle (Cat) refresh before debuff drops.
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

        -- ── CAT BUILDERS ──────────────────────────────────────────
        -- Rake – filler bleed when CP < 5 and DoT missing.
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
        shred,   -- Shred (behind target)
        mangle,  -- Mangle (Cat) when has aggro or Shred unavailable

        -- ── POWER MANAGEMENT ──────────────────────────────────────
        -- Powershift when energy is too low for next ability.
        T.PowershiftEntry({
            key = "Cat Form",
            optionKey = "use_powershift",
            minManaKey = "powershift_min_mana_pct",
        }),
    }
end

-- ── MAGE ROTATION BUILDERS ─────────────────────────────────────

function T.BuildArcaneMageRotation(spec)
    return {
        -- ── COOLDOWN STACKING (AP + IV together for max burst) ─────
        -- Arcane Power: primary DPS cooldown, stack with Icy Veins
        T.SpellEntry({
            key = "Arcane Power",
            spellKey = "Arcane Power",
            optionKey = "use_arcane_power",
            inCombat = true,
            targetValid = true,
            cooldownSpellKey = "Arcane Power",
            classificationSetting = "arcane_power_classification",
            offensive = false,
        }),
        -- Icy Veins: stack with Arcane Power for maximum haste + damage
        T.SpellEntry({
            key = "Icy Veins",
            spellKey = "Icy Veins",
            optionKey = "use_icy_veins",
            inCombat = true,
            targetValid = true,
            cooldownSpellKey = "Icy Veins",
            classificationSetting = "icy_veins_classification",
            offensive = false,
        }),
        -- Cold Snap: reset Icy Veins cooldown for double IV usage
        T.SpellEntry({
            key = "Cold Snap",
            spellKey = "Cold Snap",
            optionKey = "use_cold_snap",
            inCombat = true,
            cooldownSpellKey = "Cold Snap",
            classificationSetting = "cold_snap_classification",
            offensive = false,
            extraConditions = {
                -- Use when Icy Veins is off cooldown to double IV (confirmed by logs)
                T.CooldownReady("Icy Veins"),
            },
        }),

        -- ── ARCANE BLAST: Pure spam rotation (no regen phase in raids) ───
        -- Top parsing players cast Arcane Blast continuously throughout entire fight.
        -- Mana is sustained by external sources (Vampiric Touch, Mana Spring Totem, Innervate).
        T.SpellEntry({
            key = "Arcane Blast",
            spellKey = "Arcane Blast",
            targetValid = true,
            explicitPriority = 100,
            extraConditions = {
                T.NotIsMoving(),
            },
        }),

        -- ── MOVEMENT / INSTANT CASTS ──────────────────────────────
        -- Presence of Mind: use during cooldowns for instant AB cast (confirmed by logs)
        T.SpellEntry({
            key = "Presence of Mind",
            spellKey = "Presence of Mind",
            optionKey = "use_presence_of_mind",
            inCombat = true,
            cooldownSpellKey = "Presence of Mind",
            classificationSetting = "presence_of_mind_classification",
            offensive = false,
            extraConditions = {
                T.AnyOf({
                    -- During damage cooldowns for burst (primary usage per logs)
                    T.BuffStacks("Arcane Power", ">=", 1),
                    T.BuffStacks("Icy Veins", ">=", 1),
                    -- While moving or finishing targets
                    T.IsMoving(),
                    T.StateCompare("target_hp_pct", "<", 5),
                }),
            },
        }),
        -- Fire Blast as instant-cast movement filler (no travel time)
        T.MovementFillerEntry({
            key = "Fire Blast",
            spellKey = "Fire Blast",
            targetValid = true,
            inCombat = true,
            cooldownSpellKey = "Fire Blast",
            optionKey = "use_fire_blast",
            entryOpts = { isFiller = true, isInstant = true },
        }),

        -- ── AoE: Arcane Explosion (core AoE spell) ────────────────
        T.SpellEntry({
            key = "Arcane Explosion",
            spellKey = "Arcane Explosion",
            targetValid = true,
            inCombat = true,
            extraConditions = {
                -- Multiple targets present
                T.GroupSizeGte(3),
            },
        }),

        -- ── MANA MANAGEMENT ───────────────────────────────────────
        -- Evocation: out-of-combat mana regeneration
        T.SpellEntry({
            key = "Evocation",
            spellKey = "Evocation",
            optionKey = "use_evocation",
            notInCombat = true,
            cooldownSpellKey = "Evocation",
            classificationSetting = "evocation_classification",
            offensive = false,
            extraConditions = {
                T.StateCompare("player_mana_pct", "<", "evocationManaPct"),
            },
        }),
        -- Mana Sapphire (conjured gem) for mana recovery during combat
        T.SpellEntry({
            key = "Mana Sapphire",
            spellKey = "Mana Sapphire",
            optionKey = "use_mana_sapphire",
            inCombat = true,
            extraConditions = {
                T.StateCompare("player_mana_pct", "<", "manaGemManaPct"),
            },
        }),

        -- ── CONSUMABLES ───────────────────────────────────────────
        T.SpellEntry({
            key = "POTION",
            spellKey = "POTION",
            optionKey = "suggestPot",
            targetValid = false,
            itemKey = "selectedPotionItem",
            extraConditions = {
                T.StateCompare("player_mana_pct", "<", "potManaThreshold"),
            },
        }),
        T.SpellEntry({
            key = "RUNE",
            spellKey = "RUNE",
            optionKey = "suggestRune",
            targetValid = false,
            itemKey = "selectedRuneItem",
            extraConditions = {
                T.StateCompare("player_mana_pct", "<", "runeManaThreshold"),
            },
        }),

        -- ── ON-USE TRINKETS (stack with cooldowns) ────────────────
        T.SpellEntry({
            key = "TRINKET1",
            targetValid = true,
            optionKey = "use_trinket_1",
            extraConditions = {
                T.TrinketReady(13),
                T.ClassificationFromAnyTarget("trinket_1_classification"),
                -- Use during cooldown stacking window (confirmed by logs)
                T.AnyOf({
                    T.BuffStacks("Arcane Power", ">=", 1),
                    T.BuffStacks("Icy Veins", ">=", 1),
                }),
            },
        }),
        T.SpellEntry({
            key = "TRINKET2",
            targetValid = true,
            optionKey = "use_trinket_2",
            extraConditions = {
                T.TrinketReady(14),
                T.ClassificationFromAnyTarget("trinket_2_classification"),
                T.AnyOf({
                    T.BuffStacks("Arcane Power", ">=", 1),
                    T.BuffStacks("Icy Veins", ">=", 1),
                }),
            },
        }),
    }
end

function T.BuildFireMageRotation(spec)
    return {
        -- ── PRE-COMBAT: Scorch spam for Fire Vulnerability stacks ───
        -- Top parsing players open with 5x Scorch to build max Vulnerability stacks
        -- BEFORE using any cooldowns (confirmed by logs). This provides 25% damage increase.
        T.SpellEntry({
            key = "Scorch",
            spellKey = "Scorch",
            optionKey = "use_scorch",
            notInCombat = true,
            targetValid = true,
            explicitPriority = 100,
            extraConditions = {
                -- Build Vulnerability stacks before engaging (Scorch applies Improved Scorch debuff)
                T.DotMissing("Scorch"),
            },
        }),

        -- ── COOLDOWN STACKING: Combustion + IV together for max burst ───
        -- Combustion: use with Icy Veins and trinkets stacked (confirmed by logs)
        T.SpellEntry({
            key = "Combustion",
            spellKey = "Combustion",
            optionKey = "use_combustion",
            targetValid = true,
            inCombat = true,
            cooldownSpellKey = "Combustion",
            classificationSetting = "combustion_classification",
            offensive = false,
        }),
        -- Icy Veins: stack with Combustion for maximum haste + damage
        T.SpellEntry({
            key = "Icy Veins",
            spellKey = "Icy Veins",
            optionKey = "use_icy_veins",
            inCombat = true,
            targetValid = true,
            cooldownSpellKey = "Icy Veins",
            classificationSetting = "icy_veins_classification",
            offensive = false,
        }),

        -- ── VULNERABILITY MAINTENANCE: Scorch debuff tracking ──────
        -- Scorch when Fire Vulnerability is missing or about to expire (maintain 25% damage increase)
        T.SpellEntry({
            key = "Scorch",
            spellKey = "Scorch",
            optionKey = "use_scorch",
            targetValid = true,
            explicitPriority = 90,
            extraConditions = {
                T.NotIsMoving(),
                -- Vulnerability debuff missing or expiring soon (maintain Improved Scorch stacks)
                T.AnyOf({
                    T.DotMissing("Scorch"),
                    T.DebuffTimeLeftLt("Scorch", 3),
                }),
            },
        }),

        -- ── MAIN ROTATION: Fireball spam ───────────────────────────
        -- Continuous Fireball casting throughout fight (confirmed by logs).
        -- No filler spells needed - just pure Fireball spam.
        T.SpellEntry({
            key = "Fireball",
            spellKey = "Fireball",
            targetValid = true,
            explicitPriority = 50,
            extraConditions = {
                T.NotIsMoving(),
            },
        }),

        -- ── MOVEMENT / INSTANT CASTS ───────────────────────────────
        -- Fire Blast as instant-cast movement filler (cooldown-based spell)
        T.MovementFillerEntry({
            key = "Fire Blast",
            spellKey = "Fire Blast",
            targetValid = true,
            inCombat = true,
            cooldownSpellKey = "Fire Blast",
            optionKey = "use_fire_blast",
            entryOpts = { isFiller = true, isInstant = true },
        }),
        -- Scorch as movement filler (instant cast)
        T.MovementFillerEntry({
            key = "Scorch",
            spellKey = "Scorch",
            targetValid = true,
            inCombat = true,
            optionKey = "use_scorch",
            entryOpts = { isFiller = true, repeatLimit = 2 },
        }),

        -- ── AoE: Flamestrike for multiple targets ─────────────────
        T.SpellEntry({
            key = "Flamestrike",
            spellKey = "Flamestrike",
            targetValid = true,
            inCombat = true,
            optionKey = "use_flamestrike",
            extraConditions = {
                -- Multiple targets present
                T.GroupSizeGte(3),
            },
        }),

        -- ── CONSUMABLES ───────────────────────────────────────────
        T.SpellEntry({
            key = "POTION",
            spellKey = "POTION",
            optionKey = "suggestPot",
            targetValid = false,
            itemKey = "selectedPotionItem",
            extraConditions = {
                T.StateCompare("player_mana_pct", "<", "potManaThreshold"),
            },
        }),
        T.SpellEntry({
            key = "RUNE",
            spellKey = "RUNE",
            optionKey = "suggestRune",
            targetValid = false,
            itemKey = "selectedRuneItem",
            extraConditions = {
                T.StateCompare("player_mana_pct", "<", "runeManaThreshold"),
            },
        }),

        -- ── ON-USE TRINKETS (stack with Combustion + IV) ────────────
        T.SpellEntry({
            key = "TRINKET1",
            targetValid = true,
            optionKey = "use_trinket_1",
            extraConditions = {
                T.TrinketReady(13),
                T.ClassificationFromAnyTarget("trinket_1_classification"),
                -- Use during Combustion + IV window for maximum damage (confirmed by logs)
                T.AnyOf({
                    T.BuffStacks("Combustion", ">=", 1),
                    T.BuffStacks("Icy Veins", ">=", 1),
                }),
            },
        }),
        T.SpellEntry({
            key = "TRINKET2",
            targetValid = true,
            optionKey = "use_trinket_2",
            extraConditions = {
                T.TrinketReady(14),
                T.ClassificationFromAnyTarget("trinket_2_classification"),
                T.AnyOf({
                    T.BuffStacks("Combustion", ">=", 1),
                    T.BuffStacks("Icy Veins", ">=", 1),
                }),
            },
        }),
    }
end

function T.BuildFrostMageRotation(spec)
    return {
        -- ── WATER ELEMENTAL: Summon during fight (not pre-combat) ───
        -- Logs show Water Elemental summoned mid-fight, not pre-pull.
        T.SpellEntry({
            key = "Summon Water Elemental",
            spellKey = "Summon Water Elemental",
            optionKey = "use_water_elemental",
            inCombat = true,
            cooldownSpellKey = "Summon Water Elemental",
            classificationSetting = "summon_water_elemental_classification",
            offensive = false,
        }),

        -- ── COOLDOWN STACKING: IV + Cold Snap for double haste ────
        -- Icy Veins: primary DPS cooldown (haste + spell power)
        T.SpellEntry({
            key = "Icy Veins",
            spellKey = "Icy Veins",
            optionKey = "use_icy_veins",
            inCombat = true,
            targetValid = true,
            cooldownSpellKey = "Icy Veins",
            classificationSetting = "icy_veins_classification",
            offensive = false,
        }),
        -- Cold Snap: reset Icy Veins for double IV usage
        T.SpellEntry({
            key = "Cold Snap",
            spellKey = "Cold Snap",
            optionKey = "use_cold_snap",
            inCombat = true,
            cooldownSpellKey = "Cold Snap",
            classificationSetting = "cold_snap_classification",
            offensive = false,
            extraConditions = {
                -- Use when Icy Veins is off cooldown to double IV
                T.CooldownReady("Icy Veins"),
            },
        }),

        -- ── MAIN ROTATION: Frostbolt spam (pure rotation per logs) ───
        -- Continuous Frostbolt casting throughout fight. Top parsing players use
        -- pure Frostbolt spam with no Ice Lance priority - Winter's Chill debuff is maintained
        -- naturally through Frostbolt casts. Clearcasting procs are used for instant Frostbolts.
        T.SpellEntry({
            key = "Frostbolt",
            spellKey = "Frostbolt",
            targetValid = true,
            explicitPriority = 50,
            extraConditions = {
                T.NotIsMoving(),
            },
        }),

        -- ── MOVEMENT / INSTANT CASTS ──────────────────────────────
        -- Ice Lance as movement filler only (instant cast)
        T.MovementFillerEntry({
            key = "Ice Lance",
            spellKey = "Ice Lance",
            targetValid = true,
            inCombat = true,
            optionKey = "use_ice_lance",
            entryOpts = { isFiller = true, repeatLimit = 2 },
        }),

        -- ── AoE: Blizzard for multiple targets ────────────────────
        T.SpellEntry({
            key = "Blizzard",
            spellKey = "Blizzard",
            targetValid = true,
            inCombat = true,
            optionKey = "use_blizzard",
            extraConditions = {
                -- Multiple targets present
                T.GroupSizeGte(3),
            },
        }),

        -- ── CONSUMABLES ───────────────────────────────────────────
        T.SpellEntry({
            key = "POTION",
            spellKey = "POTION",
            optionKey = "suggestPot",
            targetValid = false,
            itemKey = "selectedPotionItem",
            extraConditions = {
                T.StateCompare("player_mana_pct", "<", "potManaThreshold"),
            },
        }),
        T.SpellEntry({
            key = "RUNE",
            spellKey = "RUNE",
            optionKey = "suggestRune",
            targetValid = false,
            itemKey = "selectedRuneItem",
            extraConditions = {
                T.StateCompare("player_mana_pct", "<", "runeManaThreshold"),
            },
        }),

        -- ── ON-USE TRINKETS (stack with Icy Veins) ────────────────
        T.SpellEntry({
            key = "TRINKET1",
            targetValid = true,
            optionKey = "use_trinket_1",
            extraConditions = {
                T.TrinketReady(13),
                T.ClassificationFromAnyTarget("trinket_1_classification"),
                -- Use during Icy Veins window for maximum damage (confirmed by logs)
                T.BuffStacks("Icy Veins", ">=", 1),
            },
        }),
        T.SpellEntry({
            key = "TRINKET2",
            targetValid = true,
            optionKey = "use_trinket_2",
            extraConditions = {
                T.TrinketReady(14),
                T.ClassificationFromAnyTarget("trinket_2_classification"),
                T.BuffStacks("Icy Veins", ">=", 1),
            },
        }),
    }
end

-- ── WARLOCK ROTATION BUILDERS ──────────────────────────────────

function T.BuildAfflictionWarlockRotation(spec)
    return {
        -- ── CURSES ──────────────────────────────────────────────────
        -- Curse of Agony: the Affliction DPS curse.  Highest curse priority;
        -- fires when CoE/CoD are disabled or not assigned.
        -- Non-ticking debuff - use direct debuff_property_compare (not DotRefreshEntry)
        T.SpellEntry({
            key = "Curse of Agony",
            spellKey = "Curse of Agony",
            optionKey = "use_curse_of_agony",
            targetValid = true,
            cooldownSpellKey = "Curse of Agony",
            extraConditions = {
                T.TargetTtdGte(8),
                -- Refresh when debuff missing or expiring soon (any source)
                T.DebuffPropertyCompare("Curse of Agony", "any", "remaining", "<", "coaRefreshSeconds"),
                -- Don't overwrite our own other curses (per-warlock curse slot: each lock has one curse per target)
                T.AllOf({
                    T.Not(T.PlayerHasDebuff("Curse of Elements")),
                    T.Not(T.PlayerHasDebuff("Curse of Doom")),
                    T.Not(T.PlayerHasDebuff("Curse of Tongues")),
                    T.Not(T.PlayerHasDebuff("Curse of Weakness")),
                }),
            },
        }),
        -- Curse of Elements: assigned raid debuff / utility (opt-in).
        T.SpellEntry({
            key = "Curse of Elements",
            spellKey = "Curse of Elements",
            optionKey = "use_curse_of_elements",
            targetValid = true,
            cooldownSpellKey = "Curse of Elements",
            extraConditions = {
                T.TargetTtdGte(12),
                -- Refresh when debuff missing or expiring soon (any source)
                T.DebuffPropertyCompare("Curse of Elements", "any", "remaining", "<", "coeRefreshSeconds"),
                -- Don't overwrite our own other curses (per-warlock curse slot: each lock has one curse per target)
                T.AllOf({
                    T.Not(T.PlayerHasDebuff("Curse of Agony")),
                    T.Not(T.PlayerHasDebuff("Curse of Doom")),
                    T.Not(T.PlayerHasDebuff("Curse of Tongues")),
                    T.Not(T.PlayerHasDebuff("Curse of Weakness")),
                }),
            },
        }),
        -- Curse of Doom: optional on very long fights.
        T.SpellEntry({
            key = "Curse of Doom",
            spellKey = "Curse of Doom",
            optionKey = "use_curse_of_doom",
            targetValid = true,
            cooldownSpellKey = "Curse of Doom",
            extraConditions = {
                T.TargetTtdGte(60),
                -- Refresh when debuff missing or expiring soon (any source)
                T.DebuffPropertyCompare("Curse of Doom", "any", "remaining", "<", "codRefreshSeconds"),
                -- Don't overwrite our own other curses (per-warlock curse slot: each lock has one curse per target)
                T.AllOf({
                    T.Not(T.PlayerHasDebuff("Curse of Agony")),
                    T.Not(T.PlayerHasDebuff("Curse of Elements")),
                    T.Not(T.PlayerHasDebuff("Curse of Tongues")),
                    T.Not(T.PlayerHasDebuff("Curse of Weakness")),
                }),
            },
        }),

        -- ── DoTs ────────────────────────────────────────────────────
        -- Unstable Affliction: highest-priority DoT (dispels punished, big damage).
        T.DotRefreshEntry({ key = "Unstable Affliction", spellKey = "Unstable Affliction", optionKey = "use_unstable_affliction", targetValid = true, minTTDKey = 12 }),
        -- Siphon Life: sustained DoT + self-healing.
        T.DotRefreshEntry({ key = "Siphon Life", spellKey = "Siphon Life", optionKey = "use_siphon_life", targetValid = true, minTTDKey = 12 }),
        -- Corruption: cheapest DoT, maintain on all valid targets.
        T.DotRefreshEntry{ key = "Corruption", spellKey = "Corruption", targetValid = true, minTTDKey = 8, maxTargetsKey = "multidotMaxCorruption" },

        -- ── FILLER / UTILITY ────────────────────────────────────────
        T.SpellEntry{ key = "Shadow Bolt", spellKey = "Shadow Bolt", targetValid = true, extraConditions = { T.NotIsMoving() } },
        T.MovementFillerEntry{ key = "Death Coil", targetValid = true, inCombat = true, optionKey = "use_death_coil", cooldownSpellKey = "Death Coil", entryOpts = { isFiller = true, isInstant = true } },
        T.MovementFillerEntry{ key = "Corruption", targetValid = true, inCombat = true, extraConditions = { T.DotMissing("Corruption") }, entryOpts = { isFiller = true, repeatLimit = 1 } },
        T.SpellEntry{ key = "Life Tap", spellKey = "Life Tap", optionKey = "use_life_tap", extraConditions = { T.StateCompare("player_mana_pct", "<", "lifeTapManaPct") } },
        T.SpellEntry{ key = "POTION", spellKey = "POTION", optionKey = "suggestPot", targetValid = false, itemKey = "selectedPotionItem", extraConditions = { T.StateCompare("player_mana_pct", "<", "potManaThreshold") } },
        T.SpellEntry{ key = "RUNE", spellKey = "RUNE", optionKey = "suggestRune", targetValid = false, itemKey = "selectedRuneItem", extraConditions = { T.StateCompare("player_mana_pct", "<", "runeManaThreshold") } },
        -- On-use trinkets.
        T.SpellEntry({
            key = "TRINKET1",
            targetValid = true,
            optionKey = "use_trinket_1",
            extraConditions = {
                T.TrinketReady(13),
                T.ClassificationFromAnyTarget("trinket_1_classification"),
            },
        }),
        T.SpellEntry({
            key = "TRINKET2",
            targetValid = true,
            optionKey = "use_trinket_2",
            extraConditions = {
                T.TrinketReady(14),
                T.ClassificationFromAnyTarget("trinket_2_classification"),
            },
        }),
    }
end

function T.BuildDemonologyWarlockRotation(spec)
    return {
        -- ── PRE-COMBAT / FORMS ────────────────────────────────────────
        -- Demonic Sacrifice: optional pre-combat shadow damage buff.
        -- Only used when explicitly enabled; most Demo players keep Felguard alive for DPS.
        T.SpellEntry({
        key = "Demonic Sacrifice",
        spellKey = "Demonic Sacrifice",
        optionKey = "use_demonic_sacrifice",
        precombat = true,
        extraConditions = {
            T.Not(T.PetAlive()),
        },
    }),

    -- ── MAJOR COOLDOWNS ───────────────────────────────────────────
    -- Note: Metamorphosis is NOT a TBC spell (added in Cataclysm). No equivalent burst CD in TBC Demo.

    -- ── CURSES ────────────────────────────────────────────────────
    -- Curse of Agony: the Demonology damage curse (default). One curse per target.
    T.SpellEntry({
        key = "Curse of Agony",
        spellKey = "Curse of Agony",
        optionKey = "use_curse_of_agony",
        targetValid = true,
        cooldownSpellKey = "Curse of Agony",
        extraConditions = {
            T.TargetTtdGte(8),
            -- Refresh when debuff missing or expiring soon (any source)
            T.DebuffPropertyCompare("Curse of Agony", "any", "remaining", "<", "coaRefreshSeconds"),
            -- Don't overwrite our own other curses (per-warlock curse slot: each lock has one curse per target)
            T.AllOf({
                T.Not(T.PlayerHasDebuff("Curse of Elements")),
                T.Not(T.PlayerHasDebuff("Curse of Doom")),
                T.Not(T.PlayerHasDebuff("Curse of Tongues")),
                T.Not(T.PlayerHasDebuff("Curse of Weakness")),
            }),
        },
    }),

    -- Curse of Doom: highest priority on long fights (>60s TTD). Let expire before reapplying.
    -- Non-ticking debuff - use direct debuff_property_compare (not DotRefreshEntry)
    T.SpellEntry({
        key = "Curse of Doom",
        spellKey = "Curse of Doom",
        optionKey = "use_curse_of_doom",
        targetValid = true,
        cooldownSpellKey = "Curse of Doom",
        extraConditions = {
            T.TargetTtdGte(60),
            -- Refresh when debuff missing or expiring soon (any source)
            T.DebuffPropertyCompare("Curse of Doom", "any", "remaining", "<", "codRefreshSeconds"),
            -- Don't overwrite our own other curses (per-warlock curse slot: each lock has one curse per target)
            T.AllOf({
                T.Not(T.PlayerHasDebuff("Curse of Agony")),
                T.Not(T.PlayerHasDebuff("Curse of Elements")),
                T.Not(T.PlayerHasDebuff("Curse of Tongues")),
                T.Not(T.PlayerHasDebuff("Curse of Weakness")),
            }),
        },
    }),

    -- Curse of Elements: assigned raid debuff or default on shorter fights.
    -- Non-ticking debuff - use direct debuff_property_compare (not DotRefreshEntry)
    T.SpellEntry({
        key = "Curse of Elements",
        spellKey = "Curse of Elements",
        optionKey = "use_curse_of_elements",
        targetValid = true,
        cooldownSpellKey = "Curse of Elements",
        extraConditions = {
            T.TargetTtdGte(12),
            -- Refresh when debuff missing or expiring soon (any source)
            T.DebuffPropertyCompare("Curse of Elements", "any", "remaining", "<", "coeRefreshSeconds"),
            -- Don't overwrite our own other curses (per-warlock curse slot: each lock has one curse per target)
            T.AllOf({
                T.Not(T.PlayerHasDebuff("Curse of Agony")),
                T.Not(T.PlayerHasDebuff("Curse of Doom")),
                T.Not(T.PlayerHasDebuff("Curse of Tongues")),
                T.Not(T.PlayerHasDebuff("Curse of Weakness")),
            }),
        },
    }),

    -- ── DoTs ──────────────────────────────────────────────────────
    -- Corruption: maintain on all valid targets. Demo talents reduce mana cost significantly.
    T.DotRefreshEntry({
        key = "Corruption",
        spellKey = "Corruption",
        targetValid = true,
        minTTDKey = 8,
        maxTargetsKey = "multidotMaxCorruption",
    }),

    -- Immolate: secondary DoT. Let expire before reapplying (Demo reduces cost).
    T.DotRefreshEntry({
        key = "Immolate",
        spellKey = "Immolate",
        optionKey = "use_immolate",
        targetValid = true,
        minTTDKey = 8,
    }),

    -- ── EXECUTE PHASE ─────────────────────────────────────────────
    -- Shadowburn: execute below 20% HP. High priority when available.
    T.SpellEntry({
        key = "Shadowburn",
        spellKey = "Shadowburn",
        optionKey = "use_shadowburn",
        targetValid = true,
        cooldownSpellKey = "Shadowburn",
        extraConditions = {
            T.StateCompare("target_hp_pct", "<", 20),
        },
    }),

    -- ── SELF-HEALING ──────────────────────────────────────────────
    -- Drain Life: channel to heal yourself when low on health. Heals for 15% of damage dealt.
    T.SpellEntry({
        key = "Drain Life",
        spellKey = "Drain Life",
        optionKey = "use_drain_life",
        targetValid = true,
        inCombat = true,
        extraConditions = {
            -- Only suggest when player HP is low (self-heal)
            T.StateCompare("player_hp_pct", "<", "drainLifeHpPct"),
        },
    }),

    -- ── AoE ROTATION ──────────────────────────────────────────────
    -- Note: Seed of Corruption is NOT a TBC spell (added in WotLK).
    -- Hellfire is the primary AoE tool for Demo in TBC.
    T.SpellEntry({
        key = "Hellfire",
        spellKey = "Hellfire",
        optionKey = "use_hellfire",
        targetValid = true,
        inCombat = true,
        cooldownSpellKey = "Hellfire",
        extraConditions = {
            T.StateCompare("tracked_target_count", ">=", 3),
        },
    }),

    -- ── PRIMARY FILLER ────────────────────────────────────────────
    -- Shadow Bolt: main damage spell when standing still.
    T.SpellEntry({
        key = "Shadow Bolt",
        spellKey = "Shadow Bolt",
        targetValid = true,
        extraConditions = {
            T.NotIsMoving(),
        },
    }),

    -- ── MOVEMENT FILLERS ──────────────────────────────────────────
    -- Death Coil: instant damage while moving, also heals pet and restores mana.
    T.MovementFillerEntry({
        key = "Death Coil",
        targetValid = true,
        inCombat = true,
        optionKey = "use_death_coil",
        cooldownSpellKey = "Death Coil",
        extraConditions = {
            T.AnyOf({
                T.IsMoving(),
                T.StateCompare("player_mana_pct", "<", "deathCoilManaPct"),
            }),
        },
        entryOpts = { isFiller = true, isInstant = true },
    }),

    -- Corruption while moving if missing (emergency apply).
    T.MovementFillerEntry({
        key = "Corruption",
        targetValid = true,
        inCombat = true,
        extraConditions = {
            T.DotMissing("Corruption"),
        },
        entryOpts = { isFiller = true, repeatLimit = 1 },
    }),

    -- Immolate while moving if missing (emergency apply).
    T.MovementFillerEntry({
        key = "Immolate",
        targetValid = true,
        inCombat = true,
        optionKey = "use_immolate",
        extraConditions = {
            T.DotMissing("Immolate"),
        },
        entryOpts = { isFiller = true, repeatLimit = 1 },
    }),

    -- ── MANA MANAGEMENT ───────────────────────────────────────────
    -- Life Tap: convert health to mana when critically low.
    T.SpellEntry({
        key = "Life Tap",
        spellKey = "Life Tap",
        optionKey = "use_life_tap",
        extraConditions = {
            T.StateCompare("player_mana_pct", "<", "lifeTapManaPct"),
        },
    }),

    -- ── CONSUMABLES ───────────────────────────────────────────────
    T.SpellEntry({
        key = "POTION",
        spellKey = "POTION",
        optionKey = "suggestPot",
        targetValid = false,
        itemKey = "selectedPotionItem",
        extraConditions = {
            T.StateCompare("player_mana_pct", "<", "potManaThreshold"),
        },
    }),

    T.SpellEntry({
        key = "RUNE",
        spellKey = "RUNE",
        optionKey = "suggestRune",
        targetValid = false,
        itemKey = "selectedRuneItem",
        extraConditions = {
            T.StateCompare("player_mana_pct", "<", "runeManaThreshold"),
        },
    }),

    -- ── ON-USE TRINKETS ───────────────────────────────────────────
    T.SpellEntry({
        key = "TRINKET1",
        targetValid = true,
        optionKey = "use_trinket_1",
        extraConditions = {
            T.TrinketReady(13),
            T.ClassificationFromAnyTarget("trinket_1_classification"),
        },
    }),

    T.SpellEntry({
        key = "TRINKET2",
        targetValid = true,
        optionKey = "use_trinket_2",
        extraConditions = {
            T.TrinketReady(14),
            T.ClassificationFromAnyTarget("trinket_2_classification"),
        },
    }),
}
end

function T.BuildDestructionWarlockRotation(spec)
    return {
        T.SpellEntry{ key = "Shadowburn", spellKey = "Shadowburn", optionKey = "use_shadowburn", targetValid = true, cooldownSpellKey = "Shadowburn" },
        T.SpellEntry{ key = "Soul Fire", spellKey = "Soul Fire", optionKey = "use_soul_fire", targetValid = true, cooldownSpellKey = "Soul Fire" },
        -- CoD on every pull for threat; 20s minimum ensures it's not wasted on trivial mobs but applies to all real encounters
        -- Non-ticking debuff - use direct debuff_property_compare (not DotRefreshEntry)
        T.SpellEntry({
            key = "Curse of Doom",
            spellKey = "Curse of Doom",
            optionKey = "use_curse_of_doom",
            targetValid = true,
            cooldownSpellKey = "Curse of Doom",
            extraConditions = {
                T.TargetTtdGte(20),
                -- Refresh when debuff missing or expiring soon (any source)
                T.DebuffPropertyCompare("Curse of Doom", "any", "remaining", "<", "codRefreshSeconds"),
                -- Don't overwrite our own other curses (per-warlock curse slot: each lock has one curse per target)
                T.AllOf({
                    T.Not(T.PlayerHasDebuff("Curse of Agony")),
                    T.Not(T.PlayerHasDebuff("Curse of Elements")),
                    T.Not(T.PlayerHasDebuff("Curse of Tongues")),
                    T.Not(T.PlayerHasDebuff("Curse of Weakness")),
                }),
            },
        }),
        T.DotRefreshEntry{ key = "Immolate", spellKey = "Immolate", targetValid = true, minTTDKey = 8 },
        T.DotRefreshEntry{ key = "Corruption", spellKey = "Corruption", targetValid = true, minTTDKey = 8, maxTargetsKey = "multidotMaxCorruption" },
        T.SpellEntry{ key = "Shadow Bolt", spellKey = "Shadow Bolt", targetValid = true, extraConditions = { T.NotIsMoving() } },
        T.SpellEntry{ key = "Incinerate", spellKey = "Incinerate", optionKey = "use_incinerate", targetValid = true, extraConditions = { T.TargetTtdGte("incinerateMinTTD"), T.NotIsMoving() } },
        -- Conflagrate only while moving (saving cooldown to prevent clipping Immolate)
        T.MovementFillerEntry{ key = "Conflagrate", targetValid = true, inCombat = true, cooldownSpellKey = "Conflagrate", entryOpts = { isFiller = true, isInstant = true } },
        T.MovementFillerEntry{ key = "Immolate", targetValid = true, inCombat = true, extraConditions = { T.DotMissing("Immolate") }, entryOpts = { isFiller = true, repeatLimit = 1 } },
        T.SpellEntry{ key = "Life Tap", spellKey = "Life Tap", optionKey = "use_life_tap", extraConditions = { T.StateCompare("player_mana_pct", "<", "lifeTapManaPct") } },
        T.SpellEntry{ key = "POTION", spellKey = "POTION", optionKey = "suggestPot", targetValid = false, itemKey = "selectedPotionItem", extraConditions = { T.StateCompare("player_mana_pct", "<", "potManaThreshold") } },
        T.SpellEntry{ key = "RUNE", spellKey = "RUNE", optionKey = "suggestRune", targetValid = false, itemKey = "selectedRuneItem", extraConditions = { T.StateCompare("player_mana_pct", "<", "runeManaThreshold") } },
        -- On-use trinkets.
        T.SpellEntry({
            key = "TRINKET1",
            targetValid = true,
            optionKey = "use_trinket_1",
            extraConditions = {
                T.TrinketReady(13),
                T.ClassificationFromAnyTarget("trinket_1_classification"),
            },
        }),
        T.SpellEntry({
            key = "TRINKET2",
            targetValid = true,
            optionKey = "use_trinket_2",
            extraConditions = {
                T.TrinketReady(14),
                T.ClassificationFromAnyTarget("trinket_2_classification"),
            },
        }),
    }
end

-- ── ROGUE ROTATION BUILDERS ────────────────────────────────────

function T.BuildAssassinationRogueRotation(spec)
    return {
        T.SpellEntry{ key = "Cold Blood", spellKey = "Cold Blood", optionKey = "use_cold_blood", inCombat = true, cooldownSpellKey = "Cold Blood", classificationSetting = "cold_blood_classification", offensive = false, extraConditions = { T.StateCompare("combo_points", ">=", 4) } },
        T.SpellEntry{ key = "Slice and Dice", spellKey = "Slice and Dice", optionKey = "use_slice_and_dice", targetValid = true, extraConditions = { T.StateCompare("combo_points", ">=", 1), T.Not(T.BuffStacks("Slice and Dice", ">", 0)) } },
        T.SpellEntry{ key = "Rupture", spellKey = "Rupture", optionKey = "use_rupture", targetValid = true, extraConditions = { T.StateCompare("combo_points", ">=", 4), T.TargetTtdGte("ruptureMinTTD") } },
        -- Note: Envenom is NOT a TBC spell (added in WotLK). Removed from rotation.
        T.SpellEntry{ key = "Expose Armor", spellKey = "Expose Armor", optionKey = "use_expose_armor", targetValid = true, extraConditions = { T.StateCompare("combo_points", ">=", 5), T.DebuffPropertyCompare("Expose Armor", "player", "remaining", "<", 4) } },
        -- Mutilate is the primary active ability in TBC Fresh Assassination (~9.5% damage vs SS ~2.6%)
        T.SpellEntry{ key = "Mutilate", spellKey = "Mutilate", optionKey = "use_mutilate", targetValid = true, extraConditions = { T.StateCompare("combo_points", "<", 5), T.ResourceGte(30) } },
        -- Sinister Strike: low priority filler in TBC Fresh Assassination (data shows ~2.6% damage, auto-attacks dominate at ~71%)
        T.SpellEntry{ key = "Sinister Strike", spellKey = "Sinister Strike", targetValid = true, extraConditions = { T.StateCompare("combo_points", "<", 5), T.ResourceGte(20) } },
        T.SpellEntry{ key = "Kick", spellKey = "Kick", optionKey = "use_kick", targetValid = true, cooldownSpellKey = "Kick", entryOpts = { isInterrupt = true } },
        T.SpellEntry{ key = "POTION", spellKey = "POTION", optionKey = "suggestPot", targetValid = false, itemKey = "selectedPotionItem" },
        -- On-use trinkets.
        T.SpellEntry({
            key = "TRINKET1",
            targetValid = true,
            optionKey = "use_trinket_1",
            extraConditions = {
                T.TrinketReady(13),
                T.ClassificationFromAnyTarget("trinket_1_classification"),
            },
        }),
        T.SpellEntry({
            key = "TRINKET2",
            targetValid = true,
            optionKey = "use_trinket_2",
            extraConditions = {
                T.TrinketReady(14),
                T.ClassificationFromAnyTarget("trinket_2_classification"),
            },
        }),
    }
end

function T.BuildCombatRogueRotation(spec)
    return {
        T.SpellEntry{ key = "Blade Flurry", spellKey = "Blade Flurry", optionKey = "use_blade_flurry", inCombat = true, cooldownSpellKey = "Blade Flurry", classificationSetting = "blade_flurry_classification", offensive = false },
        T.SpellEntry{ key = "Adrenaline Rush", spellKey = "Adrenaline Rush", optionKey = "use_adrenaline_rush", inCombat = true, cooldownSpellKey = "Adrenaline Rush", classificationSetting = "adrenaline_rush_classification", offensive = false },
        T.SpellEntry{ key = "Slice and Dice", spellKey = "Slice and Dice", optionKey = "use_slice_and_dice", targetValid = true, extraConditions = { T.StateCompare("combo_points", ">=", 1), T.Not(T.BuffStacks("Slice and Dice", ">", 0)) } },
        T.SpellEntry{ key = "Rupture", spellKey = "Rupture", optionKey = "use_rupture", targetValid = true, extraConditions = { T.StateCompare("combo_points", ">=", 4), T.TargetTtdGte("ruptureMinTTD") } },
        T.SpellEntry{ key = "Eviscerate", spellKey = "Eviscerate", targetValid = true, extraConditions = { T.StateCompare("combo_points", ">=", 5) } },
        T.SpellEntry{ key = "Expose Armor", spellKey = "Expose Armor", optionKey = "use_expose_armor", targetValid = true, extraConditions = { T.StateCompare("combo_points", ">=", 5), T.DebuffPropertyCompare("Expose Armor", "player", "remaining", "<", 4) } },
        T.SpellEntry{ key = "Sinister Strike", spellKey = "Sinister Strike", targetValid = true, extraConditions = { T.StateCompare("combo_points", "<", 5), T.ResourceGte(25) } },
        T.SpellEntry{ key = "Kick", spellKey = "Kick", optionKey = "use_kick", targetValid = true, cooldownSpellKey = "Kick", entryOpts = { isInterrupt = true } },
        T.SpellEntry{ key = "POTION", spellKey = "POTION", optionKey = "suggestPot", targetValid = false, itemKey = "selectedPotionItem" },
        -- On-use trinkets.
        T.SpellEntry({
            key = "TRINKET1",
            targetValid = true,
            optionKey = "use_trinket_1",
            extraConditions = {
                T.TrinketReady(13),
                T.ClassificationFromAnyTarget("trinket_1_classification"),
            },
        }),
        T.SpellEntry({
            key = "TRINKET2",
            targetValid = true,
            optionKey = "use_trinket_2",
            extraConditions = {
                T.TrinketReady(14),
                T.ClassificationFromAnyTarget("trinket_2_classification"),
            },
        }),
    }
end

function T.BuildSubtletyRogueRotation(spec)
    return {
        T.SpellEntry{ key = "Premeditation", spellKey = "Premeditation", optionKey = "use_premeditation", inCombat = true, targetValid = true, cooldownSpellKey = "Premeditation", classificationSetting = "premeditation_classification", offensive = false },
        T.SpellEntry{ key = "Slice and Dice", spellKey = "Slice and Dice", optionKey = "use_slice_and_dice", targetValid = true, extraConditions = { T.StateCompare("combo_points", ">=", 1), T.Not(T.BuffStacks("Slice and Dice", ">", 0)) } },
        T.SpellEntry{ key = "Rupture", spellKey = "Rupture", optionKey = "use_rupture", targetValid = true, extraConditions = { T.StateCompare("combo_points", ">=", 4), T.TargetTtdGte("ruptureMinTTD") } },
        T.SpellEntry{ key = "Eviscerate", spellKey = "Eviscerate", targetValid = true, extraConditions = { T.StateCompare("combo_points", ">=", 5) } },
        T.SpellEntry{ key = "Expose Armor", spellKey = "Expose Armor", optionKey = "use_expose_armor", targetValid = true, extraConditions = { T.StateCompare("combo_points", ">=", 5), T.DebuffPropertyCompare("Expose Armor", "player", "remaining", "<", 4) } },
        T.SpellEntry{ key = "Hemorrhage", spellKey = "Hemorrhage", optionKey = "use_hemorrhage", targetValid = true, behindTarget = true, extraConditions = { T.StateCompare("combo_points", "<", 5), T.ResourceGte(35) } },
        T.SpellEntry{ key = "Backstab", spellKey = "Backstab", targetValid = true, behindTarget = true, extraConditions = { T.StateCompare("combo_points", "<", 5), T.ResourceGte(60) } },
        T.SpellEntry{ key = "Sinister Strike", spellKey = "Sinister Strike", targetValid = true, extraConditions = { T.StateCompare("combo_points", "<", 5), T.ResourceGte(40) } },
        T.SpellEntry{ key = "Preparation", spellKey = "Preparation", optionKey = "use_preparation", inCombat = true, cooldownSpellKey = "Preparation", classificationSetting = "preparation_classification", offensive = false },
        T.SpellEntry{ key = "Vanish", spellKey = "Vanish", optionKey = "use_vanish", inCombat = true, cooldownSpellKey = "Vanish", classificationSetting = "vanish_classification", offensive = false },
        T.SpellEntry{ key = "Kick", spellKey = "Kick", optionKey = "use_kick", targetValid = true, cooldownSpellKey = "Kick", entryOpts = { isInterrupt = true } },
        T.SpellEntry{ key = "POTION", spellKey = "POTION", optionKey = "suggestPot", targetValid = false, itemKey = "selectedPotionItem" },
        -- On-use trinkets.
        T.SpellEntry({
            key = "TRINKET1",
            targetValid = true,
            optionKey = "use_trinket_1",
            extraConditions = {
                T.TrinketReady(13),
                T.ClassificationFromAnyTarget("trinket_1_classification"),
            },
        }),
        T.SpellEntry({
            key = "TRINKET2",
            targetValid = true,
            optionKey = "use_trinket_2",
            extraConditions = {
                T.TrinketReady(14),
                T.ClassificationFromAnyTarget("trinket_2_classification"),
            },
        }),
    }
end

function T.BuildArmsWarriorRotation(spec)
    return {
        T.SpellEntry{ key = "Death Wish", spellKey = "Death Wish", optionKey = "use_death_wish", cooldownSpellKey = "Death Wish", inCombat = true, targetValid = true, classificationSetting = "death_wish_classification", offensive = false },
        T.SpellEntry{ key = "Sweeping Strikes", spellKey = "Sweeping Strikes", optionKey = "use_sweeping_strikes", cooldownSpellKey = "Sweeping Strikes", inCombat = true, classificationSetting = "sweeping_strikes_classification", offensive = false },
        T.SpellEntry{ key = "Bloodrage", spellKey = "Bloodrage", optionKey = "use_bloodrage", cooldownSpellKey = "Bloodrage", inCombat = true },
        T.SpellEntry{ key = "Mortal Strike", spellKey = "Mortal Strike", targetValid = true, cooldownSpellKey = "Mortal Strike", extraConditions = { T.ResourceGte(30) } },
        T.SpellEntry{ key = "Rend", spellKey = "Rend", optionKey = "use_rend", targetValid = true, extraConditions = { T.DotMissing("Rend"), T.ResourceGte(10) } },
        T.SpellEntry{ key = "Overpower", spellKey = "Overpower", optionKey = "use_overpower", targetValid = true, extraConditions = { T.ResourceGte(5) } },
        T.SpellEntry{ key = "Slam", spellKey = "Slam", optionKey = "use_slam", targetValid = true, extraConditions = { T.NotIsMoving(), T.ResourceGte(15) } },
        T.SpellEntry{ key = "Whirlwind", spellKey = "Whirlwind", targetValid = true, cooldownSpellKey = "Whirlwind", extraConditions = { T.ResourceGte(25) } },
        T.SpellEntry{ key = "Execute", spellKey = "Execute", targetValid = true, extraConditions = { T.StateCompare("target_hp_pct", "<", 20), T.ResourceGte(15) } },
        T.SpellEntry{ key = "Heroic Strike", spellKey = "Heroic Strike", targetValid = true, extraConditions = { T.ResourceGte(30) } },
        T.SpellEntry{ key = "Battle Shout", spellKey = "Battle Shout", optionKey = "use_battle_shout", extraConditions = { T.Not(T.BuffStacks("Battle Shout", ">", 0)), T.ResourceGte(10) } },
        T.SpellEntry{ key = "Hamstring", spellKey = "Hamstring", optionKey = "use_hamstring", targetValid = true, extraConditions = { T.IsMoving(), T.ResourceGte(10) } },
        T.SpellEntry{ key = "Pummel", spellKey = "Pummel", optionKey = "use_pummel", targetValid = true, cooldownSpellKey = "Pummel", entryOpts = { isInterrupt = true } },
        -- On-use trinkets.
        T.SpellEntry({
            key = "TRINKET1",
            targetValid = true,
            optionKey = "use_trinket_1",
            extraConditions = {
                T.TrinketReady(13),
                T.ClassificationFromAnyTarget("trinket_1_classification"),
            },
        }),
        T.SpellEntry({
            key = "TRINKET2",
            targetValid = true,
            optionKey = "use_trinket_2",
            extraConditions = {
                T.TrinketReady(14),
                T.ClassificationFromAnyTarget("trinket_2_classification"),
            },
        }),
    }
end

function T.BuildFuryWarriorRotation(spec)
    return {
        T.SpellEntry{ key = "Death Wish", spellKey = "Death Wish", optionKey = "use_death_wish", cooldownSpellKey = "Death Wish", inCombat = true, targetValid = true, classificationSetting = "death_wish_classification", offensive = false },
        T.SpellEntry{ key = "Recklessness", spellKey = "Recklessness", optionKey = "use_recklessness", cooldownSpellKey = "Recklessness", inCombat = true, targetValid = true, classificationSetting = "recklessness_classification", offensive = false },
        T.SpellEntry{ key = "Bloodrage", spellKey = "Bloodrage", optionKey = "use_bloodrage", cooldownSpellKey = "Bloodrage", inCombat = true },
        T.SpellEntry{ key = "Berserker Rage", spellKey = "Berserker Rage", optionKey = "use_berserker_rage", cooldownSpellKey = "Berserker Rage", inCombat = true, extraConditions = { T.Not(T.BuffStacks("Berserker Rage", ">", 0)) } },
        T.SpellEntry{ key = "Bloodthirst", spellKey = "Bloodthirst", targetValid = true, cooldownSpellKey = "Bloodthirst", extraConditions = { T.ResourceGte(30) } },
        T.SpellEntry{ key = "Whirlwind", spellKey = "Whirlwind", targetValid = true, cooldownSpellKey = "Whirlwind", extraConditions = { T.ResourceGte(25) } },
        T.SpellEntry{ key = "Execute", spellKey = "Execute", targetValid = true, extraConditions = { T.StateCompare("target_hp_pct", "<", 20), T.ResourceGte(15) } },
        T.SpellEntry{ key = "Heroic Strike", spellKey = "Heroic Strike", targetValid = true, extraConditions = { T.ResourceGte(30) } },
        T.SpellEntry{ key = "Cleave", spellKey = "Cleave", optionKey = "use_cleave", targetValid = true, extraConditions = { T.ResourceGte(40) } },
        T.SpellEntry{ key = "Battle Shout", spellKey = "Battle Shout", optionKey = "use_battle_shout", extraConditions = { T.Not(T.BuffStacks("Battle Shout", ">", 0)), T.ResourceGte(10) } },
        T.SpellEntry{ key = "Hamstring", spellKey = "Hamstring", optionKey = "use_hamstring", targetValid = true, extraConditions = { T.IsMoving(), T.ResourceGte(10) } },
        T.SpellEntry{ key = "Pummel", spellKey = "Pummel", optionKey = "use_pummel", targetValid = true, cooldownSpellKey = "Pummel", entryOpts = { isInterrupt = true } },
        -- On-use trinkets.
        T.SpellEntry({
            key = "TRINKET1",
            targetValid = true,
            optionKey = "use_trinket_1",
            extraConditions = {
                T.TrinketReady(13),
                T.ClassificationFromAnyTarget("trinket_1_classification"),
            },
        }),
        T.SpellEntry({
            key = "TRINKET2",
            targetValid = true,
            optionKey = "use_trinket_2",
            extraConditions = {
                T.TrinketReady(14),
                T.ClassificationFromAnyTarget("trinket_2_classification"),
            },
        }),
    }
end

function T.BuildBeastMasteryHunterRotation(spec)
    return {
        T.SpellEntry{ key = "Misdirection", spellKey = "Misdirection", optionKey = "use_misdirection", cooldownSpellKey = "Misdirection", inCombat = true, extraConditions = { T.Not(T.BuffStacks("Misdirection", ">", 0)) } },
        T.SpellEntry{ key = "Hunter's Mark", spellKey = "Hunter's Mark", optionKey = "use_hunters_mark", targetValid = true, extraConditions = { T.ShouldApplyDebuff("Hunter's Mark") } },
        T.SpellEntry{ key = "Aspect of the Hawk", spellKey = "Aspect of the Hawk", optionKey = "use_aspect_hawk", extraConditions = { T.Not(T.BuffStacks("Aspect of the Hawk", ">", 0)) } },
        T.SpellEntry{ key = "Call Pet", spellKey = "Call Pet", optionKey = "use_call_pet", extraConditions = { T.Not(T.PetAlive()) } },
        T.SpellEntry{ key = "Bestial Wrath", spellKey = "Bestial Wrath", optionKey = "use_bestial_wrath", cooldownSpellKey = "Bestial Wrath", inCombat = true, targetValid = true, classificationSetting = "bestial_wrath_classification", offensive = false, extraConditions = { T.PetAlive() } },
        T.SpellEntry{ key = "Rapid Fire", spellKey = "Rapid Fire", optionKey = "use_rapid_fire", cooldownSpellKey = "Rapid Fire", inCombat = true, classificationSetting = "rapid_fire_classification", offensive = false },
        T.SpellEntry{ key = "Serpent Sting", spellKey = "Serpent Sting", optionKey = "use_serpent_sting", targetValid = true, extraConditions = { T.ShouldApplyDebuff("Serpent Sting") } },
        T.SpellEntry{ key = "Arcane Shot", spellKey = "Arcane Shot", optionKey = "use_arcane_shot", targetValid = true, extraConditions = { T.StateCompare("target_hp_pct", ">", 20) } },
        T.SpellEntry{ key = "Multi-Shot", spellKey = "Multi-Shot", optionKey = "use_multi_shot", targetValid = true, cooldownSpellKey = "Multi-Shot", extraConditions = { T.StateCompare("target_hp_pct", ">", 20) } },
        T.SpellEntry{ key = "Steady Shot", spellKey = "Steady Shot", targetValid = true, extraConditions = { T.NotIsMoving() } },
        T.SpellEntry{ key = "Serpent Sting", spellKey = "Serpent Sting", optionKey = "use_serpent_sting", targetValid = true, inCombat = true, extraConditions = { T.IsMoving(), T.ShouldApplyDebuff("Serpent Sting") }, entryOpts = { isFiller = true, repeatLimit = 1 } },
        -- On-use trinkets.
        T.SpellEntry({
            key = "TRINKET1",
            targetValid = true,
            optionKey = "use_trinket_1",
            extraConditions = {
                T.TrinketReady(13),
                T.ClassificationFromAnyTarget("trinket_1_classification"),
            },
        }),
        T.SpellEntry({
            key = "TRINKET2",
            targetValid = true,
            optionKey = "use_trinket_2",
            extraConditions = {
                T.TrinketReady(14),
                T.ClassificationFromAnyTarget("trinket_2_classification"),
            },
        }),
    }
end

function T.BuildMarksmanshipHunterRotation(spec)
    return {
        T.SpellEntry{ key = "Misdirection", spellKey = "Misdirection", optionKey = "use_misdirection", cooldownSpellKey = "Misdirection", inCombat = true, extraConditions = { T.Not(T.BuffStacks("Misdirection", ">", 0)) } },
        T.SpellEntry{ key = "Hunter's Mark", spellKey = "Hunter's Mark", optionKey = "use_hunters_mark", targetValid = true, extraConditions = { T.ShouldApplyDebuff("Hunter's Mark") } },
        T.SpellEntry{ key = "Aspect of the Hawk", spellKey = "Aspect of the Hawk", optionKey = "use_aspect_hawk", extraConditions = { T.Not(T.BuffStacks("Aspect of the Hawk", ">", 0)) } },
        T.SpellEntry{ key = "Call Pet", spellKey = "Call Pet", optionKey = "use_call_pet", extraConditions = { T.Not(T.PetAlive()) } },
        T.SpellEntry{ key = "Rapid Fire", spellKey = "Rapid Fire", optionKey = "use_rapid_fire", cooldownSpellKey = "Rapid Fire", inCombat = true, classificationSetting = "rapid_fire_classification", offensive = false },
        T.SpellEntry{ key = "Readiness", spellKey = "Readiness", optionKey = "use_readiness", cooldownSpellKey = "Readiness", inCombat = true, classificationSetting = "readiness_classification", offensive = false },
        -- Aimed Shot: very low usage in TBC Fresh MM (~0.1 CPM), keep as optional late priority
        T.SpellEntry{ key = "Serpent Sting", spellKey = "Serpent Sting", optionKey = "use_serpent_sting", targetValid = true, extraConditions = { T.ShouldApplyDebuff("Serpent Sting") } },
        T.SpellEntry{ key = "Arcane Shot", spellKey = "Arcane Shot", optionKey = "use_arcane_shot", targetValid = true, extraConditions = { T.StateCompare("target_hp_pct", ">", 20) } },
        T.SpellEntry{ key = "Multi-Shot", spellKey = "Multi-Shot", optionKey = "use_multi_shot", targetValid = true, cooldownSpellKey = "Multi-Shot", extraConditions = { T.StateCompare("target_hp_pct", ">", 20) } },
        T.SpellEntry{ key = "Steady Shot", spellKey = "Steady Shot", targetValid = true, extraConditions = { T.NotIsMoving() } },
        -- Aimed Shot moved after Steady Shot: not a priority in TBC Fresh MM (data shows ~0.1 CPM)
        T.SpellEntry{ key = "Aimed Shot", spellKey = "Aimed Shot", optionKey = "use_aimed_shot", cooldownSpellKey = "Aimed Shot", targetValid = true, extraConditions = { T.NotIsMoving() } },
        T.SpellEntry{ key = "Serpent Sting", spellKey = "Serpent Sting", optionKey = "use_serpent_sting", targetValid = true, inCombat = true, extraConditions = { T.IsMoving(), T.ShouldApplyDebuff("Serpent Sting") }, entryOpts = { isFiller = true, repeatLimit = 1 } },
        -- On-use trinkets.
        T.SpellEntry({
            key = "TRINKET1",
            targetValid = true,
            optionKey = "use_trinket_1",
            extraConditions = {
                T.TrinketReady(13),
                T.ClassificationFromAnyTarget("trinket_1_classification"),
            },
        }),
        T.SpellEntry({
            key = "TRINKET2",
            targetValid = true,
            optionKey = "use_trinket_2",
            extraConditions = {
                T.TrinketReady(14),
                T.ClassificationFromAnyTarget("trinket_2_classification"),
            },
        }),
    }
end

function T.BuildSurvivalHunterRotation(spec)
    return {
        T.SpellEntry{ key = "Misdirection", spellKey = "Misdirection", optionKey = "use_misdirection", cooldownSpellKey = "Misdirection", inCombat = true, extraConditions = { T.Not(T.BuffStacks("Misdirection", ">", 0)) } },
        T.SpellEntry{ key = "Hunter's Mark", spellKey = "Hunter's Mark", optionKey = "use_hunters_mark", targetValid = true, extraConditions = { T.ShouldApplyDebuff("Hunter's Mark") } },
        T.SpellEntry{ key = "Aspect of the Hawk", spellKey = "Aspect of the Hawk", optionKey = "use_aspect_hawk", extraConditions = { T.Not(T.BuffStacks("Aspect of the Hawk", ">", 0)) } },
        T.SpellEntry{ key = "Call Pet", spellKey = "Call Pet", optionKey = "use_call_pet", extraConditions = { T.Not(T.PetAlive()) } },
        T.SpellEntry{ key = "Rapid Fire", spellKey = "Rapid Fire", optionKey = "use_rapid_fire", cooldownSpellKey = "Rapid Fire", inCombat = true, classificationSetting = "rapid_fire_classification", offensive = false },
        T.SpellEntry{ key = "Explosive Shot", spellKey = "Explosive Shot", optionKey = "use_explosive_shot", cooldownSpellKey = "Explosive Shot", targetValid = true },
        T.SpellEntry{ key = "Serpent Sting", spellKey = "Serpent Sting", optionKey = "use_serpent_sting", targetValid = true, extraConditions = { T.ShouldApplyDebuff("Serpent Sting") } },
        T.SpellEntry{ key = "Arcane Shot", spellKey = "Arcane Shot", optionKey = "use_arcane_shot", targetValid = true, extraConditions = { T.StateCompare("target_hp_pct", ">", 20) } },
        T.SpellEntry{ key = "Multi-Shot", spellKey = "Multi-Shot", optionKey = "use_multi_shot", targetValid = true, cooldownSpellKey = "Multi-Shot", extraConditions = { T.StateCompare("target_hp_pct", ">", 20) } },
        T.SpellEntry{ key = "Steady Shot", spellKey = "Steady Shot", targetValid = true, extraConditions = { T.NotIsMoving() } },
        T.SpellEntry{ key = "Serpent Sting", spellKey = "Serpent Sting", optionKey = "use_serpent_sting", targetValid = true, inCombat = true, extraConditions = { T.IsMoving(), T.ShouldApplyDebuff("Serpent Sting") }, entryOpts = { isFiller = true, repeatLimit = 1 } },
        -- On-use trinkets.
        T.SpellEntry({
            key = "TRINKET1",
            targetValid = true,
            optionKey = "use_trinket_1",
            extraConditions = {
                T.TrinketReady(13),
                T.ClassificationFromAnyTarget("trinket_1_classification"),
            },
        }),
        T.SpellEntry({
            key = "TRINKET2",
            targetValid = true,
            optionKey = "use_trinket_2",
            extraConditions = {
                T.TrinketReady(14),
                T.ClassificationFromAnyTarget("trinket_2_classification"),
            },
        }),
    }
end

-- ── SHAMAN ROTATION BUILDERS ───────────────────────────────────

function T.BuildElementalShamanRotation(spec)
    return {
        T.SpellEntry{ key = "Elemental Mastery", spellKey = "Elemental Mastery", optionKey = "use_elemental_mastery", cooldownSpellKey = "Elemental Mastery", inCombat = true, targetValid = true, classificationSetting = "elemental_mastery_classification", offensive = false },
        T.SpellEntry{ key = "Totem of Wrath", spellKey = "Totem of Wrath", optionKey = "use_totem_wrath", extraConditions = { T.Not(T.TotemActive(1)) } },
        -- Flame Shock: very low usage in TBC Fresh Elemental (~0.67% damage), optional/low priority
        T.SpellEntry{ key = "Lightning Bolt", spellKey = "Lightning Bolt", targetValid = true, extraConditions = { T.NotIsMoving() } },
        T.SpellEntry{ key = "Chain Lightning", spellKey = "Chain Lightning", optionKey = "use_chain_lightning", targetValid = true, extraConditions = { T.StateCompare("target_hp_pct", ">", 20), T.NotIsMoving() } },
        -- Flame Shock: low priority in TBC Fresh Elemental (~0.67% damage in top parses)
        T.SpellEntry{ key = "Flame Shock", spellKey = "Flame Shock", optionKey = "use_flame_shock", targetValid = true, extraConditions = { T.DotMissing("Flame Shock") } },
        T.SpellEntry{ key = "Earth Shock", spellKey = "Earth Shock", optionKey = "use_earth_shock", targetValid = true, extraConditions = { T.IsMoving() } },
        T.SpellEntry{ key = "Thunderstorm", spellKey = "Thunderstorm", optionKey = "use_thunderstorm", cooldownSpellKey = "Thunderstorm", inCombat = true, extraConditions = { T.IsMoving() } },
        T.SpellEntry{ key = "POTION", spellKey = "POTION", optionKey = "suggestPot", targetValid = false, itemKey = "selectedPotionItem", extraConditions = { T.StateCompare("player_mana_pct", "<", "potManaThreshold") } },
        T.SpellEntry{ key = "RUNE", spellKey = "RUNE", optionKey = "suggestRune", targetValid = false, itemKey = "selectedRuneItem", extraConditions = { T.StateCompare("player_mana_pct", "<", "runeManaThreshold") } },
        -- On-use trinkets.
        T.SpellEntry({
            key = "TRINKET1",
            targetValid = true,
            optionKey = "use_trinket_1",
            extraConditions = {
                T.TrinketReady(13),
                T.ClassificationFromAnyTarget("trinket_1_classification"),
            },
        }),
        T.SpellEntry({
            key = "TRINKET2",
            targetValid = true,
            optionKey = "use_trinket_2",
            extraConditions = {
                T.TrinketReady(14),
                T.ClassificationFromAnyTarget("trinket_2_classification"),
            },
        }),
    }
end

function T.BuildEnhancementShamanRotation(spec)
    return {
        T.SpellEntry{ key = "Shamanistic Rage", spellKey = "Shamanistic Rage", optionKey = "use_shamanistic_rage", cooldownSpellKey = "Shamanistic Rage", inCombat = true, classificationSetting = "shamanistic_rage_classification", offensive = false },
        T.SpellEntry{ key = "Bloodlust", spellKey = "Bloodlust", optionKey = "use_bloodlust", cooldownSpellKey = "Bloodlust", inCombat = true, targetValid = true, classificationSetting = "bloodlust_classification", offensive = false },
        T.SpellEntry{ key = "Stormstrike", spellKey = "Stormstrike", optionKey = "use_stormstrike", targetValid = true, cooldownSpellKey = "Stormstrike" },
        T.SpellEntry{ key = "Earth Shock", spellKey = "Earth Shock", optionKey = "use_earth_shock", targetValid = true, extraConditions = { T.StateCompare("target_hp_pct", ">", 20) } },
        T.SpellEntry{ key = "Flame Shock", spellKey = "Flame Shock", optionKey = "use_flame_shock", targetValid = true, extraConditions = { T.DotMissing("Flame Shock") } },
        T.SpellEntry{ key = "Fire Nova", spellKey = "Fire Nova", optionKey = "use_fire_nova", targetValid = true, cooldownSpellKey = "Fire Nova" },
        T.SpellEntry{ key = "Magma Totem", spellKey = "Magma Totem", optionKey = "use_magma_totem", extraConditions = { T.Not(T.TotemActive(1)) } },
        T.SpellEntry{ key = "Strength of Earth Totem", spellKey = "Strength of Earth Totem", optionKey = "use_strength_totem", extraConditions = { T.Not(T.TotemActive(2)) } },
        T.SpellEntry{ key = "Windfury Totem", spellKey = "Windfury Totem", optionKey = "use_windfury_totem", extraConditions = { T.Not(T.TotemActive(4)) } },
        T.SpellEntry{ key = "Grace of Air Totem", spellKey = "Grace of Air Totem", optionKey = "use_grace_air_totem", extraConditions = { T.Not(T.TotemActive(4)) } },
        T.SpellEntry{ key = "Wind Shear", spellKey = "Wind Shear", optionKey = "use_wind_shear", targetValid = true, cooldownSpellKey = "Wind Shear", entryOpts = { isInterrupt = true } },
        -- On-use trinkets.
        T.SpellEntry({
            key = "TRINKET1",
            targetValid = true,
            optionKey = "use_trinket_1",
            extraConditions = {
                T.TrinketReady(13),
                T.ClassificationFromAnyTarget("trinket_1_classification"),
            },
        }),
        T.SpellEntry({
            key = "TRINKET2",
            targetValid = true,
            optionKey = "use_trinket_2",
            extraConditions = {
                T.TrinketReady(14),
                T.ClassificationFromAnyTarget("trinket_2_classification"),
            },
        }),
    }
end

function T.BuildRetributionPaladinRotation(spec)
    return {
        T.SpellEntry{ key = "Avenging Wrath", spellKey = "Avenging Wrath", optionKey = "use_avenging_wrath", cooldownSpellKey = "Avenging Wrath", inCombat = true, targetValid = true, classificationSetting = "avenging_wrath_classification", offensive = false },
        -- Seal of the Crusader (judge to apply debuff, pre-combat or while moving)
        T.SpellEntry{ key = "Seal of the Crusader", spellKey = "Seal of the Crusader", optionKey = "use_crusader_seal", extraConditions = {
            T.AnyOf({ T.NotInCombat(), T.IsMoving() }),
            T.Not(T.BuffStacks("Judgement of the Crusader", ">", 0)),
        }},
        T.SpellEntry{ key = "Righteous Fury", spellKey = "Righteous Fury", optionKey = "use_righteous_fury", extraConditions = { T.Not(T.BuffStacks("Righteous Fury", ">", 0)) } },
        -- Initial Seal of Blood / Vengeance (no seal active)
        T.SpellEntry{ key = "Seal of Blood", spellKey = "Seal of Blood", optionKey = "use_seal_of_blood", extraConditions = {
            T.BuffStacks("Seal of Blood", "==", 0),
            T.BuffStacks("Seal of Command", "==", 0),
            T.BuffStacks("Seal of Vengeance", "==", 0),
        }},
        -- Seal Twisting: apply Seal of Command before swing
        T.SpellEntry{ key = "Seal of Command (twist)", spellKey = "Seal of Command", optionKey = "use_seal_twisting", extraConditions = {
            T.BuffStacks("Seal of Blood", ">", 0),
            T.SwingTimeRemaining("mh", ">", 1.6),
        }},
        -- Return to Seal of Blood just before swing lands
        T.SpellEntry{ key = "Seal of Blood (return)", spellKey = "Seal of Blood", extraConditions = {
            T.BuffStacks("Seal of Command", ">", 0),
            T.SwingTimeRemaining("mh", "<", 0.4),
        }},
        T.SpellEntry{ key = "Crusader Strike", spellKey = "Crusader Strike", optionKey = "use_crusader_strike", targetValid = true, cooldownSpellKey = "Crusader Strike", extraConditions = {
            T.BuffStacks("Seal of Blood", ">", 0),
        }},
        T.SpellEntry{ key = "Judgement", spellKey = "Judgement", targetValid = true, cooldownSpellKey = "Judgement", extraConditions = {
            T.BuffStacks("Seal of Blood", ">", 0),
            T.Not(T.BuffStacks("Seal of Command", ">", 0)),
        }},
        T.SpellEntry{ key = "Consecration", spellKey = "Consecration", optionKey = "use_consecration", targetValid = true, cooldownSpellKey = "Consecration" },
        T.SpellEntry{ key = "Holy Wrath", spellKey = "Holy Wrath", optionKey = "use_holy_wrath", targetValid = true, cooldownSpellKey = "Holy Wrath" },
        T.SpellEntry{ key = "Exorcism", spellKey = "Exorcism", optionKey = "use_exorcism", targetValid = true, extraConditions = { T.AnyOf({ T.CreatureType("Undead"), T.CreatureType("Demon") }) } },
        T.SpellEntry{ key = "Hammer of Wrath", spellKey = "Hammer of Wrath", optionKey = "use_hammer_of_wrath", targetValid = true, extraConditions = { T.StateCompare("target_hp_pct", "<", 20) } },
        T.SpellEntry{ key = "Judgement of Wisdom", spellKey = "Judgement of Wisdom", optionKey = "use_judgement_wisdom", targetValid = true, extraConditions = { T.DotMissing("Judgement of Wisdom") } },
        T.SpellEntry{ key = "Divine Plea", spellKey = "Divine Plea", optionKey = "use_divine_plea", inCombat = true, cooldownSpellKey = "Divine Plea" },
        T.SpellEntry{ key = "POTION", spellKey = "POTION", optionKey = "suggestPot", targetValid = false, itemKey = "selectedPotionItem", extraConditions = { T.StateCompare("player_mana_pct", "<", "potManaThreshold") } },
        T.SpellEntry{ key = "RUNE", spellKey = "RUNE", optionKey = "suggestRune", targetValid = false, itemKey = "selectedRuneItem", extraConditions = { T.StateCompare("player_mana_pct", "<", "runeManaThreshold") } },
        -- On-use trinkets.
        T.SpellEntry({
            key = "TRINKET1",
            targetValid = true,
            optionKey = "use_trinket_1",
            extraConditions = {
                T.TrinketReady(13),
                T.ClassificationFromAnyTarget("trinket_1_classification"),
            },
        }),
        T.SpellEntry({
            key = "TRINKET2",
            targetValid = true,
            optionKey = "use_trinket_2",
            extraConditions = {
                T.TrinketReady(14),
                T.ClassificationFromAnyTarget("trinket_2_classification"),
            },
        }),
    }
end

return T