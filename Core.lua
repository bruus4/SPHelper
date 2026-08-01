------------------------------------------------------------------------
-- SPHelper  –  Core.lua
-- Shared constants, utilities, and event bus for the addon.
-- Only loads for Priests with the Shadowform talent.
------------------------------------------------------------------------
SPHelper = SPHelper or {}
local A = SPHelper
local unpack = unpack or table.unpack

local function PackValues(...)
    return { n = select("#", ...), ... }
end

A._apiCache = A._apiCache or {
    spellInfo = {},
    itemInfo  = {},
    itemIcon  = {},
}

function A.ClearAPICache()
    A._apiCache = {
        spellInfo = {},
        itemInfo  = {},
        itemIcon  = {},
    }
end

local function NormalizeSpellRef(spellRef)
    if spellRef == nil then return nil end
    if type(spellRef) == "table" then
        return spellRef.id or spellRef.baseId or spellRef.spellId
    end
    if type(spellRef) == "string" then
        local spell = A.SPELLS and A.SPELLS[spellRef]
        if spell then
            return spell.id or spell.baseId
        end
        local numeric = tonumber(spellRef)
        if numeric then
            return numeric
        end
    end
    return spellRef
end

function A.GetSpellInfoCached(spellRef)
    spellRef = NormalizeSpellRef(spellRef)
    if spellRef == nil then return nil end
    local cache = A._apiCache.spellInfo
    local cached = cache[spellRef]
    if not cached then
        cached = PackValues(GetSpellInfo(spellRef))
        cache[spellRef] = cached
    end
    return unpack(cached, 1, cached.n)
end

function A.GetSpellIconCached(spellRef)
    local _, _, icon = A.GetSpellInfoCached(spellRef)
    return icon
end

function A.GetItemInfoCached(itemRef)
    local cache = A._apiCache.itemInfo
    local cached = cache[itemRef]
    if cached then
        return unpack(cached, 1, cached.n)
    end

    local result = PackValues(GetItemInfo(itemRef))
    if result[1] ~= nil then
        cache[itemRef] = result
    end
    return unpack(result, 1, result.n)
end

function A.GetItemIconCached(itemRef)
    local cache = A._apiCache.itemIcon
    local cached = cache[itemRef]
    if cached ~= nil then
        return cached
    end

    local icon = GetItemIcon(itemRef)
    if icon then
        cache[itemRef] = icon
    end
    return icon
end

A._targetMetrics = A._targetMetrics or {}
A._spellTravel = A._spellTravel or {
    byId = {},
    byName = {},
    pending = {},
}

function A.ResetTargetMetrics()
    wipe(A._targetMetrics)
end

function A.ClearTargetMetric(guid)
    if guid then
        A._targetMetrics[guid] = nil
    end
end

function A.UpdateTargetHealthSample(guid, hpPct, now)
    if not guid or type(hpPct) ~= "number" then return nil end

    now = now or GetTime()
    if hpPct < 0 then hpPct = 0 end
    if hpPct > 1 then hpPct = 1 end

    local rec = A._targetMetrics[guid]
    if not rec then
        rec = {
            hpPct = hpPct,
            lastHP = hpPct,
            lastTime = now,
            rate = 0,
            ttd = nil,
            -- Sliding-window samples used to compute the smoothed HP-loss
            -- rate. A simple ring of {t, hp} entries trimmed to `windowSec`
            -- seconds. This avoids the spikes an EWMA produces every time a
            -- DoT tick lands (which used to cause TTD-gated suggestions like
            -- SWP/VT to flicker on/off in sync with the tick rhythm).
            samples = { { t = now, hp = hpPct } },
            windowSec = 6,
        }
        A._targetMetrics[guid] = rec
        return nil
    end

    -- Append a sample at most every 0.1s to keep the ring small.
    local lastSample = rec.samples[#rec.samples]
    if not lastSample or (now - lastSample.t) >= 0.1 then
        rec.samples[#rec.samples + 1] = { t = now, hp = hpPct }
    else
        -- Update the last sample in-place so the most recent HP is current.
        lastSample.hp = hpPct
        lastSample.t = now
    end

    -- Drop samples older than the window so the rate reflects recent
    -- combat only and recovers quickly when DPS changes.
    local cutoff = now - (rec.windowSec or 6)
    while rec.samples[1] and rec.samples[1].t < cutoff do
        table.remove(rec.samples, 1)
    end

    -- Smoothed rate: total HP lost / total time across the window. A DoT
    -- tick adds the same per-second contribution whether we sample on the
    -- tick or between ticks, so the result no longer pulses with each tick.
    local first = rec.samples[1]
    if first and (now - first.t) >= 0.5 then
        local span = now - first.t
        local lost = first.hp - hpPct
        if lost < 0 then lost = 0 end
        if span > 0.001 then
            rec.rate = lost / span
        end
    end
    if rec.rate < 0 then rec.rate = 0 end

    rec.lastHP = hpPct
    rec.lastTime = now
    rec.hpPct = hpPct

    if hpPct <= 0 then
        rec.ttd = 0
    elseif rec.rate and rec.rate > 0.0001 then
        rec.ttd = hpPct / rec.rate
    else
        rec.ttd = nil
    end
    return rec.ttd
end

function A.GetTargetTimeToDie(guid)
    local rec = guid and A._targetMetrics[guid]
    if not rec then return nil end
    return rec.ttd
end

function A.GetUnitTimeToDie(unit)
    if not unit or not UnitExists(unit) then return nil end
    local guid = UnitGUID(unit)
    if not guid then return nil end

    local maxHP = UnitHealthMax(unit) or 0
    if maxHP <= 0 then return nil end

    local hpPct = (UnitHealth(unit) or 0) / maxHP
    return A.UpdateTargetHealthSample(guid, hpPct)
end

local function ResolveSpellTravelRef(spellRef)
    if spellRef == nil then return nil, nil end
    if type(spellRef) == "number" then
        return spellRef, A.GetSpellInfoCached(spellRef)
    end
    if type(spellRef) == "table" then
        return spellRef.id, spellRef.name
    end
    if type(spellRef) == "string" then
        local spell = A.SPELLS and A.SPELLS[spellRef]
        if spell then
            return spell.id, spell.name
        end
        local numeric = tonumber(spellRef)
        if numeric then
            return numeric, A.GetSpellInfoCached(numeric)
        end
        return nil, spellRef
    end
    return nil, nil
end

local function UpdateTravelRecord(store, key, sample, now)
    if key == nil then return end
    local rec = store[key]
    if not rec then
        store[key] = {
            ema = sample,
            last = sample,
            samples = 1,
            updatedAt = now,
        }
        return
    end

    rec.last = sample
    rec.samples = (rec.samples or 0) + 1
    rec.ema = ((rec.ema or sample) * 0.75) + (sample * 0.25)
    rec.updatedAt = now
end

function A.RecordSpellTravelSample(spellId, spellName, sample, now)
    now = now or GetTime()
    sample = tonumber(sample)
    if not sample or sample < 0 or sample > 5 then return nil end

    if spellId then
        UpdateTravelRecord(A._spellTravel.byId, spellId, sample, now)
    end
    if spellName and spellName ~= "" then
        UpdateTravelRecord(A._spellTravel.byName, spellName, sample, now)
    end
    return sample
end

function A.RecordSpellTravelLaunch(spellId, spellName, targetGUID, launchTime)
    launchTime = launchTime or GetTime()
    local key = spellId or spellName
    if not key then return end

    local pending = A._spellTravel.pending[key]
    if not pending then
        pending = {}
        A._spellTravel.pending[key] = pending
    end

    pending[#pending + 1] = {
        spellId = spellId,
        spellName = spellName,
        targetGUID = targetGUID,
        launchTime = launchTime,
    }

    while #pending > 5 do
        table.remove(pending, 1)
    end
end

function A.RecordSpellTravelImpact(spellId, spellName, destGUID, impactTime)
    impactTime = impactTime or GetTime()

    local pending = A._spellTravel.pending[spellId] or A._spellTravel.pending[spellName]
    if not pending or #pending == 0 then return nil end

    local matchIndex = nil
    for i = #pending, 1, -1 do
        local launch = pending[i]
        local age = impactTime - (launch.launchTime or impactTime)
        if age >= 0 and age <= 5 and (not destGUID or not launch.targetGUID or launch.targetGUID == destGUID) then
            matchIndex = i
            break
        end
    end

    if not matchIndex then
        for i = #pending, 1, -1 do
            local launch = pending[i]
            local age = impactTime - (launch.launchTime or impactTime)
            if age >= 0 and age <= 5 then
                matchIndex = i
                break
            end
        end
    end

    if not matchIndex then return nil end

    local launch = table.remove(pending, matchIndex)
    if #pending == 0 then
        if spellId then A._spellTravel.pending[spellId] = nil end
        if spellName then A._spellTravel.pending[spellName] = nil end
    end

    local sample = impactTime - (launch.launchTime or impactTime)
    return A.RecordSpellTravelSample(spellId or launch.spellId, spellName or launch.spellName, sample, impactTime)
end

function A.GetSpellTravelTime(spellRef)
    local spellId, spellName = ResolveSpellTravelRef(spellRef)
    local rec = spellId and A._spellTravel.byId[spellId] or nil
    if not rec and spellName then
        rec = A._spellTravel.byName[spellName]
    end
    return rec and rec.ema or 0
end

------------------------------------------------------------------------
-- Spell data is populated by SpellDatabase.lua.
-- Each runtime entry uses a stable low-rank `baseId` plus a resolved
-- `id` when the player knows a higher effective rank.
------------------------------------------------------------------------
A.SPELLS = A.SPELLS or {}

------------------------------------------------------------------------
-- Consumable items (for mana suggestions)
------------------------------------------------------------------------
A.CONSUMABLES = {
    MANA_POT    = { itemId = 22832, name = "Super Mana Potion" },
    DARK_RUNE   = { itemId = 20520, name = "Dark Rune" },
    DEMONIC_RUNE= { itemId = 12662, name = "Demonic Rune" },
}

-- Common consumable IDs we offer in the UI for tracking
A.POTION_IDS = { 22832, 13444, 3385, 28101, 32948, 32902 }   -- Super, Major, Lesser, Unstable, Auchenai, Bottled Nethergon
A.RUNE_IDS   = { 20520, 12662 }         -- Dark Rune, Demonic Rune

------------------------------------------------------------------------
-- Colors
------------------------------------------------------------------------
A.COLORS = {
    VT      = { 0.45, 0.20, 0.55, 1 },
    SWP     = { 0.70, 0.30, 0.30, 1 },
    MB      = { 0.35, 0.58, 0.92, 1 },
    MF      = { 0.58, 0.51, 0.79, 1 },
    SWD     = { 0.85, 0.15, 0.15, 1 },
    DP      = { 0.40, 0.70, 0.30, 1 },
    SF      = { 0.80, 0.80, 0.20, 1 },
    MS      = { 0.30, 0.70, 0.85, 1 },
    SU      = { 0.80, 0.60, 0.20, 1 },
    POTION  = { 0.20, 0.50, 0.90, 1 },
    RUNE    = { 0.60, 0.20, 0.70, 1 },
    DEFAULT = { 0.85, 0.75, 0.36, 1 },
    BG      = { 0.08, 0.08, 0.08, 0.85 },
    BORDER  = { 0.0,  0.0,  0.0,  1 },
    SAFE    = { 0.30, 1.0,  0.30, 1 },
    WARN    = { 1.0,  0.85, 0.0,  1 },
    TEXT    = { 1, 1, 1, 1 },
}

------------------------------------------------------------------------
-- MF tick sound options — all entries are very short (< 0.4 s) unless
-- marked "medium". SoundKit IDs verified for the TBC Anniversary client.
------------------------------------------------------------------------
A.TICK_SOUNDS = {
    { key = "none",   label = "None",             id = nil  },
    -- Short, crisp clicks / pops
    { key = "click",  label = "Click",            id = 856  },
    { key = "tap",    label = "Tap",              id = 567  },
    { key = "pop",    label = "Pop",              id = 869  },
    { key = "snap",   label = "Snap",             id = 860  },
    { key = "blip",   label = "Blip",             id = 563  },
    -- Tonal / pitched
    { key = "coin",   label = "Coin",             id = 120  },
    { key = "beep",   label = "Beep",             id = 793  },
    { key = "ping",   label = "Ping",             id = 3175 },
    { key = "chime",  label = "Chime",            id = 879  },
    { key = "ding",   label = "Ding",             id = 855  },
    -- Medium-length (pleasant but audible)
    { key = "bell",   label = "Bell (medium)",    id = 5274 },
    { key = "alert",  label = "Alert (medium)",   id = 8959 },
}

function A.GetTickSoundId(key)
    for _, s in ipairs(A.TICK_SOUNDS) do
        if s.key == key then return s.id end
    end
    return nil
end

------------------------------------------------------------------------
-- MF tick screen-flash colour options
-- All five colours are available for every placement mode.
------------------------------------------------------------------------
A.TICK_FLASH_EFFECTS = {
    { key = "none",          label = "None",              color = nil,              mode = "full"  },
    -- Full-screen solid flash
    { key = "green",         label = "Green (full)",      color = {0.3, 0.9, 0.3}, mode = "full"  },
    { key = "purple",        label = "Purple (full)",     color = {0.7, 0.3, 0.9}, mode = "full"  },
    { key = "shadow",        label = "Shadow (full)",     color = {0.5, 0.2, 0.8}, mode = "full"  },
    { key = "white",         label = "White (full)",      color = {1.0, 1.0, 1.0}, mode = "full"  },
    { key = "red",           label = "Red (full)",        color = {0.9, 0.2, 0.2}, mode = "full"  },
    -- Top-edge gradient (bleeds downward from the top)
    { key = "green_top",     label = "Green (top)",       color = {0.3, 0.9, 0.3}, mode = "top"   },
    { key = "purple_top",    label = "Purple (top)",      color = {0.7, 0.3, 0.9}, mode = "top"   },
    { key = "shadow_top",    label = "Shadow (top)",      color = {0.5, 0.2, 0.8}, mode = "top"   },
    { key = "white_top",     label = "White (top)",       color = {1.0, 1.0, 1.0}, mode = "top"   },
    { key = "red_top",       label = "Red (top)",         color = {0.9, 0.2, 0.2}, mode = "top"   },
    -- Side-edge gradients (bleed inward from left and right)
    { key = "green_sides",   label = "Green (sides)",     color = {0.3, 0.9, 0.3}, mode = "sides" },
    { key = "purple_sides",  label = "Purple (sides)",    color = {0.7, 0.3, 0.9}, mode = "sides" },
    { key = "shadow_sides",  label = "Shadow (sides)",    color = {0.5, 0.2, 0.8}, mode = "sides" },
    { key = "white_sides",   label = "White (sides)",     color = {1.0, 1.0, 1.0}, mode = "sides" },
    { key = "red_sides",     label = "Red (sides)",       color = {0.9, 0.2, 0.2}, mode = "sides" },
}

function A.GetTickFlashColor(key)
    for _, e in ipairs(A.TICK_FLASH_EFFECTS) do
        if e.key == key then return e.color end
    end
    return nil
end

function A.GetTickFlashMode(key)
    for _, e in ipairs(A.TICK_FLASH_EFFECTS) do
        if e.key == key then return e.mode or "full" end
    end
    return "full"
end

------------------------------------------------------------------------
-- Utility helpers
------------------------------------------------------------------------

-- One-way world latency in seconds
function A.GetLatency()
    local _, _, _, latencyWorld = GetNetStats()
    return (latencyWorld or 50) / 1000
end

-- Remaining cooldown IGNORING the GCD (treats GCD-only as 0)
function A.GetSpellCDReal(spellId)
    if A.ResolveSpellID then
        spellId = A.ResolveSpellID(spellId) or spellId
    end
    if type(spellId) ~= "number" then return 0 end
    local start, dur, enabled = GetSpellCooldown(spellId)
    if not start or start == 0 then return 0 end
    -- If duration <= 1.5, the spell is only on GCD, not its own CD
    if dur and dur > 0 and dur <= 1.5 then return 0 end
    local remaining = start + dur - GetTime()
    return remaining > 0 and remaining or 0
end

-- Item cooldown accessor. `GetItemCooldown` is part of the TBC/Classic API
-- and is always available on the TBC Anniversary client.
function A.GetItemCooldownSafe(itemId)
    if type(GetItemCooldown) ~= "function" then return 0, 0 end
    if type(itemId) ~= "number" then
        itemId = tonumber(itemId) or 0
    end
    local ok, start, dur, enable = pcall(GetItemCooldown, itemId)
    if not ok then return 0, 0 end
    return start or 0, dur or 0, enable
end

-- Detect whether the item in an inventory slot has an on-use effect.
-- Uses GetItemSpell which returns (spellName, spellId, spellSchool, spellTrigger)
-- on Classic/TBC and (spellId, spellName, spellSchool, spellTrigger) on retail.
-- r4 is always spellTrigger regardless of ordering.
function A.ItemHasOnUseEffect(itemId)
    if type(GetItemSpell) ~= "function" then
        return true  -- can't detect, assume on-use
    end
    local r1, _, _, r4 = GetItemSpell(itemId)
    if not r1 then
        return false  -- no spell at all → passive item
    end
    -- r4 = spellTrigger in both orderings
    if type(r4) == "string" then
        return r4:upper() == "USE"
    end
    -- r4 is not a string (Classic might return nil for the trigger on older
    -- builds). If the first value is a string, it's the spell name → on-use.
    return type(r1) == "string"
end

-- Simple error reporter: logs the error and shows a message.
function A.ReportError(module, operation, err, context)
    -- Route to the debug log only — never spam the chat (red error handler)
    -- with routine pcall failures that fire on every talent/equipment change.
    if A.DebugLog then
        A.DebugLog(module, operation .. " error: " .. tostring(err or "?"))
    end
end

-- Return an estimated spell power for the player.
-- Tries common WoW APIs; as a heuristic we return the maximum
-- GetSpellBonusDamage(...) value across schools which captures
-- the player's highest spell-power (shadow for shadow priest).
function A.GetSpellPower()
    local max = 0
    if type(GetSpellBonusDamage) == "function" then
        for i = 1, 7 do
            local ok, v = pcall(GetSpellBonusDamage, i)
            v = (ok and v) and v or 0
            if v > max then max = v end
        end
        return max
    end
    -- Fallbacks could be added here if needed; return 0 when unknown
    return 0
end

-- Return the raw power stat relevant for a given schoolMask.
-- For magical schools: GetSpellBonusDamage(school index).
-- For physical (schoolMask == 1): net attack power from UnitAttackPower.
-- Falls back to GetSpellPower() for unknown masks.
--   schoolMask: 1=Physical, 2=Holy, 4=Fire, 8=Nature,
--               16=Frost, 32=Shadow, 64=Arcane
local _SCHOOL_INDEX = { [2]=2, [4]=3, [8]=4, [16]=5, [32]=6, [64]=7 }
function A.GetSchoolPower(schoolMask)
    if schoolMask == 1 then
        -- Physical: attack power (base + positive buff + negative buff).
        if type(UnitAttackPower) == "function" then
            local ok, base, pos, neg = pcall(UnitAttackPower, "player")
            if ok and base then
                return (base or 0) + (pos or 0) + (neg or 0)
            end
        end
        return 0
    end
    local idx = _SCHOOL_INDEX[schoolMask]
    if idx and type(GetSpellBonusDamage) == "function" then
        local ok, v = pcall(GetSpellBonusDamage, idx)
        return (ok and v) and v or 0
    end
    -- Unknown mask (e.g. multi-school) — fall back to highest school SP.
    return A.GetSpellPower()
end

-- Return player's haste percent and multiplier.
-- For TBC Anniversary (modern client) we rely on `UnitSpellHaste` only.
-- Caller receives: hastePercent (number), hasteMultiplier (1 + percent/100)
function A.GetHaste()
    if type(UnitSpellHaste) == "function" then
        local ok, v = pcall(UnitSpellHaste, "player")
        v = (ok and v) and v or 0
        return v, (1 + v / 100)
    end
    -- If the API is not present (very old clients), return zero haste.
    return 0, 1
end

------------------------------------------------------------------------
-- ID-first aura resolution (NAG-style).
--
-- Name-based matching alone is fragile: TBC has several auras whose real
-- in-game name differs from what a naive database uses (e.g. spell 1490 is
-- "Curse of the Elements", not "Curse of Elements"), names can carry rank
-- suffixes, and clients can be localized.  The modern Classic API returns
-- the aura's spellId from UnitBuff/UnitDebuff, so we match by spell ID first
-- (all TBC ranks of a spell via def.debuffAuraIds / resolveIds) and fall
-- back to the existing exact/prefix name matching.
------------------------------------------------------------------------

-- Resolve a spell reference (catalog key, spell name, or spell ID) into a
-- set of aura spell IDs and aura names to match against.  Merges exclusive
-- sibling spells (e.g. Faerie Fire + Faerie Fire (Feral)) so either variant
-- is detected on "any source" checks.
-- Returns: { ids = {number,...}, names = {string,...} }
function A.ResolveAuraRef(spellRef)
    local ids = {}
    local names = {}
    local seenId = {}
    local seenName = {}

    local function addId(id)
        if type(id) == "number" and id > 0 and not seenId[id] then
            seenId[id] = true
            ids[#ids + 1] = id
        end
    end
    local function addNameList(list)
        if type(list) ~= "table" then return end
        for _, nm in ipairs(list) do
            if type(nm) == "string" and nm ~= "" and not seenName[nm] then
                seenName[nm] = true
                names[#names + 1] = nm
            end
        end
    end
    local function addDefIds(def)
        if not def then return end
        addId(def.baseId)
        if def.debuffAuraIds then
            for _, id in ipairs(def.debuffAuraIds) do addId(id) end
        end
        if def.resolveIds then
            for _, id in ipairs(def.resolveIds) do addId(id) end
        end
    end
    local function addDefNames(def)
        if not def then return end
        addNameList({ def.debuffAura, def.name })
        if def.aliasNames then addNameList(def.aliasNames) end
    end

    local def = A.GetSpellDefinition and A.GetSpellDefinition(spellRef)
    if def then
        addDefIds(def)
        addDefNames(def)
        -- Exclusive-slot siblings share the aura (e.g. Faerie Fire variants).
        if def.debuffSiblings then
            for _, sibKey in ipairs(def.debuffSiblings) do
                local sibDef = A.GetSpellDefinition and A.GetSpellDefinition(sibKey)
                addDefIds(sibDef)
                addDefNames(sibDef)
            end
        end
        -- Known-rank ID from the resolved catalog entry (the rank the player casts).
        if def.key then
            local spell = A.SPELLS and A.SPELLS[def.key]
            if spell and spell.id then addId(spell.id) end
        end
    end

    -- Keep the raw reference as a fallback name (covers plain aura names that
    -- are not catalog keys, e.g. "Icy Veins").
    if type(spellRef) == "string" and spellRef ~= "" then
        addNameList({ spellRef })
    end

    return { ids = ids, names = names }
end

-- Generic aura scanner.  `apiFn` is UnitDebuff or UnitBuff, `filter` an
-- optional unit-aura filter (e.g. "PLAYER").  Matches ID-first, then exact
-- name, then prefix name (rank suffixes).
-- Returns: name, icon, count, auraType, duration, expirationTime, source, index, spellId
-- NOTE: multi-return values are built explicitly (never via unpack on a table
-- with nil holes — Lua 5.1 `#` on such tables is undefined).
local function ScanAurasByRef(apiFn, unit, filter, ref)
    if not apiFn or not unit or not ref then return nil end
    local idSet = ref.ids and #ref.ids > 0
    local names = ref.names or {}
    local prefix = nil  -- {n, ic, ct, at, du, ex, so, ix, sid}

    for i = 1, 40 do
        local name, icon, count, auraType, duration, expirationTime, source,
              _, _, spellId = apiFn(unit, i, filter)
        if not name then break end

        -- ID-first (NAG-style): the aura's spellId is authoritative.
        if idSet then
            for _, wantedId in ipairs(ref.ids) do
                if spellId and spellId == wantedId then
                    return name, icon, count or 0, auraType, duration or 0, expirationTime or 0, source or "player", i, spellId
                end
            end
        end

        -- Exact name match takes priority over prefix matches.
        for _, wantedName in ipairs(names) do
            if name == wantedName then
                return name, icon, count or 0, auraType, duration or 0, expirationTime or 0, source or "player", i, spellId
            end
        end

        -- Prefix match for rank differences (e.g. "Curse of the Elements" vs
        -- "Curse of the Elements (Rank X)").
        if not prefix then
            local lowerName = name:lower()
            for _, wantedName in ipairs(names) do
                if wantedName ~= "" and lowerName:find(wantedName:lower(), 1, true) then
                    prefix = { n = name, ic = icon, ct = count or 0, at = auraType, du = duration or 0,
                               ex = expirationTime or 0, so = source or "player", ix = i, sid = spellId }
                    break
                end
            end
        end
    end

    if prefix then
        return prefix.n, prefix.ic, prefix.ct, prefix.at, prefix.du, prefix.ex, prefix.so, prefix.ix, prefix.sid
    end
    return nil
end

-- Find a debuff by **spell ref** (catalog key, spell name, or spell ID) on a
-- unit cast by the player.  Uses the "PLAYER" filter which reliably restricts
-- to your own debuffs.  ID-first matching, name/prefix fallback.
-- Returns: name, icon, count, debuffType, duration, expirationTime, source, index, spellId
function A.FindPlayerDebuff(unit, spellRef)
    return ScanAurasByRef(UnitDebuff, unit, "PLAYER", A.ResolveAuraRef(spellRef))
end

-- Find ANY debuff matching a spell ref on a unit (regardless of caster).
-- ID-first matching, name/prefix fallback.
function A.FindDebuff(unit, spellRef)
    return ScanAurasByRef(UnitDebuff, unit, nil, A.ResolveAuraRef(spellRef))
end

-- Debuff lookup by ref with fuzzy prefix matching for rank differences.
-- Returns: name, icon, count, debuffType, duration, expirationTime, source, index, spellId
-- Used by condition evaluators and UI validation.
function A.FindDebuffByName(unit, spellRef)
    return A.FindDebuff(unit, spellRef)
end

-- Check if a unit has any debuff matching the given ref (fuzzy prefix match).
function A.HasDebuff(unit, spellRef)
    return A.FindDebuff(unit, spellRef) ~= nil
end

-- Find buff by spell ref with fuzzy prefix matching for rank differences.
-- ID-first matching, name/prefix fallback.
-- Returns: name, icon, count, duration, expirationTime, source, index, spellId
function A.FindBuffByName(unit, spellRef)
    return ScanAurasByRef(UnitBuff, unit, nil, A.ResolveAuraRef(spellRef))
end

-- Check if a unit has any buff matching the given ref (fuzzy prefix match).
function A.HasBuff(unit, spellRef)
    return A.FindBuffByName(unit, spellRef) ~= nil
end

-- Check if player knows a spell (has it in spellbook)
function A.KnowsSpell(spellRef)
    if A.ResolveSpellID then
        spellRef = A.ResolveSpellID(spellRef) or spellRef
    elseif type(spellRef) == "string" then
        local spell = A.SPELLS and A.SPELLS[spellRef]
        spellRef = spell and (spell.id or spell.baseId) or tonumber(spellRef)
    elseif type(spellRef) == "table" then
        spellRef = spellRef.id or spellRef.baseId or spellRef.spellId
    end

    if type(spellRef) ~= "number" then
        return false
    end

    if IsSpellKnown(spellRef) then
        return true
    end
    if type(IsPlayerSpell) == "function" then
        return IsPlayerSpell(spellRef) and true or false
    end
    return false
end

------------------------------------------------------------------------
-- Detect current content type (for per-zone SWD settings)
------------------------------------------------------------------------
function A.GetContentType()
    local _, instanceType = IsInInstance()
    if instanceType == "raid" then return "raid" end
    if instanceType == "party" then return "dungeon" end
    return "world"
end

------------------------------------------------------------------------
-- Target classification (boss vs elite-trash vs normal)
-- Uses ENCOUNTER_START/END when available, falls back to heuristic.
------------------------------------------------------------------------
A._activeBossEncounter = false

do
    local bossEnc = CreateFrame("Frame")
    -- ENCOUNTER_START / _END may not fire on all TBC Anniversary builds.
    -- RegisterEvent is wrapped in pcall so missing events are harmless.
    pcall(function() bossEnc:RegisterEvent("ENCOUNTER_START") end)
    pcall(function() bossEnc:RegisterEvent("ENCOUNTER_END") end)
    bossEnc:SetScript("OnEvent", function(_, ev)
        A._activeBossEncounter = (ev == "ENCOUNTER_START")
    end)
end

--- Returns "boss", "elite", "normal", "minus", or "none".
function A.GetTargetClassification()
    if not UnitExists("target") then return "none" end
    local c = UnitClassification("target") or "normal"
    -- worldboss is always a boss
    if c == "worldboss" then return "boss" end
    -- Inside an instance, distinguish boss from trash-elite
    local _, instType = IsInInstance()
    if instType == "raid" or instType == "party" then
        if A._activeBossEncounter then return "boss" end
        if c == "elite" or c == "rareelite" then return "elite" end
        return c == "minus" and "minus" or "normal"
    end
    -- Open world
    if c == "elite" or c == "rareelite" then return "elite" end
    if c == "minus" then return "minus" end
    return "normal"
end

------------------------------------------------------------------------
-- Check if player is a priest with Shadowform talent
------------------------------------------------------------------------
function A.IsShadowPriest()
    local _, class = UnitClass("player")
    if class ~= "PRIEST" then return false end
    return A.KnowsSpell(A.SPELLS.SFORM.id)
end

------------------------------------------------------------------------
-- Pixel-perfect backdrop helper
------------------------------------------------------------------------
function A.CreateBackdrop(frame, r, g, b, a, borderR, borderG, borderB, borderA)
    r, g, b, a = r or 0.08, g or 0.08, b or 0.08, a or 0.85
    borderR = borderR or 0
    borderG = borderG or 0
    borderB = borderB or 0
    borderA = borderA or 1

    frame:SetBackdrop({
        bgFile   = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(r, g, b, a)
    frame:SetBackdropBorderColor(borderR, borderG, borderB, borderA)
end

------------------------------------------------------------------------
-- Persistent frame positioning
--
-- A.RegisterMovableFrame(frame, key, defaultPoint)
--
--   Saves point/relativePoint/x/y to A.db.framePositions[key] on
--   OnDragStop and restores them at registration time. Survives /reload
--   and replaces the original SetPoint() default if a saved value exists.
--
--   `defaultPoint` is a table { point, relPoint, x, y } used the first
--   time the frame is shown. Frames must already have :SetMovable(true),
--   :EnableMouse(true), and :RegisterForDrag("LeftButton") configured.
------------------------------------------------------------------------
function A.RegisterMovableFrame(frame, key, defaultPoint)
    if not frame or not key then return end

    A.db = A.db or {}
    A.db.framePositions = A.db.framePositions or {}

    local saved = A.db.framePositions[key]
    local function ApplyPoint(p)
        if not p then return end
        frame:ClearAllPoints()
        frame:SetPoint(p.point or "CENTER", UIParent, p.relPoint or p.point or "CENTER", p.x or 0, p.y or 0)
    end

    if saved and saved.point then
        ApplyPoint(saved)
    elseif defaultPoint then
        ApplyPoint(defaultPoint)
    end

    -- Hook OnDragStop without clobbering an existing handler the frame
    -- may already define for visual / lock checks.
    local prevStop = frame:GetScript("OnDragStop")
    frame:SetScript("OnDragStop", function(self, ...)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        A.db.framePositions = A.db.framePositions or {}
        A.db.framePositions[key] = {
            point = point, relPoint = relPoint, x = x, y = y,
        }
        if prevStop and prevStop ~= self.StopMovingOrSizing then
            -- Run any extra handler the caller had registered.
            local ok, err = pcall(prevStop, self, ...)
            if not ok then A.DebugLog("ERR", "RegisterMovableFrame stop hook: " .. tostring(err)) end
        end
    end)
end

------------------------------------------------------------------------
-- Formatting
------------------------------------------------------------------------
function A.FormatTime(sec)
    if sec >= 60 then
        local mins = math.floor(sec / 60)
        local secs = math.floor(sec % 60)
        return string.format("%d:%02d", mins, secs)
    elseif sec >= 10 then
        return string.format("%d", math.floor(sec))
    else
        return string.format("%.1f", sec)
    end
end

------------------------------------------------------------------------
-- Debug logging removed for release builds. Provide a stable no-op
-- implementation so existing call-sites remain safe.
------------------------------------------------------------------------
local function NormalizeDebugModule(module)
    module = tostring(module or "GEN")
    module = strtrim(module):upper()
    if module == "" then module = "GEN" end
    return module
end

local function EnsureDebugConfig()
    if not A.db then return nil end
    A.db.debug = A.db.debug or {}
    if type(A.db.debug.modules) ~= "table" or A.db.debug.modules == A.defaults.debug.modules then
        local copy = {}
        if type(A.db.debug.modules) == "table" then
            for key, value in pairs(A.db.debug.modules) do
                copy[key] = value
            end
        end
        A.db.debug.modules = copy
    end
    if A.db.debug.echo == nil then A.db.debug.echo = false end
    if type(A.db.debug.bufferSize) ~= "number" then A.db.debug.bufferSize = 200 end
    return A.db.debug
end

local function SyncDebugEnabled()
    local enabled = false
    local debugCfg = EnsureDebugConfig()
    if debugCfg and debugCfg.modules then
        for _, value in pairs(debugCfg.modules) do
            if value then
                enabled = true
                break
            end
        end
    end
    A.debugEnabled = enabled
end

function A.IsDebugModuleEnabled(module)
    local debugCfg = EnsureDebugConfig()
    if not debugCfg or not debugCfg.modules then return false end
    local key = NormalizeDebugModule(module)
    return debugCfg.modules.ALL == true or debugCfg.modules[key] == true
end

function A.SetDebugModuleEnabled(module, enabled)
    local debugCfg = EnsureDebugConfig()
    if not debugCfg then return false end

    local key = NormalizeDebugModule(module)
    if enabled then
        debugCfg.modules[key] = true
    else
        debugCfg.modules[key] = nil
    end
    SyncDebugEnabled()
    return true
end

function A.GetKnownDebugModules()
    local modules = {}
    local seen = {}
    local function Add(key)
        if not key or seen[key] then return end
        seen[key] = true
        modules[#modules + 1] = key
    end

    for _, key in ipairs({ "ALL", "CAST", "CORE", "ENGINE", "ERR", "EVT", "ROT" }) do
        Add(key)
    end
    if A._debugSeenModules then
        for key in pairs(A._debugSeenModules) do
            Add(key)
        end
    end
    local debugCfg = EnsureDebugConfig()
    if debugCfg and debugCfg.modules then
        for key in pairs(debugCfg.modules) do
            Add(key)
        end
    end
    table.sort(modules)
    return modules
end

function A.ClearDebugLog()
    A._debugBuffer = {}
end

function A.DebugLog(module, msg)
    local key = NormalizeDebugModule(module)
    A._debugSeenModules = A._debugSeenModules or {}
    A._debugSeenModules[key] = true

    if not A.IsDebugModuleEnabled(key) then return end

    A._debugBuffer = A._debugBuffer or {}
    local entry = {
        time = GetTime(),
        module = key,
        msg = tostring(msg or ""),
    }
    table.insert(A._debugBuffer, 1, entry)

    local debugCfg = EnsureDebugConfig()
    local limit = (debugCfg and debugCfg.bufferSize) or 200
    while #A._debugBuffer > limit do
        table.remove(A._debugBuffer)
    end

    if debugCfg and debugCfg.echo then
        pcall(print, string.format("|cff8882d5SPHelper|r [%s] %s", key, entry.msg))
    end
end

function A.DumpDebugLog(module)
    local buffer = A._debugBuffer or {}
    if #buffer == 0 then
        print("SPHelper: no debug log entries recorded.")
        return
    end

    local filter = module and NormalizeDebugModule(module) or nil
    local shown = 0
    print("SPHelper: debug log" .. (filter and (" [" .. filter .. "]") or "") .. ":")
    for _, entry in ipairs(buffer) do
        if not filter or entry.module == filter then
            shown = shown + 1
            print(string.format("[%02d][%s][%.3f] %s", shown, entry.module or "GEN", entry.time or 0, entry.msg or ""))
        end
    end
    if shown == 0 then
        print("SPHelper: no debug entries for module " .. filter .. ".")
    end
end

-- Maintain a runtime flag for backwards compatibility with existing checks.
A.debugEnabled = false

------------------------------------------------------------------------
-- Saved-variables defaults
------------------------------------------------------------------------
A.defaults = {
    locked      = false,
    scale       = 1.0,
    castBar     = { enabled = true, width = 250, height = 20, tickSound = "click", tickFlash = "green", colorMode = "dynamic", color = {0.58, 0.51, 0.79, 1}, tickMarkers = "all" },
    dotTracker  = { enabled = true, width = 300, height = 40, rowHeight = 40,
                    maxTargets = 8, warnSeconds = 3, blinkSpeed = 4, dotIconSize = 18,
                    portraitSide = "left", warnMode = "border",
                    warnBorderSize = 4, warnBarAlpha = 0.35, warnIconAlpha = 0.6, newTargetPosition = "bottom", anchorPosition = "top", sortMode = "addOrder" },
    rotation    = { enabled = true, iconSize = 58, primaryIconSize = 58, enableBonusSlot = true, bonusSpacing = 4 },
    debug       = { echo = false, bufferSize = 200, modules = {} },
    -- Per-frame saved positions (point/relPoint/x/y) keyed by frame name.
    framePositions = {},
    -- Per-spec settings namespace (populated by migration and SpecManager)
    specs       = {},
    -- Legacy flat keys kept for backward compatibility during migration.
    -- Phase 2 will update all readers to use A.SpecVal(); these can be
    -- removed after Phase 2 is complete.
    selectedPotionItem = 22832,
    selectedRuneItem   = 20520,
    swdMode     = "always",
    swdWorld    = "execute",
    swdDungeon  = "always",
    swdRaid     = "always",
    swdSafetyPct = 0,
    sfManaThreshold      = 35,
    suggestPot           = true,
    potManaThreshold     = 20,
    suggestRune          = true,
    runeManaThreshold    = 15,
    potEarly             = false,
    potionTrack = "auto",
    runeTrack   = "auto",
    use_trinket_1            = true,
    use_trinket_2            = true,
    trinket_1_classification = "any",
    trinket_2_classification = "any",
}

------------------------------------------------------------------------
-- Spec-specific defaults (Shadow Priest).
-- These are the canonical defaults for the shadow_priest spec.
-- They live here temporarily; Phase 1b moves them into the spec file.
------------------------------------------------------------------------
A.SPEC_DEFAULTS = {
    shadow_priest = {
        selectedPotionItem = 22832,
        selectedRuneItem   = 20520,
        swdMode     = "always",
        swdWorld    = "execute",
        swdDungeon  = "always",
        swdRaid     = "always",
        swdSafetyPct = 0,
        sfManaThreshold      = 35,
        suggestPot           = true,
        potManaThreshold     = 20,
        suggestRune          = true,
        runeManaThreshold    = 15,
        potEarly             = false,
        potionTrack = "auto",
        runeTrack   = "auto",
        use_trinket_1            = true,
        use_trinket_2            = true,
        trinket_1_classification = "any",
        trinket_2_classification = "any",
        -- Per-spell rotation toggles (only for optional/situational spells)
        use_DP               = true,
        use_SWD              = true,
        use_SF               = true,
        -- ifInsert intentionally NOT in SPEC_DEFAULTS: Config panel owns
        -- A.db.rotation.ifInsert and GetSpecTable("ifInsert") falls through to it.
    },
}

------------------------------------------------------------------------
-- Spec-aware DB accessors
-- A.SpecVal(key [, default])  — read from active spec namespace, fallback to flat A.db, then default
-- A.SetSpecVal(key, value)    — write to active spec namespace
------------------------------------------------------------------------
A._activeSpecID = nil  -- set by SpecManager when a matching spec is activated

function A.SpecVal(key, default)
    local specID = A._activeSpecID
    local sdb = A.db and A.db.specs and A.db.specs[specID]
    if sdb and sdb[key] ~= nil then return sdb[key] end
    -- Backward compat: fall through to flat A.db
    if A.db and A.db[key] ~= nil then return A.db[key] end
    -- Fall through to SPEC_DEFAULTS
    local sd = A.SPEC_DEFAULTS and A.SPEC_DEFAULTS[specID]
    if sd and sd[key] ~= nil then return sd[key] end
    -- Fall through to active spec's settingDefs defaults (new keyed dict)
    if A.SpecManager and A.SpecManager.GetSpecByID then
        local spec = A.SpecManager:GetSpecByID(specID)
        if spec then
            if spec.settingDefs and spec.settingDefs[key] then
                local def = spec.settingDefs[key]
                if def.default ~= nil then return def.default end
            end
            -- Legacy: uiOptions array
            if spec.uiOptions then
                for _, opt in ipairs(spec.uiOptions) do
                    if opt.key == key and opt.default ~= nil then
                        return opt.default
                    end
                end
            end
            -- Also check castBarOptions defaults
            if spec.castBarOptions then
                for _, opt in ipairs(spec.castBarOptions) do
                    if opt.key == key and opt.default ~= nil then
                        return opt.default
                    end
                end
            end
        end
    end
    -- Also check customOptions in DB
    if sdb and sdb.customOptions then
        for _, opt in ipairs(sdb.customOptions) do
            if opt.key == key and opt.default ~= nil then
                return opt.default
            end
        end
    end
    return default
end

function A.SetSpecVal(key, value)
    local specID = A._activeSpecID
    if not A.db.specs then A.db.specs = {} end
    if not A.db.specs[specID] then A.db.specs[specID] = {} end
    A.db.specs[specID][key] = value
end

-- Return the spec settings sub-table directly (for ifInsert and other nested reads)
function A.GetSpecTable(key)
    local specID = A._activeSpecID
    local sdb = A.db and A.db.specs and A.db.specs[specID]
    if sdb and sdb[key] ~= nil then return sdb[key] end
    -- Backward compat: check A.db.rotation for ifInsert
    if key == "ifInsert" and A.db and A.db.rotation and A.db.rotation.ifInsert then
        return A.db.rotation.ifInsert
    end
    local sd = A.SPEC_DEFAULTS and A.SPEC_DEFAULTS[specID]
    if sd and sd[key] ~= nil then return sd[key] end
    return nil
end

function A.InitDB()
    if not SPHelperDB then SPHelperDB = {} end
    for k, v in pairs(A.defaults) do
        if SPHelperDB[k] == nil then
            if type(v) == "table" then
                SPHelperDB[k] = {}
                for k2, v2 in pairs(v) do SPHelperDB[k][k2] = v2 end
            else
                SPHelperDB[k] = v
            end
        elseif type(v) == "table" then
            for k2, v2 in pairs(v) do
                if SPHelperDB[k][k2] == nil then
                    SPHelperDB[k][k2] = v2
                end
            end
        end
    end
    A.db = SPHelperDB

    EnsureDebugConfig()
    SyncDebugEnabled()

    -- Migrate old boolean tickSound/tickFlash to string keys
    if A.db.castBar then
        if A.db.castBar.tickSound == true  then A.db.castBar.tickSound = "click" end
        if A.db.castBar.tickSound == false then A.db.castBar.tickSound = "none"  end
        if A.db.castBar.tickFlash == true  then A.db.castBar.tickFlash = "green" end
        if A.db.castBar.tickFlash == false then A.db.castBar.tickFlash = "none"  end
    end
    -- Migrate old castBar colorIndex (legacy) into new colorMode/color
    if A.db.castBar then
        if A.db.castBar.colorIndex then
            -- preserve current primary MF color as solid choice
            A.db.castBar.color = A.COLORS.MF or A.db.castBar.color
            A.db.castBar.colorMode = A.db.castBar.colorMode or "solid"
            A.db.castBar.colorIndex = nil
        end
        if not A.db.castBar.colorMode then A.db.castBar.colorMode = "dynamic" end
        if not A.db.castBar.color then A.db.castBar.color = {0.58, 0.51, 0.79, 1} end
    end
    -- Migrate old combined consumable setting
    if A.db.suggestConsumables ~= nil and A.db.suggestPot == nil then
        A.db.suggestPot  = A.db.suggestConsumables
        A.db.suggestRune = A.db.suggestConsumables
    end
    if A.db.consumableManaThreshold and not A.db.potManaThreshold then
        A.db.potManaThreshold  = A.db.consumableManaThreshold
        A.db.runeManaThreshold = A.db.consumableManaThreshold
    end

    -- Debug logging removed; no runtime toggle to sync.

    --------------------------------------------------------------------
    -- Phase 0 migration: copy spec-specific flat keys into
    -- A.db.specs["shadow_priest"] if they exist at the top level.
    -- This runs every load but only copies when the spec namespace
    -- is missing a key that the flat table has.  The flat keys are
    -- NOT deleted so backward-compatible readers still work.
    --------------------------------------------------------------------
    do
        if not A.db.specs then A.db.specs = {} end
        local specID = "shadow_priest"
        if not A.db.specs[specID] then A.db.specs[specID] = {} end
        local sdb = A.db.specs[specID]
        local MIGRATE_KEYS = {
            "selectedPotionItem", "selectedRuneItem",
            "swdMode", "swdWorld", "swdDungeon", "swdRaid", "swdSafetyPct",
            "sfManaThreshold", "suggestPot", "potManaThreshold",
            "suggestRune", "runeManaThreshold", "potEarly",
            "potionTrack", "runeTrack",
        }
        for _, k in ipairs(MIGRATE_KEYS) do
            if sdb[k] == nil and A.db[k] ~= nil then
                sdb[k] = A.db[k]
            end
        end
        -- Remove stale sdb.ifInsert if it exists (previously migrated in error).
        -- Config panel owns A.db.rotation.ifInsert; removing from spec namespace
        -- prevents GetSpecTable from returning a stale/diverged copy.
        sdb.ifInsert = nil

        -- Migrate ifInsert from A.db.rotation.ifInsert → specs.shadow_priest.ifInsert
        -- INTENTIONALLY SKIPPED: Config panel writes to A.db.rotation.ifInsert and
        -- GetSpecTable("ifInsert") falls through to that path when sdb.ifInsert is nil.
        -- Copying here would create a divergent copy after every /reload.
        --[[ if sdb.ifInsert == nil and A.db.rotation and A.db.rotation.ifInsert then
            sdb.ifInsert = {}
            for k2, v2 in pairs(A.db.rotation.ifInsert) do
                sdb.ifInsert[k2] = v2
            end
        end --]]
    end

    -- Initialize per-spec setting version tracking
    A._InitSettingVersions()
end

------------------------------------------------------------------------
-- Reset helpers — clear saved overrides so values fall back to file defaults.
-- Each function targets a specific scope; none require /reload except the full wipe.
------------------------------------------------------------------------

--- Reset ALL SPHelper settings (visuals + frame positions + all spec overrides).
--- Requires /reload to take effect. Called by `/sph reset` and `/sph reset all`.
function A.ResetAll()
    SPHelperDB = nil
    A.InitDB()
end

--- Reset only visual/layout settings: scale, castBar, dotTracker, rotation visuals, framePositions.
--- Keeps per-spec overrides (rotations + General tab settings) intact.
--- Called by `/sph reset visuals`.
function A.ResetVisuals()
    if not A.db then return end
    -- Restore each visual section from defaults
    local d = A.defaults or {}
    for _, key in ipairs({ "scale", "castBar", "dotTracker", "rotation" }) do
        if d[key] ~= nil then
            if type(d[key]) == "table" then
                A.db[key] = {}
                for k2, v2 in pairs(d[key]) do A.db[key][k2] = v2 end
            else
                A.db[key] = d[key]
            end
        end
    end
    -- Reset frame positions so modules re-anchor on next show
    A.db.framePositions = {}

    -- Apply visual changes immediately (no /reload needed)
    if A.castBarFrame then A.castBarFrame:SetScale(A.db.scale or 1.0) end
    if A.dotAnchor   then A.dotAnchor:SetScale(A.db.scale or 1.0)   end
    if A.rotFrame    then A.rotFrame:SetScale(A.db.scale or 1.0)    end

    -- Rebuild layouts with new defaults (safe to call even if module not loaded)
    pcall(function() if A.CastBarResizeLayout then A.CastBarResizeLayout() end end)
    pcall(function() if A.DotTrackerResizeLayout then A.DotTrackerResizeLayout() end end)
    pcall(function() if A.RotationResizeLayout then A.RotationResizeLayout() end end)
end

--- Reset ALL per-spec overrides (rotations + General tab settings) for every spec.
--- Keeps visual/layout settings and global toggles intact.
--- Called by `/sph reset specs`.
function A.ResetAllSpecs()
    if not A.db then return end
    A.db.specs = {}
end

--- Reset a single spec's overrides (rotation + General tab settings).
--- Other specs are untouched; visuals are untouched.
--- Called by `/sph reset spec <specID>`.
function A.ResetSpec(specID)
    if not specID or not A.db then return end
    if A.db.specs and A.db.specs[specID] then
        A.db.specs[specID] = nil
    end
end

--- Reset only the General tab settings for a single spec (checkboxes, sliders).
--- Keeps that spec's rotation override intact.
--- Called by the "Reset Settings" button in the General tab and `/sph reset spec-settings <specID>`.
function A.ResetSpecSettings(specID)
    if not specID or not A.db then return end
    local sdb = A.db.specs and A.db.specs[specID]
    if not sdb then return end

    -- Keys that are NOT General tab settings — preserve these:
    local keepKeys = { rotation = true, loadConditionsOverride = true }

    for key in pairs(sdb) do
        if not keepKeys[key] then
            sdb[key] = nil
        end
    end
end

--- Reset only the rotation override for a single spec.
--- Keeps that spec's General tab settings intact.
--- Called by the "Reset Rotation to Default" button in the Rotation tab and `/sph reset spec-rotation <specID>`.
function A.ResetSpecRotation(specID)
    if not specID or not A.db then return end
    local sdb = A.db.specs and A.db.specs[specID]
    if sdb then
        sdb.rotation = nil
    end
end

-- Play a tick sound (shared helper used by both the cast bar and tick manager)
function A.PlayTickSound(key)
    local k = key or (A.db and A.db.castBar and A.db.castBar.tickSound) or "click"
    if k == "none" or k == true or not k then return end
    local id = A.GetTickSoundId(k)
    if id then pcall(PlaySound, id, "SFX") end
end

----------------------------------------------------------------------------
-- Setting Version Change System
--
-- Each spec declares settingVersion + settingChanges.  When the addon loads,
-- saved versions are compared to declared versions.  Migrations and removals
-- run silently; default-value changes prompt only if the user has a saved
-- override (sdb[key] ~= nil).  New settings (not listed in settingChanges)
-- never trigger a prompt.
----------------------------------------------------------------------------

-- StaticPopup dialog for per-setting default-value changes
if not StaticPopupDialogs["SPHELPER_SETTING_CHANGE"] then
    StaticPopupDialogs["SPHELPER_SETTING_CHANGE"] = {
        text = "%s",
        button1 = "Reset to default",
        button2 = "Keep my value",
        OnAccept = function(self, data)
            local sdb = A.db and A.db.specs and A.db.specs[data.specID]
            if sdb then
                sdb[data.key] = nil  -- remove override → falls through to file default
            end
            -- Also clear any legacy flat copy so it cannot shadow the new default
            if A.db and A.db[data.key] ~= nil then
                A.db[data.key] = nil
            end
            A._ShowNextSettingChange()
        end,
        OnCancel = function(self, data)
            A._ShowNextSettingChange()  -- keep saved value, move to next
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

-- StaticPopup dialog for Full Reset confirmation (destructive)
if not StaticPopupDialogs["SPHELPER_RESET_ALL"] then
    StaticPopupDialogs["SPHELPER_RESET_ALL"] = {
        text = "Full reset will wipe ALL SPHelper settings:\n- Visual/layout settings\n- Frame positions\n- All spec rotations and General tab settings.\n\nThis requires /reload to take effect. Continue?",
        button1 = ACCEPT,
        button2 = CANCEL,
        OnAccept = function()
            A.ResetAll()
            print("|cff8882d5SPHelper|r: Full reset complete. /reload to apply.")
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

-- StaticPopup dialog for Reset All Specs confirmation
if not StaticPopupDialogs["SPHELPER_RESET_ALL_SPECS"] then
    StaticPopupDialogs["SPHELPER_RESET_ALL_SPECS"] = {
        text = "This will reset ALL spec overrides (rotations + General tab settings) for every spec.\n\nVisual/layout settings will be preserved. Continue?",
        button1 = ACCEPT,
        button2 = CANCEL,
        OnAccept = function()
            if A.ResetAllSpecs then A.ResetAllSpecs() end
            print("|cff8882d5SPHelper|r: All spec overrides reset (rotations + General tab settings). Visuals unchanged.")
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

--- Initialize _settingVersions tracking in the DB.
-- Detects fresh install vs upgrade from pre-version addon.
-- Fresh install: pre-populates all versions silently (no prompts).
-- Upgrade: leaves _settingVersions as {} so settingVersion > 0 triggers processing.
function A._InitSettingVersions()
    if A.db._settingVersions ~= nil then return end

    A.db._settingVersions = {}

    -- Check if any spec sub-table has user data → indicates an upgrade, not fresh install
    local hasSavedData = false
    for _, specData in pairs(A.db.specs or {}) do
        if type(specData) == "table" and next(specData) then
            hasSavedData = true
            break
        end
    end

    if not hasSavedData then
        -- Fresh install: pre-populate all versions so no prompts fire
        local specs = A.SpecManager and A.SpecManager:GetRegisteredSpecs()
        if specs then
            for specID, spec in pairs(specs) do
                if spec.settingVersion then
                    A.db._settingVersions[specID] = spec.settingVersion
                end
            end
        end
    end
    -- If hasSavedData: leave _settingVersions as {} — all specs with
    -- settingVersion > 0 will be processed (silent migrations/removals,
    -- prompts only for default changes where user has a saved override).
end

--- Process setting version changes for all registered specs.
-- Handles silent migrations, removals, and queues prompts for default-value
-- changes where the user has a saved override.  Should be called after
-- InitDB and after specs are fully registered (safe at ADDON_LOADED time).
function A.ProcessSettingChanges()
    if not A.SpecManager or not A.SpecManager.GetRegisteredSpecs then return end
    if not A.db or not A.db._settingVersions then return end

    local queue = {}

    for specID, spec in pairs(A.SpecManager:GetRegisteredSpecs()) do
        if spec.settingVersion and spec.settingChanges then
            local savedVer = A.db._settingVersions[specID] or 0
            if savedVer < spec.settingVersion then
                local sdb = A.db.specs and A.db.specs[specID]

                -- Process each version between saved and current
                for ver = savedVer + 1, spec.settingVersion do
                    local changes = spec.settingChanges[ver]
                    if changes then
                        -- Silent: migrate renamed keys
                        if changes.migrate then
                            for oldKey, newKey in pairs(changes.migrate) do
                                if sdb and sdb[oldKey] ~= nil and sdb[newKey] == nil then
                                    sdb[newKey] = sdb[oldKey]
                                    sdb[oldKey] = nil
                                end
                            end
                        end

                        -- Silent: clean up removed keys
                        if changes.removed then
                            for _, key in ipairs(changes.removed) do
                                if sdb then sdb[key] = nil end
                            end
                        end

                        -- Default-value changes: prompt only if user has a saved override
                        if changes.defaults then
                            for _, key in ipairs(changes.defaults) do
                                if sdb and sdb[key] ~= nil then
                                    -- Resolve a human-readable label
                                    local label = key
                                    if spec.settingDefs and spec.settingDefs[key] then
                                        label = spec.settingDefs[key].label or key
                                    elseif spec.castBarOptions then
                                        for _, opt in ipairs(spec.castBarOptions) do
                                            if opt.key == key then label = opt.label or key; break end
                                        end
                                    end
                                    local specName = (spec.meta and spec.meta.specName) or specID
                                    local newDefault = spec.settingDefs and spec.settingDefs[key] and spec.settingDefs[key].default
                                    queue[#queue + 1] = {
                                        specID = specID,
                                        key = key,
                                        label = label,
                                        specName = specName,
                                        savedValue = sdb[key],
                                        newDefault = newDefault,
                                    }
                                end
                                -- If user never touched it: silently takes new default (sdb[key] stays nil)
                            end
                        end
                    end
                end

                -- Advance saved version (whether or not anything was queued)
                A.db._settingVersions[specID] = spec.settingVersion
            end
        end
    end

    A._settingChangeQueue = queue
    A._ShowNextSettingChange()
end

function A._ShowNextSettingChange()
    local queue = A._settingChangeQueue
    if not queue or #queue == 0 then
        A._settingChangeQueue = nil
        return
    end

    local item = table.remove(queue, 1)
    local text = ("SPHelper: %s\n\n" ..
                  "The setting \"%s\" has a new default value.\n\n" ..
                  "Your saved value: %s\n" ..
                  "New default: %s\n\n" ..
                  "Reset this setting to the new default, or keep your current value?")
        :format(item.specName, item.label, tostring(item.savedValue), tostring(item.newDefault))
    -- Note: on the Anniversary client StaticPopup_Show has the modern signature
    -- (which, text_arg1, text_arg2, data, insertedFrame, ...) — data is the 4th
    -- positional arg. Passing the item as the 5th arg would make it land in
    -- insertedFrame and crash SetupInsertedFrame (attempt to call SetParent on
    -- a plain table).
    StaticPopup_Show("SPHELPER_SETTING_CHANGE", text, nil, item)
end

-- Apply a gradient to a texture. Requires a base texture (WHITE8X8) to be
-- set on the texture beforehand so the tinting has content to operate on.
-- Orientation: "VERTICAL"   — min = bottom, max = top
--              "HORIZONTAL" — min = left,   max = right
local function ApplyGradient(tex, orient, r, g, b, a1, a2)
    -- Modern client (TBC Anniversary) uses SetGradientAlpha with nine args.
    -- If it's absent (newer retail-only removal) fall back to SetGradient.
    if not pcall(function()
        tex:SetGradientAlpha(orient, r, g, b, a1, r, g, b, a2)
    end) then
        pcall(function()
            tex:SetGradient(orient, CreateColor(r, g, b, a1), CreateColor(r, g, b, a2))
        end)
    end
end

-- Perform a tick screen-flash with proper gradient edges and smooth fade-out.
function A.DoTickFlash(key)
    local k = key or (A.db and A.db.castBar and A.db.castBar.tickFlash)
    if k == "none" or k == true or not k then return end
    local col = A.GetTickFlashColor(k)
    if not col then return end
    local mode = A.GetTickFlashMode(k)
    local r, g, b = col[1], col[2], col[3]

    -- Build the shared flash frame once.
    if not A._tickFlashFrame then
        local flash = CreateFrame("Frame", "SPHelper_TickFlash_Shared", UIParent)
        flash:SetAllPoints(UIParent)
        flash:SetFrameStrata("FULLSCREEN_DIALOG")
        flash:SetFrameLevel(100)
        flash:EnableMouse(false)
        flash:Hide()

        -- Full-screen solid texture
        local texFull = flash:CreateTexture(nil, "ARTWORK")
        texFull:SetAllPoints(UIParent)
        texFull:Hide()
        flash.texFull = texFull

        -- Top gradient (bleeds ~150px downward from the top edge)
        -- WHITE8X8 base is required so SetGradientAlpha has content to tint.
        local texTop = flash:CreateTexture(nil, "ARTWORK")
        texTop:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        texTop:SetPoint("TOPLEFT",  UIParent, "TOPLEFT",  0, 0)
        texTop:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", 0, 0)
        texTop:SetHeight(150)
        texTop:Hide()
        flash.texTop = texTop

        -- Left-side gradient (bleeds ~120px inward from the left edge)
        local texLeft = flash:CreateTexture(nil, "ARTWORK")
        texLeft:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        texLeft:SetPoint("TOPLEFT",    UIParent, "TOPLEFT",    0, 0)
        texLeft:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
        texLeft:SetWidth(120)
        texLeft:Hide()
        flash.texLeft = texLeft

        -- Right-side gradient (bleeds ~120px inward from the right edge)
        local texRight = flash:CreateTexture(nil, "ARTWORK")
        texRight:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        texRight:SetPoint("TOPRIGHT",    UIParent, "TOPRIGHT",    0, 0)
        texRight:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", 0, 0)
        texRight:SetWidth(120)
        texRight:Hide()
        flash.texRight = texRight

        -- Animate: fade from alpha 1 → 0 at ~10 units/sec (~0.1s total)
        local flashAlpha = 0
        local fading = false
        flash:SetScript("OnUpdate", function(self, elapsed)
            if not fading then return end
            flashAlpha = flashAlpha - elapsed * 10
            if flashAlpha <= 0 then
                flashAlpha = 0
                fading     = false
                texFull:Hide(); texTop:Hide(); texLeft:Hide(); texRight:Hide()
                self:Hide()
                return
            end
            self:SetAlpha(flashAlpha)
        end)

        flash._trigger = function()
            flashAlpha = 1.0
            fading     = true
            flash:SetAlpha(1.0)
            flash:Show()
        end

        A._tickFlashFrame = flash
    end

    local flash = A._tickFlashFrame
    -- Hide all layers before picking the right one
    flash.texFull:Hide(); flash.texTop:Hide()
    flash.texLeft:Hide(); flash.texRight:Hide()

    if mode == "full" then
        -- Solid semi-transparent overlay covering the entire screen
        flash.texFull:SetColorTexture(r, g, b, 0.45)
        flash.texFull:Show()
    elseif mode == "top" then
        -- Gradient: opaque at the top edge, fading to transparent downward
        -- SetGradientAlpha VERTICAL: min = bottom (transparent), max = top (opaque)
        ApplyGradient(flash.texTop, "VERTICAL", r, g, b, 0, 1.0)
        flash.texTop:Show()
    elseif mode == "sides" then
        -- Left strip: opaque on the left edge, fading right (HORIZONTAL min=left)
        ApplyGradient(flash.texLeft,  "HORIZONTAL", r, g, b, 1.0, 0)
        -- Right strip: opaque on the right edge, fading left (HORIZONTAL max=right)
        ApplyGradient(flash.texRight, "HORIZONTAL", r, g, b, 0, 1.0)
        flash.texLeft:Show(); flash.texRight:Show()
    end

    flash._trigger()
end

-- Preview hooks exposed for Config.lua dropdowns
A.PreviewTickFlash = function(key) A.DoTickFlash(key) end
A.PreviewTickSound = function(key) A.PlayTickSound(key) end

-- TickManager: fires shared tick feedback on every tracked channel SPELL_PERIODIC_DAMAGE
-- event. When the cast bar UI is enabled and currently showing, the cast bar
-- handles tick feedback itself, so shared feedback is suppressed to avoid
-- double-firing.
function A.InitTickManager()
    if A._tickManagerInited then return end
    A._tickManagerInited = true

    local f = CreateFrame("Frame")
    f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    f:SetScript("OnEvent", function(self)
        local _, subEvent, _, sourceGUID, _, _, _, _, _, _, _, _, cleuSpellName = CombatLogGetCurrentEventInfo()
        if sourceGUID ~= UnitGUID("player") then return end
        if subEvent ~= "SPELL_PERIODIC_DAMAGE" then return end

        local channelInfo = nil
        if A.ChannelHelper then
            channelInfo = A.ChannelHelper._activeChannelInfo
                or (A.ChannelHelper.KNOWN_CHANNELS and A.ChannelHelper.KNOWN_CHANNELS[cleuSpellName])
        end
        if not channelInfo then return end

        -- Suppress if the cast bar UI is currently visible (it handles ticks itself)
        if A.castBarFrame and A.castBarFrame:IsShown() then return end

        -- Respect the active channel's tick selections even when the cast bar is disabled.
        A._tickManagerState = A._tickManagerState or { last = 0, count = 0, spellName = nil }
        local now = GetTime()
        local resetGap = 2.0
        if channelInfo.tickInterval and channelInfo.tickInterval > 0 then
            resetGap = math.max(channelInfo.tickInterval * 1.5, 2.0)
        end
        if A._tickManagerState.spellName ~= cleuSpellName or (now - A._tickManagerState.last) > resetGap then
            A._tickManagerState.count = 1
        else
            A._tickManagerState.count = A._tickManagerState.count + 1
        end
        A._tickManagerState.last = now
        A._tickManagerState.spellName = cleuSpellName

        local tickNum = A._tickManagerState.count

        local doSound = true
        local doFlash = true
        if A.ChannelHelper and A.ChannelHelper.ShouldPlayTickSelection then
            doSound = A.ChannelHelper:ShouldPlayTickSelection(channelInfo, tickNum, "tickSound")
            doFlash = A.ChannelHelper:ShouldPlayTickSelection(channelInfo, tickNum, "tickFlash")
        end

        if doSound then
            pcall(function() if A.PlayTickSound then A.PlayTickSound() end end)
        end
        if doFlash then
            pcall(function() if A.DoTickFlash then A.DoTickFlash() end end)
        end
    end)
end

function A.InitSpellTravelTracker()
    if A._spellTravelInited then return end
    A._spellTravelInited = true

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    frame:SetScript("OnEvent", function(_, event, ...)
        if event == "UNIT_SPELLCAST_SUCCEEDED" then
            local unit, _, spellId = ...
            if unit ~= "player" or not spellId then return end

            local spellName = A.GetSpellInfoCached(spellId)
            if not spellName then return end

            local targetGUID = nil
            if UnitExists("target") and UnitCanAttack("player", "target") then
                targetGUID = UnitGUID("target")
            end
            A.RecordSpellTravelLaunch(spellId, spellName, targetGUID, GetTime())
            return
        end

        local _, subEvent, _, sourceGUID, _, _, _, destGUID, _, _, _, spellId, spellName = CombatLogGetCurrentEventInfo()
        if sourceGUID ~= UnitGUID("player") then return end

        if subEvent == "SPELL_DAMAGE"
            or subEvent == "SPELL_MISSED"
            or subEvent == "SPELL_AURA_APPLIED"
            or subEvent == "SPELL_AURA_REFRESH"
            or subEvent == "SPELL_AURA_APPLIED_DOSE"
            or subEvent == "SPELL_HEAL"
        then
            A.RecordSpellTravelImpact(spellId, spellName, destGUID, GetTime())
        end
    end)

    A._spellTravelFrame = frame
end

-- Error forwarding: capture Lua errors and forward relevant SPHelper errors to chat+print.
do
    local prevHandler = geterrorhandler()
    local lastSent = 0
    local throttleSec = 5
    seterrorhandler(function(err)
        -- Call previous handler first (safe)
        pcall(prevHandler, err)

        if not err then return end
        local s = tostring(err)
        -- Only forward errors that reference this addon's path/name
        if not (s:find("Interface\\AddOns\\SPHelper") or s:find("SPHelper")) then return end

        -- Throttle repeated sends
        local now = GetTime()
        if (now - lastSent) < throttleSec then return end
        lastSent = now

        local prefix = "[SPHelper Error] "
        local out = prefix .. s
        -- Truncate to safe length for chat
        if #out > 200 then out = out:sub(1, 197) .. "..." end

        -- Print locally
        pcall(print, out)

        -- Try to send to the previously-joined diagnostics channel; attempt
        -- to join if we haven't yet. If sending fails, store the error in
        -- saved variables so the user can inspect later.
        local sentToChannel = false
        pcall(function()
            if not A._sphelperChannelID then
                if A.EnsureSphelperChannel then pcall(A.EnsureSphelperChannel) end
            end
            if A._sphelperChannelID and A._sphelperChannelID > 0 then
                pcall(function() SendChatMessage(out, "CHANNEL", nil, A._sphelperChannelID) end)
                sentToChannel = true
            end
        end)

        -- Persist the error locally if it wasn't sent to channel
        if not sentToChannel then
            pcall(function()
                if not SPHelperDB then SPHelperDB = {} end
                SPHelperDB.recentErrors = SPHelperDB.recentErrors or {}
                local entry = { time = GetTime(), msg = s, stack = (debugstack and debugstack()) or "" }
                table.insert(SPHelperDB.recentErrors, 1, entry)
                -- keep it bounded
                while #SPHelperDB.recentErrors > 80 do table.remove(SPHelperDB.recentErrors) end
            end)
        end
    end)
end

------------------------------------------------------------------------
-- Addon load event
------------------------------------------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, addon)
    if addon ~= "SPHelper" then return end
    A.InitDB()

    -- Check for setting version changes (must be after InitDB + after all specs loaded)
    A.ProcessSettingChanges()

    -- TickManager is global (not spec-specific) — always init
    if A.InitTickManager then A.InitTickManager() end
    if A.InitSpellTravelTracker then A.InitSpellTravelTracker() end

    -- Attempt to join a diagnostics channel for error forwarding
    A._sphelperChannelID = nil
    A._sphelperJoinAttempt = 0
    A.EnsureSphelperChannel = function()
        local now = GetTime()
        if A._sphelperChannelID and A._sphelperChannelID > 0 then return end
        if (now - (A._sphelperJoinAttempt or 0)) < 10 then return end
        A._sphelperJoinAttempt = now
        local chanName = "sphelper"
        local ok, cname, chanID = pcall(JoinChannelByName, chanName)
        if ok and chanID and chanID > 0 then
            A._sphelperChannelID = chanID
        end
    end
    pcall(A.EnsureSphelperChannel)

    -- Ensure config (slash commands / options panel) is initialized even
    -- if no spec becomes active. This makes `/sph` available for all classes.
    if A.InitConfig then pcall(A.InitConfig, A) end

    -- Delay spec evaluation so talent data is ready
    C_Timer.After(1, function()
        if A.SpecManager then
            A.SpecManager:ReEvaluate()
        end
        -- Informational message
        local hasActive = false
        if A.SpecManager then
            for _ in pairs(A.SpecManager:GetActiveSpecs()) do hasActive = true; break end
        end
        if hasActive then
            print("|cff8882d5SPHelper|r loaded.  /sph to configure.")
        else
            print("|cff8882d5SPHelper|r loaded — no spec enabled for this character yet.  Type |cffffcc00/sph|r to enable a built-in spec (only the Shadow Priest spec is on by default).")
        end
    end)

    -- Watch for talent/spec changes (dual spec support)
    local specWatcher = CreateFrame("Frame")
    specWatcher:RegisterEvent("PLAYER_TALENT_UPDATE")
    specWatcher:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
    specWatcher:RegisterEvent("SPELLS_CHANGED")
    specWatcher:SetScript("OnEvent", function(_, ev)
        if ev == "SPELLS_CHANGED" and A.ClearAPICache then
            A.ClearAPICache()
        end
        C_Timer.After(0.5, function()
            if A.SpecManager then
                A.SpecManager:ReEvaluate()
            end
        end)
    end)

    self:UnregisterEvent("ADDON_LOADED")
end)
