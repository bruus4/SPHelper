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
    if not spellKey or not A.SPELLS then return nil end
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
    local spellId = ResolveSpellId(spellKey)
    if not spellId then return nil end

    local _, _, _, castMS
    if A.GetSpellInfoCached then
        _, _, _, castMS = A.GetSpellInfoCached(spellId)
    else
        _, _, _, castMS = GetSpellInfo(spellId)
    end
    if castMS == nil then return nil end

    local castTime = (castMS or 0) / 1000
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

--- Return the talent-adjusted SWP duration.
-- Improved Shadow Word: Pain is tab 3, index 4 in TBC talent layout.
-- Rank 1 = +3s, Rank 2 = +6s (verify in-game).
-- Conservative approach: 18 + rank * 3.
function RE.GetSWPDuration()
    local rank = RE.GetTalentRank(3, 4)  -- Shadow tab, Improved SWP
    return 18 + rank * 3
end

------------------------------------------------------------------------
-- Context builder — snapshot of all relevant game state.
------------------------------------------------------------------------

function RE:BuildContext(spec)
    local now = GetTime()
    local constants = (spec and spec.constants) or {}

    -- Cast/channel info
    local castingSpell, castRemaining = nil, 0
    do
        local name, _, _, _, endMS = UnitCastingInfo("player")
        if name and endMS then
            castingSpell = name
            castRemaining = math.max(endMS / 1000 - now, 0)
        else
            local cname, _, _, _, cendMS = UnitChannelInfo("player")
            if cname and cendMS then
                castingSpell = cname
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

    local gcd = math.max(1.0, 1.5 / hasteMul)
    local gcdRemaining = GetGCDRemaining(now)
    local lat = A.GetLatency()
    local SAFETY = constants.SAFETY or 0.5

    -- DoT timers
    local vtRem, swpRem = 0, 0
    do
        local n, _, _, _, _, exp = A.FindPlayerDebuff("target", A.SPELLS.VT.name)
        if n and exp then vtRem = math.max(exp - now, 0) end
    end
    do
        local n, _, _, _, _, exp = A.FindPlayerDebuff("target", A.SPELLS.SWP.name)
        if n and exp then swpRem = math.max(exp - now, 0) end
    end

    -- In-flight / recent-cast fallback
    local recentCast = A._rotRecentCast or {}
    if vtRem == 0 then
        if (castingSpell and castingSpell == A.SPELLS.VT.name)
           or (recentCast[A.SPELLS.VT.name] and (now - recentCast[A.SPELLS.VT.name]) < 1.0) then
            vtRem = constants.VT_DURATION or 15
        end
    end
    if swpRem == 0 then
        if recentCast[A.SPELLS.SWP.name] and (now - recentCast[A.SPELLS.SWP.name]) < 1.0 then
            swpRem = RE.GetSWPDuration()
        end
    end

    -- Project to cast-finish
    local vtAfter  = math.max(vtRem  - castRemaining, 0)
    local swpAfter = math.max(swpRem - castRemaining, 0)

    -- Cooldowns (projected past current cast)
    local function SpellCDProj(id)
        if not A.KnowsSpell(id) then return 999 end
        return math.max(A.GetSpellCDReal(id) - castRemaining, 0)
    end

    local mbCD  = SpellCDProj(A.SPELLS.MB.id)
    local swdCD = SpellCDProj(A.SPELLS.SWD.id)
    local sfCD  = SpellCDProj(A.SPELLS.SF.id)
    local dpCD  = SpellCDProj(A.SPELLS.DP.id)

    -- Resources
    local currentMana = UnitPower("player", 0) or 0
    local maxMana = math.max(UnitPowerMax("player", 0) or 1, 1)
    local baseMana = GetPlayerBaseMana()
    if baseMana <= 0 then baseMana = maxMana end
    local manaPct = currentMana / maxMana
    local baseManaPct = currentMana / math.max(baseMana, 1)
    local hpPct   = (UnitHealth("player") or 1) /
                    math.max(UnitHealthMax("player") or 1, 1)
    local clearcasting = false
    if A.SPELLS and A.SPELLS.CLEARCASTING then
        clearcasting = PlayerHasBuff(A.SPELLS.CLEARCASTING.name)
    end

    local VT_CAST_TIME = constants.VT_CAST_TIME or 1.5
    local MF_CAST_TIME = constants.MF_CAST_TIME or 3.0
    local MIN_MF_DURATION = constants.MIN_MF_DURATION or 1.0

    local vtCastEff = VT_CAST_TIME / hasteMul
    local mfCastEff = MF_CAST_TIME / hasteMul
    local minMfEff  = MIN_MF_DURATION / hasteMul

    local sp = (A.GetSpellPower and A.GetSpellPower()) or 0
    local targetHP, targetMaxHP = 0, 0
    local targetGUID = UnitGUID("target")
    if UnitExists("target") then
        targetHP    = UnitHealth("target") or 0
        targetMaxHP = UnitHealthMax("target") or 0
    end

    local timing = (constants.timing) or {}
    local WAIT_THRESHOLD = (timing.globalWaitThresholdMs or 400) / 1000

    -- Combo points
    local comboPoints = (GetComboPoints and GetComboPoints("player", "target")) or 0

    -- Resource (energy/rage/focus for non-mana classes)
    local resourcePower = UnitPower("player") or 0

    -- Update power/energy regen estimator
    do
        local nowP = now
        local curr = resourcePower
        if _powerState.lastPower ~= nil and _powerState.lastTime then
            local dt = nowP - _powerState.lastTime
            if dt > 0.05 then
                local instant = (curr - _powerState.lastPower) / dt
                _powerState.rate = _powerState.alpha * instant + (1 - _powerState.alpha) * _powerState.rate
            end
            -- Detect discrete tick (power increase) to update tickInterval
            if curr > _powerState.lastPower + 0.5 then
                if _powerState.lastTickTime then
                    local tickDt = nowP - _powerState.lastTickTime
                    _powerState.tickInterval = _powerState.alpha * tickDt + (1 - _powerState.alpha) * _powerState.tickInterval
                end
                _powerState.lastTickTime = nowP
            end
        else
            _powerState.rate = _powerState.rate or 0
            _powerState.lastTickTime = _powerState.lastTickTime or nil
        end
        _powerState.lastPower = curr
        _powerState.lastTime  = nowP
    end

    -- HP decay
    UpdateHPDecay()
    local hpDecayRate = _hpDecay.rate  -- HP fraction lost per second, positive = dying
    local targetTTD = nil
    if targetGUID and targetMaxHP > 0 and A.UpdateTargetHealthSample then
        A.UpdateTargetHealthSample(targetGUID, targetHP / targetMaxHP, now)
    end
    if targetGUID and A.GetTargetTimeToDie then
        targetTTD = A.GetTargetTimeToDie(targetGUID)
    end
    if not targetTTD and targetMaxHP > 0 and hpDecayRate > 0.0001 then
        targetTTD = (targetHP / targetMaxHP) / hpDecayRate
    end

    local nextPowerTick = (_powerState.lastTickTime and math.max(0, _powerState.tickInterval - (now - _powerState.lastTickTime))) or nil
    local readyIn = math.max(castRemaining or 0, gcdRemaining or 0)
    local powerType = UnitPowerType("player")
    local maxResource = UnitPowerMax("player") or 100
    if maxResource <= 0 then maxResource = 100 end
    local resourceAtGCD = resourcePower
    if powerType == 3 or (Enum and Enum.PowerType and powerType == Enum.PowerType.Energy) then
        if nextPowerTick and nextPowerTick <= readyIn then
            local interval = math.max(_powerState.tickInterval or 2.0, 0.1)
            local ticks = 1 + math.floor((readyIn - nextPowerTick) / interval)
            resourceAtGCD = resourcePower + ticks * 20
        elseif (_powerState.rate or 0) > 0 then
            resourceAtGCD = resourcePower + (_powerState.rate * readyIn)
        end
    elseif (_powerState.rate or 0) > 0 then
        resourceAtGCD = resourcePower + (_powerState.rate * readyIn)
    end
    resourceAtGCD = math.min(resourceAtGCD, maxResource)
    local nextPowerTickWithGCD = nextPowerTick and (nextPowerTick - readyIn) or nil

    local activeChannelSpellKey = nil
    local channelTickInterval = 0
    local channelTicksRemaining = 0
    local channelTimeToNextTick = 0
    if A.ChannelHelper then
        if A.ChannelHelper.GetActiveChannelSpellKey then
            local ok, value = pcall(A.ChannelHelper.GetActiveChannelSpellKey, A.ChannelHelper)
            if ok then activeChannelSpellKey = value end
        end
        if A.ChannelHelper.GetChannelTickInterval then
            local ok, value = pcall(A.ChannelHelper.GetChannelTickInterval, A.ChannelHelper)
            if ok and value then channelTickInterval = value end
        end
        if A.ChannelHelper.GetChannelTicksRemaining then
            local ok, value = pcall(A.ChannelHelper.GetChannelTicksRemaining, A.ChannelHelper)
            if ok and value then channelTicksRemaining = value end
        end
        if A.ChannelHelper.GetChannelTimeToNextTick then
            local ok, value = pcall(A.ChannelHelper.GetChannelTimeToNextTick, A.ChannelHelper)
            if ok and value then channelTimeToNextTick = value end
        end
    end

    return {
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
        vtRem          = vtRem,
        swpRem         = swpRem,
        vtAfter        = vtAfter,
        swpAfter       = swpAfter,
        mbCD           = mbCD,
        swdCD          = swdCD,
        sfCD           = sfCD,
        dpCD           = dpCD,
        currentMana    = currentMana,
        maxMana        = maxMana,
        baseMana       = baseMana,
        manaPct        = manaPct,
        baseManaPct    = baseManaPct,
        hpPct          = hpPct,
        clearcasting   = clearcasting,
        vtCastEff      = vtCastEff,
        mfCastEff      = mfCastEff,
        minMfEff       = minMfEff,
        sp             = sp,
        targetGUID     = targetGUID,
        targetHP       = targetHP,
        targetMaxHP    = targetMaxHP,
        targetTTD      = targetTTD,
        inCombat       = UnitAffectingCombat("player"),
        WAIT_THRESHOLD = WAIT_THRESHOLD,
        swpDuration    = RE.GetSWPDuration(),
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
        channelTickInterval = channelTickInterval,
        channelTicksRemaining = channelTicksRemaining,
        channelTimeToNextTick = channelTimeToNextTick,
    }
end

------------------------------------------------------------------------
-- Condition evaluators (dispatch table)
------------------------------------------------------------------------

RE._condEval = {}

RE._condEval["always"] = function(cond, ctx, spec, db)
    return true
end

RE._condEval["target_valid"] = function(cond, ctx, spec, db)
    return UnitExists("target") and not UnitIsDead("target") and UnitCanAttack("player", "target")
end

RE._condEval["cooldown_ready"] = function(cond, ctx, spec, db)
    local key = cond.spellKey
    if not key then return false end
    -- Context keys are camelCase (e.g. mbCD, swdCD), rotation keys are UPPER (MB, SWD)
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
    if key == "VT" then return ctx.vtAfter == 0 end
    if key == "SWP" then return ctx.swpAfter == 0 end
    -- Generic: look up spell name from A.SPELLS and check debuff on target
    local debuffName = cond.debuff
    if not debuffName and key and A.SPELLS[key] then
        debuffName = A.SPELLS[key].name
    end
    if debuffName then
        local n = A.FindPlayerDebuff("target", debuffName)
        return not n
    end
    return false
end

RE._condEval["projected_dot_time_left_lt"] = function(cond, ctx, spec, db)
    local key = cond.spellKey
    local after = 0
    if key == "VT" then after = ctx.vtAfter
    elseif key == "SWP" then after = ctx.swpAfter
    else
        local debuffName = cond.debuff
        if not debuffName and key and A.SPELLS[key] then
            debuffName = A.SPELLS[key].name
        end
        if debuffName then
            local _, _, _, _, _, expirationTime = A.FindPlayerDebuff("target", debuffName)
            local remaining = expirationTime and math.max(expirationTime - ctx.now, 0) or 0
            after = math.max(remaining - (ctx.castRemaining or 0), 0)
        end
    end

    -- Resolve threshold expression
    local threshold = 0
    if type(cond.seconds) == "number" then
        threshold = cond.seconds
    elseif type(cond.seconds) == "string" then
        -- Simple expression resolver
        local expr = cond.seconds
        threshold = RE._resolveExpr(expr, ctx, spec)
    end
    return after < threshold
end

RE._condEval["dot_time_left_lt"] = function(cond, ctx, spec, db)
    local key = cond.spellKey
    local rem = 0
    if key == "VT" then rem = ctx.vtRem
    elseif key == "SWP" then rem = ctx.swpRem
    else
        local debuffName = cond.debuff
        if not debuffName and key and A.SPELLS[key] then
            debuffName = A.SPELLS[key].name
        end
        if debuffName and A.FindPlayerDebuff then
            local _, _, _, _, _, expirationTime = A.FindPlayerDebuff("target", debuffName)
            rem = expirationTime and math.max(expirationTime - ctx.now, 0) or 0
        end
    end
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

RE._condEval["predicted_kill"] = function(cond, ctx, spec, db)
    local sp = ctx.sp or 0
    local swdHit = math.floor(sp * 1.55 + 0.5)
    local safety = A.SpecVal("swdSafetyPct", 10) or 0
    local required = ctx.targetHP * (1 + safety / 100)
    return ctx.targetHP > 0 and swdHit >= required
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
    if not UnitExists("target") then return false end
    local debuff = cond.debuff
    if not debuff then return true end
    local n = A.FindPlayerDebuff("target", debuff)
    return not n
end

RE._condEval["not_buff_on_player"] = function(cond, ctx, spec, db)
    local name = cond.buff
    if not name then return true end
    return not PlayerHasBuff(name)
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

RE._condEval["buff_on_player"] = function(cond, ctx, spec, db)
    local name = cond.buff
    if not name then return false end
    return PlayerHasBuff(name)
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

RE._condEval["clearcasting"] = function(cond, ctx, spec, db)
    if ctx and ctx.clearcasting ~= nil then
        return ctx.clearcasting
    end
    local buffName = A.SPELLS and A.SPELLS.CLEARCASTING and A.SPELLS.CLEARCASTING.name or "Clearcasting"
    return PlayerHasBuff(buffName)
end

RE._condEval["cat_form"] = function(cond, ctx, spec, db)
    local catName = A.SPELLS.CAT_FORM and A.SPELLS.CAT_FORM.name or "Cat Form"
    return PlayerHasBuff(catName)
end

RE._condEval["bear_form"] = function(cond, ctx, spec, db)
    local bearName = A.SPELLS.BEAR_FORM and A.SPELLS.BEAR_FORM.name or "Bear Form"
    local direBearName = A.SPELLS.DIRE_BEAR_FORM and A.SPELLS.DIRE_BEAR_FORM.name or "Dire Bear Form"
    return PlayerHasBuff(bearName) or PlayerHasBuff(direBearName)
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

-- is_stealthed: true when the player has the Prowl (stealth) buff active.
RE._condEval["is_stealthed"] = function(cond, ctx, spec, db)
    local prowlName = A.SPELLS.PROWL and A.SPELLS.PROWL.name or "Prowl"
    for i = 1, 40 do
        local bname = UnitBuff("player", i)
        if not bname then break end
        if bname == prowlName then return true end
    end
    return false
end

-- not_stealthed: true when the player does NOT have Prowl active.
RE._condEval["not_stealthed"] = function(cond, ctx, spec, db)
    local prowlName = A.SPELLS.PROWL and A.SPELLS.PROWL.name or "Prowl"
    for i = 1, 40 do
        local bname = UnitBuff("player", i)
        if not bname then break end
        if bname == prowlName then return false end
    end
    return true
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

    if ctx and ctx.clearcasting then
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

-- Any-source debuff present on target (unlike not_debuff_on_target which is player-only).
RE._condEval["debuff_on_target"] = function(cond, ctx, spec, db)
    if not UnitExists("target") then return false end
    local name = cond.debuff
    if not name then return false end
    -- Search all debuffs on target including others'
    for i = 1, 40 do
        local bname = UnitDebuff("target", i)
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

------------------------------------------------------------------------
-- Simple expression resolver for threshold strings.
-- Supports additions of known context keys: "vtCastEff + lat + SAFETY"
------------------------------------------------------------------------

function RE._resolveExpr(expr, ctx, spec)
    -- Replace known tokens with values
    local env = {
        vtCastEff     = ctx.vtCastEff or 0,
        mfCastEff     = ctx.mfCastEff or 0,
        minMfEff      = ctx.minMfEff or 0,
        gcd           = ctx.gcd or 1.5,
        lat           = ctx.lat or 0.05,
        vtTravel      = math.max(GetSpellTravelTimeValue("VT") or 0, ctx.lat or 0),
        swpTravel     = math.max(GetSpellTravelTimeValue("SWP") or 0, ctx.lat or 0),
        mbTravel      = math.max(GetSpellTravelTimeValue("MB") or 0, ctx.lat or 0),
        swdTravel     = math.max(GetSpellTravelTimeValue("SWD") or 0, ctx.lat or 0),
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
    if entry.key ~= "POTION" and entry.key ~= "RUNE" and entry.key ~= "SF" then
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
        eta = math.max(A.GetSpellCDReal(spell.id) - ctx.castRemaining, 0)
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

function RE:_BuildResultFromCandidates(ctx, rotation, hasTarget, candidates)
    local WAIT_THRESHOLD = ctx.WAIT_THRESHOLD

    table.sort(candidates, function(a, b)
        return a.index < b.index
    end)

    local result = {}
    local seen   = {}

    local function Add(key, eta, clip, priorityBucket)
        if seen[key] then return end
        local entry = { key = key, eta = eta or 0 }
        if clip then entry.clip = true end
        if priorityBucket ~= nil then entry.priorityBucket = priorityBucket end
        result[#result + 1] = entry
        seen[key] = true
        local base = key:match("^([A-Z]+)_")
        if base and A.SPELLS[base] then
            seen[base] = true
        end
    end

    for _, cand in ipairs(candidates) do
        local readyIn = 0
        local spell = A.SPELLS[cand.key]
        if spell then
            readyIn = math.max(A.GetSpellCDReal(spell.id) - ctx.castRemaining, 0)
        end

        local clip = false
        if cand.key == "MF" then
            if ctx.mbCD > 0 and ctx.mbCD < ctx.mfCastEff and ctx.mbCD >= ctx.minMfEff then
                clip = true
            end
            if (ctx.vtAfter > 0 and ctx.vtAfter < ctx.mfCastEff and ctx.vtAfter >= ctx.minMfEff)
               or (ctx.swpAfter > 0 and ctx.swpAfter < ctx.mfCastEff and ctx.swpAfter >= ctx.minMfEff) then
                clip = true
            end

            local mbAlmostReady  = (ctx.mbCD > 0 and ctx.mbCD <= WAIT_THRESHOLD)
            local swdAlmostReady = (ctx.swdCD > 0 and ctx.swdCD <= WAIT_THRESHOLD)
            if mbAlmostReady or swdAlmostReady then
                cand.key = nil
            end
        end

        if cand.key then
            Add(cand.key, readyIn, clip, cand.priorityBucket)
        end
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
            if rotEntry and rotEntry.insertBefore then
                table.remove(result, ri)
                insertions[#insertions + 1] = { entry = entry, before = rotEntry.insertBefore }
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
        local specKeys = {}
        for _, rEntry in ipairs(rotation) do
            if rEntry.key then specKeys[rEntry.key] = true end
        end

        local upcoming = {}
        if specKeys["VT"] then
            local vtUrgent = A.KnowsSpell(A.SPELLS.VT.id) and (ctx.vtAfter < ctx.vtCastEff + ctx.lat + ctx.SAFETY)
            if not vtUrgent and A.KnowsSpell(A.SPELLS.VT.id) then
                local vtProj = math.max(ctx.vtAfter - ctx.vtCastEff - ctx.lat - ctx.SAFETY, 0)
                upcoming[#upcoming + 1] = { key = "VT", eta = vtProj }
            end
        end
        if specKeys["SWP"] then
            local swpUrgent = (ctx.swpAfter < ctx.gcd + ctx.lat + ctx.SAFETY)
            if not swpUrgent then
                local swpProj = math.max(ctx.swpAfter - ctx.gcd - ctx.lat - ctx.SAFETY, 0)
                upcoming[#upcoming + 1] = { key = "SWP", eta = swpProj }
            end
        end
        if specKeys["MB"] and ctx.mbCD > 0 then
            upcoming[#upcoming + 1] = { key = "MB", eta = ctx.mbCD }
        end
        if specKeys["SWD"] and A.KnowsSpell(A.SPELLS.SWD.id) and ctx.swdCD > 0 then
            upcoming[#upcoming + 1] = { key = "SWD", eta = ctx.swdCD }
        end

        if not specKeys["VT"] then
            for _, rEntry in ipairs(rotation) do
                local key = rEntry.key
                if key and not seen[key] then
                    local spell = A.SPELLS[key]
                    if spell and A.KnowsSpell(spell.id) then
                        local cd = math.max(A.GetSpellCDReal(spell.id) - ctx.castRemaining, 0)
                        if cd > 0 then
                            upcoming[#upcoming + 1] = { key = key, eta = cd }
                        end
                    end
                end
            end
        end

        table.sort(upcoming, function(a, b) return a.eta < b.eta end)
        for _, v in ipairs(upcoming) do Add(v.key, v.eta) end
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

    local result = self:_BuildResultFromCandidates(ctx, rotation, hasTarget, candidates)
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

