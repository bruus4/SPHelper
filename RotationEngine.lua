------------------------------------------------------------------------
-- SPHelper  –  RotationEngine.lua
-- Data-driven rotation evaluator.
-- Consumes spec.rotation from the active spec file (or DB override)
-- and produces an ordered priority list each evaluation cycle.
--
-- Replaces the hardcoded GetPriority() in Rotation.lua when
-- A.db.useRotationEngine is true (default: true after Phase 4).
------------------------------------------------------------------------
local A = SPHelper

A.RotationEngine = {}
local RE = A.RotationEngine

------------------------------------------------------------------------
-- HP decay tracker (EMA of target HP percent per second)
------------------------------------------------------------------------

local _hpDecay = {
    lastHP    = nil,   -- last observed target HP fraction [0-1]
    lastTime  = nil,   -- GetTime() when lastHP was recorded
    rate      = 0,     -- EMA of HP lost per second (positive = dying)
    alpha     = 0.25,  -- EMA smoothing factor
    targetGUID = nil,  -- ensure we reset on target change
}

------------------------------------------------------------------------
-- Power/energy tracker — estimate regen rate and tick timing
------------------------------------------------------------------------
local _powerState = {
    lastPower   = nil,
    lastTime    = nil,
    rate        = 0,
    alpha       = 0.25,
    lastTickTime= nil,
    tickInterval= 2.0,  -- default energy tick interval (seconds)

}

local function PlayerHasBuff(buffName)
    if not buffName then return false end
    for i = 1, 40 do
        local bname = UnitBuff("player", i)
        if not bname then break end
        if bname == buffName then return true end
    end
    return false
end

local function GetPlayerBaseMana()
    local _, class = UnitClass("player")
    local level = UnitLevel("player") or 0
    if not class or level < 1 then return 0 end

    if class == "DRUID" or class == "SHAMAN" or class == "PALADIN" then
        return ((level - 1) * 15) + 20
    end
    if class == "PRIEST" then
        return ((level - 1) * 11) + 20
    end
    if class == "MAGE" or class == "WARLOCK" then
        return ((level - 1) * 10) + 20
    end
    return 0
end

local function GetGCDRemaining(now)
    local probeSpellId = 29515
    local start, dur = GetSpellCooldown(probeSpellId)
    if not start or start == 0 or not dur or dur <= 0 then return 0 end
    if dur > 2.5 then return 0 end
    local remaining = start + dur - (now or GetTime())
    return (remaining > 0) and remaining or 0
end

local function ResolveNumericValue(raw, fallback)
    if raw == nil then return fallback end
    if type(raw) == "string" then
        local resolved = (A.SpecVal and A.SpecVal(raw, raw)) or raw
        return tonumber(resolved) or fallback
    end
    return tonumber(raw) or fallback
end

local function ResolveConditionValue(raw, fallback)
    if raw == nil then return fallback end
    if type(raw) == "string" then
        local resolved = (A.SpecVal and A.SpecVal(raw, raw)) or raw
        if resolved ~= nil then
            return resolved
        end
    end
    return raw
end

local function ResolveCompareValue(raw, lhs)
    local resolved = ResolveConditionValue(raw, raw)
    if type(lhs) == "number" then
        return tonumber(resolved)
    end
    if type(lhs) == "boolean" then
        if type(resolved) == "string" then
            local lower = resolved:lower()
            if lower == "true" then return true end
            if lower == "false" then return false end
        end
        return not not resolved
    end
    return resolved
end

local function CompareValues(lhs, op, rhs)
    op = op or ">="
    if lhs == nil or rhs == nil then return false end

    if op == "<" or op == "lt" then
        lhs = tonumber(lhs)
        rhs = tonumber(rhs)
        return lhs ~= nil and rhs ~= nil and lhs < rhs
    elseif op == "<=" or op == "lte" or op == "le" then
        lhs = tonumber(lhs)
        rhs = tonumber(rhs)
        return lhs ~= nil and rhs ~= nil and lhs <= rhs
    elseif op == ">" or op == "gt" then
        lhs = tonumber(lhs)
        rhs = tonumber(rhs)
        return lhs ~= nil and rhs ~= nil and lhs > rhs
    elseif op == ">=" or op == "gte" or op == "ge" then
        lhs = tonumber(lhs)
        rhs = tonumber(rhs)
        return lhs ~= nil and rhs ~= nil and lhs >= rhs
    elseif op == "==" or op == "=" or op == "eq" then
        return lhs == rhs
    elseif op == "!=" or op == "~=" or op == "neq" then
        return lhs ~= rhs
    end

    return false
end

local function ResolveSpellId(spellKey)
    if not spellKey then return nil end
    if A.ResolveSpellID then
        local resolved = A.ResolveSpellID(spellKey)
        if resolved then return resolved end
    end
    if not A.SPELLS then return nil end
    local spell = A.SPELLS[spellKey]
    return spell and spell.id or nil
end

local function GetProjectedSpellCooldown(spellKey, ctx)
    if not spellKey then return nil end
    local cdKey = spellKey:lower() .. "CD"
    if ctx and ctx[cdKey] ~= nil then
        return ctx[cdKey]
    end

    local spellId = ResolveSpellId(spellKey)
    if not spellId then return nil end
    return math.max((A.GetSpellCDReal and A.GetSpellCDReal(spellId) or 0) - ((ctx and ctx.castRemaining) or 0), 0)
end

local function GetEffectiveSpellCastTime(spellKey, ctx)
    if not spellKey then return nil end

    -- Authoritative source: the SpellDatabase catalog. `castType = "instant"`
    -- (or any zero/missing castTime) is treated as 0s. This guarantees the
    -- engine never invents a fake cast time for instants like SWP / SWD / DP
    -- regardless of what GetSpellInfo returns.
    local castTime
    if A.GetSpellDefinition then
        local def = A.GetSpellDefinition(spellKey)
        if def then
            local ct = def.castType
            if ct == "instant" or ct == "channel" then
                castTime = 0
            elseif def.castTime ~= nil then
                castTime = tonumber(def.castTime) or 0
            end
        end
    end

    if castTime == nil then
        local spellId = ResolveSpellId(spellKey)
        if not spellId then return nil end
        local _, _, _, castMS
        if A.GetSpellInfoCached then
            _, _, _, castMS = A.GetSpellInfoCached(spellId)
        else
            _, _, _, castMS = GetSpellInfo(spellId)
        end
        if castMS == nil then return nil end
        castTime = (castMS or 0) / 1000
    end

    if castTime <= 0 then return 0 end

    local hasteMul = (ctx and ctx.hasteMul) or ((A.GetHaste and select(2, A.GetHaste())) or 1)
    if not hasteMul or hasteMul <= 0 then hasteMul = 1 end
    return castTime / hasteMul
end

local function GetSpellTravelTimeValue(spellKey)
    local spellId = ResolveSpellId(spellKey)
    if A.GetSpellTravelTime then
        if spellId then
            return A.GetSpellTravelTime(spellId)
        end
        return A.GetSpellTravelTime(spellKey)
    end
    return nil
end

local function GetUnitBuffInfo(unit, buffName)
    if not unit or not buffName then return nil end
    for i = 1, 40 do
        local name, _, count, _, duration, expirationTime = UnitBuff(unit, i)
        if not name then break end
        if name == buffName then
            return name, count or 0, duration or 0, expirationTime or 0
        end
    end
    return nil
end

local function GetUnitDebuffInfo(unit, debuffName, sourceMode)
    if not unit or not debuffName then return nil end

    if sourceMode == "any" then
        if not A.FindDebuff then return nil end
        local name, _, count, _, duration, expirationTime = A.FindDebuff(unit, debuffName)
        if name then
            return name, count or 0, duration or 0, expirationTime or 0
        end
        return nil
    end

    if not A.FindPlayerDebuff then return nil end
    local name, _, count, _, duration, expirationTime = A.FindPlayerDebuff(unit, debuffName)
    if name then
        return name, count or 0, duration or 0, expirationTime or 0
    end
    return nil
end

local function GetTrackedDebuffDefinition(spec, spellKey)
    if not spellKey then return nil end

    local function FindDefinition(defs)
        for _, def in ipairs(defs or {}) do
            if def.spellKey == spellKey or def.key == spellKey then
                return def
            end
        end
        return nil
    end

    local found = spec and FindDefinition(spec.trackedDebuffs)
    if found then return found end

    local specID = (spec and spec.meta and spec.meta.id) or A._activeSpecID
    local dbSpec = A.db and A.db.specs and specID and A.db.specs[specID]
    if dbSpec then
        found = FindDefinition(dbSpec.trackedDebuffs)
        if found then return found end
    end

    return nil
end

local function GetDotBaseDuration(spec, spellKey)
    local def = GetTrackedDebuffDefinition(spec, spellKey)
    if def and tonumber(def.duration) then
        return tonumber(def.duration)
    end

    local spellId = ResolveSpellId(spellKey)
    if spellId and A.SpellData and A.SpellData.GetEffectiveDuration then
        local ok, duration = pcall(A.SpellData.GetEffectiveDuration, A.SpellData, spellId)
        if ok and duration and duration > 0 then
            return duration
        end
    end

    return nil
end

local function GetDotTickFrequency(spec, spellKey)
    local def = GetTrackedDebuffDefinition(spec, spellKey)
    if def then
        local tickInterval = tonumber(def.tickInterval)
        if tickInterval and tickInterval > 0 then
            return tickInterval
        end

        local ticks = tonumber(def.ticks)
        local duration = tonumber(def.duration)
        if duration and ticks and ticks > 0 then
            return duration / ticks
        end
    end

    local spellId = ResolveSpellId(spellKey)
    local coeff = spellId and A.SpellData and A.SpellData.SP_COEFFICIENTS and A.SpellData.SP_COEFFICIENTS[spellId]
    if coeff and coeff.ticks and coeff.ticks > 0 then
        local duration = GetDotBaseDuration(spec, spellKey) or coeff.dur
        if duration and duration > 0 then
            return duration / coeff.ticks
        end
    end

    return nil
end

local function GetChannelTickIntervalForSpell(spec, spellKey, ctx)
    if not spellKey then return nil end
    if ctx and ctx.activeChannelSpellKey == spellKey and (ctx.channelTickInterval or 0) > 0 then
        return ctx.channelTickInterval
    end

    local ticks = nil
    for _, channel in ipairs((spec and spec.channelSpells) or {}) do
        if channel.spellKey == spellKey then
            ticks = tonumber(channel.ticks) or ticks
            break
        end
    end

    local spellId = ResolveSpellId(spellKey)
    local data = spellId and A.SpellData and A.SpellData.SP_COEFFICIENTS and A.SpellData.SP_COEFFICIENTS[spellId]
    if (not ticks or ticks <= 0) and data and data.channel and data.ticks and data.ticks > 0 then
        ticks = data.ticks
    end
    if not ticks or ticks <= 0 then return nil end

    local duration = nil
    if data then
        duration = tonumber(data.dur) or tonumber(data.castTime)
    end
    if duration and duration > 0 then
        return duration / ticks
    end

    return nil
end

local function GetSpellDisplayName(spellKey)
    if not spellKey then return nil end
    local def = A.GetSpellDefinition and A.GetSpellDefinition(spellKey) or nil
    if def and def.name then
        return def.name
    end
    if type(spellKey) == "string" and spellKey ~= "" then
        return spellKey
    end
    return nil
end

local function GetTrackedDebuffDuration(spec, spellKey)
    if not spellKey then return 0 end

    local def = GetTrackedDebuffDefinition(spec, spellKey)
    if def and tonumber(def.duration) and tonumber(def.duration) > 0 then
        return tonumber(def.duration)
    end

    if A.SpellData and A.SpellData.GetEffectiveDuration then
        local ok, duration = pcall(A.SpellData.GetEffectiveDuration, A.SpellData, spellKey)
        if ok and duration and duration > 0 then
            return duration
        end
    end

    local spellDef = A.GetSpellDefinition and A.GetSpellDefinition(spellKey) or nil
    if spellDef and tonumber(spellDef.duration) and tonumber(spellDef.duration) > 0 then
        return tonumber(spellDef.duration)
    end

    return 0
end

local function GetTrackedDebuffState(spec, ctx, spellKey)
    if not spellKey then return nil end

    local ctxState = ctx and ctx.trackedDebuffsBySpellKey and ctx.trackedDebuffsBySpellKey[spellKey]
    if ctxState then
        return ctxState
    end

    local def = GetTrackedDebuffDefinition(spec, spellKey)
    if not def then return nil end

    local now = (ctx and ctx.now) or GetTime()
    local spellName = def.name or GetSpellDisplayName(def.spellKey or spellKey)
    local remaining = 0
    local sourceMode = def.source or "player"

    if spellName then
        local name, _, _, _, _, expirationTime
        if sourceMode == "any" and A.FindDebuff then
            name, _, _, _, _, expirationTime = A.FindDebuff("target", spellName)
        elseif A.FindPlayerDebuff then
            name, _, _, _, _, expirationTime = A.FindPlayerDebuff("target", spellName)
        end
        if name and expirationTime then
            remaining = math.max(expirationTime - now, 0)
        end
    end

    local recentWindow = tonumber(def.recentCastWindow) or 1.0
    if remaining == 0 and spellName and recentWindow > 0 and ctx and ctx.recentCast then
        local recent = ctx.recentCast[spellName]
        if recent and (now - recent) < recentWindow then
            remaining = GetTrackedDebuffDuration(spec, spellKey)
        end
    end

    -- Use clip-aware cast remaining when channeling a clippable spell
    -- (ctx.clipCastRemaining is 0 or timeToNextTick; nil when not channeling).
    -- Note: clipCastRemaining can legitimately be 0, so we test ~= nil explicitly.
    local castRemaining
    if ctx and ctx.clipCastRemaining ~= nil then
        castRemaining = ctx.clipCastRemaining
    else
        castRemaining = (ctx and ctx.castRemaining) or 0
    end
    local duration = GetTrackedDebuffDuration(spec, spellKey)
    return {
        key = def.key or spellKey,
        spellKey = def.spellKey or spellKey,
        name = spellName,
        remaining = remaining,
        after = math.max(remaining - castRemaining, 0),
        duration = duration,
    }
end

local function GetTrackedBuffState(spec, ctx, alias)
    if not alias then return nil end

    if ctx and ctx.trackedBuffs and ctx.trackedBuffs[alias] then
        return ctx.trackedBuffs[alias]
    end
    if ctx and ctx.trackedBuffsBySpellKey and ctx.trackedBuffsBySpellKey[alias] then
        return ctx.trackedBuffsBySpellKey[alias]
    end

    for _, def in ipairs((spec and spec.trackedBuffs) or {}) do
        if def.key == alias or def.spellKey == alias then
            local buffName = def.name or GetSpellDisplayName(def.spellKey or alias)
            local active = buffName and PlayerHasBuff(buffName) or false
            return {
                key = def.key or alias,
                spellKey = def.spellKey or alias,
                name = buffName,
                active = active,
            }
        end
    end

    return nil
end

local function GetChannelSpellConfig(spec, spellKey)
    if not spellKey then return nil end
    for _, channel in ipairs((spec and spec.channelSpells) or {}) do
        if channel.spellKey == spellKey or channel.key == spellKey then
            return channel
        end
    end
    return nil
end

local function GetEffectiveSpellChannelTime(spellKey, ctx)
    if not spellKey then return nil end

    local castTime = nil
    if A.GetSpellDefinition then
        local def = A.GetSpellDefinition(spellKey)
        if def then
            if def.castTime ~= nil then
                castTime = tonumber(def.castTime) or 0
            end
        end
    end

    if castTime == nil then
        local spellId = ResolveSpellId(spellKey)
        if not spellId then return nil end
        local _, _, _, castMS = GetSpellInfo(spellId)
        if castMS == nil then return nil end
        castTime = (castMS or 0) / 1000
    end

    if castTime <= 0 then return 0 end

    local hasteMul = (ctx and ctx.hasteMul) or ((A.GetHaste and select(2, A.GetHaste())) or 1)
    if not hasteMul or hasteMul <= 0 then hasteMul = 1 end
    return castTime / hasteMul
end

local function CountTrackedTargets(ctx, minTTD)
    local seen = {}
    local count = 0
    local requiredTTD = ResolveNumericValue(minTTD, 0) or 0

    local function AddTarget(guid, hpPct, isPreview)
        if not guid or seen[guid] then return end
        seen[guid] = true

        if requiredTTD > 0 then
            local ttd = A.GetTargetTimeToDie and A.GetTargetTimeToDie(guid) or nil
            local passesTTD
            if ttd ~= nil then
                passesTTD = ttd >= requiredTTD
            else
                passesTTD = isPreview or (hpPct or 0) > 0.25
            end
            if not passesTTD then
                return
            end
        end

        count = count + 1
    end

    for guid, data in pairs(A.dotTargets or {}) do
        if type(data) == "table" and not data._deadAt and (data.hpPct or 0) > 0 then
            AddTarget(guid, data.hpPct or 0, data._preview == true)
        end
    end

    local targetGUID = (ctx and ctx.targetGUID) or UnitGUID("target")
    if targetGUID and UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsDead("target") then
        local maxHP = UnitHealthMax("target") or 1
        local hpPct = (maxHP > 0) and ((UnitHealth("target") or 0) / maxHP) or 1
        AddTarget(targetGUID, hpPct, false)
    end

    return count
end

local function GetUnitThreatPercent(unit)
    unit = unit or "target"
    if not UnitExists(unit) or type(UnitDetailedThreatSituation) ~= "function" then
        return 0
    end

    local _, _, scaledPct, rawPct = UnitDetailedThreatSituation("player", unit)
    return scaledPct or rawPct or 0
end

local function GetUnitCastState(unit, now)
    unit = unit or "target"
    now = now or GetTime()
    if not UnitExists(unit) then return 0, false end

    local _, _, _, _, endMS, _, _, notInterruptible = UnitCastingInfo(unit)
    if endMS then
        return math.max((endMS / 1000) - now, 0), not notInterruptible
    end

    local _, _, _, _, channelEndMS, _, channelNotInterruptible = UnitChannelInfo(unit)
    if channelEndMS then
        return math.max((channelEndMS / 1000) - now, 0), not channelNotInterruptible
    end

    return 0, false
end

local function ResolveStateCompareValue(cond, ctx, spec, db)
    local subject = cond.subject
    if not subject then return nil end

    if subject == "resource_pct" then
        local resource = cond.resource or "mana"
        if resource == "mana" then return (ctx.manaPct or 0) * 100 end
        if resource == "hp" then return (ctx.hpPct or 0) * 100 end
        local maxResource = UnitPowerMax("player") or 1
        if maxResource <= 0 then maxResource = 1 end
        return ((ctx.resourcePower or 0) / maxResource) * 100
    elseif subject == "player_hp_pct" then
        return (ctx.hpPct or 0) * 100
    elseif subject == "player_hp" then
        return UnitHealth("player") or 0
    elseif subject == "target_hp_pct" then
        if not ctx.targetMaxHP or ctx.targetMaxHP <= 0 then return 0 end
        return (ctx.targetHP / ctx.targetMaxHP) * 100
    elseif subject == "target_hp" then
        return ctx.targetHP or 0
    elseif subject == "player_mana_pct" then
        return (ctx.manaPct or 0) * 100
    elseif subject == "player_base_mana_pct" then
        return (ctx.baseManaPct or 0) * 100
    elseif subject == "combo_points" then
        return ctx.comboPoints or 0
    elseif subject == "target_ttd" then
        if ctx.targetTTD ~= nil then return ctx.targetTTD end
        if ctx.targetMaxHP and ctx.targetMaxHP > 0 then
            local hpPct = ctx.targetHP / ctx.targetMaxHP
            return (hpPct <= 0.25) and 0 or 999
        end
        return 0
    elseif subject == "resource" then
        return ctx.resourcePower or 0
    elseif subject == "resource_at_gcd" then
        return ctx.resourceAtGCD or ctx.resourcePower or 0
    elseif subject == "next_power_tick_with_gcd" then
        return ctx.nextPowerTickWithGCD or 0
    elseif subject == "threat_pct" then
        return GetUnitThreatPercent(cond.unit or "target")
    elseif subject == "tracked_target_count" then
        return CountTrackedTargets(ctx)
    elseif subject == "tracked_targets_with_ttd" then
        return CountTrackedTargets(ctx, cond.minTTD)
    elseif subject == "channel_tick_interval" then
        return ctx.channelTickInterval or 0
    elseif subject == "channel_ticks_remaining" then
        return ctx.channelTicksRemaining or 0
    elseif subject == "channel_time_to_next_tick" then
        return ctx.channelTimeToNextTick or 0
    end

    return nil
end

local function ResolveSpellPropertyValue(cond, ctx, spec, db)
    local property = cond.property
    if property == "time_to_ready" then
        return GetProjectedSpellCooldown(cond.spellKey, ctx)
    elseif property == "cast_time" then
        return GetEffectiveSpellCastTime(cond.spellKey, ctx)
    elseif property == "travel_time" then
        return GetSpellTravelTimeValue(cond.spellKey)
    elseif property == "dot_base_duration" then
        return GetDotBaseDuration(spec, cond.spellKey)
    elseif property == "dot_tick_frequency" then
        return GetDotTickFrequency(spec, cond.spellKey)
    elseif property == "channel_tick_interval" then
        return GetChannelTickIntervalForSpell(spec, cond.spellKey, ctx)
    end
    return nil
end

local function ResolveBuffPropertyValue(cond, ctx, spec, db)
    local name, count, _, expirationTime = GetUnitBuffInfo("player", cond.buff)
    if cond.property == "remaining" then
        return name and math.max((expirationTime or 0) - (ctx.now or GetTime()), 0) or 0
    elseif cond.property == "stacks" then
        if not name then return 0 end
        return ((count or 0) > 0) and count or 1
    end
    return nil
end

local function ResolveDebuffPropertyValue(cond, ctx, spec, db)
    local debuffName = cond.debuff
    if not debuffName and cond.spellKey and A.SPELLS and A.SPELLS[cond.spellKey] then
        debuffName = A.SPELLS[cond.spellKey].name
    end
    local name, count, _, expirationTime = GetUnitDebuffInfo("target", debuffName, cond.source or "player")
    if cond.property == "remaining" then
        return name and math.max((expirationTime or 0) - (ctx.now or GetTime()), 0) or 0
    elseif cond.property == "stacks" then
        if not name then return 0 end
        return ((count or 0) > 0) and count or 1
    end
    return nil
end

local function ResolveUnitCastCompareValue(cond, ctx, spec, db)
    local remaining = GetUnitCastState(cond.unit or "target", ctx.now)
    return remaining
end

local function ResolveEntryPriorityBucket(entry)
    if not entry then return nil end
    if entry.priorityGroup ~= nil then return entry.priorityGroup end
    if entry.explicitPriority ~= nil then return entry.explicitPriority end
    if entry.priority ~= nil then return entry.priority end
    return nil
end

local function ResolveTrackedDebuffKey(spec, spellKey)
    if not spellKey then return nil end
    if spec and spec.trackedDebuffs then
        for _, def in ipairs(spec.trackedDebuffs) do
            if def.spellKey == spellKey or def.key == spellKey then
                return def.key
            end
        end
    end
    return string.lower(spellKey)
end

local function CountOtherTrackedTargetsWithDebuff(spec, ctx, spellKey, minRemaining, minTTD)
    local targets = A.dotTargets
    if not targets then return 0 end

    local trackedKey = ResolveTrackedDebuffKey(spec, spellKey)
    if not trackedKey then return 0 end

    local now = (ctx and ctx.now) or GetTime()
    local requiredRem = ResolveNumericValue(minRemaining, 0) or 0
    local requiredTTD = ResolveNumericValue(minTTD, 0) or 0
    local excludeGUID = ctx and ctx.targetGUID or nil
    local count = 0

    for guid, data in pairs(targets) do
        if guid ~= excludeGUID and type(data) == "table" and not data._deadAt and (data.hpPct or 0) > 0 then
            local exp = data[trackedKey .. "_exp"]
            local rem = exp and math.max(exp - now, 0) or 0
            if rem > requiredRem then
                local passesTTD = true
                if requiredTTD > 0 then
                    local ttd = A.GetTargetTimeToDie and A.GetTargetTimeToDie(guid) or nil
                    if not ttd and data._preview then
                        ttd = 999
                    end
                    if ttd == nil then
                        passesTTD = (data.hpPct or 0) > 0.25
                    else
                        passesTTD = ttd >= requiredTTD
                    end
                end
                if passesTTD then
                    count = count + 1
                end
            end
        end
    end

    return count
end

local function UpdateHPDecay()
    if not UnitExists("target") then
        _hpDecay.lastHP    = nil
        _hpDecay.lastTime  = nil
        _hpDecay.rate      = 0
        _hpDecay.targetGUID = nil
        return
    end
    local guid = UnitGUID("target")
    if guid ~= _hpDecay.targetGUID then
        _hpDecay.lastHP    = nil
        _hpDecay.lastTime  = nil
        _hpDecay.rate      = 0
        _hpDecay.targetGUID = guid
    end
    local maxHP = UnitHealthMax("target") or 1
    if maxHP <= 0 then return end
    local hp     = (UnitHealth("target") or 0) / maxHP
    local now    = GetTime()
    if _hpDecay.lastHP and _hpDecay.lastTime then
        local dt = now - _hpDecay.lastTime
        if dt > 0.1 then
            local instantRate = (_hpDecay.lastHP - hp) / dt  -- positive when HP drops
            _hpDecay.rate = _hpDecay.alpha * instantRate + (1 - _hpDecay.alpha) * _hpDecay.rate
            _hpDecay.lastHP   = hp
            _hpDecay.lastTime = now
        end
    else
        _hpDecay.lastHP   = hp
        _hpDecay.lastTime = now
    end
end

------------------------------------------------------------------------
-- Talent helpers
------------------------------------------------------------------------

--- Return the number of points the player has in a specific talent.
-- @param tab   number  Talent tab (1-based).
-- @param index number  Talent index within the tab (1-based).
-- @return number  Points spent (0 if unable to query).
function RE.GetTalentRank(tab, index)
    local ok, _, _, _, _, rank = pcall(GetTalentInfo, tab, index)
    return (ok and rank) or 0
end

------------------------------------------------------------------------
-- Context builder — generic snapshot of all relevant game state.
-- Class-specific fields are populated via spec.buildContext(ctx, spec).
------------------------------------------------------------------------
function RE:BuildContext(spec)
    local now = GetTime()
    local constants = (spec and spec.constants) or {}

    -- Cast/channel info
    local castingSpell, castRemaining = nil, 0
    do
        local name, _, _, _, endMS = UnitCastingInfo("player")
        if name and endMS then
            castingSpell  = name
            castRemaining = math.max(endMS / 1000 - now, 0)
        else
            local cname, _, _, _, cendMS = UnitChannelInfo("player")
            if cname and cendMS then
                castingSpell  = cname
                castRemaining = math.max(cendMS / 1000 - now, 0)
            end
        end
    end

    -- Haste
    local hastePct, hasteMul = 0, 1
    if A.GetHaste then
        local ok, hp, hm = pcall(A.GetHaste)
        if ok and hp and hm then hastePct, hasteMul = hp, hm end
    end

    local gcd          = math.max(1.0, 1.5 / hasteMul)
    local gcdRemaining = GetGCDRemaining(now)
    local lat          = A.GetLatency()
    local SAFETY       = constants.SAFETY or 0.5

    -- Resources (mana)
    local currentMana  = UnitPower("player", 0) or 0
    local maxMana      = math.max(UnitPowerMax("player", 0) or 1, 1)
    local baseMana     = GetPlayerBaseMana()
    if baseMana <= 0 then baseMana = maxMana end
    local manaPct      = currentMana / maxMana
    local baseManaPct  = currentMana / math.max(baseMana, 1)
    local hpPct        = (UnitHealth("player") or 1) /
                         math.max(UnitHealthMax("player") or 1, 1)

    local sp           = (A.GetSpellPower and A.GetSpellPower()) or 0
    local targetHP, targetMaxHP = 0, 0
    local targetGUID   = UnitGUID("target")
    if UnitExists("target") then
        targetHP    = UnitHealth("target")    or 0
        targetMaxHP = UnitHealthMax("target") or 0
    end

    local timing         = constants.timing or {}
    local WAIT_THRESHOLD = (timing.globalWaitThresholdMs or 400) / 1000

    -- Combo points
    local comboPoints  = (GetComboPoints and GetComboPoints("player", "target")) or 0

    -- Non-mana resource (energy / rage / focus)
    local resourcePower = UnitPower("player") or 0

    -- Power/energy regen estimator
    do
        local nowP = now
        local curr = resourcePower
        if _powerState.lastPower ~= nil and _powerState.lastTime then
            local dt = nowP - _powerState.lastTime
            if dt > 0.05 then
                local instant = (curr - _powerState.lastPower) / dt
                _powerState.rate = _powerState.alpha * instant +
                                   (1 - _powerState.alpha) * _powerState.rate
            end
            if curr > _powerState.lastPower + 0.5 then
                if _powerState.lastTickTime then
                    local tickDt = nowP - _powerState.lastTickTime
                    _powerState.tickInterval = _powerState.alpha * tickDt +
                                              (1 - _powerState.alpha) * _powerState.tickInterval
                end
                _powerState.lastTickTime = nowP
            end
        else
            _powerState.rate     = _powerState.rate or 0
            _powerState.lastTickTime = _powerState.lastTickTime or nil
        end
        _powerState.lastPower = curr
        _powerState.lastTime  = nowP
    end

    -- HP decay
    UpdateHPDecay()
    local hpDecayRate = _hpDecay.rate
    local targetTTD   = nil
    if targetGUID and targetMaxHP > 0 and A.UpdateTargetHealthSample then
        A.UpdateTargetHealthSample(targetGUID, targetHP / targetMaxHP, now)
    end
    if targetGUID and A.GetTargetTimeToDie then
        targetTTD = A.GetTargetTimeToDie(targetGUID)
    end
    if not targetTTD and targetMaxHP > 0 and hpDecayRate > 0.0001 then
        targetTTD = (targetHP / targetMaxHP) / hpDecayRate
    end

    local nextPowerTick = (_powerState.lastTickTime and
        math.max(0, _powerState.tickInterval - (now - _powerState.lastTickTime))) or nil
    local readyIn       = math.max(castRemaining or 0, gcdRemaining or 0)
    local powerType     = UnitPowerType("player")
    local maxResource   = UnitPowerMax("player") or 100
    if maxResource <= 0 then maxResource = 100 end

    local resourceAtGCD = resourcePower
    if powerType == 3 or (Enum and Enum.PowerType and powerType == Enum.PowerType.Energy) then
        if nextPowerTick and nextPowerTick <= readyIn then
            local interval = math.max(_powerState.tickInterval or 2.0, 0.1)
            local ticks    = 1 + math.floor((readyIn - nextPowerTick) / interval)
            resourceAtGCD  = resourcePower + ticks * 20
        elseif (_powerState.rate or 0) > 0 then
            resourceAtGCD = resourcePower + (_powerState.rate * readyIn)
        end
    elseif (_powerState.rate or 0) > 0 then
        resourceAtGCD = resourcePower + (_powerState.rate * readyIn)
    end
    resourceAtGCD = math.min(resourceAtGCD, maxResource)
    local nextPowerTickWithGCD = nextPowerTick and (nextPowerTick - readyIn) or nil

    -- Channel helper metrics
    local activeChannelSpellKey  = nil
    local channelTickInterval    = 0
    local channelTicksRemaining  = 0
    local channelTimeToNextTick  = 0
    if A.ChannelHelper then
        if A.ChannelHelper.GetActiveChannelSpellKey then
            local ok, v = pcall(A.ChannelHelper.GetActiveChannelSpellKey, A.ChannelHelper)
            if ok then activeChannelSpellKey = v end
        end
        if A.ChannelHelper.GetChannelTickInterval then
            local ok, v = pcall(A.ChannelHelper.GetChannelTickInterval, A.ChannelHelper)
            if ok and v then channelTickInterval = v end
        end
        if A.ChannelHelper.GetChannelTicksRemaining then
            local ok, v = pcall(A.ChannelHelper.GetChannelTicksRemaining, A.ChannelHelper)
            if ok and v then channelTicksRemaining = v end
        end
        if A.ChannelHelper.GetChannelTimeToNextTick then
            local ok, v = pcall(A.ChannelHelper.GetChannelTimeToNextTick, A.ChannelHelper)
            if ok and v then channelTimeToNextTick = v end
        end
    end

    local recentCast = A._rotRecentCast or {}

    -- Build the base generic context
    local ctx = {
        now            = now,
        castingSpell   = castingSpell,
        castRemaining  = castRemaining,
        hastePct       = hastePct,
        hasteMul       = hasteMul,
        gcd            = gcd,
        gcdRemaining   = gcdRemaining,
        readyIn        = readyIn,
        lat            = lat,
        SAFETY         = SAFETY,
        currentMana    = currentMana,
        maxMana        = maxMana,
        baseMana       = baseMana,
        manaPct        = manaPct,
        baseManaPct    = baseManaPct,
        hpPct          = hpPct,
        sp             = sp,
        targetGUID     = targetGUID,
        targetHP       = targetHP,
        targetMaxHP    = targetMaxHP,
        targetTTD      = targetTTD,
        inCombat       = UnitAffectingCombat("player"),
        WAIT_THRESHOLD = WAIT_THRESHOLD,
        recentCast     = recentCast,
        comboPoints    = comboPoints,
        powerType      = powerType,
        resourcePower  = resourcePower,
        resourceRegen  = _powerState.rate,
        nextPowerTick  = nextPowerTick,
        resourceAtGCD  = resourceAtGCD,
        nextPowerTickWithGCD = nextPowerTickWithGCD,
        hpDecayRate    = hpDecayRate,
        activeChannelSpellKey = activeChannelSpellKey,
        channelTickInterval   = channelTickInterval,
        channelTicksRemaining = channelTicksRemaining,
        channelTimeToNextTick = channelTimeToNextTick,
    }

    -- Clip-aware cast remaining.
    -- When channeling a spell with `allowClipping = true` in SpellDatabase,
    -- the relevant "time until we can act" for DoT refresh projections is
    -- the next tick (where we can cleanly clip the channel), not the full
    -- remaining channel time.  A 200ms window around each tick boundary
    -- (just past a tick OR next tick imminent) is treated as cast-now so
    -- the user isn't forced to wait for a tick that is essentially now.
    do
        local ttn     = channelTimeToNextTick
        local tickInt = channelTickInterval
        local clipCast = castRemaining
        if activeChannelSpellKey and ttn > 0 then
            local csDef = A.GetSpellDefinition and A.GetSpellDefinition(activeChannelSpellKey)
            if csDef and csDef.allowClipping then
                local timeSinceLast = (tickInt > 0) and (tickInt - ttn) or 0
                if ttn <= 0.2 or timeSinceLast <= 0.2 then
                    clipCast = 0
                else
                    clipCast = ttn
                end
            end
        end
        ctx.clipCastRemaining = clipCast
    end

    -- Generic tracked debuffs: build lookup tables and ctx shorthand aliases.
    -- e.g. trackedDebuffs = { {key="vt", spellKey="Vampiric Touch", ...} }
    -- produces ctx["vtRem"], ctx["vtAfter"], ctx["vtCastEff"] etc.
    local trackedDebuffsByAlias    = {}
    local trackedDebuffsBySpellKey = {}
    for _, tracked in ipairs((spec and spec.trackedDebuffs) or {}) do
        local spellKey = tracked.spellKey or tracked.key
        local alias    = tracked.key or spellKey
        if spellKey and alias then
            local state = GetTrackedDebuffState(spec, ctx, spellKey)
            if state then
                state.key     = alias
                state.spellKey = spellKey
                state.castEff  = GetEffectiveSpellCastTime(spellKey, ctx) or 0
                trackedDebuffsByAlias[alias]       = state
                trackedDebuffsBySpellKey[spellKey] = state
                ctx[alias .. "Rem"]     = state.remaining or 0
                ctx[alias .. "After"]   = math.max((state.remaining or 0) - ctx.clipCastRemaining, 0)
                ctx[alias .. "CastEff"] = state.castEff
            end
        end
    end
    ctx.trackedDebuffs           = trackedDebuffsByAlias
    ctx.trackedDebuffsBySpellKey = trackedDebuffsBySpellKey

    -- Generic tracked buffs: produces ctx["buffAlias"] = true/false
    local trackedBuffsByAlias    = {}
    local trackedBuffsBySpellKey = {}
    for _, tracked in ipairs((spec and spec.trackedBuffs) or {}) do
        local alias = tracked.key or tracked.spellKey
        if alias then
            local buffName = tracked.name or GetSpellDisplayName(tracked.spellKey or alias)
            local active   = buffName and PlayerHasBuff(buffName) or false
            local state = {
                key      = alias,
                spellKey = tracked.spellKey or alias,
                name     = buffName,
                active   = active,
            }
            trackedBuffsByAlias[alias] = state
            if tracked.spellKey then
                trackedBuffsBySpellKey[tracked.spellKey] = state
            end
            ctx[alias] = active
        end
    end
    ctx.trackedBuffs           = trackedBuffsByAlias
    ctx.trackedBuffsBySpellKey = trackedBuffsBySpellKey

    -- Channel spell config (first channel spell; used for clip overlays)
    local channelConfig = spec and spec.channelSpells and spec.channelSpells[1]
    if channelConfig then
        local csKey = channelConfig.spellKey or channelConfig.key
        if csKey then
            ctx.channelCastEff = GetEffectiveSpellChannelTime(csKey, ctx) or 0
            ctx.channelMinEff  = (tonumber(channelConfig.minDuration) or 0) / hasteMul
        end
    end

    -- Spec-specific context extension.
    -- Specs define spec.buildContext = function(ctx, spec) ... end
    -- to populate class-specific fields without touching the generic engine.
    if spec and type(spec.buildContext) == "function" then
        local ok, err = pcall(spec.buildContext, ctx, spec)
        if not ok then
            A.DebugLog("ERR", "spec.buildContext: " .. tostring(err))
        end
    end

    return ctx
end

------------------------------------------------------------------------
-- Condition evaluators (dispatch table)
------------------------------------------------------------------------

RE._condEval = {}

------------------------------------------------------------------------
-- Composite evaluator aliases.
--
-- The canonical composite types are `any_of`, `all_of`, and `not`
-- (defined further below alongside the other condition evaluators).
-- We register short aliases `any` / `all` here so spec authors can use
-- whichever name reads more naturally for them. The alias entries are
-- assigned at the bottom of this file (after the canonical definitions
-- have been registered) — see the "Composite type aliases" block.
------------------------------------------------------------------------

RE._condEval["always"] = function(cond, ctx, spec, db)
    return true
end

RE._condEval["target_valid"] = function(cond, ctx, spec, db)
    return UnitExists("target") and not UnitIsDead("target") and UnitCanAttack("player", "target")
end

RE._condEval["cooldown_ready"] = function(cond, ctx, spec, db)
    local key = cond.spellKey
    if not key then return false end
    -- Context keys are lowerCamelCase; rotation keys remain UPPER spell keys.
    local cdKey = key:lower() .. "CD"
    local cd = ctx[cdKey]
    if cd ~= nil then return cd == 0 end
    -- Try direct lookup via SPELLS table
    local spell = A.SPELLS[key]
    if spell then
        return A.KnowsSpell(spell.id) and A.GetSpellCDReal(spell.id) == 0
    end
    return false
end

RE._condEval["dot_missing"] = function(cond, ctx, spec, db)
    local key = cond.spellKey
    if key then
        local state = GetTrackedDebuffState(spec, ctx, key)
        if state then
            return (state.remaining or 0) <= 0
        end
    end
    return ResolveDebuffRemaining(spec, ctx, cond) <= 0
end

RE._condEval["projected_dot_time_left_lt"] = function(cond, ctx, spec, db)
    local key = cond.spellKey
    local after = 0
    if key then
        local state = GetTrackedDebuffState(spec, ctx, key)
        if state then
            after = state.after or 0
        end
    end
    if after <= 0 and (not key or not GetTrackedDebuffState(spec, ctx, key)) then
        local clipCast = (ctx and ctx.clipCastRemaining ~= nil) and ctx.clipCastRemaining or (ctx and ctx.castRemaining or 0)
        after = math.max(ResolveDebuffRemaining(spec, ctx, cond) - clipCast, 0)
    end

    -- Resolve threshold expression. When `seconds` is omitted, default to
    -- the haste-adjusted refresh window: cast(KEY) + travel(KEY) + SAFETY.
    -- This is class-agnostic and uses live haste so DoT reapplication is
    -- always suggested at the latest safe moment regardless of class.
    local threshold = 0
    if type(cond.seconds) == "number" then
        threshold = cond.seconds
    elseif type(cond.seconds) == "string" then
        threshold = RE._resolveExpr(cond.seconds, ctx, spec)
    elseif key then
        -- Threshold = haste-adjusted cast time only.
        -- No travel time and no SAFETY buffer — ChannelHelper / FQ handles
        -- timing precision. Adding them caused suggestions ~0.2-0.5s too early.
        -- Instants (castType = "instant") return castEff = 0, so the threshold
        -- is 0 and the condition fires when dotRem <= 0 (dot just expired).
        threshold = GetEffectiveSpellCastTime(key, ctx) or 0
    end
    -- Use <= so instant spells (threshold = 0) trigger when dotRem reaches 0.
    return after <= threshold
end

RE._condEval["dot_time_left_lt"] = function(cond, ctx, spec, db)
    local key = cond.spellKey
    local rem = ResolveDebuffRemaining(spec, ctx, cond)
    return rem < (ResolveNumericValue(cond.seconds, 0) or 0)
end

RE._condEval["resource_pct_lt"] = function(cond, ctx, spec, db)
    local resource = cond.resource or "mana"
    local pct = cond.pct
    -- Allow pct to be a db key reference (e.g. "sfManaThreshold")
    if type(pct) == "string" then
        pct = (A.SpecVal and A.SpecVal(pct, 50)) or 50
    end
    pct = (pct or 50) / 100
    if resource == "mana" then return ctx.manaPct < pct end
    if resource == "hp" then return ctx.hpPct < pct end
    if resource == "energy" or resource == "rage" or resource == "focus" then
        local max = UnitPowerMax("player") or 1
        if max <= 0 then max = 1 end
        return (ctx.resourcePower / max) < pct
    end
    return false
end

RE._condEval["resource_pct_gt"] = function(cond, ctx, spec, db)
    local resource = cond.resource or "mana"
    local pct = cond.pct
    if type(pct) == "string" then
        pct = (A.SpecVal and A.SpecVal(pct, 50)) or 50
    end
    pct = (pct or 50) / 100
    if resource == "mana" then return ctx.manaPct > pct end
    if resource == "hp" then return ctx.hpPct > pct end
    if resource == "energy" or resource == "rage" or resource == "focus" then
        local max = UnitPowerMax("player") or 1
        if max <= 0 then max = 1 end
        return (ctx.resourcePower / max) > pct
    end
    return false
end

------------------------------------------------------------------------
-- setting_compare: compare a user setting (from settingDefs / uiOptions)
-- against a value using standard comparison operators.
--
-- Schema:
--   { type = "setting_compare", optionKey = "swdRaid", op = "==", value = "always" }
--   { type = "setting_compare", optionKey = "swdSafetyPct", op = "<", value = 50 }
--
-- This is the composable replacement for hardcoded evaluators like
-- `content_mode_allow` and `spec_option_enabled`. Any setting can be
-- compared against any value, and the optionKey reference drives
-- automatic General-tab widget generation.
------------------------------------------------------------------------
RE._condEval["setting_compare"] = function(cond, ctx, spec, db)
    local key = cond.optionKey
    if not key then return false end
    local settingVal = A.SpecVal(key, cond.default)
    local target = cond.value
    if target == nil then return settingVal and settingVal ~= false and settingVal ~= 0 end
    local op = cond.op or "=="
    -- Normalize both sides to numbers if possible for numeric comparisons
    local numSetting = tonumber(settingVal)
    local numTarget  = tonumber(target)
    if numSetting and numTarget then
        return CompareValues(numSetting, op, numTarget)
    end
    -- String comparison
    local sv = tostring(settingVal or "")
    local tv = tostring(target or "")
    if op == "==" or op == "eq"  then return sv == tv end
    if op == "~=" or op == "!="  then return sv ~= tv end
    return false
end

RE._condEval["content_mode_allow"] = function(cond, ctx, spec, db)
    local contentType = A.GetContentType()
    local mode
    if contentType == "raid" then
        mode = A.SpecVal("swdRaid", "execute")
    elseif contentType == "dungeon" then
        mode = A.SpecVal("swdDungeon", "always")
    else
        mode = A.SpecVal("swdWorld", "always")
    end
    if mode == "never" then return false end
    if mode == "execute" then
        -- Only allow if SWD can kill
        local sp = ctx.sp or 0
        local swdHit = math.floor(sp * 1.55 + 0.5)
        local safety = A.SpecVal("swdSafetyPct", 10) or 0
        local required = ctx.targetHP * (1 + safety / 100)
        return ctx.targetHP > 0 and swdHit >= required
    end
    return true  -- "always"
end

RE._condEval["item_ready_and_owned"] = function(cond, ctx, spec, db)
    local itemId = cond.itemId
    if not itemId then return false end
    if type(itemId) == "string" then itemId = tonumber(itemId) end
    if not itemId then return false end
    local count = GetItemCount(itemId) or 0
    if count == 0 then return false end
    local start, dur = A.GetItemCooldownSafe(itemId)
    if start and dur and start > 0 then
        return (start + dur - ctx.now) <= 0
    end
    return true
end

RE._condEval["not_recently_cast"] = function(cond, ctx, spec, db)
    local spellName = cond.spellName
    if not spellName and cond.spellKey and A.SPELLS and A.SPELLS[cond.spellKey] then
        spellName = A.SPELLS[cond.spellKey].name
    end
    if not spellName then return true end
    local t = ctx.recentCast[spellName]
    if t and (ctx.now - t) < (cond.window or 1.0) then return false end
    return true
end

RE._condEval["precombat"] = function(cond, ctx, spec, db)
    return not UnitAffectingCombat("player")
end

RE._condEval["not_debuff_on_target"] = function(cond, ctx, spec, db)
    local unit = cond.unit or "target"
    if not UnitExists(unit) then return false end
    local name = ResolveAuraName(cond.debuff, cond.debuffId)
    if not name then return true end
    local n = A.FindPlayerDebuff(unit, name)
    return not n
end

RE._condEval["not_buff_on_player"] = function(cond, ctx, spec, db)
    local unit = cond.unit or "player"
    local name = ResolveAuraName(cond.buff, cond.buffId)
    if not name then return true end
    for i = 1, 40 do
        local bname = UnitBuff(unit, i)
        if not bname then break end
        if bname == name then return false end
    end
    return true
end

RE._condEval["target_classification"] = function(cond, ctx, spec, db)
    local required = cond.classification or "boss"
    local actual = A.GetTargetClassification()
    return actual == required
end

-- Gated classification: if optionKey is true, require the classification match;
-- if false, always pass. Used for "only on bosses" toggles.
RE._condEval["option_gated_classification"] = function(cond, ctx, spec, db)
    local optKey = cond.optionKey
    if not optKey then return true end
    local val = A.SpecVal(optKey, false)
    if not val or val == false or val == 0 then return true end -- option off → pass always
    local required = cond.classification or "boss"
    local actual = A.GetTargetClassification()
    return actual == required
end

RE._condEval["threat_pct_lt"] = function(cond, ctx, spec, db)
    local threshold = ResolveNumericValue(cond.pct, 100) or 100
    return GetUnitThreatPercent(cond.unit or "target") < threshold
end

RE._condEval["threat_pct_ge"] = function(cond, ctx, spec, db)
    local threshold = ResolveNumericValue(cond.pct, 100) or 100
    return GetUnitThreatPercent(cond.unit or "target") >= threshold
end

------------------------------------------------------------------------
-- Phase 8 condition evaluators
------------------------------------------------------------------------

-- Helper: resolve a buff/debuff name from a name string or a numeric spell ID.
local function ResolveAuraName(name, auraId)
    if name and name ~= "" then return name end
    if auraId then
        local id = tonumber(auraId)
        if id and GetSpellInfo then
            local ok, n = pcall(GetSpellInfo, id)
            if ok and n and n ~= "" then return n end
        end
    end
    return nil
end

RE._condEval["buff_on_player"] = function(cond, ctx, spec, db)
    local unit = cond.unit or "player"
    local name = ResolveAuraName(cond.buff, cond.buffId)
    if not name then return false end
    for i = 1, 40 do
        local bname = UnitBuff(unit, i)
        if not bname then break end
        if bname == name then return true end
    end
    return false
end

RE._condEval["buff_stacks_gte"] = function(cond, ctx, spec, db)
    local name = cond.buff
    if not name then return false end
    local needed = ResolveNumericValue(cond.stacks, 1) or 1
    for i = 1, 40 do
        local bname, _, count = UnitBuff("player", i)
        if not bname then break end
        if bname == name then
            local stacks = ((count or 0) > 0) and count or 1
            return stacks >= needed
        end
    end
    return false
end

RE._condEval["target_hp_pct_lt"] = function(cond, ctx, spec, db)
    if not UnitExists("target") then return false end
    local hp = UnitHealth("target") or 0
    local maxHP = UnitHealthMax("target") or 1
    local pct = cond.pct
    if type(pct) == "string" then
        pct = (A.SpecVal and A.SpecVal(pct, 20)) or 20
    end
    pct = (pct or 20) / 100
    return maxHP > 0 and (hp / maxHP) < pct
end

RE._condEval["target_hp_pct_gt"] = function(cond, ctx, spec, db)
    if not UnitExists("target") then return false end
    local hp = UnitHealth("target") or 0
    local maxHP = UnitHealthMax("target") or 1
    local pct = cond.pct
    if type(pct) == "string" then
        pct = (A.SpecVal and A.SpecVal(pct, 20)) or 20
    end
    pct = (pct or 20) / 100
    return maxHP > 0 and (hp / maxHP) > pct
end

-- Absolute target HP threshold: true when target absolute HP < provided threshold.
-- Accepts a numeric `hp` or a spec option key (string). A value of 0 disables this check.
RE._condEval["target_hp_lt"] = function(cond, ctx, spec, db)
    if not UnitExists("target") then return false end
    local raw = cond.hp or cond.amount or cond.value
    if raw == nil then return false end
    local hpThr
    if type(raw) == "string" then
        hpThr = (A.SpecVal and A.SpecVal(raw, 0)) or 0
        hpThr = tonumber(hpThr) or 0
    else
        hpThr = tonumber(raw) or 0
    end
    if hpThr <= 0 then return false end -- 0 = disabled
    local targetHP = ctx and ctx.targetHP or ((UnitHealth("target") or 0))
    return targetHP > 0 and targetHP <= hpThr
end

RE._condEval["player_hp_pct_lt"] = function(cond, ctx, spec, db)
    local pct = cond.pct
    if type(pct) == "string" then
        pct = (A.SpecVal and A.SpecVal(pct, 50)) or 50
    end
    pct = (pct or 50) / 100
    return ctx.hpPct < pct
end

RE._condEval["player_hp_pct_gt"] = function(cond, ctx, spec, db)
    local pct = cond.pct
    if type(pct) == "string" then
        pct = (A.SpecVal and A.SpecVal(pct, 50)) or 50
    end
    pct = (pct or 50) / 100
    return ctx.hpPct > pct
end

RE._condEval["player_mana_pct_lt"] = function(cond, ctx, spec, db)
    local pct = cond.pct
    if type(pct) == "string" then
        pct = (A.SpecVal and A.SpecVal(pct, 50)) or 50
    end
    pct = (pct or 50) / 100
    return ctx.manaPct < pct
end

RE._condEval["player_mana_pct_gt"] = function(cond, ctx, spec, db)
    local pct = cond.pct
    if type(pct) == "string" then
        pct = (A.SpecVal and A.SpecVal(pct, 50)) or 50
    end
    pct = (pct or 50) / 100
    return ctx.manaPct > pct
end

RE._condEval["player_base_mana_pct_lt"] = function(cond, ctx, spec, db)
    local pct = cond.pct
    if type(pct) == "string" then
        pct = (A.SpecVal and A.SpecVal(pct, 50)) or 50
    end
    pct = (pct or 50) / 100
    return (ctx.baseManaPct or 0) < pct
end

RE._condEval["player_base_mana_pct_gt"] = function(cond, ctx, spec, db)
    local pct = cond.pct
    if type(pct) == "string" then
        pct = (A.SpecVal and A.SpecVal(pct, 50)) or 50
    end
    pct = (pct or 50) / 100
    return (ctx.baseManaPct or 0) > pct
end

-- Backward-compat aliases for class-specific conditions now covered by buff_on_player.
RE._condEval["clearcasting"] = function(cond, ctx, spec, db)
    local state = GetTrackedBuffState(spec, ctx, "clearcasting")
    return state and state.active or false
end

RE._condEval["cat_form"] = function(cond, ctx, spec, db)
    local state = GetTrackedBuffState(spec, ctx, "cat_form")
    return state and state.active or false
end

RE._condEval["bear_form"] = function(cond, ctx, spec, db)
    local bear = GetTrackedBuffState(spec, ctx, "bear_form")
    if bear and bear.active then return true end
    local direBear = GetTrackedBuffState(spec, ctx, "dire_bear_form")
    return direBear and direBear.active or false
end

RE._condEval["is_stealthed"] = function(cond, ctx, spec, db)
    local state = GetTrackedBuffState(spec, ctx, "stealth")
    return state and state.active or false
end

RE._condEval["not_stealthed"] = function(cond, ctx, spec, db)
    local state = GetTrackedBuffState(spec, ctx, "stealth")
    return not (state and state.active)
end

------------------------------------------------------------------------
-- spell_can_kill_target: generic execute-range check.
-- Uses the spell's SpellDatabase entry (coefficients.spellPower +
-- damage.estimateBase) to estimate damage, then checks whether that
-- exceeds targetHP with an optional safety margin from a spec setting.
-- Fields: spellKey (required), safetyKey (optional setting key or literal %)
-- Power is school-specific: shadow SP for shadow spells, AP for physical, etc.
------------------------------------------------------------------------
RE._condEval["spell_can_kill_target"] = function(cond, ctx, spec, db)
    if not UnitExists("target") or (ctx.targetHP or 0) <= 0 then return false end
    local spellKey = cond.spellKey
    if not spellKey then return false end

    local baseDmg = 0
    local power   = 0
    local def = A.GetSpellDefinition and A.GetSpellDefinition(spellKey)
    if def then
        baseDmg = tonumber(def.damage and def.damage.estimateBase or 0) or 0

        local spCoeff = tonumber(def.coefficients and def.coefficients.spellPower  or 0) or 0
        local apCoeff = tonumber(def.coefficients and def.coefficients.attackPower or 0) or 0

        if spCoeff > 0 then
            -- Magical: use school-specific spell power (e.g. shadow SP for shadow spells).
            local schoolPower = (A.GetSchoolPower and A.GetSchoolPower(def.schoolMask))
                                or (ctx.sp or 0)
            power = schoolPower * spCoeff
        elseif apCoeff > 0 then
            -- Physical: use attack power.
            local ap = (A.GetSchoolPower and A.GetSchoolPower(1)) or 0
            power = ap * apCoeff
        end
    end

    local estimatedDmg = baseDmg + power

    -- Safety margin: a spec setting key (string) or a literal % value.
    local safetyPct = 0
    local safetyRaw = cond.safetyKey
    if safetyRaw then
        local resolved = A.SpecVal and A.SpecVal(safetyRaw, safetyRaw)
        safetyPct = tonumber(resolved) or tonumber(safetyRaw) or 0
    end

    local required = ctx.targetHP * (1 + safetyPct / 100)
    return estimatedDmg >= required
end

-- predicted_kill: legacy alias — still works for Shadow Word: Death.
RE._condEval["predicted_kill"] = function(cond, ctx, spec, db)
    return RE._condEval["spell_can_kill_target"](
        { spellKey = "Shadow Word: Death", safetyKey = "swdSafetyPct" },
        ctx, spec, db
    )
end

RE._condEval["spec_option_enabled"] = function(cond, ctx, spec, db)
    local key = cond.optionKey
    if not key then return false end
    local val = A.SpecVal(key, false)
    return val and val ~= false and val ~= 0
end

RE._condEval["spec_option_value"] = function(cond, ctx, spec, db)
    local key = cond.optionKey
    if not key then return false end
    local val = A.SpecVal(key, nil)
    return tostring(val) == tostring(cond.value)
end

RE._condEval["in_combat"] = function(cond, ctx, spec, db)
    return UnitAffectingCombat("player")
end

RE._condEval["not_in_combat"] = function(cond, ctx, spec, db)
    return not UnitAffectingCombat("player")
end

RE._condEval["not_behind_target"] = function(cond, ctx, spec, db)
    if not UnitExists("target") then return false end
    local evalFn = RE._condEval["behind_target"]
    if not evalFn then return false end
    local ok, res = pcall(evalFn, cond, ctx, spec, db)
    return not (ok and res)
end

RE._condEval["channeling"] = function(cond, ctx, spec, db)
    return ctx.castingSpell ~= nil and UnitChannelInfo("player") ~= nil
end

RE._condEval["cooldown_lt"] = function(cond, ctx, spec, db)
    local key = cond.spellKey
    if not key then return false end
    local cdKey = key:lower() .. "CD"
    local cd = ctx[cdKey]
    if cd == nil then
        local spell = A.SPELLS[key]
        if spell then
            cd = math.max(A.GetSpellCDReal(spell.id) - ctx.castRemaining, 0)
        else
            return false
        end
    end
    return cd < (cond.seconds or 1)
end

RE._condEval["spell_usable"] = function(cond, ctx, spec, db)
    local key = cond.spellKey
    if not key then return false end
    local spell = A.SPELLS[key]
    if not spell then return false end
    if not A.KnowsSpell(spell.id) then return false end
    -- Use IsSpellKnown to check the spell is learned (works while stealthed/out-of-combat).
    -- IsUsableSpell returns false for combat-only spells (e.g. Pounce, Ravage) when in
    -- stealth before combat — we skip usability and only gate on mana/power.
    local known = IsSpellKnown and IsSpellKnown(spell.id)
    if known == false then return false end  -- explicitly not known
    -- Check spell cooldown (projected past current cast). If on cooldown, not usable.
    local castRem = (ctx and ctx.castRemaining) or 0
    local cd = 0
    if A.GetSpellCDReal and spell.id then
        cd = math.max(A.GetSpellCDReal(spell.id) - castRem, 0)
    end
    if cd > 0 then return false end

    local clearcasting = GetTrackedBuffState(spec, ctx, "clearcasting")
    if clearcasting and clearcasting.active then
        return true
    end

    -- If player is stealthed/out-of-combat, IsUsableSpell can report unusable for
    -- combat-only opener spells. In that case, skip IsUsableSpell's boolean and
    -- allow the spell (we already checked cooldown and knowledge).
    local isStealthed = false
    if RE and RE._condEval and RE._condEval["is_stealthed"] then
        local ok, res = pcall(RE._condEval["is_stealthed"], nil, ctx, spec, db)
        if ok and res then isStealthed = true end
    end
    if isStealthed and not ctx.inCombat then
        return true
    end

    -- Otherwise, check mana/resource availability via IsUsableSpell's noMana flag.
    local _, noMana = IsUsableSpell(spell.name or spell.id)
    return not noMana
end

RE._condEval["group_size_gte"] = function(cond, ctx, spec, db)
    local size = cond.size or 1
    local n = GetNumGroupMembers and GetNumGroupMembers() or ((GetNumRaidMembers and GetNumRaidMembers()) or 0)
    if n == 0 then n = (IsInGroup and IsInGroup()) and 1 or 0 end
    return n >= size
end

------------------------------------------------------------------------
-- Phase 9 – Feral / positional / resource / HP-decay evaluators
------------------------------------------------------------------------

-- True if the player is behind the target.
-- If we cannot query a facing API, fail closed so behind-only spells do not
-- get suggested in front of the target.
RE._condEval["behind_target"] = function(cond, ctx, spec, db)
    local debug = {
        hasTarget = UnitExists("target") and true or false,
        unitFacingAvailable = (type(UnitFacing) == "function") and true or false,
        objectFacingAvailable = (type(ObjectFacing) == "function") and true or false,
    }
    if not debug.hasTarget then
        debug.reason = "no_target"
        ctx.behindTargetDebug = debug
        return false
    end
    -- Use player and target positions + target facing to determine if player is behind.
    -- UnitPosition returns (posY, posX, posZ, instanceID).
    local ok, p1, p2, p3, p4 = pcall(UnitPosition, "player")
    local ok2, t1, t2, t3, t4 = pcall(UnitPosition, "target")
    debug.playerPos = { ok = ok and true or false, y = p1, x = p2, z = p3, instanceID = p4 }
    debug.targetPos = { ok = ok2 and true or false, y = t1, x = t2, z = t3, instanceID = t4 }
    if not ok or p1 == nil or p2 == nil then
        debug.reason = "player_position_unavailable"
    end
    if not ok2 or t1 == nil or t2 == nil then
        debug.reason = "target_position_unavailable"
    end
    local targetFacing = nil
    local facingFn = (type(UnitFacing) == "function" and UnitFacing) or (type(ObjectFacing) == "function" and ObjectFacing) or nil
    if facingFn then
        local okf, tf = pcall(facingFn, "target")
        if okf then
            targetFacing = tf
        else
            debug.reason = debug.reason or "facing_api_error"
        end
    end
    debug.targetFacing = targetFacing
    debug.facingSource = facingFn and ((facingFn == UnitFacing) and "UnitFacing" or "ObjectFacing") or "none"

    -- If we don't have facing information, fail closed.
    if not targetFacing then
        debug.reason = debug.reason or "no_facing_api"
        ctx.behindTargetDebug = debug
        return false
    end

    -- Try both possible return-orderings for UnitPosition (some clients differ):
    local candidateCoords = {
        { name = "yx", px = p2, py = p1, tx = t2, ty = t1 },  -- assume UnitPosition -> y,x
        { name = "xy", px = p1, py = p2, tx = t1, ty = t2 },  -- swapped ordering fallback
    }

    for _, c in ipairs(candidateCoords) do
        local px, py, tx, ty = c.px, c.py, c.tx, c.ty
        if px and py and tx and ty then
            local dx = px - tx
            local dy = py - ty
            if dx == 0 and dy == 0 then return true end
            -- Convert the cartesian angle (0 at east) to the WoW facing system
            -- used by UnitFacing/ObjectFacing (0 at north, counterclockwise).
            local angleToPlayer = (math.pi / 2) - math.atan2(dy, dx)
            local backAngle = targetFacing + math.pi
            local diff = angleToPlayer - backAngle
            while diff >  math.pi do diff = diff - 2 * math.pi end
            while diff < -math.pi do diff = diff + 2 * math.pi end
            debug.usedOrdering = c.name
            debug.dx = dx
            debug.dy = dy
            debug.angleToPlayer = angleToPlayer
            debug.backAngle = backAngle
            debug.diff = diff
            if math.abs(diff) <= (math.pi / 2) then
                debug.reason = "behind"
                debug.result = true
                ctx.behindTargetDebug = debug
                return true
            end
        end
    end
    debug.reason = "front_or_undetermined"
    debug.result = false
    ctx.behindTargetDebug = debug
    return false
end

RE._condEval["combo_points_gte"] = function(cond, ctx, spec, db)
    local req = cond.points or 1
    if type(req) == "string" then
        -- Allow reading numeric threshold from spec option keys (e.g. "rip_min_cp")
        if A.SpecVal then
            local v = A.SpecVal(req, nil)
            if v ~= nil then
                req = tonumber(v) or req
            end
        end
    end
    return ctx.comboPoints >= (req or 1)
end

RE._condEval["combo_points_lt"] = function(cond, ctx, spec, db)
    local req = cond.points or 5
    if type(req) == "string" then
        if A.SpecVal then
            local v = A.SpecVal(req, nil)
            if v ~= nil then
                req = tonumber(v) or req
            end
        end
    end
    return ctx.comboPoints < (req or 5)
end

-- Any-source debuff present on unit (cond.unit defaults to "target").
RE._condEval["debuff_on_target"] = function(cond, ctx, spec, db)
    local unit = cond.unit or "target"
    if not UnitExists(unit) then return false end
    local name = ResolveAuraName(cond.debuff, cond.debuffId)
    if not name then return false end
    for i = 1, 40 do
        local bname = UnitDebuff(unit, i)
        if not bname then break end
        if bname == name then return true end
    end
    return false
end

-- Debuff time remaining on target < cond.seconds (any source, by name).
RE._condEval["debuff_time_left_lt"] = function(cond, ctx, spec, db)
    if not UnitExists("target") then return false end
    local name = cond.debuff
    if not name then return false end
    local seconds = cond.seconds or 3
    for i = 1, 40 do
        local bname, _, _, _, _, expireTime = UnitDebuff("target", i)
        if not bname then break end
        if bname == name then
            local rem = expireTime and math.max(expireTime - ctx.now, 0) or 0
            return rem < seconds
        end
    end
    -- Debuff not present at all → treat as 0 remaining → passes the "< seconds" check
    return true
end

-- Compares the target's HP decay rate against a threshold.
-- cond.direction: "faster" (default) means HP is dropping rapidly (target dying).
--                 "slower" means HP is NOT dropping fast (target healthy/tank).
RE._condEval["target_dying_fast"] = function(cond, ctx, spec, db)
    local raw = cond.pctPerSec or 5
    local resolved = raw
    if type(raw) == "string" then
        resolved = (A.SpecVal and A.SpecVal(raw, 5)) or 5
    end
    local threshold = (tonumber(resolved) or 5) / 100  -- convert % to fraction
    local direction = cond.direction or "faster"
    if direction == "slower" then
        return ctx.hpDecayRate < threshold
    end
    return ctx.hpDecayRate >= threshold
end

RE._condEval["target_ttd_gte"] = function(cond, ctx, spec, db)
    local seconds = ResolveNumericValue(cond.seconds, 0)
    if seconds <= 0 then return true end
    local ttd = ctx.targetTTD
    if ttd ~= nil then
        return ttd >= seconds
    end
    if ctx.targetMaxHP and ctx.targetMaxHP > 0 then
        local hpPct = ctx.targetHP / ctx.targetMaxHP
        if hpPct <= 0.25 then
            return false
        end
    end
    return true
end

RE._condEval["target_ttd_lt"] = function(cond, ctx, spec, db)
    local seconds = ResolveNumericValue(cond.seconds, 0)
    if seconds <= 0 then return false end
    local ttd = ctx.targetTTD
    if ttd ~= nil then
        return ttd < seconds
    end
    if ctx.targetMaxHP and ctx.targetMaxHP > 0 then
        local hpPct = ctx.targetHP / ctx.targetMaxHP
        return hpPct <= 0.25
    end
    return false
end

-- Flat resource check: current resource (energy/rage/mana) >= cond.amount.
RE._condEval["resource_gte"] = function(cond, ctx, spec, db)
    return ctx.resourcePower >= (cond.amount or 0)
end

-- Flat resource check: current resource < cond.amount (energy/rage/mana).
RE._condEval["resource_lt"] = function(cond, ctx, spec, db)
    return ctx.resourcePower < (cond.amount or 0)
end

RE._condEval["resource_at_gcd_lt"] = function(cond, ctx, spec, db)
    local req = ResolveNumericValue(cond.amount, 0)
    return (ctx.resourceAtGCD or ctx.resourcePower or 0) < req
end

RE._condEval["resource_at_gcd_gt"] = function(cond, ctx, spec, db)
    local req = ResolveNumericValue(cond.amount, 0)
    return (ctx.resourceAtGCD or ctx.resourcePower or 0) > req
end

RE._condEval["next_power_tick_with_gcd_lt"] = function(cond, ctx, spec, db)
    local seconds = ResolveNumericValue(cond.seconds, 0)
    return (ctx.nextPowerTickWithGCD or 0) < seconds
end

RE._condEval["next_power_tick_with_gcd_gt"] = function(cond, ctx, spec, db)
    local seconds = ResolveNumericValue(cond.seconds, 0)
    return (ctx.nextPowerTickWithGCD or 0) > seconds
end

-- Hard-fail resource check: same as resource_gte but treated as a non-predictive
-- condition by the Evaluate loop (no ETA estimation — entry is simply skipped).
RE._condEval["resource_required_gte"] = function(cond, ctx, spec, db)
    local req = cond.amount or 0
    if type(req) == "string" then
        req = tonumber((A.SpecVal and A.SpecVal(req, tostring(req))) or req) or 0
    end
    return ctx.resourcePower >= req
end

-- Like item_ready_and_owned but reads the itemId from a DB option key.
RE._condEval["item_ready_by_key"] = function(cond, ctx, spec, db)
    local key = cond.itemKey
    if not key then return false end
    local itemId = A.SpecVal and A.SpecVal(key, nil)
    if not itemId or itemId == "none" then return false end
    if type(itemId) == "string" then itemId = tonumber(itemId) end
    if not itemId then return false end
    local count = GetItemCount(itemId) or 0
    if count == 0 then return false end
    local start, dur = A.GetItemCooldownSafe(itemId)
    if start and dur and start > 0 then
        return (start + dur - ctx.now) <= 0
    end
    return true
end

RE._condEval["other_targets_with_debuff_lt"] = function(cond, ctx, spec, db)
    local limit = ResolveNumericValue(cond.count, 0)
    local count = CountOtherTrackedTargetsWithDebuff(spec, ctx, cond.spellKey, cond.seconds, cond.minTTD)
    return count < limit
end

-- Content type check: world, dungeon, or raid.
RE._condEval["content_type"] = function(cond, ctx, spec, db)
    local required = cond.contentType or "world"
    local actual = A.GetContentType()
    return actual == required
end

-- Generic compare family used to cover overlapping *_lt / *_gt style conditions.
RE._condEval["state_compare"] = function(cond, ctx, spec, db)
    local lhs = ResolveStateCompareValue(cond, ctx, spec, db)
    local rhs = ResolveCompareValue(cond.value, lhs)
    return CompareValues(lhs, cond.op, rhs)
end

RE._condEval["spell_property_compare"] = function(cond, ctx, spec, db)
    local lhs = ResolveSpellPropertyValue(cond, ctx, spec, db)
    local rhs = ResolveCompareValue(cond.value, lhs)
    return CompareValues(lhs, cond.op, rhs)
end

RE._condEval["buff_property_compare"] = function(cond, ctx, spec, db)
    local lhs = ResolveBuffPropertyValue(cond, ctx, spec, db)
    local rhs = ResolveCompareValue(cond.value, lhs)
    return CompareValues(lhs, cond.op, rhs)
end

RE._condEval["debuff_property_compare"] = function(cond, ctx, spec, db)
    local lhs = ResolveDebuffPropertyValue(cond, ctx, spec, db)
    local rhs = ResolveCompareValue(cond.value, lhs)
    return CompareValues(lhs, cond.op, rhs)
end

RE._condEval["unit_cast_compare"] = function(cond, ctx, spec, db)
    local lhs = ResolveUnitCastCompareValue(cond, ctx, spec, db)
    local rhs = ResolveCompareValue(cond.value, lhs)
    return CompareValues(lhs, cond.op, rhs)
end

RE._condEval["unit_interruptible"] = function(cond, ctx, spec, db)
    local _, interruptible = GetUnitCastState(cond.unit or "target", ctx.now)
    return interruptible
end

------------------------------------------------------------------------
-- Logical grouping evaluators
--
-- any_of: OR — passes when at least one sub-condition passes.
-- all_of: AND — passes when ALL sub-conditions pass (useful for nesting).
-- not:    NOT — passes when the single wrapped condition fails.
--
-- Example (OR): cast SWP when it is either missing OR expiring soon:
--   { type = "any_of", conditions = {
--       { type = "dot_missing",          spellKey = "SWP" },
--       { type = "projected_dot_time_left_lt", spellKey = "SWP", seconds = 2 },
--   }},
------------------------------------------------------------------------

RE._condEval["any_of"] = function(cond, ctx, spec, db)
    if not cond.conditions then return false end
    for _, subCond in ipairs(cond.conditions) do
        local evalFn = RE._condEval[subCond.type]
        if evalFn then
            local ok, r = pcall(evalFn, subCond, ctx, spec, db)
            if ok and r then return true end
        end
    end
    return false
end

RE._condEval["all_of"] = function(cond, ctx, spec, db)
    if not cond.conditions then return true end
    for _, subCond in ipairs(cond.conditions) do
        local evalFn = RE._condEval[subCond.type]
        if evalFn then
            local ok, r = pcall(evalFn, subCond, ctx, spec, db)
            if not ok or not r then return false end
        end
    end
    return true
end

RE._condEval["not"] = function(cond, ctx, spec, db)
    if not cond.condition then return true end
    local evalFn = RE._condEval[cond.condition.type]
    if not evalFn then return true end
    local ok, r = pcall(evalFn, cond.condition, ctx, spec, db)
    return not (ok and r)
end

-- Composite type aliases: short-form names for spec authors.
-- `any` / `or` -> any_of    `all` / `and` -> all_of
RE._condEval["any"] = RE._condEval["any_of"]
RE._condEval["or"]  = RE._condEval["any_of"]
RE._condEval["all"] = RE._condEval["all_of"]
RE._condEval["and"] = RE._condEval["all_of"]

------------------------------------------------------------------------
-- Simple expression resolver for threshold strings.
    -- Supports additions of generic context keys such as `channelCastEff + lat + SAFETY`.
------------------------------------------------------------------------

function RE._resolveExpr(expr, ctx, spec)
    -- Generic per-spell tokens of the form `cast(KEY)` and `travel(KEY)` are
    -- resolved to haste-adjusted cast time and observed travel time so any
    -- spec can express refresh windows like "cast(SWP) + travel(SWP) + SAFETY"
    -- without hardcoding new tokens for every class.
    local function NormalizeSpellToken(token)
        if type(token) ~= "string" then return token end
        token = token:gsub("^%s+", "")
        token = token:gsub("%s+$", "")
        token = token:gsub('^["\']', "")
        token = token:gsub('["\']$', "")
        return token
    end

    expr = expr:gsub("cast%((.-)%)", function(rawKey)
        local key = NormalizeSpellToken(rawKey)
        local v = GetEffectiveSpellCastTime(key, ctx)
        return tostring(v or 0)
    end)
    expr = expr:gsub("travel%((.-)%)", function(rawKey)
        local key = NormalizeSpellToken(rawKey)
        local v = GetSpellTravelTimeValue(key) or (ctx and ctx.lat) or 0
        return tostring(math.max(v, (ctx and ctx.lat) or 0))
    end)
    -- setting(KEY) — resolve a user-configurable setting value.
    -- This allows expressions to reference dynamic settings, e.g.
    -- "setting(swdSafetyPct) / 100" in a threshold expression.
    expr = expr:gsub("setting%((.-)%)", function(rawKey)
        local key = NormalizeSpellToken(rawKey)
        local v = (A.SpecVal and A.SpecVal(key, 0)) or 0
        return tostring(tonumber(v) or 0)
    end)
    -- spell_damage(KEY) — resolve estimated base damage from SpellDatabase.
    -- Uses SpellDatabase catalog's damage.estimateBase field.
    expr = expr:gsub("spell_damage%((.-)%)", function(rawKey)
        local key = NormalizeSpellToken(rawKey)
        local def = A.GetSpellDefinition and A.GetSpellDefinition(key)
        if def and def.damage and def.damage.estimateBase then
            return tostring(def.damage.estimateBase)
        end
        return "0"
    end)
    -- spell_coeff(KEY) — resolve the spellPower coefficient from SpellDatabase.
    expr = expr:gsub("spell_coeff%((.-)%)", function(rawKey)
        local key = NormalizeSpellToken(rawKey)
        local def = A.GetSpellDefinition and A.GetSpellDefinition(key)
        if def and def.coefficients and def.coefficients.spellPower then
            return tostring(def.coefficients.spellPower)
        end
        return "0"
    end)

    -- Replace known tokens with values
    local env = {
        channelCastEff = ctx.channelCastEff or 0,
        channelMinEff  = ctx.channelMinEff or 0,
        gcd           = ctx.gcd or 1.5,
        lat           = ctx.lat or 0.05,
        vtTravel      = math.max(GetSpellTravelTimeValue("Vampiric Touch") or 0, ctx.lat or 0),
        swpTravel     = math.max(GetSpellTravelTimeValue("Shadow Word: Pain") or 0, ctx.lat or 0),
        mbTravel      = math.max(GetSpellTravelTimeValue("Mind Blast") or 0, ctx.lat or 0),
        swdTravel     = math.max(GetSpellTravelTimeValue("Shadow Word: Death") or 0, ctx.lat or 0),
        channelTickInterval = ctx.channelTickInterval or 0,
        channelToNextTick = ctx.channelTimeToNextTick or 0,
        channelTicksRemaining = ctx.channelTicksRemaining or 0,
        SAFETY        = ctx.SAFETY or 0.5,
        castRemaining = ctx.castRemaining or 0,
    }
    -- Replace each token in expr with its numeric value
    local resolved = expr
    for token, val in pairs(env) do
        resolved = resolved:gsub(token, tostring(val))
    end
    -- Safe arithmetic evaluation via loadstring (only math operators)
    -- Strip anything that isn't digits, dots, spaces, +, -, *, /
    local sanitized = resolved:gsub("[^%d%.%s%+%-%*/%(%)]+", "")
    if sanitized == "" then return 0 end
    local fn = loadstring("return " .. sanitized)
    if fn then
        local ok, result = pcall(fn)
        if ok and type(result) == "number" then return result end
    end
    return 0
end

local function EntryHasConditionType(entry, condType)
    for _, cond in ipairs(entry.conditions or {}) do
        if cond and cond.type == condType then
            return true
        end
    end
    return false
end

------------------------------------------------------------------------
-- Class-agnostic refresh-ETA helper.
--
-- Walks an entry's conditions and computes "seconds until this entry
-- becomes castable" by inspecting:
--   * `cooldown_ready`             — spell cooldown gating
--   * `projected_dot_time_left_lt` — DoT-refresh window (absolute remaining
--                                    minus the threshold expression)
--   * `dot_time_left_lt`           — same, but uses non-projected remaining
--   * `debuff_property_compare` (property=remaining, op=<|<=) — generic
--                                  refresh window for any tracked debuff
--
-- Returns the largest gating ETA found, or nil if no gating condition was
-- recognised. The caller can use this to display a live countdown for
-- entries that are not yet candidates ("when will this be the next cast?")
-- and to determine an ETA for currently-blocked candidates so the queue
-- icons keep counting down.
------------------------------------------------------------------------
local function ResolveDebuffRemaining(spec, ctx, cond)
    local spellKey = cond and cond.spellKey or nil
    if spellKey then
        local state = GetTrackedDebuffState(spec, ctx, spellKey)
        if state then
            return state.remaining or 0
        end
    end

    local debuffName = cond and cond.debuff or nil
    if not debuffName and spellKey then
        local def = A.GetSpellDefinition and A.GetSpellDefinition(spellKey) or nil
        debuffName = def and def.name or nil
    end
    if not debuffName then return 0 end

    local source = cond and cond.source or "player"
    local fn = (source == "any" and A.FindDebuff) or A.FindPlayerDebuff
    if not fn then return 0 end
    local _, _, _, _, _, exp = fn("target", debuffName)
    if not exp then return 0 end
    return math.max(exp - (ctx.now or GetTime()), 0)
end

function RE._ComputeEntryRefreshETA(entry, ctx, spec)
    if not entry or not entry.conditions then return nil end

    local maxEta
    local function bump(value)
        if not value or value < 0 then return end
        if not maxEta or value > maxEta then maxEta = value end
    end

    for _, cond in ipairs(entry.conditions) do
        local t = cond and cond.type
        -- IMPORTANT: ETAs returned here are seconds-from-NOW until the
        -- entry becomes castable. We deliberately do NOT subtract
        -- `castRemaining` from these values: the absolute moment when a
        -- spell becomes castable / a DoT needs refreshing is anchored in
        -- real time (cooldown end, debuff expiration), and `cooldownEnd =
        -- now + eta` would otherwise drift forward each refresh during a
        -- cast (`now` advances, `castRem` shrinks, eta stays constant)
        -- making the displayed countdown freeze instead of ticking.
        if t == "cooldown_ready" then
            local key = cond.spellKey
            local spell = key and A.SPELLS and A.SPELLS[key]
            if spell and spell.id and A.GetSpellCDReal then
                local cd = A.GetSpellCDReal(spell.id) or 0
                bump(math.max(cd, 0))
            end
        elseif t == "projected_dot_time_left_lt" then
            local rem = ResolveDebuffRemaining(spec, ctx, cond)
            local thresh = 0
            if type(cond.seconds) == "number" then
                thresh = cond.seconds
            elseif type(cond.seconds) == "string" then
                thresh = RE._resolveExpr(cond.seconds, ctx, spec) or 0
            elseif cond.spellKey then
                thresh = GetEffectiveSpellCastTime(cond.spellKey, ctx) or 0
            end
            -- Refresh moment in absolute time = expirationTime - threshold.
            -- Time-from-now = rem - threshold. (No castRem subtraction.)
            bump(math.max(rem - thresh, 0))
        elseif t == "dot_time_left_lt" then
            local rem = ResolveDebuffRemaining(spec, ctx, cond)
            local thresh = ResolveNumericValue(cond.seconds, 0) or 0
            bump(math.max(rem - thresh, 0))
        elseif t == "debuff_property_compare" and cond.property == "remaining" then
            local op = cond.op or ">="
            if op == "<" or op == "<=" or op == "lt" or op == "lte" or op == "le" then
                local rem = ResolveDebuffRemaining(spec, ctx, cond)
                local thresh = ResolveNumericValue(cond.value, 0) or 0
                bump(math.max(rem - thresh, 0))
            end
        end
    end

    return maxEta
end

function RE:_EvaluateEntry(entry, index, ctx, spec, db, hasTarget, wantDiagnostics)
    local diag = nil
    if wantDiagnostics then
        diag = {
            index = index,
            key = entry.key,
            status = "fail",
            conditionResults = {},
        }
    end

    local blocked = false
    local resourceBlock = nil
    local otherFail = false
    local entrySpell = entry.key and A.SPELLS and A.SPELLS[entry.key]

    if entrySpell and not A.KnowsSpell(entrySpell.id) then
        otherFail = true
        if diag then diag.status = "unknown_spell" end
    else
        for _, cond in ipairs(entry.conditions or {}) do
            if cond.type == "resource_gte" then
                local req = ResolveNumericValue(cond.amount, 0)
                local passNow = (ctx.resourcePower or 0) >= req
                if not passNow then
                    resourceBlock = { required = req }
                end
                if diag then
                    diag.conditionResults[#diag.conditionResults + 1] = {
                        cond = cond,
                        pass = passNow,
                        status = passNow and "pass" or "predict",
                        required = req,
                    }
                end
            elseif cond.type == "resource_pct_gt" then
                local pct = ResolveNumericValue(cond.pct, 0)
                local max = UnitPowerMax("player") or 100
                local req = math.floor(max * ((pct or 0) / 100) + 0.5)
                local passNow = (ctx.resourcePower or 0) >= req
                if not passNow then
                    resourceBlock = { required = req }
                end
                if diag then
                    diag.conditionResults[#diag.conditionResults + 1] = {
                        cond = cond,
                        pass = passNow,
                        status = passNow and "pass" or "predict",
                        required = req,
                    }
                end
            elseif cond.type == "resource_pct_lt" then
                local evalFn = self._condEval[cond.type]
                if evalFn then
                    local ok, result = pcall(evalFn, cond, ctx, spec, db)
                    if not ok or not result then
                        otherFail = true
                        if diag then
                            diag.conditionResults[#diag.conditionResults + 1] = { cond = cond, pass = false, status = "fail" }
                        end
                        break
                    end
                    if diag then
                        diag.conditionResults[#diag.conditionResults + 1] = { cond = cond, pass = true, status = "pass" }
                    end
                else
                    otherFail = true
                    if diag then
                        diag.conditionResults[#diag.conditionResults + 1] = { cond = cond, pass = false, status = "unknown" }
                    end
                    break
                end
            elseif cond.type == "state_compare" then
                local subject = cond.subject
                local op = cond.op or ">="
                local isGreater = (op == ">" or op == ">=" or op == "gt" or op == "gte" or op == "ge")
                local predictiveResource = subject == "resource"
                    or (subject == "resource_pct" and cond.resource ~= "mana" and cond.resource ~= "hp")
                if predictiveResource and isGreater then
                    local req
                    if subject == "resource" then
                        req = ResolveNumericValue(cond.value, 0) or 0
                    else
                        local pct = ResolveNumericValue(cond.value, 0) or 0
                        local max = UnitPowerMax("player") or 100
                        if max <= 0 then max = 100 end
                        req = math.floor(max * (pct / 100) + 0.5)
                    end
                    if op == ">" or op == "gt" then
                        req = req + 1
                    end

                    local passNow = (ctx.resourcePower or 0) >= req
                    if not passNow then
                        resourceBlock = { required = req }
                    end
                    if diag then
                        diag.conditionResults[#diag.conditionResults + 1] = {
                            cond = cond,
                            pass = passNow,
                            status = passNow and "pass" or "predict",
                            required = req,
                        }
                    end
                else
                    local evalFn = self._condEval[cond.type]
                    if evalFn then
                        local ok, result = pcall(evalFn, cond, ctx, spec, db)
                        if not ok or not result then
                            otherFail = true
                            if diag then
                                diag.conditionResults[#diag.conditionResults + 1] = { cond = cond, pass = false, status = "fail" }
                            end
                            break
                        end
                        if diag then
                            diag.conditionResults[#diag.conditionResults + 1] = { cond = cond, pass = true, status = "pass" }
                        end
                    else
                        otherFail = true
                        if diag then
                            diag.conditionResults[#diag.conditionResults + 1] = { cond = cond, pass = false, status = "unknown" }
                        end
                        break
                    end
                end
            elseif cond.type == "spell_usable" then
                local key = cond.spellKey
                local spell = key and A.SPELLS and A.SPELLS[key]
                if not spell or not A.KnowsSpell(spell.id) then
                    otherFail = true
                    if diag then
                        diag.conditionResults[#diag.conditionResults + 1] = { cond = cond, pass = false, status = "fail" }
                    end
                    break
                end
                local cd = math.max(A.GetSpellCDReal(spell.id) - ctx.castRemaining, 0)
                if cd > 0 then
                    blocked = true
                    if diag then
                        diag.conditionResults[#diag.conditionResults + 1] = { cond = cond, pass = false, status = "predict", cooldown = cd }
                    end
                else
                    local _, noMana = IsUsableSpell(spell.name or spell.id)
                    if noMana then
                        resourceBlock = resourceBlock or { required = nil }
                        if diag then
                            diag.conditionResults[#diag.conditionResults + 1] = { cond = cond, pass = false, status = "predict" }
                        end
                    else
                        if diag then
                            diag.conditionResults[#diag.conditionResults + 1] = { cond = cond, pass = true, status = "pass" }
                        end
                    end
                end
            elseif cond.type == "debuff_property_compare" and cond.property == "remaining" then
                -- Timed block: treat "debuff remaining < N" as a countdown gate
                -- so refresh entries (Faerie Fire, Mangle debuff, etc.) appear in
                -- the queue with a live timer rather than being silently discarded.
                local op = cond.op or ">="
                if op == "<" or op == "<=" or op == "lt" or op == "lte" or op == "le" then
                    local evalFn = self._condEval[cond.type]
                    local passNow = false
                    if evalFn then
                        local ok, r = pcall(evalFn, cond, ctx, spec, db)
                        passNow = ok and r or false
                    end
                    if not passNow then
                        -- Debuff is still healthy. Discard this entry from the
                        -- candidate list; the synth timeline system will insert
                        -- it at the correct queue position with a live countdown.
                        otherFail = true
                        if diag then
                            diag.conditionResults[#diag.conditionResults + 1] = {
                                cond = cond, pass = false, status = "predict_synth",
                            }
                        end
                        break
                    else
                        if diag then
                            diag.conditionResults[#diag.conditionResults + 1] = { cond = cond, pass = true, status = "pass" }
                        end
                    end
                else
                    -- Other comparison ops (remaining >= N, remaining == N, etc.) — evaluate normally.
                    local evalFn = self._condEval[cond.type]
                    if evalFn then
                        local ok, result = pcall(evalFn, cond, ctx, spec, db)
                        if not ok or not result then
                            otherFail = true
                            if diag then
                                diag.conditionResults[#diag.conditionResults + 1] = { cond = cond, pass = false, status = "fail" }
                            end
                            break
                        end
                        if diag then
                            diag.conditionResults[#diag.conditionResults + 1] = { cond = cond, pass = true, status = "pass" }
                        end
                    else
                        otherFail = true
                        if diag then
                            diag.conditionResults[#diag.conditionResults + 1] = { cond = cond, pass = false, status = "unknown" }
                        end
                        break
                    end
                end
            elseif cond.type == "any_of" or cond.type == "all_of" then
                -- For composite groups containing resource checks, try to extract
                -- a resource requirement so the entry shows up as resource-blocked
                -- instead of being silently discarded.
                -- Strategy: evaluate the group normally first.  If it passes, great.
                -- If it fails AND it contains a resource_gte/resource_pct_gt/state_compare(resource)
                -- as the ONLY non-resource sub-condition (or the ONLY failing sub-condition in all_of),
                -- treat it as a resource block so the entry joins the queue.
                local evalFn = self._condEval[cond.type]
                local passNow = false
                if evalFn then
                    local ok, r = pcall(evalFn, cond, ctx, spec, db)
                    passNow = ok and r or false
                end
                if passNow then
                    if diag then
                        diag.conditionResults[#diag.conditionResults + 1] = { cond = cond, pass = true, status = "pass" }
                    end
                else
                    -- Scan sub-conditions for a resource gate we can predict.
                    local resSub = nil
                    local allSubsAreResourceOrCC = true
                    for _, sub in ipairs(cond.conditions or {}) do
                        if sub.type == "resource_gte" then
                            resSub = sub
                        elseif sub.type == "resource_pct_gt" then
                            resSub = sub
                        elseif sub.type == "state_compare" and sub.subject == "resource" then
                            local subOp = sub.op or ">="
                            if subOp == ">" or subOp == ">=" or subOp == "gt" or subOp == "gte" or subOp == "ge" then
                                resSub = sub
                            else
                                allSubsAreResourceOrCC = false
                            end
                        elseif sub.type == "clearcasting" then
                            -- clearcasting is a valid "free cast" alternative to spending resources
                        else
                            allSubsAreResourceOrCC = false
                        end
                    end
                    if resSub and allSubsAreResourceOrCC then
                        -- All alternatives in this group are resource checks or clearcasting.
                        -- Treat failure as a resource block.
                        local req
                        if resSub.type == "resource_gte" then
                            req = ResolveNumericValue(resSub.amount, 0) or 0
                        elseif resSub.type == "resource_pct_gt" then
                            local pct = ResolveNumericValue(resSub.pct, 0) or 0
                            local maxR = UnitPowerMax("player") or 100
                            req = math.floor(maxR * (pct / 100) + 0.5)
                        elseif resSub.type == "state_compare" then
                            req = ResolveNumericValue(resSub.value, 0) or 0
                        end
                        resourceBlock = resourceBlock or { required = req }
                        if diag then
                            diag.conditionResults[#diag.conditionResults + 1] = {
                                cond = cond, pass = false, status = "predict", required = req,
                            }
                        end
                    else
                        -- Mixed group with non-resource conditions — can't predict timing.
                        otherFail = true
                        if diag then
                            diag.conditionResults[#diag.conditionResults + 1] = { cond = cond, pass = false, status = "fail" }
                        end
                        break
                    end
                end
            else
                local evalFn = self._condEval[cond.type]
                if evalFn then
                    local ok, result = pcall(evalFn, cond, ctx, spec, db)
                    if not ok or not result then
                        otherFail = true
                        if diag then
                            diag.conditionResults[#diag.conditionResults + 1] = { cond = cond, pass = false, status = "fail" }
                        end
                        break
                    end
                    if diag then
                        diag.conditionResults[#diag.conditionResults + 1] = { cond = cond, pass = true, status = "pass" }
                    end
                else
                    otherFail = true
                    if diag then
                        diag.conditionResults[#diag.conditionResults + 1] = { cond = cond, pass = false, status = "unknown" }
                    end
                    break
                end
            end
        end
    end

    if not otherFail and resourceBlock and EntryHasConditionType(entry, "precombat") then
        otherFail = true
        if diag then diag.precombatResourceFail = true end
    end

    local allowCandidate = true
    if entry.key ~= "POTION" and entry.key ~= "RUNE" and entry.key ~= "Shadowfiend" then
        if not hasTarget and not resourceBlock then
            allowCandidate = false
        end
    end

    if diag then
        diag.blocked = blocked
        diag.resourceBlock = resourceBlock
        diag.allowCandidate = allowCandidate
        diag.otherFail = otherFail
    end

    if otherFail or not allowCandidate then
        if diag and not otherFail and not allowCandidate then
            diag.status = "no_target"
        end
        return nil, diag
    end

    local eta = 0
    local spell = A.SPELLS[entry.key]
    if spell and spell.id then
        -- Time-from-now until spell is off cooldown. (See note in
        -- _ComputeEntryRefreshETA: do NOT subtract castRemaining here or
        -- the displayed countdown freezes during a cast.)
        eta = math.max(A.GetSpellCDReal(spell.id) or 0, 0)
    end
    if resourceBlock then
        local req = resourceBlock.required
        if not req then
            if ctx.nextPowerTick then
                eta = math.max(eta, ctx.nextPowerTick)
            else
                eta = math.max(eta, 0.5)
            end
        else
            local have = ctx.resourcePower or 0
            local need = math.max(0, req - have)
            local regen = ctx.resourceRegen or 0
            if regen > 0.001 then
                local t = need / regen
                if ctx.nextPowerTick and ctx.nextPowerTick > 0 then
                    local ticks = math.ceil(t / math.max(0.001, ctx.nextPowerTick))
                    t = ticks * ctx.nextPowerTick
                end
                eta = math.max(eta, t)
            else
                if ctx.nextPowerTick then
                    eta = math.max(eta, ctx.nextPowerTick)
                else
                    eta = math.max(eta, 1.0)
                end
            end
        end
    end
    if diag then
        diag.eta = eta
        diag.status = (resourceBlock or blocked) and "predict" or "pass"
    end

    return {
        key   = entry.key,
        index = index,
        eta   = eta,
        clip  = false,
        entry = entry,
        priorityBucket = ResolveEntryPriorityBucket(entry),
    }, diag
end

function RE:_BuildResultFromCandidates(ctx, rotation, hasTarget, candidates, spec)
    local WAIT_THRESHOLD = ctx.WAIT_THRESHOLD
    local now = ctx.now or GetTime()

    table.sort(candidates, function(a, b)
        return a.index < b.index
    end)

    local result = {}
    local seen   = {}

    -- Add a result entry with both an `eta` (used for ordering / "next cast"
    -- semantics) and a `cooldownEnd` absolute timestamp so the UI can render
    -- a smoothly-ticking countdown without stalling when the player is in
    -- the middle of a cast/channel.
    -- `isChained` marks entries that are sequenced in the cast chain (ready
    -- but not castable yet because something else is being cast first) vs
    -- entries that are genuinely blocked by a cooldown or resource deficit.
    -- Chained entries are rendered bright; blocked entries are dimmed.
    local function Add(key, eta, clip, priorityBucket, cooldownEnd, isChained)
        if seen[key] then return end
        eta = eta or 0
        local entry = { key = key, eta = eta }
        if cooldownEnd and cooldownEnd > now then
            entry.cooldownEnd = cooldownEnd
        elseif eta > 0 then
            entry.cooldownEnd = now + eta
        end
        if clip then entry.clip = true end
        if isChained then entry.chained = true end
        if priorityBucket ~= nil then entry.priorityBucket = priorityBucket end
        result[#result + 1] = entry
        seen[key] = true
        local base = key:match("^([A-Z]+)_")
        if base and A.SPELLS[base] then
            seen[base] = true
        end
    end

    -- Two-phase processing: prefer ready candidates (eta ~ 0) for the
    -- top-of-list slot. Resource/refresh-blocked candidates get queued
    -- with their ETA so the user sees a live countdown without losing
    -- the "cast something now" suggestion at the top.
    --
    -- All ETAs here are seconds-from-NOW so cooldownEnd = now + eta is a
    -- stable absolute timestamp that ticks down naturally during a cast.
    local READY_EPSILON = 0.05
    local readyCands = {}
    local blockedCands = {}
    for _, cand in ipairs(candidates) do
        local spell = A.SPELLS[cand.key]
        local rawCD = 0
        if spell and spell.id then
            rawCD = A.GetSpellCDReal(spell.id) or 0
        end
        local candEta = cand.eta or 0
        local readyIn = math.max(candEta, rawCD)
        local cooldownEnd = (readyIn > 0) and (now + readyIn) or nil

        if cand.key then
            local bucket = (readyIn <= READY_EPSILON) and readyCands or blockedCands
            bucket[#bucket + 1] = {
                cand = cand, readyIn = readyIn, clip = false, cooldownEnd = cooldownEnd,
            }
        end
    end

    -- ------------------------------------------------------------------
    -- Class-agnostic DoT-refresh timeline merge.
    --
    -- For every rotation entry with `projected_dot_time_left_lt` that is
    -- NOT yet a candidate (dot still healthy, condition not fired), compute:
    --
    --   deadline = dotRem - (castEff + travel + SAFETY)   (seconds from NOW)
    --   = the latest moment FROM NOW at which we can START casting this spell
    --     without the dot expiring before the cast lands.
    --
    -- Walk readyCands in order, accumulating chain time. Before each step,
    -- flush synths whose deadline would be missed if we took that step first.
    -- The synth is inserted AT the current position (before the step that
    -- would miss it).
    --
    -- KEY RULE: synths are NEVER inserted before position 1.
    --   Position 1 is reserved for natural candidates emitted by
    --   _EvaluateEntry when `projected_dot_time_left_lt` fires
    --   (dotRem < castEff + travel + SAFETY). A synth exists precisely while
    --   dotRem >= threshold, so it should never be at position 1 — the
    --   natural condition handles that transition cleanly. Skipping the flush
    --   before position 1 prevents a premature "cast VT now" suggestion that
    --   arrives ~1 GCD before the actual threshold.
    --
    -- TIMER RULE:
    --   * Synths always use `now + s.deadline` as cooldownEnd regardless of
    --     which slot they end up in. This equals `dotExpiry - own` — a stable
    --     absolute timestamp that ticks naturally. Chain-position time (accTime)
    --     resets every 0.1s evaluation and must NOT be used for synth timers.
    --   * Chain readyCands show NO timer (cooldownEnd = nil, eta = 0) unless
    --     they are the primary slot during an active cast, where the timer
    --     shows the remaining cast/channel time. This avoids the "1.5 / 3.0 /
    --     4.5 static" display the user reported.
    --   * Blocked candidates (real spell CD or resource) already carry a
    --     `cooldownEnd` anchored to `now + rawCD` which ticks correctly.
    -- ------------------------------------------------------------------
    local function ChainStepTime(key)
        local castEff = GetEffectiveSpellCastTime(key, ctx) or 0
        return math.max(castEff, ctx.gcd or 1.5)
    end

    local function GetDotRemaining(spellKey)
        local state = GetTrackedDebuffState(spec, ctx, spellKey)
        if state then
            return state.remaining or 0
        end
        local debuffName = GetSpellDisplayName(spellKey)
        if debuffName and A.FindPlayerDebuff then
            local _, _, _, _, _, expirationTime = A.FindPlayerDebuff("target", debuffName)
            if expirationTime then return math.max(expirationTime - now, 0) end
        end
        return 0
    end

    local function GetRefreshDeadline(entry)
        if not entry or not entry.conditions then return nil end
        for _, cond in ipairs(entry.conditions) do
            if cond.type == "projected_dot_time_left_lt" then
                local key    = cond.spellKey or entry.key
                local dotRem = ResolveDebuffRemaining(spec, ctx, cond)
                if dotRem <= 0 then return nil end
                local castEff = GetEffectiveSpellCastTime(key, ctx) or 0
                return math.max(dotRem - castEff, 0)
            elseif cond.type == "debuff_property_compare"
                    and cond.property == "remaining"
                    and (cond.op == "<" or cond.op == "<=" or cond.op == "lt" or cond.op == "lte" or cond.op == "le") then
                -- Generic refresh window: e.g. Faerie Fire remaining < 2, Mangle remaining < 2.
                -- deadline = how many seconds from NOW until we must START casting.
                -- = max(remaining - threshold - castTime, 0)
                -- Synth shows in the queue when accTime approaches deadline so the
                -- user sees the refresh spell gradually move up the chain.
                local rem = ResolveDebuffRemaining(spec, ctx, cond)
                if rem <= 0 then return nil end  -- debuff absent/expired → condition already fires → entry is a readyCandidate
                local thresh = ResolveNumericValue(cond.value, 0) or 0
                if rem <= thresh then return nil end  -- already in refresh window → entry is a readyCandidate
                local castEff = GetEffectiveSpellCastTime(entry.key, ctx) or 0
                return math.max(rem - thresh - castEff, 0)
            end
        end
        return nil
    end

    -- Collect synths: refresh-pending entries not already in candidates.
    local seenCandKeys = {}
    for _, c in ipairs(readyCands)   do seenCandKeys[c.cand.key] = true end
    for _, c in ipairs(blockedCands) do seenCandKeys[c.cand.key] = true end

    local synths = {}
    for _, entry in ipairs(rotation) do
        if entry.key and not seenCandKeys[entry.key] and entry.conditions then
            local deadline = GetRefreshDeadline(entry)
            if deadline ~= nil then
                local spell = A.SPELLS[entry.key]
                local rawCD = (spell and spell.id and (A.GetSpellCDReal(spell.id) or 0)) or 0
                if spell and spell.id and rawCD <= READY_EPSILON then
                    synths[#synths + 1] = { deadline = deadline, entry = entry, key = entry.key }
                end
            end
        end
    end
    table.sort(synths, function(a, b) return a.deadline < b.deadline end)

    -- accTime accumulates chain time starting from the end of the current
    -- cast/channel. When channeling a clippable spell (allowClipping = true),
    -- accTime starts from clipCastRemaining (next tick) rather than the full
    -- channel remaining, so chain-position cooldownEnds reflect the clip point.
    local accTime = (ctx.clipCastRemaining ~= nil) and ctx.clipCastRemaining or (ctx.castRemaining or 0)
    local si = 1  -- next unplaced synth index

    local activeChannelConfig = GetChannelSpellConfig(spec, ctx.activeChannelSpellKey)
    local activeChannelSpellKey = activeChannelConfig and (activeChannelConfig.spellKey or activeChannelConfig.key) or nil
    local activeChannelCastEff = activeChannelSpellKey and (GetEffectiveSpellChannelTime(activeChannelSpellKey, ctx) or 0) or 0
    local activeChannelElapsed = math.max(activeChannelCastEff - (ctx.castRemaining or 0), 0)
    local activeChannelMinRemaining = 0
    if activeChannelConfig then
        activeChannelMinRemaining = math.max((tonumber(activeChannelConfig.minDuration) or 0) - activeChannelElapsed, 0)
    end

    -- Flush all synths whose deadline < threshold into the queue at the
    -- current position. Synths always use their deadline as the cooldownEnd
    -- anchor (= dotExpiry - own = constant absolute), not the chain position.
    local function FlushSynthsBefore(threshold)
        while si <= #synths and synths[si].deadline < threshold do
            local s = synths[si]; si = si + 1
            -- `now + s.deadline` = absolute "must-start-by" timestamp.
            -- Stable across re-evaluations because dotExpiry is fixed by the API.
            local cd = (s.deadline > READY_EPSILON) and (now + s.deadline) or nil
            Add(s.key, 0, false, ResolveEntryPriorityBucket(s.entry), cd)
            accTime = accTime + ChainStepTime(s.key)
        end
    end

    for i, c in ipairs(readyCands) do
        local step = ChainStepTime(c.cand.key)

        -- ── Casting-spell correction ──────────────────────────────────
        -- `accTime` is initialised to `castRemaining`, which already
        -- represents "the currently-casting spell finishes in N seconds".
        -- If that spell also surfaces as position-1 in the chain
        -- (e.g. VT refreshes itself while mid-cast), adding its full
        -- ChainStepTime would double-count the cast duration and push
        -- every subsequent spell (SWP, MB, …) back by one extra cast time.
        --
        -- For a non-channel cast the GCD runs concurrently with the cast
        -- and both expire at the same moment, so the "next-slot" step is
        -- max(gcdRemaining, 0) – accTime (i.e. any GCD extension beyond
        -- the cast, which is 0 for spells where cast ≥ GCD).
        if i == 1 and ctx.castingSpell and not ctx.activeChannelSpellKey then
            local spellEntry = A.SPELLS and A.SPELLS[c.cand.key]
            if spellEntry and spellEntry.name == ctx.castingSpell then
                -- Replace step with only the GCD overhang (almost always 0).
                step = math.max((ctx.gcdRemaining or 0) - accTime, 0)
            end
        end

        -- Never insert synths before position 1 (i == 1).
        -- The natural `projected_dot_time_left_lt` condition handles the
        -- position-1 transition when the tracked debuff crosses its
        -- threshold.
        if i > 1 then
            FlushSynthsBefore(accTime + step)
        end

        local channelClip = false
        local channelClipKey = nil
        local channelClipTime = nil
        local channelClipBucket = nil
        if activeChannelConfig and activeChannelSpellKey and c.cand.key == activeChannelSpellKey and ctx.activeChannelSpellKey == activeChannelSpellKey then
            local clipReasons = activeChannelConfig.clipReasons or {}
            for _, reasonKey in ipairs(clipReasons) do
                local reasonEntry = nil
                for _, rEntry in ipairs(rotation) do
                    if rEntry.key == reasonKey then
                        reasonEntry = rEntry
                        break
                    end
                end
                if reasonEntry then
                    local reasonEta = RE._ComputeEntryRefreshETA(reasonEntry, ctx, spec)
                    if reasonEta ~= nil then
                        local breakAt = math.max(activeChannelMinRemaining, reasonEta)
                        if breakAt < activeChannelCastEff and (not channelClipTime or breakAt < channelClipTime) then
                            channelClip = true
                            channelClipKey = reasonKey
                            channelClipTime = breakAt
                            channelClipBucket = ResolveEntryPriorityBucket(reasonEntry)
                        end
                    end
                end
            end
        end

        if channelClip and channelClipKey then
            local clipCd = (channelClipTime and channelClipTime > READY_EPSILON) and (now + channelClipTime) or nil
            Add(channelClipKey, 0, false, channelClipBucket, clipCd, true)
            Add(c.cand.key, 0, true, c.cand.priorityBucket, nil, true)
        else
            -- Compute chain-position cooldownEnd so every queued spell shows
            -- a timer reflecting when it will actually be cast:
            --   accTime = castRemaining + sum of cast times of all prior chain items.
            -- This equals (now + accTime) = a stable absolute timestamp that
            -- ticks naturally as the cast progresses (now increases, castRemaining
            -- decreases by the same amount, so now+accTime is constant).
            -- If a real spell cooldown is longer, that takes priority.
            local chainCooldownEnd
            if c.cooldownEnd and c.cooldownEnd > now then
                -- Actual rawCD dominates (edge case: rawCD just at READY_EPSILON boundary).
                chainCooldownEnd = c.cooldownEnd
            elseif accTime > READY_EPSILON then
                -- Chain position: won't be cast until accTime seconds from now.
                chainCooldownEnd = now + accTime
            end
            Add(c.cand.key, 0, c.clip, c.cand.priorityBucket, chainCooldownEnd, true)
        end
        accTime = accTime + step
    end

    -- Tail synths: show any synth whose deadline falls within the chain
    -- horizon PLUS a lookahead of (N_VISIBLE_SLOTS * gcd). This gives the
    -- player advance notice of upcoming dot refreshes even when the active
    -- chain is short (e.g. only MF as the filler). Without the lookahead,
    -- a dot with 4.5s remaining on a 3s chain wouldn't appear until the
    -- last 4.5s, which feels "late". Using 3 extra GCDs ≈ 4.5s extra lead.
    local tailHorizon = accTime + (ctx.gcd or 1.5) * 3
    while si <= #synths do
        local s = synths[si]; si = si + 1
        if s.deadline <= tailHorizon then
            local cd = (s.deadline > READY_EPSILON) and (now + s.deadline) or nil
            Add(s.key, 0, false, ResolveEntryPriorityBucket(s.entry), cd)
        end
    end

    -- ------------------------------------------------------------------
    -- Post-cast resource projection.
    -- If the top ready candidate has `entry.postCast` data declaring how it
    -- modifies a resource (e.g. powershift refunds energy via Furor +
    -- Wolfshead), build a projected ctx with that resource state and
    -- re-evaluate blocked candidates so their ETAs reflect the post-cast
    -- world. This is what makes "Cat Form (powershift)" show "Shred ready
    -- in 1.5s" instead of "Shred ready when energy regens to 42".
    -- ------------------------------------------------------------------
    local topReady = readyCands[1]
    local postCast = topReady and topReady.cand and topReady.cand.entry and topReady.cand.entry.postCast
    if postCast and #blockedCands > 0 then
        local pCtx = setmetatable({}, { __index = ctx })
        local resource = postCast.resource or "energy"
        local maxR = (resource == "mana" and (UnitPowerMax("player", 0) or 1)) or (UnitPowerMax("player") or 100)
        if maxR <= 0 then maxR = 100 end

        local newVal
        if postCast.set ~= nil then
            local v = postCast.set
            if type(v) == "string" then
                v = (A.SpecVal and tonumber(A.SpecVal(v, v))) or tonumber(v) or 0
            end
            newVal = tonumber(v) or 0
        elseif postCast.delta ~= nil then
            local d = postCast.delta
            if type(d) == "string" then
                d = (A.SpecVal and tonumber(A.SpecVal(d, d))) or tonumber(d) or 0
            end
            newVal = (ctx.resourcePower or 0) + (tonumber(d) or 0)
        end

        if newVal then
            newVal = math.min(math.max(newVal, 0), maxR)
            if resource == "mana" then
                pCtx.currentMana = newVal
                pCtx.manaPct = newVal / maxR
            else
                pCtx.resourcePower = newVal
                pCtx.resourceAtGCD = newVal
            end
            -- Anchor projection just past the GCD finish so blocked entries
            -- compute their post-GCD readiness against the boosted resource.
            local gcd = ctx.gcd or 1.5
            pCtx.castRemaining = gcd
            pCtx.readyIn = gcd

            local recomputed = {}
            for _, b in ipairs(blockedCands) do
                local newCand = self:_EvaluateEntry(b.cand.entry, b.cand.index, pCtx, spec, db, hasTarget, false)
                if newCand then
                    local spell = A.SPELLS[b.cand.key]
                    local rawCD = (spell and spell.id and (A.GetSpellCDReal(spell.id) or 0)) or 0
                    local readyIn = math.max(newCand.eta or 0, math.max(rawCD - (ctx.castRemaining or 0), 0))
                    -- Add the GCD time we will spend casting the top entry.
                    readyIn = readyIn + gcd
                    recomputed[#recomputed + 1] = {
                        cand = b.cand,
                        readyIn = readyIn,
                        clip = b.clip,
                        cooldownEnd = now + readyIn,
                    }
                else
                    recomputed[#recomputed + 1] = b
                end
            end
            blockedCands = recomputed
        end
    end

    -- Show the soonest blocked candidate first so the user sees the most
    -- imminent next cast above slower fallbacks.
    table.sort(blockedCands, function(a, b) return (a.readyIn or 0) < (b.readyIn or 0) end)
    for _, c in ipairs(blockedCands) do
        Add(c.cand.key, c.readyIn, c.clip, c.cand.priorityBucket, c.cooldownEnd)
    end

    if #result == 0 then
        if ctx.inCombat and hasTarget then
            local fillerKey = nil
            for i = #rotation, 1, -1 do
                local rEntry = rotation[i]
                if rEntry.key and A.SPELLS[rEntry.key] then
                    local isAlways = rEntry.conditions and #rEntry.conditions == 1
                                     and rEntry.conditions[1].type == "always"
                    if isAlways or not rEntry.conditions then
                        fillerKey = rEntry.key
                        break
                    end
                end
            end
            if fillerKey then
                Add(fillerKey)
            else
                return nil
            end
        else
            return nil
        end
    end

    do
        local insertions = {}
        for ri = #result, 1, -1 do
            local entry = result[ri]
            local rotEntry = nil
            for _, re in ipairs(rotation) do
                if re.key == entry.key then rotEntry = re; break end
            end
            if rotEntry and (rotEntry.insertBefore or rotEntry.insertBeforeKey) then
                -- Resolve the target spell: prefer insertBeforeKey (setting-driven) over
                -- the literal insertBefore string so that user-configured values work.
                local beforeTarget = rotEntry.insertBefore
                if rotEntry.insertBeforeKey then
                    local resolved = A.SpecVal and A.SpecVal(rotEntry.insertBeforeKey)
                    if type(resolved) == "string" and resolved ~= "" then
                        beforeTarget = resolved
                    end
                end
                table.remove(result, ri)
                insertions[#insertions + 1] = { entry = entry, before = beforeTarget }
            end
        end
        for _, ins in ipairs(insertions) do
            local idx = nil
            for ri = 1, #result do
                if result[ri].key == ins.before then idx = ri; break end
            end
            if idx then
                table.insert(result, idx, ins.entry)
            else
                result[#result + 1] = ins.entry
            end
        end
    end

    if hasTarget then
        local upcoming = {}
        for _, rEntry in ipairs(rotation) do
            local key = rEntry.key
            if key and not seen[key] then
                local spell = A.SPELLS and A.SPELLS[key]
                local known = spell and (not A.KnowsSpell or A.KnowsSpell(spell.id))
                if known ~= false then
                    -- Use the same generic refresh-ETA helper that powers
                    -- predictive timers for DoT/cooldown/refresh windows.
                    local eta = RE._ComputeEntryRefreshETA(rEntry, ctx, spec)
                    if eta == nil and spell and spell.id and A.GetSpellCDReal then
                        local cd = math.max((A.GetSpellCDReal(spell.id) or 0) - (ctx.castRemaining or 0), 0)
                        if cd > 0 then eta = cd end
                    end
                    if eta and eta > 0 then
                        upcoming[#upcoming + 1] = {
                            key = key,
                            eta = eta,
                            cooldownEnd = now + eta,
                            priorityBucket = ResolveEntryPriorityBucket(rEntry),
                        }
                    end
                end
            end
        end

        table.sort(upcoming, function(a, b) return a.eta < b.eta end)
        for _, v in ipairs(upcoming) do
            Add(v.key, v.eta, false, v.priorityBucket, v.cooldownEnd)
        end
    end

    return result
end

function RE:_EvaluatePrepared(spec, ctx, db, rotation, hasTarget, wantDiagnostics)
    local candidates = {}
    local diagnostics = wantDiagnostics and { ctx = ctx, rotation = rotation, entries = {}, candidates = candidates, hasTarget = hasTarget } or nil

    for i, entry in ipairs(rotation) do
        if entry.key and entry.conditions then
            local candidate, diag = self:_EvaluateEntry(entry, i, ctx, spec, db, hasTarget, wantDiagnostics)
            if candidate then
                candidates[#candidates + 1] = candidate
            end
            if diagnostics then
                diagnostics.entries[#diagnostics.entries + 1] = diag
            end
        end
    end

    local result = self:_BuildResultFromCandidates(ctx, rotation, hasTarget, candidates, spec)
    if diagnostics then
        diagnostics.result = result
    end
    return result, diagnostics
end

------------------------------------------------------------------------
-- Core evaluator
------------------------------------------------------------------------

--- Evaluate the active spec's rotation and return an ordered priority list.
-- @param spec  table   The active spec table.
-- @return table|nil    Array of { key, eta, clip } or nil.
function RE:Evaluate(spec)
    if not spec or not spec.rotation then return nil end

    local ctx = self:BuildContext(spec)
    local db  = A.db and A.db.specs and A.db.specs[spec.meta.id]

    -- Use DB override rotation if present, else file rotation
    local rotation = (db and db.rotation) or spec.rotation

    -- Target validation
    local hasTarget = UnitExists("target")
                      and not UnitIsDead("target")
                      and UnitCanAttack("player", "target")
    local result = self:_EvaluatePrepared(spec, ctx, db, rotation, hasTarget, false)

    -- ------------------------------------------------------------------
    -- DoT-refresh hint table for FakeQueue.
    --
    -- For every rotation entry that uses `projected_dot_time_left_lt`, we
    -- compute the *ideal* cast-start moment (so the DoT lands just after
    -- the previous DoT's last tick) and publish it as a per-spell hint.
    -- The FQ macro reads this to busy-wait up to 150ms and release the
    -- /cast at the perfect moment, eliminating the SAFETY margin without
    -- risking a clipped tick.
    -- ------------------------------------------------------------------
    A.DotRefreshHints = A.DotRefreshHints or {}
    local now = ctx.now or GetTime()
    -- Expire stale hints
    for name, hint in pairs(A.DotRefreshHints) do
        if hint.expiresAt and now > hint.expiresAt then
            A.DotRefreshHints[name] = nil
        end
    end

    if hasTarget then
        for _, rEntry in ipairs(rotation) do
            if rEntry.key and rEntry.conditions then
                for _, cond in ipairs(rEntry.conditions) do
                    if cond and cond.type == "projected_dot_time_left_lt" then
                        local key = cond.spellKey or rEntry.key
                        local spell = A.SPELLS and A.SPELLS[key]
                        local spellName = spell and spell.name
                        if spellName then
                            local castEff = GetEffectiveSpellCastTime(key, ctx) or 0
                            local travel  = math.max(GetSpellTravelTimeValue(key) or 0, ctx.lat or 0)
                            local rem = ResolveDebuffRemaining(spec, ctx, cond)
                            -- Ideal fire moment: cast finishes just after the
                            -- last tick lands. If we're already past that
                            -- moment (rem - cast - travel < 0) we leave the
                            -- hint at "fire now" so FQ does nothing.
                            local fireDelay = math.max(rem - castEff - travel, 0)
                            A.DotRefreshHints[spellName] = {
                                fireAt = now + fireDelay,
                                expiresAt = now + fireDelay + 1.5,
                                spellKey = key,
                                castEff = castEff,
                                travel = travel,
                            }
                        end
                        break
                    end
                end
            end
        end
    end

    return result
end

function RE:DebugEvaluate(spec)
    if not spec or not spec.rotation then return nil end

    local ctx = self:BuildContext(spec)
    local db  = A.db and A.db.specs and A.db.specs[spec.meta.id]
    local rotation = (db and db.rotation) or spec.rotation
    local hasTarget = UnitExists("target")
                      and not UnitIsDead("target")
                      and UnitCanAttack("player", "target")

    local _, diagnostics = self:_EvaluatePrepared(spec, ctx, db, rotation, hasTarget, true)
    return diagnostics
end

------------------------------------------------------------------------
-- Register as SpecManager helper
------------------------------------------------------------------------
if A.SpecManager then
    A.SpecManager:RegisterHelper("RotationEngine", {
        _initialized = false,
        _spec = nil,
        OnSpecActivate = function(self, spec)
            if self._initialized then return end
            self._initialized = true
            self._spec = spec
        end,
        OnSpecDeactivate = function(self, spec)
            self._initialized = false
            self._spec = nil
        end,
    })
end

