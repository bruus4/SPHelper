-- SPHelper  –  ChannelHelper.lua
-- Tracks channeled spell ticks, provides clip-window calculations,
-- and optionally implements a fake-queue (FQ) busy-wait for precise
-- channel clipping.
--
-- Can operate standalone (visual/audio cues only) or attach to the
-- existing CastBar frame for integrated clip-zone display.
------------------------------------------------------------------------
local A = SPHelper

A.ChannelHelper = {}
local CH = A.ChannelHelper

-- Macro-driven /run scripts on the Anniversary client start tripping the
-- script-time budget a little below 189 ms. Keep a hard safety margin below
-- that limit so FQ never leaves an action button in a broken state.
CH.FAKE_QUEUE_SCRIPT_SAFE_MS = 189

-- FQ always holds the FULL script-time budget; deliberately NOT a user
-- setting. When a tick is further away than the budget, the macro consumes
-- the whole hold so the cast lands as close to the tick as the client
-- allows (firing immediately would land ~budget + latency too early and
-- lose the tick).
CH.FAKE_QUEUE_HOLD_MS = CH.FAKE_QUEUE_SCRIPT_SAFE_MS

-- Fixed safety buffer applied on top of latency compensation: FQ releases so
-- the cast ARRIVES at the server this many ms AFTER the predicted tick lands.
-- This guarantees the last tick is never clipped even when the server ticks
-- a few ms off schedule; the only cost is this many ms of delay (worst case
-- the next cast starts slightly late instead of clipping the tick).
CH.FAKE_QUEUE_FIRE_AFTER_MS = 20

local function NormalizeChannelToken(value)
    if type(value) ~= "string" then return nil end
    value = value:gsub("[%s%-]+", "_")
    value = value:gsub("__+", "_")
    return string.upper(value)
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

local function GetRotationForSpec(spec)
    if not spec or not spec.meta then return nil end
    local sdb = A.db and A.db.specs and A.db.specs[spec.meta.id]
    return (sdb and sdb.rotation) or spec.rotation
end

local function GetEntryId(entry, index)
    -- Stable per-entry ID used as the key in saved helperOptions. Prefers an
    -- explicit entry.id; otherwise derives one from the spell name + spell ID
    -- so it survives rotation reordering (index is not part of the key).
    if entry and entry.id and entry.id ~= "" then return entry.id end
    local def = A.GetSpellDefinition and A.GetSpellDefinition(entry and entry.key)
    local name = (def and def.name) or (entry and entry.key) or "entry"
    local spellID = (def and (def.id or def.baseId)) or (A.ResolveSpellID and A.ResolveSpellID(entry and entry.key)) or 0
    return string.format("%s_%s", SanitizeEntryToken(name), tostring(spellID))
end

local function GetSavedHelperOptions(spec, entry, index)
    if not spec or not spec.meta or not entry then return nil end
    local sdb = A.db and A.db.specs and A.db.specs[spec.meta.id]
    local saved = sdb and sdb.helperOptions
    if type(saved) ~= "table" then return nil end

    local entryId = GetEntryId(entry, index)
    if type(saved[entryId]) == "table" then return saved[entryId] end

    local spellName = entry.key
    local def = A.GetSpellDefinition and A.GetSpellDefinition(entry.key)
    if def and def.name then spellName = def.name end
    if spellName and type(saved[spellName]) == "table" then return saved[spellName] end
    return nil
end

local function GetEntryHelperOptions(spec, entry, index)
    local options = CopyValue(entry and entry.helperOptions or {}) or {}
    MergeInto(options, GetSavedHelperOptions(spec, entry, index))
    return options
end

local function BuildChannelDefinitionFromEntry(spec, entry, index)
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
    local markerOpts = options.tickMarkers or {}
    local soundOpts = options.tickSound or {}
    local flashOpts = options.tickFlash or {}

    return {
        _fromRotation = true,
        id = GetEntryId(entry, index),
        castType = "channel",
        spellKey = entry.key,
        spellName = def.name or entry.key,
        ticks = tonumber(def.ticks) or 0,
        duration = def.duration or def.castTime,
        tickInterval = def.tickInterval,
        clipOverlay = helpers.clipOverlay == true,
        minDuration = clipOpts.minDuration,
        clipReasons = clipOpts.clipReasons or {},
        tickSound = helpers.tickSound == true,
        tickSoundTicks = soundOpts.ticks or {},
        tickFlash = helpers.tickFlash == true,
        tickFlashTicks = flashOpts.ticks or {},
        tickMarkers = helpers.tickMarkers == true,
        tickMarkerMode = markerOpts.mode or "all",
        tickMarkerTicks = markerOpts.ticks or {},
    }
end

local function ChannelSpecMatches(def, spec)
    if not def or not spec or not spec.meta then return true end

    local specMeta = spec.meta or {}
    if def.class and specMeta.class and def.class ~= specMeta.class then
        return false
    end

    if not def.spec or def.spec == "" then
        return true
    end

    local defSpec = NormalizeChannelToken(def.spec)
    if not defSpec then return true end

    local specId = NormalizeChannelToken(specMeta.id or "")
    local specName = NormalizeChannelToken(specMeta.specName or "")

    if defSpec == specId or defSpec == specName then
        return true
    end

    if specId and specId:find(defSpec, 1, true) then
        return true
    end
    if specName and specName:find(defSpec, 1, true) then
        return true
    end

    return false
end

local function NormalizeChannelSpellEntry(entry, fallbackKey, fallbackName)
    if type(entry) ~= "table" then return nil end

    local spellKey = entry.spellKey or entry.key or fallbackKey
    local spellName = entry.spellName or entry.name or fallbackName
    if not spellName and spellKey and A.SPELLS and A.SPELLS[spellKey] then
        spellName = A.SPELLS[spellKey].name
    end
    if not spellName and spellKey and A.GetSpellInfoCached then
        spellName = A.GetSpellInfoCached(spellKey)
    end
    if not spellName then return nil end

    local ticks = tonumber(entry.ticks) or 0
    if ticks <= 0 then
        local duration = tonumber(entry.duration or entry.castTime) or 0
        local tickInterval = tonumber(entry.tickInterval) or 0
        if duration > 0 and tickInterval > 0 then
            ticks = math.max(1, math.floor((duration / tickInterval) + 0.5))
        elseif duration > 0 then
            ticks = math.max(1, math.floor(duration + 0.5))
        end
    end
    if ticks <= 0 then
        -- Fall back to SpellDatabase entry before hardcoding 3
        local dbDef = A.GetSpellDefinition
            and (A.GetSpellDefinition(spellKey) or A.GetSpellDefinition(spellName))
        if dbDef and (dbDef.ticks or 0) > 0 then
            ticks = dbDef.ticks
        end
    end
    if ticks <= 0 then ticks = 3 end

    local defaultOn = entry._legacyChannel == true
    local function ResolveEntryFlag(field, defaultValue)
        local value = entry[field]
        if value == nil then return defaultValue end
        return value ~= false
    end

    local normalized = {
        _fromRotation = entry._fromRotation == true,
        id = entry.id,
        castType = "channel",
        spellKey = spellKey,
        spellName = spellName,
        ticks = ticks,
        clipOverlay = ResolveEntryFlag("clipOverlay", defaultOn),
        minDuration = entry.minDuration,
        clipReasons = entry.clipReasons or {},
        tickSound = ResolveEntryFlag("tickSound", defaultOn),
        tickSoundTicks = entry.tickSoundTicks or {},
        tickFlash = ResolveEntryFlag("tickFlash", defaultOn),
        tickFlashTicks = entry.tickFlashTicks or {},
        tickMarkers = ResolveEntryFlag("tickMarkers", defaultOn),
        tickMarkerMode = entry.tickMarkerMode or "all",
        tickMarkerTicks = entry.tickMarkerTicks or {},
    }

    return normalized
end

function CH:GetChannelSpellDefinitions(spec)
    local defs = {}
    local seen = {}

    local function AddEntry(entry, fallbackKey, fallbackName)
        local normalized = NormalizeChannelSpellEntry(entry, fallbackKey, fallbackName)
        if not normalized then return end

        local dedupeKey = normalized.spellKey or normalized.spellName
        local nameKey = normalized.spellName
        if (dedupeKey and seen[dedupeKey]) or (nameKey and seen[nameKey]) then return end
        if dedupeKey then seen[dedupeKey] = true end
        if nameKey then seen[nameKey] = true end
        defs[#defs + 1] = normalized
    end

    local rotation = GetRotationForSpec(spec)
    if type(rotation) == "table" then
        for index, entry in ipairs(rotation) do
            AddEntry(BuildChannelDefinitionFromEntry(spec, entry, index), entry and entry.key, nil)
        end
    end

    if spec and type(spec.channelSpells) == "table" then
        for _, cs in ipairs(spec.channelSpells) do
            local legacy = CopyValue(cs)
            legacy._legacyChannel = true
            AddEntry(legacy, legacy.spellKey or legacy.key, legacy.spellName or legacy.name)
        end
    end

    local specClass = spec and spec.meta and spec.meta.class
    local catalog = A.SpellDatabase and A.SpellDatabase.catalog or nil
    local sortedKeys = A.SpellDatabase and A.SpellDatabase.sortedKeys or nil

    if catalog and sortedKeys then
        for _, key in ipairs(sortedKeys) do
            local def = catalog[key]
            if def and (def.castType == "channel" or def.channel == true or (def.flags and def.flags.channel)) then
                if ChannelSpecMatches(def, spec) and (not specClass or not def.class or def.class == specClass) then
                    AddEntry(def, key, def.name)
                end
            end
        end
    elseif A.SPELLS then
        for key, spell in pairs(A.SPELLS) do
            if type(spell) == "table" and (spell.castType == "channel" or spell.channel == true or (spell.flags and spell.flags.channel)) then
                if ChannelSpecMatches(spell, spec) and (not specClass or not spell.class or spell.class == specClass) then
                    AddEntry(spell, key, spell.name)
                end
            end
        end
    end

    if self.KNOWN_CHANNELS then
        for spellName, info in pairs(self.KNOWN_CHANNELS) do
            if type(info) == "table" and spellName then
                -- Apply the same class/spec filter as the SpellDatabase path.
                local mockDef = { class = info.class, spec = info.spec }
                if ChannelSpecMatches(mockDef, spec)
                   and (not spec or not spec.meta or not spec.meta.class
                        or not info.class or info.class == spec.meta.class) then
                    AddEntry(info, info.spellKey or info.spellID or spellName, spellName)
                end
            end
        end
    end

    return defs
end

function CH:GetDefaultChannelSpellName(spec)
    local defs = self._channelSpellDefs
    if defs and defs[1] and defs[1].spellName then
        return defs[1].spellName
    end

    local specDefs = self:GetChannelSpellDefinitions(spec)
    if specDefs and specDefs[1] and specDefs[1].spellName then
        return specDefs[1].spellName
    end

    local fallbackDefs = self:GetChannelSpellDefinitions(nil)
    if fallbackDefs and fallbackDefs[1] and fallbackDefs[1].spellName then
        return fallbackDefs[1].spellName
    end

    return nil
end

function CH:IsChannelSpell(spellRef, spec)
    if spellRef == nil then return false end

    local def = nil
    if A.GetSpellDefinition then
        def = A.GetSpellDefinition(spellRef)
    end
    if def and (def.castType == "channel" or def.channel == true or (def.flags and def.flags.channel)) then
        return true
    end

    local defs = self:GetChannelSpellDefinitions(spec)
    for _, info in ipairs(defs or {}) do
        if info.spellKey == spellRef or info.spellName == spellRef then
            return true
        end
    end

    return false
end

function CH:GetChannelInfoForSpell(spellName, spellID)
    if spellName and self.KNOWN_CHANNELS and self.KNOWN_CHANNELS[spellName] then
        return self.KNOWN_CHANNELS[spellName]
    end

    local resolvedName = spellName
    local def = nil
    if A.GetSpellDefinition then
        def = A.GetSpellDefinition(spellID or spellName)
    end

    -- Non-English clients: the name from UnitChannelInfo is localized
    -- (e.g. German "Gedankenschlag"), so the English-keyed KNOWN_CHANNELS
    -- lookup above misses. Match the resolved definition against the known
    -- channels instead, so the configured tick / clip / FQ features still
    -- apply instead of the default-off fallback info.
    if def and def.name and self.KNOWN_CHANNELS then
        for knownName, info in pairs(self.KNOWN_CHANNELS) do
            if type(info) == "table"
               and (info.spellKey == def.key or info.spellName == def.name or knownName == def.name) then
                return info
            end
        end
    end

    if not resolvedName and spellID and A.GetSpellInfoCached then
        resolvedName = A.GetSpellInfoCached(spellID)
    end
    if not resolvedName and def and def.name then
        resolvedName = def.name
    end
    if not resolvedName then
        return nil
    end

    local function ResolveFlag(field, defaultValue)
        if not def then
            return defaultValue
        end
        local value = def[field]
        if value == nil then
            return defaultValue
        end
        return value ~= false
    end

    local info = {
        castType = "channel",
        ticks = (def and def.ticks) or 3,

        clipOverlay = ResolveFlag("clipOverlay", false),
        tickSound = ResolveFlag("tickSound", false),
        tickSoundTicks = def and def.tickSoundTicks or {},
        tickFlash = ResolveFlag("tickFlash", false),
        tickFlashTicks = def and def.tickFlashTicks or {},
        tickMarkers = ResolveFlag("tickMarkers", false),
        tickMarkerMode = def and def.tickMarkerMode or "all",
        tickMarkerTicks = def and def.tickMarkerTicks or {},
        spellKey = def and def.key or nil,
        spellID = spellID,
        spellName = resolvedName,
        _fallback = true,
    }

    self.KNOWN_CHANNELS[resolvedName] = info
    return info
end

local function TickListContains(list, tickNum)
    if type(list) ~= "table" or #list == 0 then return false end
    for _, value in ipairs(list) do
        if tonumber(value) == tickNum then
            return true
        end
    end
    return false
end

function CH:TickSelectionContains(list, tickNum, defaultAll)
    if type(list) ~= "table" or #list == 0 then
        return defaultAll ~= false
    end
    return TickListContains(list, tickNum)
end

function CH:ShouldShowTickMarker(info, tickNum)
    if not info or info.tickMarkers == false then return false end
    local mode = info.tickMarkerMode or "all"
    if mode == "none" then return false end
    if mode == "specific" then
        return self:TickSelectionContains(info.tickMarkerTicks, tickNum, false)
    end
    return true
end

function CH:ShouldPlayTickSelection(info, tickNum, selectionKey)
    if not info then return true end
    if info[selectionKey] == false then return false end
    return self:TickSelectionContains(info[selectionKey .. "Ticks"], tickNum, true)
end

local function HideAllClipOverlays(self)
    if self._clipOverlay then
        self._clipOverlay:Hide()
    end
    if self._clipOverlays then
        for i = 1, #self._clipOverlays do
            if self._clipOverlays[i] then
                self._clipOverlays[i]:Hide()
            end
        end
    end
end

-- State
------------------------------------------------------------------------
CH._state = {
    active          = false,
    spellID         = nil,
    spellName       = nil,
    startTime       = 0,
    endTime         = 0,
    totalDuration   = 0,
    tickCount       = 3,      -- default channel tick count
    tickInterval    = 1.0,
    ticksSoFar      = 0,
    latency         = 0,
    clipWindowStart = 0,      -- earliest safe clip time (may be FQ-extended)
    clipWindowEnd   = 0,      -- latest safe clip time
    clipWindowBase  = 0,      -- clip window start WITHOUT FQ extension (FQ waits until this)
}

-- (Overlay is shown continuously for the clip window while channeling.)

------------------------------------------------------------------------
-- Configuration (populated from spec constants / SpecUI toggles)
------------------------------------------------------------------------
CH._config = {
    clipCues         = true,
    fakeQueueEnabled = true,  -- single FQ on/off switch (castBarOptions.channelFakeQueue)
    clipMarginMs     = 50,    -- spec tuning constant: safe-clip-zone margin
}

------------------------------------------------------------------------
-- Known channeled spells and their tick counts.
-- Populated from spec.channelSpells on activate; falls back to SpellDatabase
-- discovery if no spec data is available.
------------------------------------------------------------------------
CH.KNOWN_CHANNELS = {}

------------------------------------------------------------------------
-- Update KNOWN_CHANNELS from spec's channelSpells data
------------------------------------------------------------------------
function CH:LoadChannelSpells(spec)
    self.KNOWN_CHANNELS = {}
    local defs = self:GetChannelSpellDefinitions(spec)
    self._channelSpellDefs = defs
    for _, cs in ipairs(defs) do
        if cs.spellName then
            -- Per-spell saved overrides live under "cs_<spellKey>_<field>" in
            -- the spec namespace. Rotation-defined entries (fromRotation)
            -- are authoritative and ignore those overrides; catalog/legacy
            -- entries fall back to the saved value, then the entry default.
            local prefix = "cs_" .. (cs.spellKey or "") .. "_"
            local fromRotation = cs._fromRotation == true
            self.KNOWN_CHANNELS[cs.spellName] = {
                castType    = "channel",
                ticks       = cs.ticks or 3,

                clipOverlay = fromRotation and (cs.clipOverlay == true) or A.SpecVal(prefix .. "clipOverlay", cs.clipOverlay ~= false),
                minDuration = cs.minDuration,
                clipReasons = cs.clipReasons or {},
                tickSound   = fromRotation and (cs.tickSound == true) or A.SpecVal(prefix .. "tickSound", cs.tickSound ~= false),
                tickSoundTicks = fromRotation and (cs.tickSoundTicks or {}) or A.SpecVal(prefix .. "tickSoundTicks", cs.tickSoundTicks or {}),
                tickFlash   = fromRotation and (cs.tickFlash == true) or A.SpecVal(prefix .. "tickFlash", cs.tickFlash ~= false),
                tickFlashTicks = fromRotation and (cs.tickFlashTicks or {}) or A.SpecVal(prefix .. "tickFlashTicks", cs.tickFlashTicks or {}),
                tickMarkers = fromRotation and (cs.tickMarkers == true) or A.SpecVal(prefix .. "tickMarkers", cs.tickMarkers ~= false),
                tickMarkerMode  = fromRotation and (cs.tickMarkerMode or "all") or A.SpecVal(prefix .. "tickMarkerMode", cs.tickMarkerMode or "all"),
                tickMarkerTicks = fromRotation and (cs.tickMarkerTicks or {}) or A.SpecVal(prefix .. "tickMarkerTicks", cs.tickMarkerTicks or {}),
                spellKey    = cs.spellKey,
                id          = cs.id,
            }
        end
    end
end

------------------------------------------------------------------------
-- Update configuration from spec constants and DB
------------------------------------------------------------------------
function CH:UpdateConfig(spec)
    if not spec then return end
    -- Single on/off switch + visual cues; FQ hold time is a fixed constant
    -- (CH.FAKE_QUEUE_HOLD_MS) and is deliberately not configurable.
    self._config.fakeQueueEnabled = A.SpecVal("channelFakeQueue", true)
    self._config.clipCues         = A.SpecVal("channelClipCues",  true)

    local timing = spec.constants and spec.constants.timing
    if timing then
        self._config.clipMarginMs = A.SpecVal("clipMarginMs", timing.clipMarginMs or 50)
    else
        self._config.clipMarginMs = A.SpecVal("clipMarginMs", 50)
    end
end

------------------------------------------------------------------------
-- Channel start / stop / update
------------------------------------------------------------------------

function CH:OnChannelStart(spellName, startTime, endTime, spellID)
    local info = self:GetChannelInfoForSpell(spellName, spellID)
    if not info then
        self._state.active = false
        return
    end

    -- Store per-spell config for this channel
    self._activeChannelInfo = info

    local duration = endTime - startTime
    local ticks    = info.ticks or 3
    local interval = duration / ticks

    self._state.active        = true
    self._state.spellID       = spellID
    self._state.spellName     = spellName
    self._state.startTime     = startTime
    self._state.endTime       = endTime
    self._state.totalDuration = duration
    self._state.tickCount     = ticks
    self._state.tickInterval  = interval
    self._state.ticksSoFar    = 0
    self._state.latency       = A.GetLatency()

    self:_RecalcClipWindow()
end

function CH:OnChannelStop()
    A._fqBlocking       = false
    self._state.active = false
    self._activeChannelInfo = nil
    HideAllClipOverlays(self)
end

function CH:OnChannelUpdate(endTime)
    if not self._state.active then return end
    self._state.endTime = endTime
    self._state.totalDuration = endTime - self._state.startTime
    self._state.tickInterval  = self._state.totalDuration / self._state.tickCount
    -- Refresh one-way latency: it can shift mid-channel and the FQ release
    -- target depends on it (release = tickTime - latency + buffer).
    self._state.latency = A.GetLatency()
    self:_RecalcClipWindow()
end

function CH:OnTick()
    if not self._state.active then return end
    self._state.ticksSoFar = self._state.ticksSoFar + 1
    self:_RecalcClipWindow()
end

------------------------------------------------------------------------
-- Clip window calculation
--
-- The "safe clip zone" is the time between the last full tick completing
-- and the end of the channel, minus latency and margin.
-- Clipping here ensures the last tick has already fired.
------------------------------------------------------------------------
function CH:_RecalcClipWindow()
    local s = self._state
    if not s.active then return end

    local margin   = self._config.clipMarginMs / 1000
    local lat      = s.latency

    -- Time of the last safe tick
    local lastTickTime = s.startTime + (s.tickCount * s.tickInterval)

    -- Safe clip window: after last tick + margin, before channel end - latency
    s.clipWindowStart = lastTickTime - s.tickInterval + margin
    s.clipWindowEnd   = s.endTime - lat - margin

    -- Store the base (un-extended) start for FQ wait target
    s.clipWindowBase = s.clipWindowStart

    -- Extend clip window earlier by FQ hold time when FQ is enabled
    -- (this makes the overlay show the extended zone; FQ waits until clipWindowBase)
    if self._config.fakeQueueEnabled then
        local fqExtend = CH.FAKE_QUEUE_HOLD_MS / 1000
        s.clipWindowStart = s.clipWindowStart - fqExtend
    end

    -- Clamp
    if s.clipWindowStart < s.startTime then s.clipWindowStart = s.startTime end
    if s.clipWindowBase < s.startTime then s.clipWindowBase = s.startTime end
    if s.clipWindowEnd < s.clipWindowStart then s.clipWindowEnd = s.clipWindowStart end
end

------------------------------------------------------------------------
-- Public query API
------------------------------------------------------------------------

--- Returns (windowStart, windowEnd, ticksRemaining) for the current channel.
function CH:GetChannelTickWindow()
    if not self._state.active then return 0, 0, 0 end
    local s = self._state
    return s.clipWindowStart, s.clipWindowEnd, s.tickCount - s.ticksSoFar
end

--- Returns true if the player should clip NOW (within the safe window).
function CH:CanClipNow()
    if not self._state.active then return false end
    local now = GetTime()
    return now >= self._state.clipWindowStart and now <= self._state.clipWindowEnd
end

--- Returns the number of seconds until the clip window opens (0 if now or past).
function CH:TimeToClip()
    if not self._state.active then return 0 end
    return math.max(self._state.clipWindowStart - GetTime(), 0)
end

--- Returns the remaining channel time.
function CH:GetChannelRemaining()
    if not self._state.active then return 0 end
    return math.max(self._state.endTime - GetTime(), 0)
end

--- Returns the live tick interval for the current channel.
function CH:GetChannelTickInterval()
    if not self._state.active then return 0 end
    return self._state.tickInterval or 0
end

--- Returns the number of ticks remaining on the current channel.
function CH:GetChannelTicksRemaining()
    if not self._state.active then return 0 end
    return math.max((self._state.tickCount or 0) - (self._state.ticksSoFar or 0), 0)
end

--- Returns the time until the next expected tick on the current channel.
function CH:GetChannelTimeToNextTick()
    if not self._state.active then return 0 end
    local nextTick = (self._state.ticksSoFar or 0) + 1
    if nextTick > (self._state.tickCount or 0) then return 0 end
    local nextAt = (self._state.startTime or 0) + (nextTick * (self._state.tickInterval or 0))
    return math.max(nextAt - GetTime(), 0)
end

--- Returns the active channel spell key, if known.
function CH:GetActiveChannelSpellKey()
    if not self._state.active then return nil end
    return self._activeChannelInfo and self._activeChannelInfo.spellKey or nil
end

------------------------------------------------------------------------
-- CastBar attachment
-- Draws a green clip-zone overlay on the given castbar frame.
-- If castbarFrame is nil, creates a standalone minimal indicator.
------------------------------------------------------------------------
CH._attachedFrame = nil
CH._clipOverlay   = nil

function CH:AttachToCastbar(castbarFrame)
    self._attachedFrame = castbarFrame
    -- The overlay is created on first use in UpdateCastbarOverlay
end

function CH:UpdateCastbarOverlay()
    -- Check global clip cues AND per-spell clipOverlay setting
    local channelInfo = self._activeChannelInfo
    local spellClip = channelInfo and channelInfo.clipOverlay ~= false
    local isChannel = channelInfo and channelInfo.castType == "channel"
    if not self._state.active or not isChannel or not self._config.clipCues or not spellClip then
        HideAllClipOverlays(self)
        return
    end

    local parent = self._attachedFrame
    if not parent or not parent:IsShown() then
        HideAllClipOverlays(self)
        return
    end

    -- Create overlay textures on first use. One texture per tick keeps all
    -- tick markers visible for the whole channel instead of only around the
    -- next pending tick.
    if not self._clipOverlays then
        self._clipOverlays = {}
    end

    local s = self._state
    local totalDur = s.totalDuration
    if totalDur <= 0 then
        HideAllClipOverlays(self)
        return
    end

    local barWidth = parent:GetWidth()

    -- Render one persistent zone per shown tick marker. The zone visualizes
    -- both windows for each tick:
    --   * BEFORE the tick (only when FQ is enabled): from the earliest point
    --     FQ can hold from (tickTime - FAKE_QUEUE_HOLD_MS, clamped to channel
    --     start) up to the tick — pressing there makes FQ hold and release
    --     right after the tick.
    --   * AFTER the tick (always): tickTime + 100ms — clipping within this
    --     window is also safe because the tick has already landed.
    local overlayAfter = 0.1 -- seconds shown after the tick (100ms)
    local fqExtend = (self._config.fakeQueueEnabled and CH.FAKE_QUEUE_HOLD_MS / 1000) or 0
    local activeCount = 0
    for i = 1, s.tickCount do
        local showTick = true
        if self._activeChannelInfo then
            showTick = self:ShouldShowTickMarker(self._activeChannelInfo, i)
        end

        if showTick then
            local tickTime = s.startTime + (i * s.tickInterval)
            local baseStart = math.max(tickTime - fqExtend, s.startTime)
            local endSec = math.min(tickTime + overlayAfter, s.endTime)
            local clipStartFrac = (baseStart - s.startTime) / totalDur
            local clipEndFrac   = (endSec   - s.startTime) / totalDur
            clipStartFrac = math.max(0, math.min(1, clipStartFrac))
            clipEndFrac   = math.max(0, math.min(1, clipEndFrac))

            -- Invert: remaining = 1 - elapsed
            local startPx = barWidth * (1 - clipEndFrac)
            local endPx   = barWidth * (1 - clipStartFrac)
            local width   = endPx - startPx

            local tex = self._clipOverlays[i]
            if width < 1 then
                if tex then tex:Hide() end
            else
                if not tex then
                    tex = parent:CreateTexture(nil, "OVERLAY")
                    tex:SetColorTexture(0.3, 0.9, 0.3, 0.35)
                    self._clipOverlays[i] = tex
                end
                tex:SetHeight(parent:GetHeight())
                tex:ClearAllPoints()
                tex:SetPoint("LEFT", parent, "LEFT", startPx, 0)
                tex:SetWidth(width)
                tex:Show()
                activeCount = activeCount + 1
            end
        else
            local tex = self._clipOverlays[i]
            if tex then tex:Hide() end
        end
    end

    for i = s.tickCount + 1, #self._clipOverlays do
        if self._clipOverlays[i] then
            self._clipOverlays[i]:Hide()
        end
    end

    if activeCount == 0 then
        HideAllClipOverlays(self)
    end
end

------------------------------------------------------------------------
-- Fake Queue (FQ) — busy-wait clip assist
--
-- Global function SPH_FQ() is called from macros like:
--   /run SPH_FQ()
--   /cast Mind Blast
--
-- It will busy-wait up to the fixed hold (CH.FAKE_QUEUE_HOLD_MS = 189ms)
-- if a channel is active and the clip moment hasn't arrived yet, so the
-- next /cast fires at the optimal moment: right after the last tick.
------------------------------------------------------------------------

function CH:FakeQueue(spellArg)
    local maxWait = CH.FAKE_QUEUE_HOLD_MS / 1000
    if maxWait <= 0 then return end

    -- ------------------------------------------------------------------
    -- DoT-refresh mode
    -- When SPH_FQ is invoked with a spell name (or while no channel is
    -- active and a hint exists for the spell currently queued via macro),
    -- busy-wait until the ideal cast-start moment computed by the
    -- RotationEngine. Capped at the same script safety budget as the
    -- channel FQ. This eliminates the SAFETY margin on DoT reapplication
    -- without risking a clipped tick.
    -- ------------------------------------------------------------------
    local hint = nil
    if spellArg and A.DotRefreshHints then
        hint = A.DotRefreshHints[spellArg]
        if not hint then
            -- Allow callers to pass a spell key (e.g. "VT") instead of the name.
            local spell = A.SPELLS and A.SPELLS[spellArg]
            if spell and spell.name then
                hint = A.DotRefreshHints[spell.name]
            end
        end
    end

    if not self._state.active then
        if hint and hint.fireAt then
            local now = GetTime()
            local needed = hint.fireAt - now

            -- If the fire-at delay is too long or already past, check whether
            -- a DoT tick is imminent (within budget). If so, delay for the
            -- tick so it lands before the refresh, avoiding a clipped tick.
            if (needed <= 0 or needed > maxWait) and hint.nextTickIn
                and hint.nextTickIn > 0 and hint.nextTickIn <= maxWait then
                needed = hint.nextTickIn
            end

            if needed <= 0 or needed > maxWait then return end
            local needed_ms = needed * 1000
            local start_dbp = debugprofilestop()
            A._fqBlocking = true
            repeat until (debugprofilestop() - start_dbp) >= needed_ms
            A._fqBlocking = false
        end
        return
    end

    -- ------------------------------------------------------------------
    -- Channel-clip mode (original behaviour)
    -- ------------------------------------------------------------------
    if not self._config.fakeQueueEnabled then return end

    local s = self._state

    -- ---------------------------------------------------------------
    -- Compute the next upcoming tick time we should wait for.
    --
    -- lat_s = one-way latency to server (seconds).
    --   release at: T_tick - lat_s + FAKE_QUEUE_FIRE_AFTER_MS
    -- The cast command reaches the server one-way latency later, i.e.
    -- at T_tick + FAKE_QUEUE_FIRE_AFTER_MS — right AFTER the tick lands.
    -- Jitter in the server tick schedule can then only make the cast
    -- slightly late, never clip the tick.
    -- ---------------------------------------------------------------
    local lat_s      = s.latency                              -- one-way latency in seconds
    local fineOffset = CH.FAKE_QUEUE_FIRE_AFTER_MS / 1000
    local now        = GetTime()

    local targetTime = nil
    for n = (s.ticksSoFar + 1), s.tickCount do
        local tickTime = s.startTime + (n * s.tickInterval) - lat_s + fineOffset
        if tickTime > now then
            targetTime = tickTime
            break
        end
    end

    if not targetTime then return end  -- no upcoming ticks

    local needed = targetTime - now

    -- Only engage the busy-wait when the release point is within the
    -- script-time budget. Presses further out are handled by WoW's native
    -- spell queue; holding would only delay the cast without landing it on
    -- the tick, and it freezes the UI for no benefit. (Matches the
    -- DoT-refresh branch above.)
    if needed <= 0 or needed > maxWait then return end

    -- ---------------------------------------------------------------
    -- Sub-millisecond busy-wait using debugprofilestop().
    -- debugprofilestop() returns elapsed ms since the profiler reset
    -- with sub-ms precision on all WoW clients (no frame-rate limit).
    -- GetTime() / GetTimePreciseSec would both be less accurate here
    -- because GetTime() is frame-quantised (~10-16 ms resolution) and
    -- GetTimePreciseSec is unavailable on TBC Anniversary.
    -- ---------------------------------------------------------------
    local needed_ms  = needed * 1000
    local start_dbp  = debugprofilestop()
    A._fqBlocking    = true
    repeat until (debugprofilestop() - start_dbp) >= needed_ms
    A._fqBlocking    = false

end

-- Expose global function for macros
SPH_FQ = function(spellArg)
    if A.ChannelHelper then
        A.ChannelHelper:FakeQueue(spellArg)
    end
end

------------------------------------------------------------------------
-- Macro generator
------------------------------------------------------------------------

function CH:GetMacroText(spellName)
    if not spellName and self._channelSpellDefs and self._channelSpellDefs[1] then
        spellName = self._channelSpellDefs[1].spellName
    end
    -- Pass the spell name into SPH_FQ so DoT-refresh hints can be looked up.
    -- For channel spells the argument is harmless (channel mode ignores it).
    local sn = spellName or self:GetDefaultChannelSpellName() or ""
    local escaped = sn:gsub('"', '\\"')
    return '/run SPH_FQ("' .. escaped .. '")\n/cast ' .. sn
end

function CH:PrintMacros()
    print("|cff8882d5SPHelper|r: Fake Queue macros (create in-game macros with this text):")
    local spells = self:GetMacroSpells()
    for _, name in ipairs(spells) do
        print("|cffffcc00" .. name .. ":|r")
        print("  " .. self:GetMacroText(name):gsub("\n", "\n  "))
    end
end

--- Get the list of spell names that should have FQ macros for the active spec.
-- Returns channel spells PLUS any DoT-refresh spells (those with a
-- `projected_dot_time_left_lt` condition) so the FQ helper can also smooth
-- out DoT reapplication timing.
function CH:GetMacroSpells()
    local spells = {}
    local seen = {}
    local hasExplicitHelpers = false
    local function add(name)
        if not name or seen[name] then return end
        seen[name] = true
        spells[#spells + 1] = name
    end

    -- Prefer the explicit rotation-entry helper model.
    if A.SpecManager and A.SpecManager.GetActiveSpecs then
        local activeSpecs = A.SpecManager:GetActiveSpecs() or {}
        for _, spec in pairs(activeSpecs) do
            local rotation = GetRotationForSpec(spec)
            if rotation then
                for _, entry in ipairs(rotation) do
                    if entry and entry.key and entry.helpers then
                        local spell = A.GetSpellDefinition and A.GetSpellDefinition(entry.key)
                        if spell and spell.name then
                            add(spell.name)
                            hasExplicitHelpers = true
                        end
                    end
                end
            end
        end
    end

    if not hasExplicitHelpers then
        if self._channelSpellDefs and #self._channelSpellDefs > 0 then
            for _, cs in ipairs(self._channelSpellDefs) do
                add(cs.spellName)
            end
        elseif self.KNOWN_CHANNELS then
            for spellName, _ in pairs(self.KNOWN_CHANNELS) do
                add(spellName)
            end
        end

        -- Legacy DoT-refresh spells from the active spec's rotation.
        if A.SpecManager and A.SpecManager.GetActiveSpecs then
            local activeSpecs = A.SpecManager:GetActiveSpecs() or {}
            for _, spec in pairs(activeSpecs) do
                local rotation = GetRotationForSpec(spec)
                if rotation then
                    for _, entry in ipairs(rotation) do
                        if entry.key and entry.conditions then
                            for _, cond in ipairs(entry.conditions) do
                                if cond and (cond.type == "projected_dot_time_left_lt" or cond.type == "dot_missing") then
                                    local spell = A.SPELLS and A.SPELLS[entry.key]
                                    if spell and spell.name then
                                        add(spell.name)
                                    end
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if #spells == 0 then
        local fallback = self:GetDefaultChannelSpellName()
        if fallback then
            add(fallback)
        end
    end
    return spells
end

local function GetMacroIconForSpell(spellName)
    local iconTexture = A.GetSpellIconCached and A.GetSpellIconCached(spellName) or select(3, GetSpellInfo(spellName))
    if iconTexture then return iconTexture end
    for _, spellData in pairs(A.SPELLS or {}) do
        if spellData.name == spellName then
            iconTexture = (A.GetSpellIconCached and A.GetSpellIconCached(spellData.id)) or select(3, GetSpellInfo(spellData.id))
            if iconTexture then return iconTexture end
        end
    end
    return "INV_MISC_QUESTIONMARK"
end

function CH:CreateMacroForSpell(spellName)
    if not spellName or spellName == "" then return "failed" end
    local macroName = "SPH: " .. spellName
    local body = self:GetMacroText(spellName)
    local iconTexture = GetMacroIconForSpell(spellName)
    local existingIdx = GetMacroIndexByName(macroName)
    if existingIdx and existingIdx > 0 then
        EditMacro(existingIdx, macroName, iconTexture, body)
        return "updated"
    end

    local ok, result = pcall(CreateMacro, macroName, iconTexture, body, 1)
    if ok and result then return "created" end

    -- Some client builds reject the 4-arg form (slot index); retry without it.
    local ok2, result2 = pcall(CreateMacro, macroName, iconTexture, body, nil)
    if ok2 and result2 then return "created" end
    return "failed"
end

--- Automatically create or update FQ macros for selected spells.
--- Uses CreateMacro() API. Only creates macros that don't already exist.
--- Returns the number of macros created.
function CH:CreateMacros(selectedSpells)
    if InCombatLockdown and InCombatLockdown() then
        print("|cffff4444SPHelper|r: Macros cannot be created or updated while in combat.")
        return 0
    end

    local spells = selectedSpells or self:GetMacroSpells()
    local created = 0
    local skipped = 0
    local failed = 0

    for _, spellName in ipairs(spells) do
        local result = self:CreateMacroForSpell(spellName)
        if result == "updated" then
            skipped = skipped + 1
        elseif result == "created" then
            created = created + 1
        else
            failed = failed + 1
        end
    end

    local msg = string.format("|cff8882d5SPHelper|r: Macros — %d created, %d updated, %d failed.", created, skipped, failed)
    print(msg)
    if created > 0 or skipped > 0 then
        print("|cff8882d5SPHelper|r: Open the macro panel (|cffffcc00/macro|r) and drag them to your action bar.")
    end
    if failed > 0 then
        print("|cffff4444SPHelper|r: Some macros failed — you may have too many macros. Delete unused ones and try again.")
    end
    return created
end

function CH:OpenMacroChooser()
    local spells = self:GetMacroSpells()
    if self.macroChooser and self.macroChooser:IsShown() then
        self.macroChooser:Hide()
        return
    end

    local frame = self.macroChooser
    if not frame then
        frame = CreateFrame("Frame", "SPHelperMacroChooser", UIParent, "BackdropTemplate")
        frame:SetSize(540, 420)
        frame:SetPoint("CENTER")
        frame:SetFrameStrata("DIALOG")
        frame:SetToplevel(true)
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:SetClampedToScreen(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
        frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
        A.CreateBackdrop(frame, 0.045, 0.038, 0.060, 1, 0.30, 0.25, 0.42, 1)

        local title = frame:CreateFontString(nil, "OVERLAY")
        title:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
        title:SetPoint("TOP", frame, "TOP", 0, -10)
        title:SetText("SPHelper Fake Queue Macros")

        local closeBtn = CreateFrame("Button", nil, frame, "BackdropTemplate")
        closeBtn:SetSize(20, 20)
        closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)
        A.CreateBackdrop(closeBtn, 0.30, 0.08, 0.08, 0.95, 0.55, 0.18, 0.18, 1)
        local closeText = closeBtn:CreateFontString(nil, "OVERLAY")
        closeText:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
        closeText:SetPoint("CENTER")
        closeText:SetText("X")
        closeBtn:SetScript("OnClick", function() frame:Hide() end)

        local note = frame:CreateFontString(nil, "OVERLAY")
        note:SetFont("Fonts\\FRIZQT__.TTF", 9)
        note:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -34)
        note:SetWidth(500)
        note:SetJustifyH("LEFT")
        note:SetTextColor(0.76, 0.76, 0.82, 1)
        note:SetText("Select which macros to create or update. Existing macros are updated with the current helper body.")

        local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -60)
        scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -32, 58)
        local content = CreateFrame("Frame", nil, scroll)
        content:SetWidth(480)
        scroll:SetScrollChild(content)
        frame._content = content
        frame._rows = {}

        local function MakeButton(text, x, onClick)
            local btn = CreateFrame("Button", nil, frame, "BackdropTemplate")
            btn:SetSize(94, 24)
            btn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", x, 18)
            A.CreateBackdrop(btn, 0.13, 0.11, 0.18, 0.96, 0.34, 0.30, 0.48, 1)
            local fs = btn:CreateFontString(nil, "OVERLAY")
            fs:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
            fs:SetPoint("CENTER")
            fs:SetText(text)
            btn:SetScript("OnClick", onClick)
            return btn
        end

        MakeButton("Select All", 16, function()
            for _, row in ipairs(frame._rows or {}) do
                if row._check then row._check:SetChecked(true) end
            end
        end)
        MakeButton("Select None", 118, function()
            for _, row in ipairs(frame._rows or {}) do
                if row._check then row._check:SetChecked(false) end
            end
        end)
        MakeButton("Create", 328, function()
            local selected = {}
            for _, row in ipairs(frame._rows or {}) do
                if row:IsShown() and row._check and row._check:GetChecked() and row._spellName then
                    selected[#selected + 1] = row._spellName
                end
            end
            if #selected == 0 then
                print("|cff8882d5SPHelper|r: No macros selected.")
                return
            end
            if InCombatLockdown and InCombatLockdown() then
                print("|cffff4444SPHelper|r: Macros cannot be created or updated while in combat.")
                return
            end
            A.ChannelHelper:CreateMacros(selected)
            frame:Hide()
            A.ChannelHelper:OpenMacroChooser()
        end)
        MakeButton("Close", 430, function() frame:Hide() end)

        frame:SetScript("OnShow", function()
            if type(UISpecialFrames) == "table" then
                local found = false
                for _, name in ipairs(UISpecialFrames) do
                    if name == "SPHelperMacroChooser" then found = true; break end
                end
                if not found then table.insert(UISpecialFrames, "SPHelperMacroChooser") end
            end
        end)
        frame:SetScript("OnHide", function()
            if type(UISpecialFrames) == "table" then
                for i, name in ipairs(UISpecialFrames) do
                    if name == "SPHelperMacroChooser" then table.remove(UISpecialFrames, i); break end
                end
            end
        end)

        self.macroChooser = frame
    end

    local content = frame._content
    for _, row in ipairs(frame._rows or {}) do row:Hide() end
    wipe(frame._rows)

    if #spells == 0 then
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(480, 30)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -4)
        local text = row:CreateFontString(nil, "OVERLAY")
        text:SetFont("Fonts\\FRIZQT__.TTF", 10)
        text:SetPoint("LEFT", row, "LEFT", 8, 0)
        text:SetTextColor(0.85, 0.85, 0.85, 1)
        text:SetText("No Fake Queue macro-enabled spells were found for the active rotation.")
        frame._rows[1] = row
        content:SetHeight(40)
    else
        for index, spellName in ipairs(spells) do
            local row = CreateFrame("Frame", nil, content, "BackdropTemplate")
            row:SetSize(480, 54)
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -((index - 1) * 58))
            A.CreateBackdrop(row, 0.07, 0.06, 0.09, 0.96, 0.28, 0.24, 0.34, 1)
            row._spellName = spellName

            local check = CreateFrame("CheckButton", nil, row)
            check:SetSize(22, 22)
            check:SetPoint("LEFT", row, "LEFT", 8, 0)
            check:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
            check:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
            check:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
            check:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
            check:SetChecked(true)
            row._check = check

            local icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetSize(32, 32)
            icon:SetPoint("LEFT", check, "RIGHT", 8, 0)
            icon:SetTexture(GetMacroIconForSpell(spellName))

            local macroName = "SPH: " .. spellName
            local exists = (GetMacroIndexByName(macroName) or 0) > 0
            local nameText = row:CreateFontString(nil, "OVERLAY")
            nameText:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
            nameText:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -5)
            nameText:SetWidth(380)
            nameText:SetJustifyH("LEFT")
            nameText:SetText(macroName .. (exists and "  |cff66dd88update|r" or "  |cffffcc00new|r"))

            local bodyText = row:CreateFontString(nil, "OVERLAY")
            bodyText:SetFont("Fonts\\FRIZQT__.TTF", 8)
            bodyText:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -24)
            bodyText:SetWidth(380)
            bodyText:SetJustifyH("LEFT")
            bodyText:SetTextColor(0.68, 0.68, 0.74, 1)
            bodyText:SetText((self:GetMacroText(spellName) or ""):gsub("\n", "  /  "))

            frame._rows[#frame._rows + 1] = row
        end
        content:SetHeight((#spells * 58) + 8)
    end

    frame:Show()
end

------------------------------------------------------------------------
-- Event handler frame
------------------------------------------------------------------------
do
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
    frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
    frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_UPDATE")
    frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

    frame:SetScript("OnEvent", function(self, event, ...)
        if event == "UNIT_SPELLCAST_CHANNEL_START" then
            local unit, _, spellID = ...
            if unit ~= "player" then return end
            -- Use the server-reported startTimeMS for accurate tick prediction.
            -- UnitChannelInfo: name, text, texture, startTimeMS, endTimeMS, ...
            local name, _, _, startMS, endMS = UnitChannelInfo("player")
            if name and startMS and endMS then
                local startTime = startMS / 1000  -- server-synced; same clock as GetTime()
                local endTime   = endMS   / 1000
                CH:OnChannelStart(name, startTime, endTime, spellID)
            end

        elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
            local unit = ...
            if unit ~= "player" then return end
            CH:OnChannelStop()

        elseif event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
            local unit = ...
            if unit ~= "player" then return end
            local _, _, _, _, endMS = UnitChannelInfo("player")
            if endMS then
                CH:OnChannelUpdate(endMS / 1000)
            end

        elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
            local _, subEvent, _, sourceGUID, _, _, _, _, _, _, _, _, cleuSpellName = CombatLogGetCurrentEventInfo()
            if sourceGUID ~= UnitGUID("player") then return end
            if subEvent == "SPELL_PERIODIC_DAMAGE" and CH._state.active and cleuSpellName == CH._state.spellName then
                CH:OnTick()
            end
        end
    end)

    -- OnUpdate: refresh castbar overlay
    frame:SetScript("OnUpdate", function(self, elapsed)
        if CH._state.active then
            CH:UpdateCastbarOverlay()
        end
    end)

    CH._eventFrame = frame
end

------------------------------------------------------------------------
-- Register as SpecManager helper
------------------------------------------------------------------------
if A.SpecManager then
    A.SpecManager:RegisterHelper("ChannelHelper", {
        _initialized = false,
        OnSpecActivate = function(self, spec)
            if self._initialized then return end
            self._initialized = true
            CH:LoadChannelSpells(spec)
            CH:UpdateConfig(spec)
            -- Attach to existing castbar if available
            if A.castBarFrame then
                -- Attach to the inner StatusBar so pixel coordinates align with bar fill
                local barTarget = A.castBarFrame.bar or A.castBarFrame
                CH:AttachToCastbar(barTarget)
            end
        end,
        OnSpecDeactivate = function(self, spec)
            self._initialized = false
            CH:OnChannelStop()
            if CH._clipOverlay then CH._clipOverlay:Hide() end
        end,
    }, {
        exports = { "GetChannelTickWindow", "CanClipNow", "TimeToClip", "GetChannelRemaining", "GetChannelTickInterval", "GetChannelTicksRemaining", "GetChannelTimeToNextTick", "GetActiveChannelSpellKey", "AttachToCastbar" },
        depends = {},
    })
end
