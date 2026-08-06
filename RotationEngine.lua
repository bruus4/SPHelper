------------------------------------------------------------------------
-- SPHelper  –  RotationEngine.lua
-- Data-driven rotation evaluator.
-- Consumes spec.rotation from the active spec file (or DB override)
-- and produces an ordered priority list each evaluation cycle.
--
-- Replaces the hardcoded GetPriority() in Rotation.lua when
-- A.db.useRotationEngine is true (default: true).
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
-- Energy ticks on a fixed 2.0s cadence in this client (Classic/TBC era).
-- It is NOT affected by haste, so we treat the interval as a constant and
-- only track the tick *phase* (lastTickTime).  Estimating the interval with
-- an EMA is unreliable: whenever energy is capped (ticks add nothing and go
-- undetected) or a tick is missed, the next detected gap is much larger than
-- 2s and corrupts the average for several seconds, which made energy-gated
-- "time to cast" countdowns (e.g. Mangle / Shred) jump around.
local ENERGY_TICK_INTERVAL = 2.0
local ENERGY_PER_TICK      = 20

local _powerState = {
    -- Per-power-type trackers: [powerType] = { lastPower, lastTime, rate, lastTickTime }.
    -- Each resource (mana=0, rage=1, focus=2, energy=3) is tracked separately so a
    -- form shift (cat -> bear -> cat) never corrupts the other resource's EMA rate
    -- or the energy tick phase.  Energy is sampled explicitly (UnitPower("player", 3))
    -- in EVERY form because druids regenerate energy regardless of the form they are
    -- in — the tick phase must survive form shifts or energy-gated countdowns
    -- (Mangle/Shred) drift the moment the player re-shifts into cat form.
    byType      = {},
    alpha       = 0.25,
    tickInterval= ENERGY_TICK_INTERVAL,  -- fixed energy tick interval (seconds)
}

-- Update the EMA rate and tick phase for one power type.  `curr` is the current
-- value of that specific power bar (e.g. UnitPower("player", 3) for energy).
local function _UpdatePowerTracker(powerType, curr, nowP)
    if powerType == nil then powerType = 0 end
    local st = _powerState.byType[powerType]
    if not st then
        st = { rate = 0 }
        _powerState.byType[powerType] = st
    end
    if st.lastPower ~= nil and st.lastTime then
        local dt = nowP - st.lastTime
        if dt > 0.05 then
            local instant = (curr - st.lastPower) / dt
            st.rate = _powerState.alpha * instant + (1 - _powerState.alpha) * st.rate
        end
        -- Track only the tick PHASE (when the last tick landed) so
        -- nextPowerTick stays aligned with the game's 2.0s cadence.
        -- The interval itself is a fixed constant (see ENERGY_TICK_INTERVAL)
        -- because an EMA estimate drifts whenever a tick is missed or
        -- energy is capped, producing erratic energy-gated countdowns.
        if curr > st.lastPower + 0.5 then
            st.lastTickTime = nowP
        end
    else
        st.rate = st.rate or 0
        st.lastTickTime = st.lastTickTime or nil
    end
    st.lastPower = curr
    st.lastTime  = nowP
    return st
end

-- Throttle for the POWER debug snapshot (BuildContext runs on every refresh).
local _powerLastDebugAt = nil

--------------------------------------------------------------------
-- Swing timer tracker — built-in (no external library needed).
-- Tracks main-hand, off-hand, and ranged swing timing via
-- COMBAT_LOG_EVENT_UNFILTERED (SWING_DAMAGE / RANGE_DAMAGE)
-- and UNIT_ATTACK_SPEED (weapon speed changes).
--------------------------------------------------------------------
local _swingState = nil  -- lazy-initialized

local function _InitSwingTracker()
    if _swingState then return end
    _swingState = {
        mh = { lastSwing = 0, speed = 0, readyTime = 0 },
        oh = { lastSwing = 0, speed = 0, readyTime = 0 },
        r  = { lastSwing = 0, speed = 0, readyTime = 0 },
    }

    local f = CreateFrame("Frame")
    f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    f:RegisterEvent("UNIT_ATTACK_SPEED")
    f:SetScript("OnEvent", function(self, event, ...)
        if event == "COMBAT_LOG_EVENT_UNFILTERED" then
            local timestamp, subevent, _, sourceGUID = ...
            if sourceGUID ~= UnitGUID("player") then return end
            local now = GetTime()

            if subevent == "SWING_DAMAGE" then
                _swingState.mh.lastSwing = now
                if _swingState.mh.speed > 0 then
                    _swingState.mh.readyTime = now + _swingState.mh.speed
                end
            elseif subevent == "RANGE_DAMAGE" then
                _swingState.r.lastSwing = now
                if _swingState.r.speed > 0 then
                    _swingState.r.readyTime = now + _swingState.r.speed
                end
            end
        elseif event == "UNIT_ATTACK_SPEED" then
            local unit = ...
            if unit ~= "player" then return end
            local mhSpeed = UnitAttackSpeed("player")
            if mhSpeed and mhSpeed > 0 then
                _swingState.mh.speed = mhSpeed
                if _swingState.mh.lastSwing > 0 then
                    _swingState.mh.readyTime = _swingState.mh.lastSwing + mhSpeed
                end
            end
            local ohSpeed = UnitAttackSpeed("player", true) or UnitAttackSpeed("player")
            if ohSpeed and ohSpeed > 0 then
                _swingState.oh.speed = ohSpeed
                if _swingState.oh.lastSwing > 0 then
                    _swingState.oh.readyTime = _swingState.oh.lastSwing + ohSpeed
                end
            end
            local rItemLink = GetInventoryItemLink("player", 18)
            if rItemLink then
                local _, _, _, _, _, _, _, _, _, _, itemSpeed = GetItemInfo(rItemLink)
                if itemSpeed and itemSpeed > 0 then
                    _swingState.r.speed = itemSpeed
                    if _swingState.r.lastSwing > 0 then
                        _swingState.r.readyTime = _swingState.r.lastSwing + itemSpeed
                    end
                end
            end
        end
    end)
end

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
    -- TBC base mana = max mana minus the mana granted by intellect.
    -- Intellect grants 1 mana per point for the first 20 points, then 15 mana
    -- per point beyond that (TBC formula).  This matches the known level-70
    -- values (Priest 2620, Mage 2241, Warlock 2871, ...) and is what
    -- %-of-base-mana spell costs (Shadowfiend 6%, Shadowform 32%) use.
    -- The old per-class (level-1)*N+20 guesses were wrong (e.g. 1055 for a
    -- level-70 priest instead of 2620), which understated %-of-base costs.
    local maxMana = UnitPowerMax("player", 0) or 0
    if maxMana <= 0 then return 0 end
    local int = UnitStat("player", 4) or 0
    local manaFromInt = math.min(20, int) + 15 * (int - math.min(20, int))
    return math.max(maxMana - manaFromInt, 0)
end

-- GCD tracking.  The GCD is not directly queryable in TBC Classic, and the
-- old hardcoded probe spell (29515 "TEST Scorch") is a test spell that not
-- every player knows — GetSpellCooldown returned 0 for it, so the GCD always
-- appeared ready.  Instead we record when the last GCD-triggering cast
-- STARTED (UNIT_SPELLCAST_START) and compute remaining = start + gcd - now.
-- Item casts (trinkets, potions, runes) and catalog spells marked
-- `gcd = "none"` (e.g. Inner Focus) never trigger the GCD and are excluded.
local _gcdState = { start = nil, frame = nil }

local function _IsNoGCDSpellId(spellId)
    if not spellId then return false end
    -- Catalog spells: if the cast resolves to a known spell, only spells
    -- explicitly marked gcd = "none" skip the GCD.
    for key, spell in pairs(A.SPELLS or {}) do
        if spell and (spell.id == spellId or spell.baseId == spellId) then
            local def = A.GetSpellDefinition and A.GetSpellDefinition(key)
            return (def and def.gcd == "none") or false
        end
    end
    -- Item casts (trinkets, potions, runes) never trigger the GCD.
    for _, slot in ipairs({ 13, 14 }) do
        local ok, itemId = pcall(GetInventoryItemID, "player", slot)
        if ok and itemId then
            local ok2, _, itemSpellId = pcall(GetItemSpell, itemId)
            if ok2 and itemSpellId == spellId then return true end
        end
    end
    local db = A.db or {}
    for _, itemId in ipairs({ tonumber(db.selectedPotionItem), tonumber(db.selectedRuneItem) }) do
        if itemId then
            local ok2, _, itemSpellId = pcall(GetItemSpell, itemId)
            if ok2 and itemSpellId == spellId then return true end
        end
    end
    return false
end

local function _InitGCDTracker()
    if _gcdState.frame then return end
    local f = CreateFrame("Frame")
    f:RegisterEvent("UNIT_SPELLCAST_START")
    f:SetScript("OnEvent", function(self, event, unit, _, spellId)
        if unit ~= "player" then return end
        if _IsNoGCDSpellId(spellId) then return end
        _gcdState.start = GetTime()
    end)
    _gcdState.frame = f
end

local function GetGCDRemaining(now, gcdDuration)
    _InitGCDTracker()
    if not _gcdState.start then return 0 end
    local remaining = _gcdState.start + (gcdDuration or 1.5) - (now or GetTime())
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

local function IsGreaterCompareOp(op)
    op = op or ">="
    return op == ">" or op == ">=" or op == "gt" or op == "gte" or op == "ge"
end

local function IsLessCompareOp(op)
    op = op or "<"
    return op == "<" or op == "<=" or op == "lt" or op == "lte" or op == "le"
end

local function TargetHPPct(ctx)
    if not ctx or not ctx.targetMaxHP or ctx.targetMaxHP <= 0 then return nil end
    return (ctx.targetHP or 0) / ctx.targetMaxHP
end

local function ResolveTargetTTDCompareValue(ctx, op, threshold)
    if ctx and ctx.targetTTD ~= nil then
        return ctx.targetTTD
    end

    local hpPct = TargetHPPct(ctx)
    if not hpPct then return nil end
    if hpPct <= 0.25 then return 0 end

    threshold = tonumber(threshold) or 0
    if IsGreaterCompareOp(op) then
        if op == ">" or op == "gt" then
            return threshold + 0.001
        end
        return threshold
    end
    if IsLessCompareOp(op) then
        return threshold + 0.001
    end
    return nil
end

local function TargetTTDMeetsMinimum(ttd, hpPct, isPreview, requiredTTD)
    requiredTTD = tonumber(requiredTTD) or 0
    if requiredTTD <= 0 then return true end
    if ttd ~= nil then return ttd >= requiredTTD end
    if isPreview then return true end
    return (hpPct or 0) > 0.25
end

local function TargetTTDComparePasses(ctx, op, threshold)
    local lhs = ResolveTargetTTDCompareValue(ctx, op, threshold)
    return CompareValues(lhs, op, threshold)
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
    local simElapsed = 0
    if ctx and ctx.builtAt and ctx.now then
        simElapsed = math.max((ctx.now or 0) - (ctx.builtAt or 0), 0)
    end

    local spell = A.SPELLS and A.SPELLS[spellKey]
    if ctx and ctx.simulatedCooldowns and spell and spell.id then
        local cdEnd = ctx.simulatedCooldowns[spell.id]
        if cdEnd then
            return math.max(cdEnd - (ctx.now or GetTime()), 0)
        end
    end

    local cdKey = spellKey:lower() .. "CD"
    if ctx and ctx[cdKey] ~= nil then
        return math.max((ctx[cdKey] or 0) - simElapsed, 0)
    end

    local spellId = ResolveSpellId(spellKey)
    if not spellId then return nil end
    -- Project the cooldown past the current cast/channel.  During an active
    -- channel do NOT subtract the remaining channel time: channels are
    -- interruptible, and the channel-exception rule (see the queue chain)
    -- says the advisor shows REAL spell cooldowns while channeling.
    -- Subtracting the full channel (up to 3 s for Mind Flay) projected short
    -- cooldowns to 0, which flipped e.g. Mind Blast to "ready" and removed
    -- its timer the moment a Mind Flay channel started (user request).
    local cdLeft = (A.GetSpellCDReal and A.GetSpellCDReal(spellId) or 0)
    if not (ctx and ctx.activeChannelSpellKey) then
        cdLeft = cdLeft - ((ctx and ctx.castRemaining) or 0)
    end
    return math.max(cdLeft - simElapsed, 0)
end

-- Does this spell/action trigger the global cooldown?  The spell catalog
-- marks exceptions with `gcd = "none"` (e.g. Inner Focus); trinkets /
-- potions / runes are item actions that never trigger the GCD.  Everything
-- else defaults to triggering it.
local function SpellTriggersGCD(key)
    if key == "TRINKET1" or key == "TRINKET2" or key == "POTION" or key == "RUNE" then
        return false
    end
    local def = A.GetSpellDefinition and A.GetSpellDefinition(key)
    if def and def.gcd == "none" then
        return false
    end
    return true
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

local function GetSpellTravelTimeForCompare(spellKey, ctx)
    local observed = tonumber(GetSpellTravelTimeValue(spellKey)) or 0
    local latency = (ctx and ctx.lat) or (A.GetLatency and A.GetLatency()) or 0
    latency = tonumber(latency) or 0
    return math.max(observed, latency, 0)
end

local function GetUnitBuffInfo(unit, buffName, ctx)
    if not unit or not buffName then return nil end
    -- Projected simulation: check simBuffs table first.
    if ctx and ctx.simBuffs and ctx.simBuffs[buffName] then
        local sim = ctx.simBuffs[buffName]
        if sim.active then
            return buffName, sim.count or 1, sim.duration or 0, sim.expiry or math.huge
        else
            return nil
        end
    end
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

    -- Table of names: check all, return the entry with the most time remaining.
    if type(debuffName) == "table" then
        local bestName, bestCount, bestDur, bestExp
        for _, dName in ipairs(debuffName) do
            local n, c, d, e = GetUnitDebuffInfo(unit, dName, sourceMode)
            if n and (not bestExp or (e and e > bestExp)) then
                bestName, bestCount, bestDur, bestExp = n, c, d, e
            end
        end
        return bestName, bestCount, bestDur, bestExp
    end

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

-- Get all in-game debuff names to scan for a spell (primary + exclusive siblings).
-- Used by source="any" checks so e.g. Faerie Fire (Feral) also catches a Balance
-- druid's "Faerie Fire" copy and vice-versa.
local function GetDebuffAuraNames(spellKey)
    if not spellKey then return nil end
    local def = A.GetSpellDefinition and A.GetSpellDefinition(spellKey)
    if not def then return nil end
    local primary = def.debuffAura or def.name
    if not primary then return nil end
    if not (def.debuffExclusive and def.debuffSiblings) then
        return { primary }
    end
    local names = { primary }
    local seen  = { [primary] = true }
    for _, sibKey in ipairs(def.debuffSiblings) do
        local sibDef = A.GetSpellDefinition and A.GetSpellDefinition(sibKey)
        local sibName = sibDef and (sibDef.debuffAura or sibDef.name)
        if sibName and not seen[sibName] then
            names[#names + 1] = sibName
            seen[sibName] = true
        end
    end
    return names
end

-- Unified debuff application check.
-- Returns true if the given spell's debuff SHOULD be applied to the target (i.e., it is missing or expired).
-- Reads stacking rules from SpellDatabase.debuffStackingMode so all specs use consistent logic.
-- Parameters:
--   spellKey  : database key for the spell (e.g. "Curse of Elements", "Faerie Fire (Feral)")
--   target    : unit id to check ("target", "focus", etc.)
--   ctx       : optional context table with keys like { spec, playerGUID }
-- Stacking modes:
--   per_player         - Each player applies own copy; return true only if THIS player lacks it.
--   single_any_source  - Only one variant ever active globally; check any source (Faerie Fire variants).
--   single_curse_slot  - Warlock curse that doesn't stack effects across locks; check any source for this specific curse.
--   stacks_damage_only - Multiple sources apply but only damage stacks; return true if THIS player lacks it.
--   strongest_wins     - Only strongest version matters globally; check any source (Hunter's Mark).
local function ShouldApplyDebuff(spellKey, target, ctx)
    if not spellKey or not target then return false end

    local def = A.GetSpellDefinition and A.GetSpellDefinition(spellKey)
    if not def then return false end

    -- Non-debuff spells: nothing to check
    local isDebuff = (def.flags and def.flags.debuff) or (def.flags and def.flags.dot)
    if not isDebuff then return false end

    local stackingMode = def.debuffStackingMode or "per_player"  -- default assumption

    -- Helper: choose lookup function based on whether we care about any source or only this player's copy.
    -- A.FindDebuff     -> scans all debuffs regardless of caster (for "any source" modes).
    -- A.FindPlayerDebuff -> scans only debuffs cast by us (for per-player modes).
    -- Both are ID-first with name fallback, so rank/localization mismatches
    -- (e.g. "Curse of the Elements" vs "Curse of Elements") are handled.
    local function GetLookupFn(checkAnySource)
        if checkAnySource then return A.FindDebuff else return A.FindPlayerDebuff end
    end
    local function FindOnTarget(findFn, findKey)
        local foundName = findFn(target, findKey)
        return foundName ~= nil  -- presence is name/ID-based; non-stacking auras report count = 0
    end

    -- Check mutual exclusivity: if ANY mutually exclusive debuff from THIS player is on target, don't apply.
    -- This handles warlock curse slot (each lock has one curse), hunter sting slot, etc.
    local mutEx = def.debuffMutuallyExclusive
    if mutEx and type(mutEx) == "table" and #mutEx > 0 then
        local findFn = GetLookupFn(false)  -- per-player mutual exclusivity: only care about our own curses/stings
        for _, exKey in ipairs(mutEx) do
            if FindOnTarget(findFn, exKey) then
                return false  -- we already have a mutually exclusive debuff on target; don't overwrite it
            end
        end
    end

    if stackingMode == "single_any_source" then
        -- Only one variant can be active globally (e.g. Faerie Fire variants).
        -- If ANY variant is present from ANY source (ID/name aware), don't recast.
        local findFn = GetLookupFn(true)  -- any source
        if FindOnTarget(findFn, spellKey) then
            return false  -- some variant already active on target
        end
        return true

    elseif stackingMode == "single_curse_slot" then
        -- Curse that doesn't stack effects across warlocks (e.g. Curse of Elements).
        -- If ANY warlock has this curse (any TBC rank) on the target, don't recast it.
        local findFn = GetLookupFn(true)  -- any source
        if FindOnTarget(findFn, spellKey) then
            return false  -- someone already applied this curse
        end
        return true

    elseif stackingMode == "strongest_wins" then
        -- Only strongest version matters globally (e.g. Hunter's Mark).
        -- If ANYONE has it active, don't recast unless we're stronger (simplified: just check presence).
        local findFn = GetLookupFn(true)  -- any source
        if FindOnTarget(findFn, spellKey) then
            return false  -- someone already has it active; assume theirs is fine for now
        end
        return true

    elseif stackingMode == "per_player" or stackingMode == "stacks_damage_only" then
        -- Each player applies their own copy (VT, SWP, Corruption) OR damage stacks but we only care about our copy.
        -- Return true only if THIS player does NOT have it applied.
        local findFn = GetLookupFn(false)  -- per-player: only check our own debuffs
        if FindOnTarget(findFn, spellKey) then
            return false  -- we already have our copy on target (FindPlayerDebuff guarantees it's ours)
        end
        return true

    else
        -- Unknown mode: conservative default - check by source (per_player behavior)
        local findFn = GetLookupFn(false)  -- per-player
        if FindOnTarget(findFn, spellKey) then
            return false
        end
        return true
    end
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

local function CopyValue(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, child in pairs(value) do
        copy[key] = CopyValue(child)
    end
    return copy
end

local function MergeInto(dest, src)
    if type(src) ~= "table" then return dest end
    for key, value in pairs(src) do
        if type(value) == "table" and type(dest[key]) == "table" then
            MergeInto(dest[key], value)
        else
            dest[key] = CopyValue(value)
        end
    end
    return dest
end

local function SanitizeEntryToken(value)
    value = tostring(value or "entry"):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if value == "" then value = "entry" end
    return value
end

local function GetRuntimeRotation(spec)
    if not spec or not spec.meta then return nil end
    local sdb = A.db and A.db.specs and A.db.specs[spec.meta.id]
    return (sdb and sdb.rotation) or spec.rotation
end

local function GetEntryId(entry, index)
    if entry and entry.id and entry.id ~= "" then return entry.id end
    local def = A.GetSpellDefinition and A.GetSpellDefinition(entry and entry.key)
    local name = (def and def.name) or (entry and entry.key) or "entry"
    local spellID = (def and (def.id or def.baseId)) or ResolveSpellId(entry and entry.key) or 0
    return string.format("%s_%s", SanitizeEntryToken(name), tostring(spellID))
end

local function GetEntryHelperOptions(spec, entry, index)
    local options = CopyValue(entry and entry.helperOptions or {}) or {}
    local sdb = spec and spec.meta and A.db and A.db.specs and A.db.specs[spec.meta.id]
    local saved = sdb and sdb.helperOptions
    if type(saved) == "table" then
        MergeInto(options, saved[GetEntryId(entry, index)])
        local def = A.GetSpellDefinition and A.GetSpellDefinition(entry and entry.key)
        local name = def and def.name or (entry and entry.key)
        if name then MergeInto(options, saved[name]) end
    end
    return options
end

local function BuildChannelConfigFromEntry(spec, entry, index)
    if not entry or not entry.key or type(entry.helpers) ~= "table" then return nil end
    local helpers = entry.helpers
    if not (helpers.clipOverlay or helpers.tickSound or helpers.tickFlash or helpers.tickMarkers) then
        return nil
    end

    local def = A.GetSpellDefinition and A.GetSpellDefinition(entry.key)
    if not def or not (def.castType == "channel" or def.channel == true or (def.flags and def.flags.channel)) then
        return nil
    end

    local options = GetEntryHelperOptions(spec, entry, index)
    local clipOpts = options.clipOverlay or options.channel or {}
    return {
        _fromRotation = true,
        id = GetEntryId(entry, index),
        spellKey = entry.key,
        key = entry.key,
        spellName = def.name or entry.key,
        ticks = tonumber(def.ticks) or nil,
        duration = def.duration or def.castTime,
        tickInterval = def.tickInterval,
        minDuration = clipOpts.minDuration,
        clipReasons = clipOpts.clipReasons or {},
        clipOverlay = helpers.clipOverlay == true,
    }
end

local function GetRotationChannelConfig(spec, spellKey)
    local rotation = GetRuntimeRotation(spec)
    if type(rotation) ~= "table" then return nil end
    for index, entry in ipairs(rotation) do
        if entry and entry.key == spellKey then
            local config = BuildChannelConfigFromEntry(spec, entry, index)
            if config then return config end
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
    local channelConfig = GetRotationChannelConfig(spec, spellKey)
    if channelConfig then
        ticks = tonumber(channelConfig.ticks) or ticks
    end
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
    if channelConfig then
        duration = tonumber(channelConfig.duration) or nil
        if (not duration or duration <= 0) and tonumber(channelConfig.tickInterval) and ticks and ticks > 0 then
            return tonumber(channelConfig.tickInterval)
        end
    end
    if (not duration or duration <= 0) and data then
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
    -- Projected simulation: check simDebuffs table first so forward-simulated
    -- debuffs (e.g. Mangle applied during cast-chain prediction) resolve correctly.
    if ctx and ctx.simDebuffs then
        local debuffAura = def.name  -- the trackedDef may have a name override
        local spellDef = A.GetSpellDefinition and A.GetSpellDefinition(def.spellKey or spellKey)
        if spellDef and spellDef.debuffAura then debuffAura = spellDef.debuffAura end
        local sim = debuffAura and ctx.simDebuffs[debuffAura]
        if sim ~= nil then
            -- sim = { expiry = N } or false (explicitly absent)
            local remaining = sim and math.max((sim.expiry or 0) - now, 0) or 0
            local castRem = (ctx.dotBlockRemaining ~= nil) and ctx.dotBlockRemaining or (ctx.castRemaining or 0)
            local duration = GetTrackedDebuffDuration(spec, spellKey)
            return {
                key = def.key or spellKey,
                spellKey = def.spellKey or spellKey,
                name = debuffAura,
                remaining = remaining,
                after = math.max(remaining - castRem, 0),
                duration = duration,
            }
        end
    end
    -- Prefer the SpellDatabase's debuffAura (exact in-game name) over the spell name.
    -- Lookups go through the catalog spell KEY so A.FindDebuff/FindPlayerDebuff
    -- resolve all TBC aura spell IDs first with name fallback.
    local spellRef = def.spellKey or spellKey
    local spellDef = A.GetSpellDefinition and A.GetSpellDefinition(spellRef)
    local spellName = def.name
                   or (spellDef and (spellDef.debuffAura or spellDef.name))
                   or GetSpellDisplayName(spellRef)
    local remaining = 0
    local sourceMode = def.source or "player"

    if A.FindDebuff or A.FindPlayerDebuff then
        local name, _, _, _, _, expirationTime
        if sourceMode == "any" and A.FindDebuff then
            name, _, _, _, _, expirationTime = A.FindDebuff("target", spellRef)
            -- Also check sibling exclusive debuffs (e.g. Balance Faerie Fire vs Feral).
            if (not name) and spellDef and spellDef.debuffExclusive and spellDef.debuffSiblings then
                for _, sibKey in ipairs(spellDef.debuffSiblings) do
                    local n2, _, _, _, _, e2 = A.FindDebuff("target", sibKey)
                    if n2 and e2 and (not expirationTime or e2 > expirationTime) then
                        name, expirationTime = n2, e2
                    end
                end
            end
        elseif A.FindPlayerDebuff then
            name, _, _, _, _, expirationTime = A.FindPlayerDebuff("target", spellRef)
        end
        if name and expirationTime then
            remaining = math.max(expirationTime - now, 0)
        end
    end

    local recentWindow = tonumber(def.recentCastWindow) or 1.0
    if remaining == 0 and spellName and recentWindow > 0 and ctx and ctx.recentCast then
        local recent = ctx.recentCast[spellName] or ctx.recentCast[spellRef]
        if recent and (now - recent) < recentWindow then
            remaining = GetTrackedDebuffDuration(spec, spellKey)
        end
    end

    -- Use cast remaining for DoT "after" projection. ctx.dotBlockRemaining is
    -- the clip-aware blocking time (only the unclippable minimum of an active
    -- channel); ctx.clipCastRemaining always equals full remaining channel
    -- time (clip-aware logic disabled for the queue chain).
    -- Note: these can legitimately be 0, so we test ~= nil explicitly.
    local castRemaining
    if ctx and ctx.dotBlockRemaining ~= nil then
        castRemaining = ctx.dotBlockRemaining
    elseif ctx and ctx.clipCastRemaining ~= nil then
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
            -- Projected simulation: check simBuffs before hitting the live WoW API.
            local active
            if ctx and ctx.simBuffs and buffName and ctx.simBuffs[buffName] ~= nil then
                active = ctx.simBuffs[buffName] and ctx.simBuffs[buffName].active or false
            else
                active = buffName and PlayerHasBuff(buffName) or false
            end
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
    local rotationConfig = GetRotationChannelConfig(spec, spellKey)
    if rotationConfig then return rotationConfig end
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
            -- Prefer the channel's full duration (authoritative channel length);
            -- fall back to castTime for channels that only declare castTime
            -- (e.g. Evocation).  This is the single source of truth for channel
            -- length so ChainStepTime and SimulateSpellEffect always agree.
            if def.duration ~= nil then
                castTime = tonumber(def.duration) or 0
            elseif def.castTime ~= nil then
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
            if not TargetTTDMeetsMinimum(ttd, hpPct, isPreview, requiredTTD) then
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
        return math.max((endMS / 1000) - now, 0), not (notInterruptible == true)
    end

    local _, _, _, _, channelEndMS, _, channelNotInterruptible = UnitChannelInfo(unit)
    if channelEndMS then
        return math.max((channelEndMS / 1000) - now, 0), not (channelNotInterruptible == true)
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
        local maxResource = ctx.maxResource or (UnitPowerMax("player") or 1)
        if maxResource <= 0 then maxResource = 1 end
        return ((ctx.resourcePower or 0) / maxResource) * 100
    elseif subject == "player_hp_pct" then
        return (ctx.hpPct or 0) * 100
    elseif subject == "player_hp" then
        return ctx.playerHP or (UnitHealth("player") or 0)
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
        local rhs = ResolveCompareValue(cond.value, 0)
        return ResolveTargetTTDCompareValue(ctx, cond.op, rhs)
    elseif subject == "resource" then
        return ctx.resourcePower or 0
    elseif subject == "resource_at_gcd" then
        return ctx.resourceAtGCD or ctx.resourcePower or 0
    elseif subject == "next_power_tick_with_gcd" then
        return ctx.nextPowerTickWithGCD
    elseif subject == "threat_pct" then
        local unit = cond.unit or "target"
        if unit == "target" and ctx.threatPct ~= nil then return ctx.threatPct end
        return GetUnitThreatPercent(unit)
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
    elseif subject == "moving" then
        return ctx.moving and 1 or 0
    elseif subject == "pet_alive" then
        return ctx.petAlive and 1 or 0
    elseif subject == "pet_attacking" then
        return ctx.petAttacking and 1 or 0
    elseif subject == "swing_mh" then
        local sw = ctx.swingMH
        if not sw or not sw.readyTime or sw.readyTime <= 0 then return 0 end
        return math.max(sw.readyTime - ctx.now, 0)
    elseif subject == "swing_oh" then
        local sw = ctx.swingOH
        if not sw or not sw.readyTime or sw.readyTime <= 0 then return 0 end
        return math.max(sw.readyTime - ctx.now, 0)
    elseif subject == "swing_ranged" then
        local sw = ctx.swingR
        if not sw or not sw.readyTime or sw.readyTime <= 0 then return 0 end
        return math.max(sw.readyTime - ctx.now, 0)
    elseif subject == "feral_mode" then
        -- Druid feral mode dropdown (cat_dps / bear_tank).  Resolved from the
        -- spec setting so the mode-based form entries (Cat Form / Dire Bear
        -- Form) can actually fire; previously this subject resolved to nil and
        -- the form-switch suggestions never appeared.
        return A.SpecVal and A.SpecVal("feral_mode", "cat_dps") or "cat_dps"
    end

    return nil
end

local function ResolveSpellPropertyValue(cond, ctx, spec, db)
    local property = cond.property
    if property == "time_to_ready" then
        return GetProjectedSpellCooldown(cond.spellKey, ctx)
    elseif property == "cast_time" then
        local def = A.GetSpellDefinition and A.GetSpellDefinition(cond.spellKey)
        if def and (def.castType == "channel" or def.channel == true or (def.flags and def.flags.channel)) then
            return GetEffectiveSpellChannelTime(cond.spellKey, ctx)
        end
        return GetEffectiveSpellCastTime(cond.spellKey, ctx)
    elseif property == "travel_time" then
        return GetSpellTravelTimeForCompare(cond.spellKey, ctx)
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
    local name, count, _, expirationTime = GetUnitBuffInfo("player", cond.buff, ctx)
    if cond.property == "remaining" then
        return name and math.max((expirationTime or 0) - (ctx.now or GetTime()), 0) or 0
    elseif cond.property == "stacks" then
        if not name then return 0 end
        return ((count or 0) > 0) and count or 1
    end
    return nil
end

local function ResolveDebuffPropertyValue(cond, ctx, spec, db)
    local source = cond.source or "player"
    local debuffName = cond.debuff
    -- When a spellKey is provided, resolve the exact in-game debuff name via SpellDatabase.
    -- For source="any" with exclusive debuffs, GetDebuffAuraNames also returns sibling
    -- names so e.g. "Faerie Fire (Feral)" correctly catches a Balance "Faerie Fire" too.
    if cond.spellKey then
        local resolvedNames = (source == "any") and GetDebuffAuraNames(cond.spellKey)
        if resolvedNames then
            debuffName = (#resolvedNames == 1) and resolvedNames[1] or resolvedNames
        elseif not debuffName then
            local spellDef = A.GetSpellDefinition and A.GetSpellDefinition(cond.spellKey)
            debuffName = (spellDef and (spellDef.debuffAura or spellDef.name))
                      or (A.SPELLS and A.SPELLS[cond.spellKey] and A.SPELLS[cond.spellKey].name)
        end
    end
    -- Prefer the spell KEY for the lookup: A.FindDebuff resolves it to all TBC
    -- aura spell IDs (ID-first) plus the aura names, so rank and
    -- naming mismatches (e.g. "Curse of the Elements") are handled.
    local name, count, _, expirationTime = GetUnitDebuffInfo("target", cond.spellKey or debuffName, source)

    -- Recent-cast buffer: if we just cast this spell (<1s ago), assume the debuff is applied
    -- even if UnitDebuff hasn't updated yet (animation delay / API timing). Prevents
    -- spam-suggesting immediately after casting (e.g. Faerie Fire, Mangle).
    local now = ctx.now or GetTime()
    if not name and cond.spellKey and ctx and ctx.recentCast then
        -- Try multiple keys since recentCast uses in-game spell names from GetSpellInfo,
        -- which may differ from database keys (e.g. "Faerie Fire" vs "Faerie Fire (Feral)").
        local recent = nil
        -- First try the debuff aura name (what GetSpellInfo returns for most spells)
        if not recent and debuffName then
            recent = ctx.recentCast[debuffName]
        end
        -- Then try the database key directly
        if not recent then
            recent = ctx.recentCast[cond.spellKey]
        end
        -- Finally try resolving via SpellDatabase to get alternative names
        if not recent and type(debuffName) ~= "table" then
            local spellDef = A.GetSpellDefinition and A.GetSpellDefinition(cond.spellKey)
            if spellDef then
                local altNames = GetDebuffAuraNames(cond.spellKey) or { spellDef.debuffAura or spellDef.name }
                for _, altName in ipairs(altNames) do
                    recent = ctx.recentCast[altName]
                    if recent then break end
                end
            end
        end

        if recent and (now - recent) < 1.0 then
            -- Pretend the debuff is freshly applied at full duration so "remaining" checks pass.
            name = true
            expirationTime = now + 40  -- generous default; exact value doesn't matter here
        end
    end

    if cond.property == "remaining" then
        return name and math.max((expirationTime or 0) - now, 0) or 0
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
                    passesTTD = TargetTTDMeetsMinimum(ttd, data.hpPct or 0, data._preview == true, requiredTTD)
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

--- Return talent name and definition from TalentDatabase by position.
-- @param classToken string Player class token (e.g. "DRUID", "PRIEST").
-- @param tab number Talent tree (1-based).
-- @param index number Position in tree (1-based).
-- @return string|nil Talent display name, table|nil Definition from database.
function RE.GetTalentInfo(tab, index)
    local _, playerClass = UnitClass("player")
    if not playerClass then return nil, nil end

    -- Try API first for validation
    local ok, name, icon, description, rank, maxRank, tabName, isHeader, canLearn, isKnown, isGray = pcall(GetTalentInfo, tab, index)
    if not ok or not name then return nil, nil end

    -- Look up in our database for structured info
    local talentName, def = A.TalentDatabase and A.TalentDatabase:GetTalentByPosition(playerClass, tab, index)
    return (talentName or name), def
end

------------------------------------------------------------------------
-- Threat estimation helpers (TBC Classic rules)
-- Direct damage: 1x damage as threat
-- DoT ticks: 1.3x tick damage as threat per tick
-- Channeled spells: 1x per tick
-- Healing: 0.5x heal amount as threat
------------------------------------------------------------------------

--- Estimate threat generated by casting a spell once.
-- Uses the spell's threatMultiplier from SpellDatabase if available,
-- otherwise falls back to TBC Classic defaults based on flags.
-- @param spellDef table|number  Spell definition or baseId.
-- @param estimatedDamage number (optional) Estimated damage/healing done.
-- @return number Estimated threat generated by one cast.
function RE.EstimateSpellThreat(spellDef, estimatedDamage)
    if not spellDef then return 0 end

    -- Resolve to catalog entry if given an ID or name
    local def = spellDef
    if type(def) == "number" or type(def) == "string" then
        def = A.GetSpellDefinition and A.GetSpellDefinition(def)
    end
    if not def then return 0 end

    -- Use explicit threatMultiplier from catalog if present
    local tm = def.threatMultiplier
    if tm and type(tm) == "number" and tm > 0 then
        if estimatedDamage and estimatedDamage > 0 then
            return estimatedDamage * tm
        end
        -- Fall back to base damage estimate from catalog
        local baseDmg = (def.damage and def.damage.estimateBase) or 0
        if baseDmg > 0 then
            return baseDmg * tm
        end
        return tm -- Return multiplier itself as a relative indicator
    end

    -- Fallback: derive from flags using TBC Classic rules
    local flags = def.flags or {}
    if flags.dot then
        -- DoT: 1.3x per tick; total threat ≈ baseDamage * 1.3
        local baseDmg = (def.damage and def.damage.estimateBase) or 0
        return baseDmg * 1.3
    elseif flags.channel then
        -- Channeled: 1x per tick; total threat ≈ baseDamage * 1.0
        local baseDmg = (def.damage and def.damage.estimateBase) or 0
        return baseDmg * 1.0
    else
        -- Direct damage: 1x
        local baseDmg = (def.damage and def.damage.estimateBase) or 0
        return baseDmg * 1.0
    end
end

--- Compare two spells by estimated threat; returns true if spellA generates less threat than spellB.
-- Useful for choosing lower-threat alternatives when near aggro pull.
function RE.IsLowerThreat(spellA, spellB)
    local threatA = RE.EstimateSpellThreat(spellA)
    local threatB = RE.EstimateSpellThreat(spellB)
    return threatA < threatB and true or false
end

--- Estimate the mana cost of casting a spell once.
-- Reads manaCost (flat) or manaCostPct (% of base mana) from the catalog.
-- Returns 0 for free spells (Inner Focus) and when the Inner Focus buff is
-- active (the next spell is free).  Returns nil when the spell has no mana
-- cost data (non-mana classes / uncatalogued spells) so callers can skip.
function RE.GetSpellManaCost(spellKey, ctx)
    local def = A.GetSpellDefinition and A.GetSpellDefinition(spellKey)
    if not def then return nil end
    local cost = def.manaCost
    if cost == nil and def.manaCostPct then
        local baseMana = (ctx and ctx.baseMana) or GetPlayerBaseMana()
        if not baseMana or baseMana <= 0 then
            baseMana = (ctx and ctx.maxMana) or (UnitPowerMax("player", 0) or 1)
        end
        cost = baseMana * def.manaCostPct
    elseif cost and cost > 0 then
        -- Level-aware scaling: the catalog stores the MAX-rank cost, but at
        -- lower levels the player's known rank costs less.  Scale linearly
        -- from ~20% of the max cost at the spell's minLevel (rank 1) to 100%
        -- at level 70 so low-level play isn't over-blocked (e.g. PW:Fortitude
        -- costs 1695 at max rank but only ~70 at rank 1).  %-of-base-mana
        -- costs (manaCostPct) are level-independent and are NOT scaled.
        local level = UnitLevel("player") or 70
        local minLevel = def.minLevel or 1
        local scale = (level - minLevel) / math.max(70 - minLevel, 1)
        scale = math.max(0.2, math.min(1, scale))
        cost = cost * scale
    end
    if not cost or cost <= 0 then return 0 end
    -- Inner Focus makes the next spell free.  The forward simulation tracks
    -- the buff in simBuffs when the spec tracks it; otherwise fall back to
    -- the live buff.
    local ifActive = false
    if ctx and ctx.simBuffs and ctx.simBuffs["Inner Focus"] ~= nil then
        ifActive = ctx.simBuffs["Inner Focus"].active == true
    elseif A.HasBuff then
        local ok, active = pcall(A.HasBuff, "player", "Inner Focus")
        ifActive = ok and active == true
    end
    if ifActive then return 0 end
    return cost
end

--- Safety filter shared by the main queue, the upcoming section, and the
-- forward simulation so all paths agree.  Returns:
--   "mana"   - the player can't afford the spell's mana cost,
--   "threat" - casting it would push scaled threat to/past the aggro
--              threshold (threat avoidance active, group content only),
--   nil      - safe to cast.
function RE.GetSpellSafetyBlock(spellKey, ctx)
    if not spellKey or not ctx then return nil end
    -- Mana affordability
    local mCost = RE.GetSpellManaCost(spellKey, ctx)
    if mCost and mCost > 0 and (ctx.currentMana or 0) < mCost then
        return "mana"
    end
    -- Threat avoidance (party/raid only — solo scaled threat is meaningless
    -- because the player is always the tank).
    local mode = ctx.threatAvoidance or "never"
    if mode ~= "never" and ctx.inGroup and ctx.threatPct and ctx.threatPct > 0 then
        local scaled = ctx.threatPct
        local threshold = (mode == "aggressive") and 100 or 95
        local spellThreat = RE.EstimateSpellThreat(spellKey)
        if spellThreat and spellThreat > 0 then
            local threatValue = ctx.threatValue or 0
            -- Buffs / free casts (threat ~1) can never pull aggro, so never
            -- threat-block them: skip when the spell adds less than 1% of the
            -- current threat value (it can't meaningfully move scaled threat).
            if threatValue > 0 and spellThreat < threatValue * 0.01 then
                return nil
            end
            -- scaledPct is proportional to total threat at a fixed distance,
            -- so a cast's new scaled value is scaled * (1 + add/current).
            -- Without an absolute threat value, fall back to the current
            -- scaled percentage alone (the "scaledPct shortcut").
            local newScaled = (threatValue > 0)
                and (scaled * (threatValue + spellThreat) / threatValue)
                or scaled
            if newScaled >= threshold then
                return "threat"
            end
        end
    end
    return nil
end

------------------------------------------------------------------------
-- Context builder — generic snapshot of all relevant game state.
-- Class-specific fields are populated via spec.buildContext(ctx, spec).
------------------------------------------------------------------------
function RE:BuildContext(spec)
    _InitSwingTracker()
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
    local gcdRemaining = GetGCDRemaining(now, gcd)
    local lat          = A.GetLatency()
    local SAFETY       = constants.SAFETY or 0.5

    -- Resources (mana)
    local currentMana  = UnitPower("player", 0) or 0
    local maxMana      = math.max(UnitPowerMax("player", 0) or 1, 1)
    local baseMana     = GetPlayerBaseMana()
    if baseMana <= 0 then baseMana = maxMana end
    local manaPct      = currentMana / maxMana
    local baseManaPct  = currentMana / math.max(baseMana, 1)
    local playerHP     = UnitHealth("player") or 0
    local playerMaxHP  = math.max(UnitHealthMax("player") or 1, 1)
    local hpPct        = playerHP / playerMaxHP

    local sp           = (A.GetSpellPower and A.GetSpellPower()) or 0
    local targetHP, targetMaxHP = 0, 0
    local targetGUID   = UnitGUID("target")
    if UnitExists("target") then
        targetHP    = UnitHealth("target")    or 0
        targetMaxHP = UnitHealthMax("target") or 0
    end

    -- Threat snapshot for the current target — read once per refresh instead
    -- of per condition (threat_pct / threat_pct_lt / threat_pct_ge).
    -- scaledPct = player threat scaled so the tank is 100 (100 = about to
    -- pull aggro at current distance); threatValue = absolute threat units;
    -- isTank = player is the mob's primary target.
    local threatPct = 0
    local threatValue = 0
    local threatIsTank = false
    if UnitExists("target") and type(UnitDetailedThreatSituation) == "function" then
        local isTank, _, scaledPct, rawPct, tValue = UnitDetailedThreatSituation("player", "target")
        threatPct = scaledPct or rawPct or 0
        threatValue = tValue or 0
        threatIsTank = isTank == true
    end

    -- Group presence (party/raid) — gates the threat avoidance filter, which
    -- is meaningless solo (the player is always the primary target).
    local inGroup = (GetNumGroupMembers and GetNumGroupMembers() > 0) or false

    -- Threat avoidance mode from the active spec's settings ("never" for
    -- specs that don't define it).
    local threatAvoidance = "never"
    if A.SpecVal then
        local tv = A.SpecVal("threatAvoidance", "never")
        if type(tv) == "string" then threatAvoidance = tv end
    end

    local timing         = constants.timing or {}
    local WAIT_THRESHOLD = (timing.globalWaitThresholdMs or 400) / 1000

    -- Combo points
    local comboPoints  = (GetComboPoints and GetComboPoints("player", "target")) or 0

    -- Non-mana resource (energy / rage / focus)
    local resourcePower = UnitPower("player") or 0

    -- Power/energy regen estimator (per power type)
    local currentPowerType = UnitPowerType("player") or 0
    do
        local nowP = now
        -- Track the current power type (energy / rage / focus).
        _UpdatePowerTracker(currentPowerType, resourcePower, nowP)
        -- Always track energy ticks too: druids regenerate energy in every form
        -- (cat, bear, caster, moonkin), so the energy tick phase must be sampled
        -- from the energy bar directly rather than only when the current power
        -- type happens to be energy.  Form shifts therefore never reset the
        -- energy cadence that energy-gated countdowns (Mangle/Shred) rely on.
        if currentPowerType ~= 3 then
            local eCurr = UnitPower("player", 3)
            if eCurr ~= nil then
                _UpdatePowerTracker(3, eCurr, nowP)
            end
        end
    end
    local currentPowerState = _powerState.byType[currentPowerType]
    local energyPowerState  = _powerState.byType[3]
    local currentRegen      = (currentPowerState and currentPowerState.rate) or 0

    -- HP decay
    UpdateHPDecay()
    local hpDecayRate = _hpDecay.rate
    local targetTTD   = nil
    if targetGUID and targetMaxHP > 0 and A.UpdateTargetHealthSample then
        A.UpdateTargetHealthSample(targetGUID, targetHP / targetMaxHP, now)
    end
    if targetGUID and A.GetTargetHealthDecayRate then
        local stableRate = A.GetTargetHealthDecayRate(targetGUID)
        if stableRate ~= nil then
            hpDecayRate = math.max(tonumber(stableRate) or 0, 0)
        end
    end
    if targetGUID and A.GetTargetTimeToDie then
        targetTTD = A.GetTargetTimeToDie(targetGUID)
    end
    if not targetTTD and targetMaxHP > 0 and hpDecayRate > 0.0001 then
        targetTTD = (targetHP / targetMaxHP) / hpDecayRate
    end

    -- Time until the next energy tick (or the current power's last detected
    -- gain when the current power is not energy).  Because the cadence is a
    -- fixed 2.0s, we project the phase forward with modulo so the estimate stays
    -- correct even when the last detected tick is several seconds stale (e.g.
    -- after energy was capped and no tick gain was observed).  For energy we
    -- always use the ENERGY tracker's phase (maintained in every form), so form
    -- shifts don't reset the countdown cadence.
    local nextPowerTick = nil
    local energyNextPowerTick = nil
    local currentIsEnergy = (currentPowerType == 3) or
        (Enum and Enum.PowerType and currentPowerType == Enum.PowerType.Energy)
    local tickState = currentIsEnergy and energyPowerState or currentPowerState
    if tickState and tickState.lastTickTime then
        local sinceTick = now - tickState.lastTickTime
        if sinceTick < 0 then sinceTick = 0 end
        local intoTick = sinceTick % _powerState.tickInterval
        nextPowerTick = _powerState.tickInterval - intoTick
        if nextPowerTick >= _powerState.tickInterval - 0.0001 then nextPowerTick = 0 end
    end
    if energyPowerState and energyPowerState.lastTickTime then
        local sinceTick = now - energyPowerState.lastTickTime
        if sinceTick < 0 then sinceTick = 0 end
        local intoTick = sinceTick % _powerState.tickInterval
        energyNextPowerTick = _powerState.tickInterval - intoTick
        if energyNextPowerTick >= _powerState.tickInterval - 0.0001 then energyNextPowerTick = 0 end
    end
    local readyIn       = math.max(castRemaining or 0, gcdRemaining or 0)
    local powerType     = currentPowerType
    local maxResource   = UnitPowerMax("player") or 100
    if maxResource <= 0 then maxResource = 100 end

    local resourceAtGCD = resourcePower
    local isEnergyPower = currentIsEnergy
    local powerTickInterval = math.max(_powerState.tickInterval or 2.0, 0.1)
    if isEnergyPower then
        if nextPowerTick and nextPowerTick <= readyIn then
            local ticks    = 1 + math.floor((readyIn - nextPowerTick) / powerTickInterval)
            resourceAtGCD  = resourcePower + ticks * 20
        end
    elseif currentRegen > 0 then
        resourceAtGCD = resourcePower + (currentRegen * readyIn)
    end
    resourceAtGCD = math.min(resourceAtGCD, maxResource)
    local nextPowerTickWithGCD = nil
    if nextPowerTick then
        if nextPowerTick >= readyIn then
            nextPowerTickWithGCD = nextPowerTick - readyIn
        else
            local remainder = (readyIn - nextPowerTick) % powerTickInterval
            nextPowerTickWithGCD = (remainder <= 0.0001) and 0 or (powerTickInterval - remainder)
        end
    end

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

    -- Movement detection (available on 2.5.5)
    local moving = false
    local ok_move, moveSpeed = pcall(GetUnitSpeed, "player")
    if ok_move and moveSpeed and moveSpeed > 0 then moving = true end

    -- Melee range check: distance² ≤ 36 (6 yards squared). Used by leveling specs
    -- to decide when to switch from wand to direct spells.
    local inMeleeRange = false
    if UnitExists("target") then
        local ok_dist, distSq = pcall(UnitDistanceSquared, "player", "target")
        if ok_dist and distSq ~= nil and distSq <= 36 then
            inMeleeRange = true
        end
    end

    -- Wand detection: check inventory slot 18 (ranged weapon) for a wand-type item.
    -- Used by leveling specs to decide whether wand is available as filler.
    local wandEquipped = false
    do
        local rLink = GetInventoryItemLink("player", 18)
        if rLink then
            -- Wands have "Wand" in their tooltip class string or item type substring.
            -- GetItemInfo returns (name, link, quality, level, minLevel, type, subtype, ...)
            local _, _, _, _, _, itemType, itemSubType = GetItemInfo(rLink)
            if itemSubType and itemSubType:lower() == "wand" then
                wandEquipped = true
            end
        end
    end

    -- Pet state
    local petAlive, petAttacking = false, false
    if UnitExists("pet") then
        petAlive = not UnitIsDead("pet")
        if petAlive then
            local petTarget = UnitGUID("pettarget")
            petAttacking = petTarget ~= nil and petTarget ~= ""
        end
    end

    -- Totem state
    local totem = {}
    for slot = 1, 4 do
        local haveTotem, totemName, startTime, duration = GetTotemInfo(slot)
        if haveTotem and totemName then
            local remaining = math.max(0, duration - (now - startTime))
            totem[slot] = {
                name = totemName,
                remaining = remaining,
                duration = duration,
                startTime = startTime,
            }
        end
    end

    -- Swing timer state (populated by _swingFrame handler)
    local swingMH   = _swingState and _swingState.mh   or {}
    local swingOH   = _swingState and _swingState.oh   or {}
    local swingR    = _swingState and _swingState.r    or {}

    -- Build the base generic context
    local ctx = {
        now            = now,
        builtAt        = now,  -- Snapshot time; sim contexts inherit this via __index so
                               -- cooldown evaluators can compute simElapsed = ctx.now - ctx.builtAt.
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
        playerHP       = playerHP,
        hpPct          = hpPct,
        sp             = sp,
        targetGUID     = targetGUID,
        targetHP       = targetHP,
        targetMaxHP    = targetMaxHP,
        targetTTD      = targetTTD,
        threatPct      = threatPct,
        threatValue    = threatValue,
        threatIsTank   = threatIsTank,
        inGroup        = inGroup,
        threatAvoidance = threatAvoidance,
        inCombat       = UnitAffectingCombat("player"),
        WAIT_THRESHOLD = WAIT_THRESHOLD,
        recentCast     = recentCast,
        comboPoints    = comboPoints,
        powerType      = powerType,
        maxResource    = maxResource,
        resourcePower  = resourcePower,
        resourceRegen  = currentRegen,
        nextPowerTick  = nextPowerTick,
        energyNextPowerTick = energyNextPowerTick,
        resourceAtGCD  = resourceAtGCD,
        nextPowerTickWithGCD = nextPowerTickWithGCD,
        hpDecayRate    = hpDecayRate,
        activeChannelSpellKey = activeChannelSpellKey,
        channelTickInterval   = channelTickInterval,
        channelTicksRemaining = channelTicksRemaining,
        channelTimeToNextTick = channelTimeToNextTick,
        moving         = moving,
        inMeleeRange   = inMeleeRange,
        wandEquipped   = wandEquipped,
        petAlive       = petAlive,
        petAttacking   = petAttacking,
        totem          = totem,
        swingMH        = swingMH,
        swingOH        = swingOH,
        swingR         = swingR,
    }

    -- Debug: power-state snapshot (POWER module).  Throttled to ~2 Hz so a fight
    -- doesn't flood the 200-entry buffer.  Contains everything needed to
    -- reproduce energy-gated countdown issues: the reported power type, every
    -- power bar (mana/rage/energy), the per-type EMA rates and tick phases, the
    -- next-tick projections, and the GCD/cast state.
    if A.IsDebugModuleEnabled and A.IsDebugModuleEnabled("POWER") then
        if (not _powerLastDebugAt) or (now - _powerLastDebugAt) >= 0.5 then
            _powerLastDebugAt = now
            local function SafePower(t)
                local ok, v = pcall(UnitPower, "player", t)
                return ok and v or "?"
            end
            local parts = {
                string.format("type=%d bar=%d max=%d", currentPowerType, resourcePower, maxResource),
                string.format("mana=%.0f/%.0f pct=%.1f", currentMana, maxMana, manaPct * 100),
            }
            if currentPowerType ~= 0 then
                parts[#parts + 1] = string.format("manaExplicit=%s", tostring(SafePower(0)))
            end
            if currentPowerType ~= 1 then
                parts[#parts + 1] = string.format("rage=%s", tostring(SafePower(1)))
            end
            if currentPowerType ~= 3 then
                parts[#parts + 1] = string.format("energy=%s", tostring(SafePower(3)))
            end
            for pt, st in pairs(_powerState.byType) do
                parts[#parts + 1] = string.format("trk[%d]:rate=%.2f lastTick=%s", pt, st.rate or 0,
                    st.lastTickTime and string.format("%.2f", st.lastTickTime) or "nil")
            end
            parts[#parts + 1] = string.format("forms: cat=%s bear=%s dire=%s moonkin=%s",
                tostring(PlayerHasBuff("Cat Form")), tostring(PlayerHasBuff("Bear Form")),
                tostring(PlayerHasBuff("Dire Bear Form")), tostring(PlayerHasBuff("Moonkin Form")))
            parts[#parts + 1] = string.format("regen=%.2f nextTick=%s energyNextTick=%s atGCD=%s",
                currentRegen or 0,
                nextPowerTick and string.format("%.2f", nextPowerTick) or "nil",
                energyNextPowerTick and string.format("%.2f", energyNextPowerTick) or "nil",
                tostring(resourceAtGCD))
            parts[#parts + 1] = string.format("gcd=%.2f gcdRem=%.2f castRem=%s readyIn=%.2f",
                gcd, gcdRemaining, tostring(castRemaining), readyIn)
            A.DebugLog("POWER", table.concat(parts, " | "))
        end
    end

    -- Clip-aware cast remaining (DISABLED).
    -- Previously: when channeling a spell with `allowClipping = true`, this set
    -- clipCastRemaining to "time to next tick" instead of full remaining channel
    -- time, so queue timers reflected the optimal clip moment. This caused timers
    -- to jump around during channels as ticks fired (ttn reset each tick).
    -- Disabled per user request: castbar markings and fakequeue helpers already
    -- handle clip timing; rotation advisor should only show normal remaining time.
    do
        ctx.clipCastRemaining = castRemaining
    end

    -- DoT-projection blocking time.
    -- The DoT "after" projection (projected_dot_time_left_lt) answers "how much
    -- remaining time will the DoT have when the current blocking action ends".
    -- For a hard cast the blocking time is the full remaining cast.  For an
    -- active channel that supports clipping (minDuration > 0) the channel is
    -- interruptible, so only the unclippable minimum (minDuration - elapsed)
    -- blocks the refresh.  Subtracting the FULL remaining channel time made
    -- DoT refreshes (e.g. Vampiric Touch) fire ~3 s early while channeling —
    -- most visibly right after clipping Mind Flay into a new Mind Flay, where
    -- castRemaining jumps back to the full channel duration (user request).
    -- Mirrors the channelClip breakAt formula (minDuration - elapsed).
    local dotBlockRemaining = castRemaining
    if ctx.activeChannelSpellKey then
        local cfg = GetChannelSpellConfig(spec, ctx.activeChannelSpellKey)
        local minDur = cfg and tonumber(cfg.minDuration)
        if minDur and minDur > 0 then
            local chanEff = GetEffectiveSpellChannelTime(ctx.activeChannelSpellKey, ctx) or 0
            local elapsed = math.max(chanEff - castRemaining, 0)
            dotBlockRemaining = math.max(minDur - elapsed, 0)
        end
    end
    ctx.dotBlockRemaining = dotBlockRemaining

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
                ctx[alias .. "After"]   = math.max((state.remaining or 0) - ((ctx.dotBlockRemaining ~= nil) and ctx.dotBlockRemaining or (ctx.clipCastRemaining or 0)), 0)
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

    -- Channel spell config (first helper-enabled channel; used for clip overlays)
    local channelConfig = nil
    local rotation = GetRuntimeRotation(spec)
    if type(rotation) == "table" then
        for index, entry in ipairs(rotation) do
            channelConfig = BuildChannelConfigFromEntry(spec, entry, index)
            if channelConfig then break end
        end
    end
    channelConfig = channelConfig or (spec and spec.channelSpells and spec.channelSpells[1])
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
            A.ReportError("ENGINE", "spec.buildContext", err, { spec = spec and spec.meta and spec.meta.id or "?" })
        end
    end

    return ctx
end

------------------------------------------------------------------------
-- Forward-simulation context projection.
--
-- Creates a lightweight projected ctx that reflects game state AFTER a
-- given spell is cast.  Used by _BuildResultFromCandidates to predict
-- positions 2–4 in the queue without any spec-specific logic.
--
-- What is projected from SpellDatabase data:
--   now              — advanced by max(castTime, GCD)
--   resourcePower    — cost subtracted, regen added
--   comboPoints      — incremented (builders) or cleared (finishers)
--   simBuffs         — form buffs granted/removed; other buffs granted
--   simDebuffs       — debuffs applied to target with full duration
--   simulatedCooldowns — spell placed on cooldown
--   castingSpell / castRemaining — cleared (cast finished)
--
-- The returned ctx uses metatable inheritance so unchanged fields
-- read through to the parent ctx.
------------------------------------------------------------------------
function RE:SimulateSpellEffect(ctx, spellKey, spec, advanceOverride)
    if not ctx or not spellKey then return ctx end

    local def = A.GetSpellDefinition and A.GetSpellDefinition(spellKey)
    local now = ctx.now or GetTime()
    local gcd = ctx.gcd or 1.5

    -- Time advance: GCD (instants) or cast time, whichever is longer.
    -- For channeled spells GetEffectiveSpellCastTime returns 0 (they only
    -- cost one GCD to start), but the player is fully occupied for the
    -- entire channel duration.  Use def.duration so the forward simulation
    -- correctly places subsequent spells (e.g. Mind Blast coming off CD
    -- after two full Mind Flay channels).
    -- advanceOverride can be provided by the caller (forward simulation loop)
    -- to simulate channel clipping – a shorter advance than the full channel
    -- time.
    local castEff = GetEffectiveSpellCastTime(spellKey, ctx) or 0
    if def and def.castType == "channel" then
        -- Channels occupy the player for their full haste-adjusted duration.
        -- Use the same helper as ChainStepTime so the chain and the forward
        -- simulation always agree on channel length.
        castEff = GetEffectiveSpellChannelTime(spellKey, ctx) or 0
    end
    -- Spells that do NOT trigger the global cooldown (Inner Focus, trinkets,
    -- potions, runes) advance only by their cast time (0 for instants) — the
    -- next spell can start immediately after them (user request).
    local advance
    if not SpellTriggersGCD(spellKey) then
        advance = advanceOverride or castEff
    else
        advance = math.max(advanceOverride or castEff, gcd)
    end

    -- Build projected ctx inheriting everything from parent.
    local p = setmetatable({}, { __index = ctx })
    p.now           = now + advance
    p.castRemaining = 0
    p.gcdRemaining  = 0
    -- Use explicit non-nil sentinels so that __index does NOT fall through to
    -- the live parent ctx's values (assigning nil to a proxy table field just
    -- deletes it, which then exposes the parent value via __index).
    p.castingSpell          = false   -- false is falsy like nil but blocks __index
    p.isChanneling          = false   -- channeling evaluator checks this in sim ctx
    p.clipCastRemaining     = 0       -- must be numeric (used in arithmetic)
    p.dotBlockRemaining     = 0       -- no channel blocking after simulated cast
    p.activeChannelSpellKey = false   -- no longer mid-channel after simulated cast

    -- Resource (energy/rage/mana)
    local cost  = (def and (def.resourceCost or 0)) or 0
    local consumesClearcasting = false
    if cost > 0 and def and def.flags and def.flags.offensive then
        local clearcasting = GetTrackedBuffState(spec, ctx, "clearcasting")
        if clearcasting and clearcasting.active then
            cost = 0
            consumesClearcasting = true
        end
    end
    local regen = (ctx.resourceRegen or 0) * advance
    local maxR  = ctx.maxResource or (UnitPowerMax("player") or 100)
    if maxR <= 0 then maxR = 100 end
    p.resourcePower  = math.max(0, math.min(maxR, (ctx.resourcePower or 0) - cost + regen))
    p.resourceAtGCD  = p.resourcePower

    -- Mana projection (mana classes): subtract the spell's mana cost and add
    -- mana regen over the advance window so forward simulation stays honest
    -- about affordability for positions 2-4.  Spells without mana cost data
    -- (or free casts like Inner Focus) leave currentMana inherited.
    if def and (def.manaCost ~= nil or def.manaCostPct ~= nil) then
        local mCost = RE.GetSpellManaCost(spellKey, ctx)
        if mCost and mCost > 0 then
            local mRegen = (ctx.resourceRegen or 0) * advance
            local maxM = ctx.maxMana or (UnitPowerMax("player", 0) or 1)
            if maxM <= 0 then maxM = 1 end
            p.currentMana = math.max(0, math.min(maxM, (ctx.currentMana or 0) - mCost + mRegen))
            p.manaPct = p.currentMana / maxM
        end
    end

    -- Combo points
    local cp = ctx.comboPoints or 0
    if def then
        if def.comboPointsGenerated then
            cp = math.min(5, cp + def.comboPointsGenerated)
        elseif def.comboPointsConsumed == "all" then
            cp = 0
        end
    end
    p.comboPoints = cp

    -- Simulated cooldowns: copy parent table and mark this spell.
    local simCDs = {}
    for k, v in pairs(ctx.simulatedCooldowns or {}) do simCDs[k] = v end
    if def and def.baseId then
        local cooldown = def.cooldown
        if not cooldown then
            -- Instant spells share the GCD; spells with explicit CD use that.
            local spId = def.baseId
            if spId and A.GetSpellCDReal then
                local liveCd = A.GetSpellCDReal(spId) or 0
                if liveCd > gcd then cooldown = liveCd end
            end
        end
        if cooldown and cooldown > 0 then
            local resolvedId = (A.ResolveSpellID and A.ResolveSpellID(spellKey)) or def.baseId
            simCDs[resolvedId or def.baseId] = p.now + cooldown
            if def.baseId and def.baseId ~= resolvedId then
                simCDs[def.baseId] = p.now + cooldown
            end
        end
    end
    p.simulatedCooldowns = simCDs

    -- Simulated buffs: copy parent simBuffs (or empty) then apply changes.
    local simB = {}
    for k, v in pairs(ctx.simBuffs or {}) do simB[k] = v end
    local function DeactivateTrackedBuff(buffKey)
        if not buffKey then return end
        for _, bd in ipairs((spec and spec.trackedBuffs) or {}) do
            if bd.key == buffKey or bd.spellKey == buffKey then
                local bname = bd.name or GetSpellDisplayName(bd.spellKey or buffKey)
                if bname then simB[bname] = { active = false } end
            end
        end
    end
    if def then
        -- Remove forms that this spell replaces.
        if def.removesFormKeys then
            for _, fkey in ipairs(def.removesFormKeys) do
                DeactivateTrackedBuff(fkey)
            end
        end
        if def.removesBuffKeys then
            for _, bkey in ipairs(def.removesBuffKeys) do
                DeactivateTrackedBuff(bkey)
            end
        end
        if def.flags and def.flags.requiresStealth then
            DeactivateTrackedBuff("stealth")
        end
        if consumesClearcasting then
            DeactivateTrackedBuff("clearcasting")
        end
        -- Grant the buff this spell applies.
        if def.grantsFormKey or (def.buffId and def.flags and def.flags.form) then
            local grantKey = def.grantsFormKey
            -- Find the spec trackedBuffs entry for this key.
            for _, bd in ipairs((spec and spec.trackedBuffs) or {}) do
                local match = (grantKey and bd.key == grantKey)
                           or (def.buffId and bd.spellKey and A.SPELLS and A.SPELLS[bd.spellKey]
                               and A.SPELLS[bd.spellKey].id == def.buffId)
                if match then
                    local bname = bd.name or GetSpellDisplayName(bd.spellKey or bd.key)
                    if bname then
                        simB[bname] = { active = true, count = 1,
                                        duration = def.duration or -1,
                                        expiry   = def.duration and def.duration > 0
                                                   and (p.now + def.duration) or math.huge }
                    end
                    break
                end
            end
        end
        -- Generic non-form buffs (e.g. Tiger's Fury, Inner Focus).
        if def.buffId and not (def.flags and def.flags.form) then
            local bname = def.name
            if bname then
                simB[bname] = { active = true, count = 1,
                                duration = def.duration or 0,
                                expiry   = (def.duration and def.duration > 0)
                                           and (p.now + def.duration) or math.huge }
            end
        end
    end
    p.simBuffs = simB

    -- Replace the trackedBuffs caches with empty tables rather than nil.
    -- Setting a metatable-proxy field to nil does NOT mask the parent table;
    -- __index would fall through to the live ctx's populated caches and return
    -- the real game state instead of the simulated one.
    -- An empty table causes cache lookups to miss and fall through to the
    -- spec.trackedBuffs loop, which then reads simBuffs correctly.
    p.trackedBuffs           = {}
    p.trackedBuffsBySpellKey = {}

    -- Simulated debuffs: copy parent simDebuffs then apply what this spell applies.
    local simD = {}
    for k, v in pairs(ctx.simDebuffs or {}) do simD[k] = v end
    if def then
        local auraName = def.debuffAura or (def.debuffId and def.name)
        if auraName and def.duration and def.duration > 0 then
            simD[auraName] = { expiry = p.now + def.duration }
            -- Also register sibling names for exclusive debuffs so the
            -- "remaining" check resolves correctly (e.g. Faerie Fire vs FF Feral).
            if def.debuffExclusive and def.debuffSiblings then
                for _, sibKey in ipairs(def.debuffSiblings) do
                    local sibDef = A.GetSpellDefinition and A.GetSpellDefinition(sibKey)
                    local sibName = sibDef and (sibDef.debuffAura or sibDef.name)
                    if sibName and sibName ~= auraName then
                        -- Sibling is the same debuff — mark absent so the engine
                        -- doesn't double-count from the live API.
                        simD[sibName] = false
                    end
                end
            end
        end
    end
    p.simDebuffs = simD

    -- Same fix for debuff caches: use empty tables so cache misses fall through
    -- to GetTrackedDebuffState → simDebuffs.
    p.trackedDebuffs           = {}
    p.trackedDebuffsBySpellKey = {}

    -- recentCast: mark this spell as recently cast so not_recently_cast conditions
    -- correctly block re-queuing the same spell in positions 2–4.
    local newRecentCast = {}
    for k, v in pairs(ctx.recentCast or {}) do newRecentCast[k] = v end
    if def and def.name then
        newRecentCast[def.name] = p.now
    end
    p.recentCast = newRecentCast

    return p
end

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
    local spell = A.SPELLS and A.SPELLS[key]
    -- Gate on spell knowledge FIRST: an unlearned catalog spell has no real
    -- cooldown (GetProjectedSpellCooldown would report 0 and suggest it).
    if spell and not A.KnowsSpell(spell.id) then return false end
    local cd = GetProjectedSpellCooldown(key, ctx)
    if cd ~= nil then return cd == 0 end
    if spell then
        return A.KnowsSpell(spell.id) and A.GetSpellCDReal(spell.id) == 0
    end
    return false
end

RE._condEval["dot_missing"] = function(cond, ctx, spec, db)
    local key = cond.spellKey
    if key then
        -- Gate on spell knowledge: an unlearned DoT would otherwise be
        -- reported as "missing" and suggested.
        local spell = A.SPELLS and A.SPELLS[key]
        if spell and not A.KnowsSpell(spell.id) then return false end
        local state = GetTrackedDebuffState(spec, ctx, key)
        if state then
            return (state.remaining or 0) <= 0
        end
    end
    return ResolveDebuffRemaining(spec, ctx, cond) <= 0
end

RE._condEval["should_apply_debuff"] = function(cond, ctx, spec, db)
    local key = cond.spellKey
    if not key then return false end
    local target = (ctx and ctx.targetUnit) or "target"
    -- Pass playerGUID from context so stacking checks can identify our own debuffs
    local evalCtx = { playerGUID = ctx and ctx.playerGUID }
    return ShouldApplyDebuff(key, target, evalCtx)
end

RE._condEval["player_has_debuff"] = function(cond, ctx, spec, db)
    -- Returns true if THIS player has the given debuff on target.
    -- Used for mutual exclusivity checks (e.g., warlock curse slot).
    local key = cond.spellKey
    if not key then return false end
    local target = (ctx and ctx.targetUnit) or "target"
    local playerGUID = ctx and ctx.playerGUID
    if not playerGUID then return false end

    -- ID-first: resolve all TBC aura spell IDs + names for this key.
    local ref = A.ResolveAuraRef and A.ResolveAuraRef(key)
    local ids = ref and ref.ids or {}
    local names = ref and (ref.names or {}) or { key }

    -- Check all harmful debuffs on target for our caster GUID
    local count = select(1, UnitDebuff(target)) or 0
    for i = 1, count do
        local name, _, _, _, _, _, casterGUID, _, _, spellId = UnitDebuff(target, i - 1, "HARMFUL")
        if name and casterGUID and casterGUID == playerGUID then
            -- Match by aura spell ID first (rank/localization-proof)
            for _, wantedId in ipairs(ids) do
                if spellId and spellId == wantedId then
                    return true
                end
            end
            -- Fall back to exact/prefix name matching
            for _, targetName in ipairs(names) do
                if name == targetName or name:lower():find(targetName:lower(), 1, true) then
                    return true
                end
            end
        end
    end
    return false
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
        local clipCast = (ctx and ctx.dotBlockRemaining ~= nil) and ctx.dotBlockRemaining
            or ((ctx and ctx.clipCastRemaining ~= nil) and ctx.clipCastRemaining)
            or (ctx and ctx.castRemaining or 0)
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
        local max = ctx.maxResource or (UnitPowerMax("player") or 1)
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
        local max = ctx.maxResource or (UnitPowerMax("player") or 1)
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
        mode = A.SpecVal("swdRaid", "always")
    elseif contentType == "dungeon" then
        mode = A.SpecVal("swdDungeon", "always")
    else
        mode = A.SpecVal("swdWorld", "execute")
    end
    if mode == "never" then return false end
    if mode == "execute" then
        -- Only allow if SWD can kill
        local sp = ctx.sp or 0
        local swdHit = math.floor(sp * 1.55 + 0.5)
        local safety = A.SpecVal("swdSafetyPct", 0) or 0
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
    if ctx and ctx.simInCombat ~= nil then return not ctx.simInCombat end
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
    -- Use fuzzy matching for rank differences
    return not A.HasBuff(unit, name)
end

RE._condEval["target_classification"] = function(cond, ctx, spec, db)
    local required = cond.classification or "boss"
    local actual = A.GetTargetClassification()
    return actual == required
end

-- classification_from_setting: reads a setting key (e.g. "trinket_1_classification")
-- at runtime; if the value is "any" or nil, pass.  Otherwise require an exact match
-- against the current target's classification (for offensive spells).
RE._condEval["classification_from_setting"] = function(cond, ctx, spec, db)
    local key = cond.settingKey
    if not key then return true end
    local val = A.SpecVal(key, "any")
    if val == "any" or val == nil or val == "" then return true end
    local actual = A.GetTargetClassification()
    return actual == tostring(val)
end

-- classification_any_target: same as above but checks ANY tracked target
-- (for non-offensive abilities like self-buffs, summons, party buffs).
-- If there is a boss in the target tracker, Bloodlust will fire even when
-- the player has a normal mob targeted.
RE._condEval["classification_any_target"] = function(cond, ctx, spec, db)
    local key = cond.settingKey
    if not key then return true end
    local val = A.SpecVal(key, "any")
    if val == "any" or val == nil or val == "" then return true end
    -- Check current target first
    local actual = A.GetTargetClassification()
    if actual == tostring(val) then return true end
    -- Boss encounter active always matches "boss"
    if val == "boss" and A._activeBossEncounter then return true end
    -- Check all tracked targets
    for guid, _ in pairs(A.dotTargets or {}) do
        local unit = A.FindUnitForGUID(guid)
        if unit and UnitExists(unit) then
            actual = A.GetUnitClassification(unit)
            if actual == tostring(val) then return true end
        end
    end
    return false
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
    local unit = cond.unit or "target"
    local threat = (unit == "target" and ctx.threatPct ~= nil) and ctx.threatPct or GetUnitThreatPercent(unit)
    return threat < threshold
end

RE._condEval["threat_pct_ge"] = function(cond, ctx, spec, db)
    local threshold = ResolveNumericValue(cond.pct, 100) or 100
    local unit = cond.unit or "target"
    local threat = (unit == "target" and ctx.threatPct ~= nil) and ctx.threatPct or GetUnitThreatPercent(unit)
    return threat >= threshold
end

------------------------------------------------------------------------
-- Condition evaluators
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
    -- Use fuzzy matching for rank differences
    return A.HasBuff(unit, name)
end

RE._condEval["buff_stacks_gte"] = function(cond, ctx, spec, db)
    local name = cond.buff
    if not name then return false end
    local needed = ResolveNumericValue(cond.stacks, 1) or 1
    -- Use fuzzy matching for rank differences
    local _, _, count = A.FindBuffByName("player", name)
    if count then
        local stacks = ((count or 0) > 0) and count or 1
        return stacks >= needed
    end
    return false
end

RE._condEval["target_hp_pct_lt"] = function(cond, ctx, spec, db)
    if not UnitExists("target") then return false end
    -- Prefer the once-per-refresh ctx snapshot (fetched a single time per
    -- evaluation and shared by every slot) over a per-condition API call.
    local hp = (ctx and ctx.targetHP) or (UnitHealth("target") or 0)
    local maxHP = (ctx and ctx.targetMaxHP) or (UnitHealthMax("target") or 1)
    local pct = cond.pct
    if type(pct) == "string" then
        pct = (A.SpecVal and A.SpecVal(pct, 20)) or 20
    end
    pct = (pct or 20) / 100
    return maxHP > 0 and (hp / maxHP) < pct
end

RE._condEval["target_hp_pct_gt"] = function(cond, ctx, spec, db)
    if not UnitExists("target") then return false end
    local hp = (ctx and ctx.targetHP) or (UnitHealth("target") or 0)
    local maxHP = (ctx and ctx.targetMaxHP) or (UnitHealthMax("target") or 1)
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
-- Estimates the MINIMUM damage the ability can deal (base damage floor +
-- spell power / attack power scaling) and multiplies it by any % damage
-- modifiers that are reliably active:
--   • passive talents (e.g. Darkness for shadow spells)
--   • player buffs granting % spell damage (e.g. Shadowform +15% shadow)
--   • debuffs on the target increasing damage taken (e.g. Misery +5%,
--     Shadow Weaving per-stack, Improved Shadow Bolt +5%)
-- Crit is deliberately NOT included — kill checks use the conservative floor.
--
-- Per-school modifier tables (schoolMask = 2^(school-1), 32 = shadow, 1 = physical).
------------------------------------------------------------------------
local SCHOOL_KILL_MODS = {
    [32] = { -- shadow
        passiveTalents = {
            { tab = 3, index = 16, perRank = 0.02 },  -- Darkness: +2%/rank shadow damage
        },
        buffs = {
            { name = "Shadowform", pct = 0.15 },       -- +15% shadow damage
        },
        targetDebuffs = {
            { name = "Misery",              pct = 0.05 },                  -- +5% spell damage taken
            { name = "Shadow Weaving",      perStack = 0.02, maxStacks = 5 }, -- +2% shadow per stack
            { name = "Improved Shadow Bolt", pct = 0.05 },                  -- +5% shadow damage taken (TBC)
        },
    },
    -- physical (e.g. Ferocious Bite): no % damage-taken multipliers modeled
    -- (armor reduction is not a % modifier and is intentionally excluded).
    [1] = {},
}

RE._condEval["spell_can_kill_target"] = function(cond, ctx, spec, db)
    if not UnitExists("target") or (ctx.targetHP or 0) <= 0 then return false end
    local spellKey = cond.spellKey
    if not spellKey then return false end

    local baseDmg = 0
    local power   = 0
    local def = A.GetSpellDefinition and A.GetSpellDefinition(spellKey)
    if def then
        -- estimateBase is the conservative FLOOR of the ability's damage range,
        -- so using it directly gives the minimum non-crit hit.
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
            -- For AP-scaling finishers, multiply per combo point (e.g. Ferocious Bite is ~0.07/CP).
            local cp = (def.comboScaling and ctx and ctx.comboPoints) and math.max(ctx.comboPoints, 1) or 1
            power = ap * apCoeff * cp
        end

        -- Additive combo-point scaling (e.g. Ferocious Bite: +36 flat damage per combo point).
        if def.comboScaling and def.comboScaling.pointsPerComboPoint then
            local cp = ctx and math.max(ctx.comboPoints or 1, 1) or 1
            baseDmg = baseDmg + tonumber(def.comboScaling.pointsPerComboPoint) * cp
        end
    end

    -- Minimum-damage multiplier: only apply modifiers that are verifiably
    -- active right now (talents the player has, buffs currently up, debuffs
    -- currently on the target).  Nothing random (crit) is included.
    local mult = 1
    local mods = def and SCHOOL_KILL_MODS[def.schoolMask]
    if mods then
        for _, t in ipairs(mods.passiveTalents or {}) do
            local rank = (A.RotationEngine and A.RotationEngine.GetTalentRank
                          and A.RotationEngine.GetTalentRank(t.tab, t.index)) or 0
            if rank > 0 then
                mult = mult * (1 + rank * (t.perRank or 0))
            end
        end
        for _, b in ipairs(mods.buffs or {}) do
            if A.HasBuff and A.HasBuff("player", b.name) then
                mult = mult * (1 + (b.pct or 0))
            end
        end
        for _, d in ipairs(mods.targetDebuffs or {}) do
            if A.FindDebuff then
                if d.perStack then
                    local _, stacks = A.FindDebuff("target", d.name)
                    local n = math.min(stacks or 0, d.maxStacks or 5)
                    if n > 0 then
                        mult = mult * (1 + n * d.perStack)
                    end
                else
                    local found = A.FindDebuff("target", d.name)
                    if found then
                        mult = mult * (1 + (d.pct or 0))
                    end
                end
            end
        end
    end

    local estimatedDmg = (baseDmg + power) * mult

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
    if ctx and ctx.simInCombat ~= nil then return ctx.simInCombat end
    return UnitAffectingCombat("player")
end

RE._condEval["not_in_combat"] = function(cond, ctx, spec, db)
    return not UnitAffectingCombat("player")
end

------------------------------------------------------------------------
-- has_aggro / not_has_aggro
-- True when the target is currently attacking the player.
-- Primary signal: target's current target is the player.
-- Secondary signal: UnitThreatSituation level >= 2 (tanking).
------------------------------------------------------------------------
RE._condEval["has_aggro"] = function(cond, ctx, spec, db)
    if not UnitExists("target") then return false end
    if UnitIsUnit("targettarget", "player") then return true end
    local threat = UnitThreatSituation and UnitThreatSituation("player", "target")
    return threat ~= nil and threat >= 2
end

RE._condEval["not_has_aggro"] = function(cond, ctx, spec, db)
    if not UnitExists("target") then return true end
    if UnitIsUnit("targettarget", "player") then return false end
    local threat = UnitThreatSituation and UnitThreatSituation("player", "target")
    return not (threat ~= nil and threat >= 2)
end

RE._condEval["not_behind_target"] = function(cond, ctx, spec, db)
    if not UnitExists("target") then return false end
    local evalFn = RE._condEval["behind_target"]
    if not evalFn then return false end
    local ok, res = pcall(evalFn, cond, ctx, spec, db)
    return not (ok and res)
end

RE._condEval["channeling"] = function(cond, ctx, spec, db)
    -- ctx.isChanneling is explicitly set to false by SimulateSpellEffect for
    -- projected sim contexts, so conditions like not{channeling} correctly
    -- pass in queue slots 2-4 even while the player is physically channeling.
    -- For the live context isChanneling is nil (not set), so we fall through
    -- to the WoW API to read real game state.
    local isChanneling = ctx.isChanneling
    if isChanneling == nil then
        isChanneling = (UnitChannelInfo("player") ~= nil)
    end
    if cond.spellKey then
        if not isChanneling then return false end
        local channelingSpell = UnitChannelInfo("player")
        if not channelingSpell then return false end
        local def = A.GetSpellDefinition and A.GetSpellDefinition(cond.spellKey)
        local spellName = def and def.name or cond.spellKey
        if channelingSpell == spellName then return true end
        -- Non-English clients: UnitChannelInfo returns the localized name
        -- (e.g. German "Gedankenschlag"). Resolve it via the spell DB
        -- (which registers localized names) and compare by key.
        local chDef = A.GetSpellDefinition and A.GetSpellDefinition(channelingSpell)
        return chDef ~= nil and chDef.key == cond.spellKey
    end
    -- Without spellKey: true when any channel is active and we have its name.
    return isChanneling and ctx.castingSpell ~= nil and ctx.castingSpell ~= false
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
-- Feral / positional / resource / HP-decay evaluators
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
    -- Use fuzzy matching for rank differences (e.g., lower-rank curses)
    return A.HasDebuff(unit, name)
end

-- Debuff time remaining on target < cond.seconds (any source, by name).
RE._condEval["debuff_time_left_lt"] = function(cond, ctx, spec, db)
    if not UnitExists("target") then return false end
    local name = cond.debuff
    if not name then return false end
    local seconds = cond.seconds or 3
    -- Use fuzzy matching for rank differences
    local _, _, _, _, _, expireTime = A.FindDebuffByName("target", name)
    if expireTime then
        local rem = math.max(expireTime - ctx.now, 0)
        return rem < seconds
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
    local rate = math.max(tonumber(ctx.hpDecayRate) or 0, 0)
    if direction == "slower" then
        return rate < threshold
    end
    return rate >= threshold
end

RE._condEval["target_ttd_gte"] = function(cond, ctx, spec, db)
    local seconds = ResolveNumericValue(cond.seconds ~= nil and cond.seconds or cond.value, 0)
    if seconds <= 0 then return true end
    return TargetTTDComparePasses(ctx, ">=", seconds)
end

RE._condEval["target_ttd_lt"] = function(cond, ctx, spec, db)
    local seconds = ResolveNumericValue(cond.seconds ~= nil and cond.seconds or cond.value, 0)
    if seconds <= 0 then return false end
    return TargetTTDComparePasses(ctx, "<", seconds)
end

-- Flat resource check: current resource (energy/rage/mana) >= cond.amount.
RE._condEval["resource_gte"] = function(cond, ctx, spec, db)
    return ctx.resourcePower >= (ResolveNumericValue(cond.amount, 0) or 0)
end

-- Flat resource check: current resource < cond.amount (energy/rage/mana).
RE._condEval["resource_lt"] = function(cond, ctx, spec, db)
    return ctx.resourcePower < (ResolveNumericValue(cond.amount, 0) or 0)
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
    if ctx.nextPowerTickWithGCD == nil then return false end
    return ctx.nextPowerTickWithGCD < seconds
end

RE._condEval["next_power_tick_with_gcd_gt"] = function(cond, ctx, spec, db)
    local seconds = ResolveNumericValue(cond.seconds, 0)
    if ctx.nextPowerTickWithGCD == nil then return false end
    return ctx.nextPowerTickWithGCD > seconds
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

-- trinket_ready: checks if a trinket in the given inventory slot (13 or 14)
-- is equipped, has an on-use effect, and its cooldown is ready.  Passive
-- proc/equip trinkets (no "Use:" effect) never satisfy this condition.
RE._condEval["trinket_ready"] = function(cond, ctx, spec, db)
    local slot = tonumber(cond.slot) or 13
    if slot ~= 13 and slot ~= 14 then return false end
    local ok, itemId = pcall(GetInventoryItemID, "player", slot)
    if not ok or not itemId then return false end
    if not A.ItemHasOnUseEffect(itemId, slot) then
        if A.DebugLog then
            A.DebugLog("ROT", "trinket_ready: slot " .. slot .. " item " .. tostring(itemId) .. " has no on-use effect (passive) - skipped")
        end
        return false
    end
    local start, dur = GetInventoryItemCooldown("player", slot)
    if start and start > 0 then
        return (start + dur - ctx.now) <= 0
    end
    -- start == 0: trinket off cooldown → ready.
    return true
end

-- is_moving: true when GetUnitSpeed("player") > 0 (available on 2.5.5).
RE._condEval["is_moving"] = function(cond, ctx, spec, db)
    return ctx.moving == true
end

RE._condEval["not_is_moving"] = function(cond, ctx, spec, db)
    return ctx.moving ~= true
end

-- melee_range: true when target is within 6 yards (melee distance).
-- Used by leveling specs to decide wand vs direct spells.
RE._condEval["melee_range"] = function(cond, ctx, spec, db)
    return ctx.inMeleeRange == true
end

-- not_melee_range: inverse of melee_range.
RE._condEval["not_melee_range"] = function(cond, ctx, spec, db)
    return ctx.inMeleeRange ~= true
end

-- wand_equipped: true when player has a wand-type ranged weapon in slot 18.
RE._condEval["wand_equipped"] = function(cond, ctx, spec, db)
    return ctx.wandEquipped == true
end

-- pet_alive: true when pet exists and is not dead.
RE._condEval["pet_alive"] = function(cond, ctx, spec, db)
    return ctx.petAlive == true
end

-- pet_attacking: true when pet has a valid target.
RE._condEval["pet_attacking"] = function(cond, ctx, spec, db)
    return ctx.petAttacking == true
end

-- creature_type: checks UnitCreatureType("target") against cond.typeName.
RE._condEval["creature_type"] = function(cond, ctx, spec, db)
    local required = cond.typeName or cond.creatureType
    if not required then return false end
    if not UnitExists("target") then return false end
    local actual = UnitCreatureType("target")
    if not actual then return false end
    return actual == required
end

-- totem_active: true when a totem exists in the given slot.
RE._condEval["totem_active"] = function(cond, ctx, spec, db)
    local slot = tonumber(cond.slot) or 1
    local t = ctx.totem and ctx.totem[slot]
    return t ~= nil
end

-- totem_remaining_lt: checks remaining time on a totem slot.
RE._condEval["totem_remaining_lt"] = function(cond, ctx, spec, db)
    local slot = tonumber(cond.slot) or 1
    local t = ctx.totem and ctx.totem[slot]
    if not t then return false end
    local seconds = ResolveNumericValue(cond.seconds, 0)
    return t.remaining < seconds
end

-- totem_name: checks the name of a totem in a given slot.
RE._condEval["totem_name"] = function(cond, ctx, spec, db)
    local slot = tonumber(cond.slot) or 1
    local t = ctx.totem and ctx.totem[slot]
    if not t or not t.name then return false end
    local required = cond.name or cond.totemName
    if not required then return false end
    if t.name == required then return true end
    -- Non-English clients: totem names from GetTotemInfo are localized;
    -- the spell DB registers localized names, so resolve and compare by
    -- catalog key/name.
    local def = A.GetSpellDefinition and A.GetSpellDefinition(t.name)
    return def ~= nil and (def.name == required or def.key == required)
end

-- swing_time_remaining: checks time until the next auto-swing for a hand.
-- cond.hand: "mh" (default), "oh", "ranged"
RE._condEval["swing_time_remaining"] = function(cond, ctx, spec, db)
    local hand = cond.hand or "mh"
    local sw = hand == "oh" and ctx.swingOH or (hand == "ranged" and ctx.swingR or ctx.swingMH)
    if not sw or not sw.readyTime or sw.readyTime <= 0 then return false end
    local remaining = sw.readyTime - ctx.now
    local op = cond.op or "<"
    local threshold = ResolveNumericValue(cond.seconds or cond.value, 0)
    if op == "<" then return remaining < threshold end
    if op == ">" then return remaining > threshold end
    if op == "<=" then return remaining <= threshold end
    if op == ">=" then return remaining >= threshold end
    return remaining < threshold
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
        local v = GetSpellTravelTimeForCompare(key, ctx)
        return tostring(v or 0)
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

    local source   = cond and cond.source or "player"
    local debuffName = cond and cond.debuff or nil
    -- Use SpellDatabase debuffAura and sibling resolution for accurate in-game names.
    if spellKey then
        if source == "any" then
            local names = GetDebuffAuraNames(spellKey)
            if names then
                debuffName = (#names == 1) and names[1] or names
            end
        end
        if not debuffName then
            local def = A.GetSpellDefinition and A.GetSpellDefinition(spellKey) or nil
            debuffName = (def and (def.debuffAura or def.name)) or nil
        end
    end
    local now = (ctx and ctx.now) or GetTime()

    -- ID-first: resolve by catalog spell key so all TBC aura spell
    -- IDs (and sibling variants) are matched before falling back to names.
    if spellKey then
        local fn = (source == "any" and A.FindDebuff) or A.FindPlayerDebuff
        if fn then
            local _, _, _, _, _, exp = fn("target", spellKey)
            if exp then return math.max(exp - now, 0) end
        end
        return 0
    end

    -- Legacy conditions without a spellKey: name-based scan.
    if not debuffName then return 0 end
    if type(debuffName) == "table" then
        local maxRem = 0
        for _, dName in ipairs(debuffName) do
            local fn = (source == "any" and A.FindDebuff) or A.FindPlayerDebuff
            if fn then
                local _, _, _, _, _, exp = fn("target", dName)
                if exp then maxRem = math.max(maxRem, exp - now) end
            end
        end
        return math.max(maxRem, 0)
    end
    local fn = (source == "any" and A.FindDebuff) or A.FindPlayerDebuff
    if not fn then return 0 end
    local _, _, _, _, _, exp = fn("target", debuffName)
    if not exp then return 0 end
    return math.max(exp - now, 0)
end

function RE._ComputeEntryRefreshETA(entry, ctx, spec)
    if not entry or not entry.conditions then return nil end

    local ok_init, result = pcall(function()
        local maxEta
        local function bump(value)
            if not value or value < 0 then return end
            if not maxEta or value > maxEta then maxEta = value end
        end

        for _, cond in ipairs(entry.conditions) do
            local t = cond and cond.type
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
            elseif t == "trinket_ready" then
                local slot = tonumber(cond.slot) or 13
                local ok_e, itemId = pcall(GetInventoryItemID, "player", slot)
                -- Only on-use trinkets are suggestable (see _EvaluatePrepared).
                if ok_e and itemId and A.ItemHasOnUseEffect(itemId, slot) then
                    local start, dur = GetInventoryItemCooldown("player", slot)
                    if start and start > 0 then
                        bump(math.max(start + dur - (ctx.now or GetTime()), 0))
                    end
                end
            end
        end

        return maxEta
    end)

    if not ok_init then
        if A.ReportError then
            pcall(A.ReportError, "ROT", "_ComputeEntryRefreshETA", tostring(result))
        end
        return nil
    end
    return result
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

    -- Pseudo-keys (TRINKET1/2, POTION, RUNE, WAND) have no spell id
    -- (spellKey = nil): never gate them on spell knowledge, or they get
    -- blocked as "unknown_spell" (A.KnowsSpell(nil) == false) and silently
    -- vanish from suggestions. Their item conditions (equipped slot,
    -- cooldown) already handle availability.
    local entrySpellId = entrySpell and (entrySpell.id or entrySpell.baseId)
    if entrySpell and entrySpellId and not A.KnowsSpell(entrySpellId) then
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
                local max = ctx.maxResource or (UnitPowerMax("player") or 100)
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
                        local max = ctx.maxResource or (UnitPowerMax("player") or 100)
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
                            local maxR = ctx.maxResource or (UnitPowerMax("player") or 100)
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

    -- NOTE: No range gate here.  Out-of-range abilities intentionally STAY in
    -- the rotation so the player can see the next suggestion while moving into
    -- range.  The display layer (Rotation.lua IsKeyInRange / SetTextureColor)
    -- tints them red as the standard "out of range" indicator.

    -- Safety filters (mana affordability + threat avoidance), shared with the
    -- upcoming section and the forward simulation via RE.GetSpellSafetyBlock.
    -- A mana block becomes a resource block (countdown, never suggested while
    -- unaffordable); a threat block just flags the candidate so the queue and
    -- sim can drop it (the display then suggests Fade / the wand fallback).
    local manaBlocked = false
    local threatBlocked = false
    if not otherFail and not resourceBlock then
        local safety = RE.GetSpellSafetyBlock(entry.key, ctx)
        if safety == "mana" then
            manaBlocked = true
            local mCost = RE.GetSpellManaCost(entry.key, ctx)
            resourceBlock = { required = mCost or 0, resource = "mana" }
        elseif safety == "threat" then
            threatBlocked = true
        end
    end

    if not otherFail and resourceBlock and EntryHasConditionType(entry, "precombat") then
        otherFail = true
        if diag then diag.precombatResourceFail = true end
    end

    local allowCandidate = true
    if entry.key ~= "POTION" and entry.key ~= "RUNE" and entry.key ~= "TRINKET1" and entry.key ~= "TRINKET2" and entry.key ~= "Shadowfiend" then
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
        -- Time-from-now until spell is off cooldown.  Use the projected
        -- helper so simulated contexts can move cooldowns forward as the
        -- queue advances through channel/cast time.
        eta = math.max(GetProjectedSpellCooldown(entry.key, ctx) or 0, 0)
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
            -- For energy (power type 3) use a tick-based formula instead of the
            -- continuous EMA rate.  Energy in WoW regenerates as discrete 20-unit
            -- ticks every ~2 seconds.  The EMA rate (_powerState.rate) is unstable:
            -- it briefly goes negative or spikes every time the player spends energy,
            -- which caused the displayed countdown to jump several seconds per cycle.
            -- The tick-based formula is stable: as `now` advances by dt,
            -- `ctx.nextPowerTick` decreases by dt, so `now + eta` is constant
            -- between evaluations (changes only when a tick actually fires).
            -- Energy spells are detected from the reported power type AND from the
            -- spell's own definition (requiresCatForm / energy flag).  The flags
            -- matter because UnitPowerType can report a stale or wrong index right
            -- after a form shift — a cat-form ability is always energy-gated, so
            -- its wait must stay tick-based instead of falling back to the
            -- continuous EMA rate (which is what produced the multi-second "Mangle
            -- not ready yet" countdowns).
            local isPowerTypeEnergy = (ctx.powerType == 3) or
                (Enum and Enum.PowerType and ctx.powerType == Enum.PowerType.Energy) or
                (entrySpell and entrySpell.meta and entrySpell.meta.flags and
                    (entrySpell.meta.flags.requiresCatForm or entrySpell.meta.flags.energy or
                     entrySpell.meta.flags.energyResource))
            if isPowerTypeEnergy then
                local energyPerTick = ENERGY_PER_TICK
                local tickInterval  = math.max(_powerState.tickInterval or ENERGY_TICK_INTERVAL or 2.0, 0.1)
                local ticksNeeded   = math.max(math.ceil(need / energyPerTick), 1)
                -- Use the ENERGY tracker's tick phase, which is maintained in every
                -- form (see BuildContext) and is independent of the reported power
                -- type.  If the phase is unknown, fall back to one full tick
                -- interval so energy waits stay tick-based instead of reverting to
                -- the unstable EMA regen estimate.
                local timeToFirstTick = ctx.energyNextPowerTick
                if timeToFirstTick == nil then
                    timeToFirstTick = tickInterval
                end
                -- timeToFirstTick = time to first tick.  Nth tick is at:
                --   timeToFirstTick + (N-1) * tickInterval
                local timeToNthTick = timeToFirstTick + (ticksNeeded - 1) * tickInterval
                eta = math.max(eta, timeToNthTick)
            else
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
        manaBlocked    = manaBlocked,
        threatBlocked  = threatBlocked,
    }, diag
end

function RE:_BuildResultFromCandidates(ctx, rotation, hasTarget, candidates, spec)
    local WAIT_THRESHOLD = ctx.WAIT_THRESHOLD
    local now = ctx.now or GetTime()

    table.sort(candidates, function(a, b)
        return a.index < b.index
    end)

    -- Safety filters: drop candidates the player can't afford (mana) or that
    -- would pull aggro (threat avoidance).  These are removed entirely rather
    -- than queued with an ETA — mana regen in combat is ~0 so a mana countdown
    -- would never tick down, and the threat situation is resolved by Fade /
    -- the wand fallback below, not by waiting.
    do
        local filtered = {}
        for _, cand in ipairs(candidates) do
            if not cand.manaBlocked and not cand.threatBlocked then
                filtered[#filtered + 1] = cand
            end
        end
        candidates = filtered
    end

    local result = {}
    local seen   = {}
    local resultByKey = {}

    local function GetEntryRepeatLimit(entry)
        local limit = entry and (entry.repeatLimit or entry.queueRepeatLimit)
        limit = tonumber(limit)
        if limit and limit > 0 then
            return math.max(1, math.floor(limit + 0.5))
        end
        if entry and entry.isFiller then
            return 2
        end
        return 1
    end

    -- Add a result entry with both an `eta` (used for ordering / "next cast"
    -- semantics) and a `cooldownEnd` absolute timestamp so the UI can render
    -- a smoothly-ticking countdown without stalling when the player is in
    -- the middle of a cast/channel.
    -- `isChained` marks entries that are sequenced in the cast chain (ready
    -- but not castable yet because something else is being cast first) vs
    -- entries that are genuinely blocked by a cooldown or resource deficit.
    -- Chained entries are rendered bright; blocked entries are dimmed.
    local function Add(entry, key, eta, clip, priorityBucket, cooldownEnd, isChained)
        local repeatLimit = GetEntryRepeatLimit(entry)
        if not key then return end
        local existing = resultByKey[key]
        if existing and repeatLimit <= 1 then
            local newEta = eta or 0
            local newCooldownEnd = cooldownEnd
            if not (newCooldownEnd and newCooldownEnd > now) and newEta > 0 then
                newCooldownEnd = now + newEta
            end

            local existingEta = existing.eta or 0
            local existingCooldownEnd = existing.cooldownEnd
            local shouldReplace = newEta < existingEta
                or (newEta == existingEta and newCooldownEnd and existingCooldownEnd and newCooldownEnd < existingCooldownEnd)

            if shouldReplace then
                existing.eta = newEta
                existing.entry = entry
                if newCooldownEnd and newCooldownEnd > now then
                    existing.cooldownEnd = newCooldownEnd
                else
                    existing.cooldownEnd = nil
                end
            end
            if clip then existing.clip = true end
            if isChained then existing.chained = true end
            if priorityBucket ~= nil and existing.priorityBucket == nil then
                existing.priorityBucket = priorityBucket
            end
            return
        end
        if seen[key] then
            if repeatLimit <= 1 then return end
            local count = tonumber(seen[key]) or 1
            if count >= repeatLimit then return end
            seen[key] = count + 1
        else
            seen[key] = (repeatLimit > 1) and 1 or true
        end
        eta = eta or 0
        local resultEntry = { key = key, eta = eta, entry = entry }
        if cooldownEnd and cooldownEnd > now then
            resultEntry.cooldownEnd = cooldownEnd
        elseif eta > 0 then
            resultEntry.cooldownEnd = now + eta
        end
        if clip then resultEntry.clip = true end
        if isChained then resultEntry.chained = true end
        if priorityBucket ~= nil then resultEntry.priorityBucket = priorityBucket end
        result[#result + 1] = resultEntry
        resultByKey[key] = resultEntry
        -- Note: seen[key] is already set above, before the early-return checks.
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
    local readyOptCands = {}  -- ready bonus-slot actions (trinkets, potions, runes)
    local blockedCands = {}
    for _, cand in ipairs(candidates) do
        local candEta = cand.eta or 0
        local projectedCD = GetProjectedSpellCooldown(cand.key, ctx) or 0
        local readyIn = math.max(candEta, projectedCD)
        local cooldownEnd = (readyIn > 0) and (now + readyIn) or nil

        if cand.key then
            if readyIn <= READY_EPSILON and cand.entry and cand.entry.optional then
                -- BONUS-SLOT ACTIONS (trinkets, potions, runes) are NOT part
                -- of the priority chain: the display layer routes ready
                -- optionals to the bonus slot, so they must never occupy a
                -- chain position nor consume a GCD (which inflated the
                -- timers of the priority spells after them — user request).
                -- They are re-appended by the optional re-add block below.
                readyOptCands[#readyOptCands + 1] = {
                    cand = cand, readyIn = readyIn, clip = false, cooldownEnd = cooldownEnd,
                }
            else
                local bucket = (readyIn <= READY_EPSILON) and readyCands or blockedCands
                bucket[#bucket + 1] = {
                    cand = cand, readyIn = readyIn, clip = false, cooldownEnd = cooldownEnd,
                }
            end
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
    --   * Synths carry NO timer (cooldownEnd = nil, eta = 0): they are OFF
    --     cooldown (except GCD), and their countdown used to look like a very
    --     long global cooldown and suggested them 4+ s before they should be
    --     cast.  The cast signal is their queue position plus the flip to
    --     slot 1 when the refresh condition fires (user request).
    --   * Chain readyCands show NO timer (cooldownEnd = nil, eta = 0) unless
    --     they are the primary slot during an active cast, where the timer
    --     shows the remaining cast/channel time. This avoids the "1.5 / 3.0 /
    --     4.5 static" display the user reported.
    --   * Blocked candidates (real spell CD or resource) already carry a
    --     `cooldownEnd` anchored to `now + rawCD` which ticks correctly.
    -- ------------------------------------------------------------------
    local function ChainStepTime(key)
        -- A channeled spell (Mind Flay) occupies the player for its full
        -- haste-adjusted duration, not a single GCD.  GetEffectiveSpellCastTime
        -- returns 0 for channels, so without this branch every channel in the
        -- chain was costed at the GCD floor (1.5s) — inconsistent with
        -- SimulateSpellEffect, which advances by the full channel duration when
        -- predicting positions 2-4.  The ACTIVE channel is special-cased to a
        -- zero step at i==1 below (its time is already folded into accTime via
        -- clipCastRemaining), so this only affects predicted/future channels.
        local def = A.GetSpellDefinition and A.GetSpellDefinition(key)
        if def and def.castType == "channel" then
            local chanEff = GetEffectiveSpellChannelTime(key, ctx) or 0
            return math.max(chanEff, ctx.gcd or 1.5)
        end
        local castEff = GetEffectiveSpellCastTime(key, ctx) or 0
        -- Spells that do NOT trigger the global cooldown (Inner Focus,
        -- trinkets, potions, runes) cost only their cast time (0 for
        -- instants) — they can be cast immediately after another ability
        -- without a GCD (user request).
        if not SpellTriggersGCD(key) then
            return castEff
        end
        return math.max(castEff, ctx.gcd or 1.5)
    end

    local function ChainFillerStep(key)
        -- Fillers are interruptible casts: a channel filler only commits up
        -- to its clip point (second-to-last tick), so it can squeeze into a
        -- gap before a refresh deadline instead of blocking the chain with
        -- its full duration.  This is what lets the queue show "Mind Flay,
        -- then the refresh" instead of jumping straight to the refresh 4 s
        -- before it should be cast (user request).  Same math as the
        -- forward-sim GetClipAdvance helper.
        local def = A.GetSpellDefinition and A.GetSpellDefinition(key)
        if def and def.castType == "channel" then
            local haste = ctx.hasteMul or 1
            if haste <= 0 then haste = 1 end
            local fullChannel = ((def.duration or def.castTime) or 3) / haste
            local tickInterval = def.tickInterval or 1
            local totalTicks = def.ticks or math.ceil(fullChannel * haste)
            if totalTicks > 1 then
                local clipPoint = ((totalTicks - 1) * tickInterval) / haste
                if clipPoint > READY_EPSILON and fullChannel > clipPoint then
                    return clipPoint
                end
            end
        end
        return ChainStepTime(key)
    end

    local function GetDotRemaining(spellKey)
        local state = GetTrackedDebuffState(spec, ctx, spellKey)
        if state then
            return state.remaining or 0
        end
        -- ID-first lookup via the catalog key (all ranks/sibling IDs, name fallback).
        if A.FindPlayerDebuff then
            local _, _, _, _, _, expirationTime = A.FindPlayerDebuff("target", spellKey)
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

    -- Synth gate: a refresh-timer synth is only meaningful if the entry's
    -- OTHER (non-timing) conditions hold NOW — form gates, spec options,
    -- target validity, stealth, etc.  The synth represents "cast this when
    -- the refresh deadline arrives", so an entry that can't be cast at all
    -- (e.g. Mangle (Bear) while in cat form) must not contribute a refresh
    -- countdown to the queue.  Conditions are checked in order, stopping at
    -- the refresh-window condition that drives the synth (it legitimately
    -- fails while the debuff is healthy) — mirroring _EvaluateEntry's
    -- early-break semantics.  cooldown_ready is skipped: the synth
    -- collector already requires the spell to be off cooldown.
    local function SynthGatesPass(entry)
        if not entry or not entry.conditions then return true end
        for _, cond in ipairs(entry.conditions) do
            if cond.type == "debuff_property_compare" and cond.property == "remaining"
                    and (cond.op == "<" or cond.op == "<=" or cond.op == "lt" or cond.op == "lte" or cond.op == "le") then
                return true
            end
            if cond.type ~= "cooldown_ready" then
                local evalFn = self._condEval[cond.type]
                if not evalFn then return false end
                local ok, r = pcall(evalFn, cond, ctx, spec, nil)
                if not ok or not r then return false end
            end
        end
        return true
    end

    -- Collect synths: refresh-pending entries not already in candidates.
    local seenCandKeys = {}
    for _, c in ipairs(readyCands)   do seenCandKeys[c.cand.key] = true end
    for _, c in ipairs(blockedCands) do seenCandKeys[c.cand.key] = true end

    local synths = {}
    for _, entry in ipairs(rotation) do
        if entry.key and not seenCandKeys[entry.key] and entry.conditions then
            local deadline = GetRefreshDeadline(entry)
            if deadline ~= nil and SynthGatesPass(entry) then
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
    -- cast/channel. Always uses full remaining channel time (clip-aware logic disabled).
    local accTime = (ctx.clipCastRemaining ~= nil) and ctx.clipCastRemaining or (ctx.castRemaining or 0)
    -- queueTime is the cast-state-INDEPENDENT queue timeline: every chain
    -- position costs its full ChainStepTime, and the in-flight cast remainder
    -- is NOT folded in.  The DoT-refresh synth horizon and the chain-fill
    -- placement must use queueTime so the queue content (filler run vs
    -- refresh countdown) is identical whether the player is mid-cast or idle.
    -- accTime (wall-clock) still drives the chained countdown anchors.
    local queueTime = 0
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
    -- current position. Synths carry no cooldownEnd (see TIMER RULE).
    local function FlushSynthsBefore(threshold)
        while si <= #synths and synths[si].deadline < threshold do
            local s = synths[si]; si = si + 1
            -- No countdown on refresh synths: they are OFF cooldown (except
            -- GCD), and the cast signal is their queue position plus the
            -- flip to slot 1 when the refresh condition actually fires.
            -- Showing the deadline as a timer made them look like a very
            -- long global cooldown and suggested them 4+ s before they
            -- should be cast (user request).
            Add(s.entry, s.key, 0, false, ResolveEntryPriorityBucket(s.entry), nil)
            accTime = accTime + ChainStepTime(s.key)
            queueTime = queueTime + ChainStepTime(s.key)
        end
    end

    for i, c in ipairs(readyCands) do
        local step = ChainStepTime(c.cand.key)
        local fullStep = step  -- uncorrected step for the state-independent queueTime

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
            local isCastingCandidate = spellEntry and spellEntry.name == ctx.castingSpell
            if not isCastingCandidate then
                -- Non-English clients: UnitCastingInfo returns localized names
                -- (e.g. German "Gedankenschlag"); resolve and compare by key.
                local castDef = A.GetSpellDefinition and A.GetSpellDefinition(ctx.castingSpell)
                isCastingCandidate = castDef ~= nil and castDef.key == c.cand.key
            end
            if isCastingCandidate then
                -- Replace step with only the GCD overhang (almost always 0).
                step = math.max((ctx.gcdRemaining or 0) - accTime, 0)
            end
        end

        -- ── Active-channel anchor correction ──────────────────────────
        -- When the top suggestion IS the spell currently being channeled
        -- (e.g. "keep channeling Mind Flay"), `accTime` already equals the
        -- full remaining channel time. Adding another ChainStepTime here would
        -- double-count the channel and push every following queue slot ~1
        -- channel-duration too far out, so the step is zero — the next spell
        -- can be cast at the finish point already in accTime.
        if i == 1 and ctx.activeChannelSpellKey and c.cand.key == ctx.activeChannelSpellKey then
            step = 0
        end

        -- Never insert synths before position 1 (i == 1).
        -- The natural `projected_dot_time_left_lt` condition handles the
        -- position-1 transition when the tracked debuff crosses its
        -- threshold.
        if i > 1 then
            FlushSynthsBefore(queueTime + step)
        end

        local channelClip = false
        local channelClipKey = nil
        local channelClipEntry = nil
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
                            channelClipEntry = reasonEntry
                            channelClipTime = breakAt
                            channelClipBucket = ResolveEntryPriorityBucket(reasonEntry)
                        end
                    end
                end
            end
        end

        if channelClip and channelClipKey then
            local clipCd = (channelClipTime and channelClipTime > READY_EPSILON) and (now + channelClipTime) or nil
            Add(channelClipEntry, channelClipKey, 0, false, channelClipBucket, clipCd, true)
            Add(c.cand.entry, c.cand.key, 0, true, c.cand.priorityBucket, nil, true)
        else
            -- Chain-position cooldownEnd: only meaningful while something is
            -- actively casting.  When not casting, accTime is just "position N
            -- in the priority queue" — nothing is actually blocking these
            -- spells, so showing a timer (1.5 / 3.0 / 4.5 s) is misleading
            -- and will appear frozen because it gets re-anchored every cycle.
            -- Only set a cooldownEnd when there is a real cast in flight that
            -- makes these spells genuinely unavailable for accTime seconds.
            --
            -- CHANNEL EXCEPTION (user request): while channeling (e.g. Mind
            -- Flay), accTime equals the full channel remaining, which would
            -- anchor every suggestion to a multi-second countdown that shows
            -- right after the GCD and dies when the channel ends ("stops mid
            -- countdown").  Channel progress is already shown by the CastBar;
            -- the rotation advisor must only show the GCD and real spell
            -- cooldowns during a channel.  Hence: no chain anchor when an
            -- active channel is in flight.
            local chainCooldownEnd
            if c.cooldownEnd and c.cooldownEnd > now then
                -- Actual rawCD dominates.
                chainCooldownEnd = c.cooldownEnd
            elseif accTime > READY_EPSILON and ctx.castingSpell and not ctx.activeChannelSpellKey then
                -- Actively casting (not a channel): accTime = castRemaining +
                -- prior-spell GCDs. now + accTime is a stable absolute
                -- timestamp that ticks as castRemaining decreases (now
                -- advances at the same rate).
                chainCooldownEnd = now + accTime
            end
            -- When chainCooldownEnd is nil the icon shows no timer (ready, just
            -- sequenced) — bright icon, no number.
            Add(c.cand.entry, c.cand.key, 0, c.clip, c.cand.priorityBucket, chainCooldownEnd, true)
        end
        accTime = accTime + step
        queueTime = queueTime + fullStep
    end

    -- Tail synths: show any synth whose deadline falls within the chain
    -- horizon PLUS a lookahead to give the player advance notice of upcoming
    -- dot refreshes.  We use 8 extra GCDs (≈12 s at 1.5 s/GCD) so that dots
    -- with long remaining times (VT ~12 s, SWP ~21 s) appear in the queue
    -- as "coming up" rather than only when they are about to expire.
    --
    -- Chain-fill: when the top of the chain is a repeatable, cooldown-free
    -- filler (e.g. Warlock Shadow Bolt spam), insert as many copies of it as
    -- fit BEFORE each synth's deadline.  Without this the queue showed the
    -- upcoming dot refresh at slot 2 immediately (e.g. "Immolate" with 7.5 s
    -- left on the applied DoT) instead of the expected run of filler casts.
    --
    -- A candidate only qualifies as a chain filler if it is genuinely
    -- spammable: no cooldown, and its conditions contain no one-shot/
    -- target-state/cooldown gates (otherwise we'd fill the queue with e.g.
    -- Curse of Doom or a cooldown spell). Channels are allowed ONLY when the
    -- entry is explicitly marked isFiller (e.g. Mind Flay with repeatLimit =
    -- 3), so the queue can show consecutive channel casts; any other channel
    -- is still excluded (never fill with a non-filler channel).
    local FILLER_BLOCKED_CONDS = {
        ["cooldown_ready"] = true, ["cooldown_lt"] = true,
        ["dot_missing"] = true, ["projected_dot_time_left_lt"] = true,
        ["debuff_property_compare"] = true, ["buff_property_compare"] = true,
        ["target_ttd_gte"] = true, ["target_ttd_lt"] = true,
        ["trinket_ready"] = true, ["item_ready_by_key"] = true,
        ["item_ready_and_owned"] = true, ["predicted_kill"] = true,
        ["spell_can_kill_target"] = true, ["state_compare"] = true,
        ["resource_gte"] = true, ["resource_lt"] = true,
        ["resource_required_gte"] = true, ["resource_pct_gt"] = true,
        ["resource_pct_lt"] = true, ["combo_points_gte"] = true,
        ["combo_points_lt"] = true, ["not_recently_cast"] = true,
    }
    local MAX_CHAIN_FILLS = 6
    local fillerCand = nil
    local fillerStep = 0
    for _, rc in ipairs(readyCands) do
        local cand = rc.cand
        local key = cand and cand.key
        if key and key ~= "POTION" and key ~= "RUNE" and not key:match("^TRINKET") then
            local entry = cand.entry
            local blocked = false
            for _, c in ipairs((entry and entry.conditions) or {}) do
                if FILLER_BLOCKED_CONDS[c.type] then blocked = true break end
            end
            if not blocked then
                local spell = A.SPELLS and A.SPELLS[key]
                local meta = spell and spell.meta
                local hasRealCD = meta and meta.cooldown and tonumber(meta.cooldown) > 0
                local projectedCD = GetProjectedSpellCooldown(key, ctx) or 0
                if not hasRealCD and projectedCD <= READY_EPSILON
                   and (not (meta and meta.castType == "channel")
                        or (entry and entry.isFiller == true)) then
                    local step = ChainFillerStep(key)
                    if step > READY_EPSILON then
                        fillerCand = cand
                        fillerStep = step
                        break
                    end
                end
            end
        end
    end

    local function AddChainFiller()
        -- Same channel exception as the main chain: never anchor fillers to
        -- channel remaining time (only real CDs / non-channel casts get a
        -- chain timer).
        local chainCd = (accTime > READY_EPSILON and ctx.castingSpell and not ctx.activeChannelSpellKey) and (now + accTime) or nil
        result[#result + 1] = {
            key = fillerCand.key,
            eta = 0,
            entry = fillerCand.entry,
            cooldownEnd = chainCd,
            chained = true,
            priorityBucket = ResolveEntryPriorityBucket(fillerCand.entry),
        }
        accTime = accTime + fillerStep
        queueTime = queueTime + fillerStep
    end

    -- Tail horizon: show the refresh synth (and its filler run) as soon as
    -- the deadline is within the max filler run span, so the queue shows the
    -- "cast fillers until the refresh" plan early instead of only when the
    -- refresh is ~8 GCDs away.  Without a filler the 8-GCD lookahead stands.
    -- (User report: with a 3 s-cast filler the 8-GCD horizon only admitted
    -- ~4 fills, so the run appeared several seconds late mid-fight.)
    local tailHorizon = queueTime + (ctx.gcd or 1.5) * 8
    if fillerCand and fillerStep > READY_EPSILON then
        -- Cover the full plan: max filler run + the refresh's own step, so a
        -- freshly-applied DoT (e.g. CoA at 24 s) shows its filler run right
        -- away instead of only once the deadline is ~8 GCDs out.
        tailHorizon = math.max(tailHorizon, queueTime + MAX_CHAIN_FILLS * fillerStep + (ctx.gcd or 1.5))
    end
    local fillsUsed = 0
    while si <= #synths do
        local s = synths[si]; si = si + 1
        if s.deadline <= tailHorizon then
            -- Fill the chain with repeatable filler casts until the refresh
            -- deadline is the next thing that must happen.
            if fillerCand then
                while fillsUsed < MAX_CHAIN_FILLS and (queueTime + fillerStep) < s.deadline do
                    AddChainFiller()
                    fillsUsed = fillsUsed + 1
                end
            end
            -- No countdown on refresh synths: they are OFF cooldown (except
            -- GCD), and the cast signal is their queue position plus the
            -- flip to slot 1 when the refresh condition actually fires.
            -- Showing the deadline as a timer made them look like a very
            -- long global cooldown and suggested them 4+ s before they
            -- should be cast (user request).
            Add(s.entry, s.key, 0, false, ResolveEntryPriorityBucket(s.entry), nil)
            accTime = accTime + ChainStepTime(s.key)
            queueTime = queueTime + ChainStepTime(s.key)
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
        local maxR = (resource == "mana" and (ctx.maxMana or (UnitPowerMax("player", 0) or 1)))
                         or (ctx.maxResource or (UnitPowerMax("player") or 100))
        if maxR <= 0 then maxR = 100 end

        local newVal
        if postCast.compute ~= nil then
            -- Dynamic: call a named function on A (e.g. A.ComputePowershiftEnergy)
            -- so the result is always calculated at evaluation time rather than
            -- stored as a user-editable setting.
            local fn = type(postCast.compute) == "string" and A[postCast.compute]
            if type(fn) == "function" then
                local ok, v = pcall(fn)
                newVal = ok and tonumber(v) or nil
            end
        elseif postCast.set ~= nil then
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
            pCtx.now = now + gcd
            pCtx.castRemaining = gcd
            pCtx.readyIn = gcd

            local recomputed = {}
            for _, b in ipairs(blockedCands) do
                local newCand = self:_EvaluateEntry(b.cand.entry, b.cand.index, pCtx, spec, db, hasTarget, false)
                if newCand then
                    local projectedCD = GetProjectedSpellCooldown(b.cand.key, pCtx) or 0
                    local readyIn = math.max(newCand.eta or 0, projectedCD)
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
        Add(c.cand.entry, c.cand.key, c.readyIn, c.clip, c.cand.priorityBucket, c.cooldownEnd)
    end

    if #result == 0 then
        if ctx.inCombat and hasTarget then
            local fillerKey = nil
            local fillerEntry = nil
            for i = #rotation, 1, -1 do
                local rEntry = rotation[i]
                if rEntry.key and A.SPELLS[rEntry.key] then
                    local isAlways = rEntry.conditions and #rEntry.conditions == 1
                                     and rEntry.conditions[1].type == "always"
                    if isAlways or not rEntry.conditions then
                        fillerKey = rEntry.key
                        fillerEntry = rEntry
                        break
                    end
                end
            end
            if fillerKey then
                Add(fillerEntry, fillerKey)
            elseif (ctx.threatAvoidance or "never") ~= "never" and ctx.inGroup
                   and (ctx.threatPct or 0) >= 90 then
                -- Threat-blocked fallback: everything safe is filtered out and
                -- the player is close to/at aggro — suggest Fade to drop threat.
                Add(nil, "Fade")
            elseif ctx.wandEquipped then
                -- Mana-blocked fallback: wand keeps the player DPSing when no
                -- spell is affordable.
                Add(nil, "WAND")
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
            local targetReady = false
            for ri = 1, #result do
                if result[ri].key == ins.before then
                    idx = ri
                    targetReady = (result[ri].eta or 0) <= READY_EPSILON
                    break
                end
            end
            if idx and targetReady then
                table.insert(result, idx, ins.entry)
            end
            -- else: the before-target is not ready (still on cooldown /
            -- resource-blocked, or not in the queue at all). Drop the entry
            -- instead of inserting it anyway: an insertBefore ability (e.g.
            -- Inner Focus before Mind Blast) must not be suggested while the
            -- spell it is meant to precede cannot be cast yet.
        end
    end

    if hasTarget then
        local upcoming = {}
        for _, rEntry in ipairs(rotation) do
            local key = rEntry.key
            if key and not seen[key] then
                local spell = A.SPELLS and A.SPELLS[key]
                local known = spell and (not A.KnowsSpell or A.KnowsSpell(spell.id))
                -- Same synth gate as the refresh synths: an entry whose
                -- non-timing conditions fail (e.g. Mangle (Bear) while in cat
                -- form) must not surface an "upcoming" countdown either.
                if known ~= false and SynthGatesPass(rEntry) then
                    -- Skip spells the player currently can't afford or that
                    -- would pull aggro (same safety filters as the main queue).
                    local safety = RE.GetSpellSafetyBlock(key, ctx)
                    if safety == nil then
                        -- Use the same generic refresh-ETA helper that powers
                        -- predictive timers for DoT/cooldown/refresh windows.
                        local eta = RE._ComputeEntryRefreshETA(rEntry, ctx, spec)
                        if eta == nil then
                            local cd = GetProjectedSpellCooldown(key, ctx)
                            if cd and cd > 0 then eta = cd end
                        end
                        if eta and eta > 0 then
                            upcoming[#upcoming + 1] = {
                                entry = rEntry,
                                key = key,
                                eta = eta,
                                cooldownEnd = now + eta,
                                priorityBucket = ResolveEntryPriorityBucket(rEntry),
                            }
                        end
                    end
                end
            end
        end

        table.sort(upcoming, function(a, b) return a.eta < b.eta end)
        for _, v in ipairs(upcoming) do
            Add(v.entry, v.key, v.eta, false, v.priorityBucket, v.cooldownEnd)
        end
    end

    -- ------------------------------------------------------------------
    -- Forward simulation: predict positions 2–4 in the queue by projecting
    -- game-state changes from each preceding cast and re-evaluating the
    -- priority list.  This lets the queue show "what happens next" rather
    -- than just repeating the current best candidate.
    --
    -- Simulated entries replace positions 2-4.  If simulation produces zero
    -- predictions (e.g. unknown spell database entry), we fall back to the
    -- existing ETA-sorted candidates that were already added above.
    -- ------------------------------------------------------------------
    if hasTarget and result[1] then
        local fillerKeys = {}
        local fillerRepeatLimits = {}
        for _, rEntry in ipairs(rotation) do
            local repeatLimit = GetEntryRepeatLimit(rEntry)
            if rEntry.key and repeatLimit > 1 then
                fillerKeys[rEntry.key] = true
                fillerRepeatLimits[rEntry.key] = repeatLimit
            end
        end

        local simResult = {}
        local simSeen   = { [result[1].key] = true }
        local projCtx   = ctx
        local projKey
        if #readyCands > 0 and fillerKeys[readyCands[1].key] then
            projKey = readyCands[1].key
        end
        local simOk     = true

        -- Ensure simInCombat is set on the projected chain (never precombat).
        if projCtx.simInCombat == nil then
            projCtx = setmetatable({ simInCombat = true }, { __index = projCtx })
        end

        -- Forward-simulation clip helper: checks whether a filler channel
        -- spell (e.g. Mind Flay) should be clipped because a higher-priority
        -- clip-reason spell will become ready during or shortly after the
        -- channel.  Returns the clipped advance time (seconds) or nil.
        -- Fully data-driven: reads tick count/interval from SpellDatabase and
        -- minDuration + clipReasons from spec.channelSpells config.
        local function GetClipAdvance(spellKey, simCtx)
            local def = A.GetSpellDefinition and A.GetSpellDefinition(spellKey)
            if not def or def.castType ~= "channel" then return nil end
            if not fillerKeys[spellKey] then return nil end

            local haste = (simCtx and simCtx.hasteMul) or 1
            if haste <= 0 then haste = 1 end

            -- Channel duration from spell database.
            local fullChannel = ((def.duration or def.castTime) or 3) / haste

            -- Tick-based clip point: clip at the second-to-last tick for efficiency.
            -- e.g. Mind Flay (3 ticks, 1s interval): clipPoint = 2 * 1 / haste = 2/haste
            local tickInterval = def.tickInterval or 1
            local totalTicks   = def.ticks or math.ceil(fullChannel * haste)
            if totalTicks <= 1 then return nil end

            -- Look up per-spell channel config from spec.channelSpells.
            local chanConfig = nil
            if spec and spec.channelSpells then
                for _, cs in ipairs(spec.channelSpells) do
                    if (cs.spellKey == spellKey or cs.spellName == spellKey) then
                        chanConfig = cs
                        break
                    end
                end
            end

            -- minDuration: prefer channel config, else one tick.
            local rawMinDur = tonumber(chanConfig and chanConfig.minDuration) or tickInterval
            local minDuration = math.max(rawMinDur / haste, 0)

            -- clipPoint: second-to-last tick (lose only the final tick).
            local clipTicks = totalTicks - 1
            local clipPoint = (clipTicks * tickInterval) / haste

            if clipPoint <= 0 or fullChannel <= clipPoint then return nil end

            -- clipReasons from channel config.
            local clipReasons = chanConfig and chanConfig.clipReasons
            if not clipReasons or #clipReasons == 0 then return nil end

            local now    = ctx.now or GetTime()
            local simNow = simCtx and simCtx.now or now
            local elapsed = simNow - now   -- how far into the future we've advanced

            for _, reasonKey in ipairs(clipReasons) do
                local spell = A.SPELLS and A.SPELLS[reasonKey]
                if spell and spell.id then
                    local liveCD = A.GetSpellCDReal and A.GetSpellCDReal(spell.id) or 0
                    if liveCD > 0 then
                        local projectedCD = math.max(liveCD - elapsed, 0)
                        -- Clip if the reason becomes ready during the channel
                        -- or within one clipPoint after the channel ends
                        -- (lookahead for multi-channel alignment).
                        if projectedCD > minDuration and projectedCD <= fullChannel + clipPoint then
                            return clipPoint
                        end
                    end
                end
            end
            return nil
        end

        -- Tracks whether the previous sim slot was a filler channel that
        -- the simulation decided to clip.  When true the *previous* sim
        -- entry (or result[1] for slot == 2) gets clip = true.
        local clipOnPrev = false

        for slot = 2, 4 do
            if not projKey or not simOk then break end

            -- Apply the clip flag from the PREVIOUS simulation step to the
            -- entry that was just simulated (which lives in simResult[-1]
            -- or result[1] for slot == 2).
            if clipOnPrev then
                if slot == 2 then
                    -- projKey was result[1] (the spell at position 1)
                    result[1].clip = true
                elseif #simResult > 0 then
                    -- projKey was the previous simResult entry
                    simResult[#simResult].clip = true
                end
                clipOnPrev = false
            end

            -- Check whether we should clip the spell we're about to simulate.
            local advanceOverride = nil
            if fillerKeys[projKey] then
                advanceOverride = GetClipAdvance(projKey, projCtx)
            end
            clipOnPrev = advanceOverride ~= nil

            local ok_sim, nextCtx = pcall(RE.SimulateSpellEffect, RE, projCtx, projKey, spec, advanceOverride)
            if not ok_sim or not nextCtx then simOk = false; break end
            projCtx = nextCtx

            local bestKey = nil
            for _, rEntry in ipairs(rotation) do
                local eKey = rEntry.key
                -- Skip trinket/optional entries in the simulation chain:
                -- these are handled by _EvaluatePrepared which strips the
                -- trinket_ready gate and sets eta from the actual remaining CD.
                -- Re-evaluating here with the original trinket_ready would
                -- discard on-CD trinkets (trinket_ready fails) and lose the
                -- correct eta from _EvaluatePrepared.
                local isTrinketSim = false
                if rEntry.conditions then
                    for _, rc in ipairs(rEntry.conditions) do
                        if rc.type == "trinket_ready" then isTrinketSim = true; break end
                    end
                end
                -- Allow filler spells to repeat in the sim chain so that all
                -- four icon slots are populated when no higher-priority spell
                -- is available.  Non-filler spells are still deduplicated.
                if not isTrinketSim and eKey and (not simSeen[eKey] or fillerKeys[eKey]) and rEntry.conditions then
                    local ok_eval, cand = pcall(RE._EvaluateEntry, RE, rEntry,
                                                1, projCtx, spec,
                                                A.db and A.db.specs and A.db.specs[spec and spec.meta and spec.meta.id],
                                                hasTarget, false)
                    if ok_eval and cand and not cand.manaBlocked and not cand.threatBlocked
                       and ((cand.eta or 0) <= 0.05) then
                        bestKey = eKey
                        break
                    end
                end
            end

            if bestKey then
                local pBucket = nil
                for _, rEntry in ipairs(rotation) do
                    if rEntry.key == bestKey then
                        pBucket = ResolveEntryPriorityBucket(rEntry)
                        break
                    end
                end
                local simEntry = { key = bestKey, eta = 0, simulated = true }
                if pBucket ~= nil then simEntry.priorityBucket = pBucket end
                simResult[#simResult + 1] = simEntry
                simSeen[bestKey] = true
                projKey = bestKey
            else
                break
            end
        end

        -- If the very last simulated spell was flagged for clipping, apply
        -- the clip flag to the final simResult entry now (no subsequent
        -- iteration to set it).
        if clipOnPrev and #simResult > 0 then
            simResult[#simResult].clip = true
        end

        -- Only replace positions 2–4 if simulation produced at least one entry.
        if #simResult > 0 then
            local compressed = { result[1] }
            local repeatCounts = {}
            if fillerKeys[result[1].key] then
                repeatCounts[result[1].key] = 1
            end
            for _, e in ipairs(simResult) do
                if fillerKeys[e.key] then
                    local count = repeatCounts[e.key] or 0
                    if count < (fillerRepeatLimits[e.key] or 2) then
                        repeatCounts[e.key] = count + 1
                        compressed[#compressed + 1] = e
                    end
                else
                    compressed[#compressed + 1] = e
                end
            end
            result = compressed
        end
    end

    -- Re-add optional entries discarded by forward simulation compression.
    -- The simulation replaces everything past result[1] with simResults,
    -- throwing away on-cooldown trinkets (blockedCands) AND ready trinkets
    -- (readyCands).  We must put them back so the display layer sees them.
    --
    -- On-CD optionals: insert at position 4 so they're always visible in the
    -- queue (prio[4] is shown whether fade is on or off).  As their remaining
    -- CD ticks down, the countdown decreases.
    --
    -- Ready optionals (eta=0): append to end — Refresh() separates them into
    -- the bonus slot via its normal optional/ready routing.
    if (#blockedCands > 0) or (#readyCands > 0) or (#readyOptCands > 0) then
        local optKeys = {}
        for _, entry in ipairs(rotation) do
            if entry.optional and entry.key then optKeys[entry.key] = true end
        end
        if next(optKeys) then
            local resultKeys = {}
            for _, ent in ipairs(result) do
                resultKeys[ent.key] = true
            end
            -- Collect missing on-CD optionals (eta > 0) sorted by eta ascending
            local cdOpts = {}
            for _, c in ipairs(blockedCands) do
                if optKeys[c.cand.key] and not resultKeys[c.cand.key] then
                    cdOpts[#cdOpts + 1] = {
                        key = c.cand.key, eta = c.readyIn, entry = c.cand.entry,
                        cooldownEnd = c.cooldownEnd,
                    }
                end
            end
            table.sort(cdOpts, function(a, b) return a.eta < b.eta end)
            -- Insert the closest-to-ready on-CD optional at position 4
            for _, ta in ipairs(cdOpts) do
                if ta.eta > 0.05 then
                    if #result >= 4 then
                        table.insert(result, 4, ta)
                    else
                        result[#result + 1] = ta
                    end
                    break
                end
            end
            -- Append ready optionals (eta=0) — Refresh routes them to bonus slot
            for _, c in ipairs(readyOptCands) do
                if optKeys[c.cand.key] and not resultKeys[c.cand.key] then
                    result[#result + 1] = {
                        key = c.cand.key, eta = 0, entry = c.cand.entry,
                    }
                end
            end
        end
    end

    if hasTarget and #result > 0 and #result < 4 then
        local fallbackRefresh = nil
        for _, rEntry in ipairs(rotation) do
            local key = rEntry.key
            if key and not seen[key] and rEntry.conditions then
                local spell = A.SPELLS and A.SPELLS[key]
                local known = spell and (not A.KnowsSpell or A.KnowsSpell(spell.id))
                if known ~= false and SynthGatesPass(rEntry) then
                    local deadline = GetRefreshDeadline(rEntry)
                    if deadline and deadline > 0 then
                        if not fallbackRefresh or deadline < fallbackRefresh.eta then
                            fallbackRefresh = {
                                entry = rEntry,
                                key = key,
                                eta = deadline,
                                cooldownEnd = now + deadline,
                                priorityBucket = ResolveEntryPriorityBucket(rEntry),
                            }
                        end
                    end
                end
            end
        end
        if fallbackRefresh then
            Add(fallbackRefresh.entry, fallbackRefresh.key, fallbackRefresh.eta, false, fallbackRefresh.priorityBucket, fallbackRefresh.cooldownEnd)
        end
    end

    -- No countdown on refresh synths: they are OFF cooldown (except GCD),
    -- and the cast signal is their queue position plus the flip to slot 1
    -- when the refresh condition actually fires.  Showing the refresh
    -- deadline as a timer made them look like a very long global cooldown
    -- and suggested them 4+ s before they should be cast (user request).
    -- See the TIMER RULE comment above FlushSynthsBefore.

    return result
end

function RE:_EvaluatePrepared(spec, ctx, db, rotation, hasTarget, wantDiagnostics)
    local candidates = {}
    local diagnostics = wantDiagnostics and { ctx = ctx, rotation = rotation, entries = {}, candidates = candidates, hasTarget = hasTarget } or nil

    for i, entry in ipairs(rotation) do
        if entry.key and entry.conditions then
            -- Special handling for trinket entries: evaluate without trinket_ready gate
            -- so on-cooldown trinkets still appear as candidates with eta from remaining CD.
            local evalEntry = entry
            local isTrinketEntry = false
            local trinketSlot = nil
            for _, cond in ipairs(entry.conditions) do
                if cond.type == "trinket_ready" then
                    isTrinketEntry = true
                    trinketSlot = tonumber(cond.slot) or 13
                    -- Create modified conditions without trinket_ready
                    evalEntry = { key = entry.key, conditions = {}, optional = entry.optional }
                    for _, c in ipairs(entry.conditions) do
                        if c.type ~= "trinket_ready" then
                            evalEntry.conditions[#evalEntry.conditions + 1] = c
                        end
                    end
                    break
                end
            end

            local candidate, diag = self:_EvaluateEntry(evalEntry, i, ctx, spec, db, hasTarget, wantDiagnostics)
            if candidate then
                -- For trinket entries, set eta from actual remaining cooldown.
                -- Gate: only trinkets with an on-use ("Use:") effect are
                -- suggested - passive proc/equip trinkets are not pressable.
                -- Detection is tooltip-based (GetItemSpell only reports the
                -- FIRST item effect and cannot distinguish USE from EQUIP).
                if isTrinketEntry and trinketSlot then
                    local ok, itemId = pcall(GetInventoryItemID, "player", trinketSlot)
                    if ok and itemId then
                        if not A.ItemHasOnUseEffect(itemId, trinketSlot) then
                            if A.DebugLog then
                                A.DebugLog("ROT", "trinket filter: slot " .. trinketSlot .. " item " .. tostring(itemId) .. " has no on-use effect (passive) - skipped")
                            end
                            candidate = nil
                        else
                            local start, dur = GetInventoryItemCooldown("player", trinketSlot)
                            if start and start > 0 then
                                -- On CD: eta = remaining cooldown (no buffer).
                                -- Trinket travels through the queue as CD ticks down.
                                candidate.eta = math.max(start + dur - ctx.now, 0)
                            else
                                -- Off CD: ready immediately, goes to bonus slot.
                                candidate.eta = 0
                            end
                        end
                    else
                        -- No equipped item: don't add as candidate.
                        if A.DebugLog then
                            A.DebugLog("ROT", "trinket filter: slot " .. trinketSlot .. " has no equipped item")
                        end
                        candidate = nil
                    end
                end
                if candidate then
                    candidates[#candidates + 1] = candidate
                end
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
    -- The FQ macro reads this to busy-wait up to 189ms and release the
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

    local function SetDotHint(key, spellName, rem)
        local castEff = GetEffectiveSpellCastTime(key, ctx) or 0
        local travel  = math.max(GetSpellTravelTimeValue(key) or 0, ctx.lat or 0)
        local fireDelay = math.max(rem - castEff - travel, 0)
        local nextTickIn
        local tickInterval = GetDotTickFrequency(spec, key)
        if tickInterval and tickInterval > 0 and rem and rem > 0 then
            nextTickIn = rem % tickInterval
            if nextTickIn < 0.001 then
                nextTickIn = tickInterval
            end
        end
        A.DotRefreshHints[spellName] = {
            fireAt = now + fireDelay,
            expiresAt = now + fireDelay + 1.5,
            spellKey = key,
            castEff = castEff,
            travel = travel,
            nextTickIn = nextTickIn,
        }
    end

    if hasTarget then
        -- Generate hints from rotation entries with refresh conditions.
        for _, rEntry in ipairs(rotation) do
            if rEntry.key and rEntry.conditions then
                for _, cond in ipairs(rEntry.conditions) do
                    if cond and (cond.type == "projected_dot_time_left_lt" or cond.type == "dot_missing") then
                        local key = cond.spellKey or rEntry.key
                        local spell = A.SPELLS and A.SPELLS[key]
                        local spellName = spell and spell.name
                        if spellName then
                            local rem = ResolveDebuffRemaining(spec, ctx, cond)
                            SetDotHint(key, spellName, rem)
                        end
                        break
                    end
                end
            end
        end
        -- Also generate/update hints for all tracked DoTs so FakeQueue
        -- can check for imminent ticks even when the DoT is not due for
        -- refresh (e.g. the user invokes the macro mid-channel or between
        -- filler spells).  Hints are updated every tick so nextTickIn
        -- stays current as the DoT ticks down.
        if spec.trackedDebuffs then
            for _, td in ipairs(spec.trackedDebuffs) do
                if td.isDot and td.spellKey then
                    local spell = A.SPELLS and A.SPELLS[td.spellKey]
                    local spellName = spell and spell.name
                    if spellName then
                        local rem = ResolveDebuffRemaining(spec, ctx, { spellKey = td.spellKey })
                        local tickInterval = GetDotTickFrequency(spec, td.spellKey)
                        if tickInterval and tickInterval > 0 then
                            SetDotHint(td.spellKey, spellName, rem)
                        end
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
-- Per-slot diagnostics for the Troubleshooter UI.
--
-- Returns each queue slot (up to 4) with:
--   entry       – the result entry { key, eta, simulated }
--   ctx         – the evaluation context (real for slot 1, projected 2–4)
--   isSimulated – false for slot 1, true for 2–4
--   diagnostics – { entries = [{key, status, conditionResults, …}] }
--
-- The 'diagnostics.entries' array covers every rotation entry so the UI
-- can show which conditions passed/failed and why.
------------------------------------------------------------------------
function RE:DebugEvaluateSlots(spec)
    if not spec or not spec.rotation then return nil end

    local ctx = self:BuildContext(spec)
    local db  = A.db and A.db.specs and A.db.specs[spec.meta.id]
    local rotation = (db and db.rotation) or spec.rotation
    local hasTarget = UnitExists("target")
                      and not UnitIsDead("target")
                      and UnitCanAttack("player", "target")

    -- Slot 1: full evaluator fills result[1..4] and returns per-entry diagnostics.
    local result, diag1 = self:_EvaluatePrepared(spec, ctx, db, rotation, hasTarget, true)
    if not result then return nil end

    local slots = {}
    slots[1] = {
        slotIndex   = 1,
        entry       = result[1],
        ctx         = ctx,
        isSimulated = false,
        diagnostics = diag1,
    }

    -- Slots 2–4: simulate each preceding cast, then run _EvaluateEntry for every
    -- rotation entry against the projected ctx.  We skip _BuildResultFromCandidates
    -- to avoid costly nested forward simulation.
    local projCtx = ctx
    if projCtx.simInCombat == nil then
        projCtx = setmetatable({ simInCombat = true }, { __index = projCtx })
    end

    for i = 2, 4 do
        local prevEntry = result[i - 1]
        if not prevEntry then break end

        local ok_sim, nextCtx = pcall(RE.SimulateSpellEffect, RE, projCtx, prevEntry.key, spec)
        if not ok_sim or not nextCtx then break end
        projCtx = nextCtx

        local entries = {}
        for _, rotEntry in ipairs(rotation) do
            if rotEntry.key and rotEntry.conditions then
                local ok_ev, _, entryDiag = pcall(
                    self._EvaluateEntry, self,
                    rotEntry, 1, projCtx, spec, db, hasTarget, true
                )
                if ok_ev and entryDiag then
                    entries[#entries + 1] = entryDiag
                end
            end
        end

        slots[i] = {
            slotIndex   = i,
            entry       = result[i],
            ctx         = projCtx,
            isSimulated = true,
            diagnostics = { entries = entries, hasTarget = hasTarget },
        }
    end

    return { slots = slots, result = result, hasTarget = hasTarget }
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

