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
CH.FAKE_QUEUE_SCRIPT_SAFE_MS = 150

local function ClampFakeQueueMaxMs(ms)
    ms = tonumber(ms) or 0
    if ms < 0 then ms = 0 end
    if ms > CH.FAKE_QUEUE_SCRIPT_SAFE_MS then
        ms = CH.FAKE_QUEUE_SCRIPT_SAFE_MS
    end
    return ms
end

function CH:GetEffectiveFakeQueueMaxMs()
    return ClampFakeQueueMaxMs(self._config and self._config.fakeQueueMaxMs or 0)
end

local function NormalizeChannelToken(value)
    if type(value) ~= "string" then return nil end
    value = value:gsub("[%s%-]+", "_")
    value = value:gsub("__+", "_")
    return string.upper(value)
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

    local normalized = {
        castType = "channel",
        spellKey = spellKey,
        spellName = spellName,
        ticks = ticks,
        fakeQueue = entry.fakeQueue ~= false,
        clipOverlay = entry.clipOverlay ~= false,
        tickSound = entry.tickSound ~= false,
        tickSoundTicks = entry.tickSoundTicks or {},
        tickFlash = entry.tickFlash ~= false,
        tickFlashTicks = entry.tickFlashTicks or {},
        tickMarkers = entry.tickMarkers ~= false,
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

    if spec and type(spec.channelSpells) == "table" then
        for _, cs in ipairs(spec.channelSpells) do
            AddEntry(cs, cs.spellKey or cs.key, cs.spellName or cs.name)
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
                AddEntry(info, info.spellKey or info.spellID or spellName, spellName)
            end
        end
    end

    return defs
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
        fakeQueue = ResolveFlag("fakeQueue", true),
        clipOverlay = ResolveFlag("clipOverlay", true),
        tickSound = ResolveFlag("tickSound", true),
        tickSoundTicks = def and def.tickSoundTicks or {},
        tickFlash = ResolveFlag("tickFlash", true),
        tickFlashTicks = def and def.tickFlashTicks or {},
        tickMarkers = ResolveFlag("tickMarkers", true),
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
    enabled          = true,
    clipCues         = true,
    fakeQueueEnabled = true,
    fakeQueueMaxMs   = CH.FAKE_QUEUE_SCRIPT_SAFE_MS,
    clipMarginMs     = 50,
    -- FQ precision tuning --------------------------------------------------
    -- fqFireOffsetMs: milliseconds added to the predicted tick time before
    -- the FQ busy-wait exits.  0 = fire at the predicted tick; negative =
    -- fire that many ms before the tick (pre-compensates for network lag so
    -- the cast reaches the server at tick time).  Typical ideal value:
    --   -(oneWayLatency_ms)  →  cast arrives at server right at the tick.
    -- Tune using the diagnostic output printed after each FQ activation.
    fqFireOffsetMs   = 30,  -- safety buffer ms on top of baked-in latency compensation
    -- fqDiag: when true, print per-tick timing diagnostics after each FQ.
    fqDiag           = true,
    -- fqAutoAdjust: [EXPERIMENTAL] when true, automatically nudge fqFireOffsetMs each
    -- tick to drive the EMA drift toward 0.  Requires fqDiag data (needs ~5 warmup ticks).
    fqAutoAdjust     = false,
    -- Allow negative fq offsets when explicitly enabled in the spec UI.
    fqAllowNegative  = false,
    inputLagMs       = 0,   -- populated from GetNetStats
}

------------------------------------------------------------------------
-- Known channeled spells and their tick counts.
-- Populated from spec.channelSpells on activate; falls back to this
-- default table if no spec data is available.
------------------------------------------------------------------------
CH.KNOWN_CHANNELS = {
    ["Mind Flay"] = { castType = "channel", ticks = 3, fakeQueue = true, clipOverlay = true, tickSound = true, tickFlash = true, tickMarkers = true },
}

------------------------------------------------------------------------
-- Update KNOWN_CHANNELS from spec's channelSpells data
------------------------------------------------------------------------
function CH:LoadChannelSpells(spec)
    self.KNOWN_CHANNELS = {}
    local defs = self:GetChannelSpellDefinitions(spec)
    self._channelSpellDefs = defs
    for _, cs in ipairs(defs) do
        if cs.spellName then
            local prefix = "cs_" .. (cs.spellKey or "") .. "_"
            self.KNOWN_CHANNELS[cs.spellName] = {
                castType    = "channel",
                ticks       = cs.ticks or 3,
                fakeQueue   = A.SpecVal(prefix .. "fakeQueue",   cs.fakeQueue ~= false),
                clipOverlay = A.SpecVal(prefix .. "clipOverlay", cs.clipOverlay ~= false),
                tickSound   = A.SpecVal(prefix .. "tickSound",  cs.tickSound ~= false),
                tickSoundTicks = A.SpecVal(prefix .. "tickSoundTicks", cs.tickSoundTicks or {}),
                tickFlash   = A.SpecVal(prefix .. "tickFlash",  cs.tickFlash ~= false),
                tickFlashTicks = A.SpecVal(prefix .. "tickFlashTicks", cs.tickFlashTicks or {}),
                tickMarkers = A.SpecVal(prefix .. "tickMarkers", cs.tickMarkers ~= false),
                tickMarkerMode  = A.SpecVal(prefix .. "tickMarkerMode",  cs.tickMarkerMode or "all"),
                tickMarkerTicks = A.SpecVal(prefix .. "tickMarkerTicks", cs.tickMarkerTicks or {}),
                spellKey    = cs.spellKey,
            }
        end
    end
end

------------------------------------------------------------------------
-- Update configuration from spec constants and DB
------------------------------------------------------------------------
function CH:UpdateConfig(spec)
    if not spec then return end
    local timing = spec.constants and spec.constants.timing
    local rawMaxMs
    if timing then
        -- Use spec-level settings first (from uiOptions/DB), fallback to spec constants
        rawMaxMs = A.SpecVal("fakeQueueMaxMs", timing.fakeQueueMaxMs or CH.FAKE_QUEUE_SCRIPT_SAFE_MS)
        self._config.clipMarginMs    = A.SpecVal("clipMarginMs",    timing.clipMarginMs    or 50)
        self._config.fqFireOffsetMs  = A.SpecVal("fqFireOffsetMs",  timing.fqFireOffsetMs  or 0)
    else
        rawMaxMs = A.SpecVal("fakeQueueMaxMs", CH.FAKE_QUEUE_SCRIPT_SAFE_MS)
        self._config.clipMarginMs    = A.SpecVal("clipMarginMs",    50)
        self._config.fqFireOffsetMs  = A.SpecVal("fqFireOffsetMs",  0)
    end
    self._config.fakeQueueMaxMs = ClampFakeQueueMaxMs(rawMaxMs)
    -- Read from per-spec DB
    self._config.fakeQueueEnabled = A.SpecVal("channelFakeQueue", true)
    self._config.clipCues         = A.SpecVal("channelClipCues",  true)
    local diagVal = A.SpecVal("fqDiag", true)
    self._config.fqDiag = (diagVal == true or diagVal == 1)
    local autoVal = A.SpecVal("fqAutoAdjust", false)
    self._config.fqAutoAdjust = (autoVal == true or autoVal == 1)
    local allowNeg = A.SpecVal("fqAllowNegative", false)
    self._config.fqAllowNegative = (allowNeg == true or allowNeg == 1)

    if tonumber(rawMaxMs) and tonumber(rawMaxMs) > self._config.fakeQueueMaxMs then
        if A.SetSpecVal then
            pcall(A.SetSpecVal, "fakeQueueMaxMs", self._config.fakeQueueMaxMs)
        end
        if not self._warnedFakeQueueCap then
            self._warnedFakeQueueCap = true
            print(string.format(
                "|cff8882d5SPHelper|r: FQ max hold capped at |cffffcc00%dms|r to avoid macro script timeouts.",
                self._config.fakeQueueMaxMs))
        end
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
    -- If an FQ run happened but the target tick never arrived, report a
    -- clipped event so the user can see that the release did not produce
    -- the awaited tick. This helps identify when an early release skipped
    -- the tick (clipped too soon).
    if self._fqLastHeldMs and self._fqTargetTickN and (self._state.ticksSoFar < self._fqTargetTickN) then
        if self._config.fqDiag then
            local held = self._fqLastHeldMs or 0
            print(string.format("|cff8882d5SPHelper|r: FQ held |cffffcc00%dms|r — tick did NOT occur |cffff4444(clipped)|r", held))
            print(string.format("|cff8882d5SPHelper FQ diag|r target tick=%d/%d  lat=%dms  off=%dms",
                self._fqTargetTickN or 0, self._state.tickCount or 0, math.floor((self._state.latency or 0) * 1000), self._config.fqFireOffsetMs))
        end
    end

    -- Clear any pending FQ state
    self._fqExitDbp     = nil
    self._fqTargetTickN = nil
    self._fqLastHeldMs  = nil
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
    self:_RecalcClipWindow()
end

function CH:OnTick()
    if not self._state.active then return end
    -- Record precise arrival time FIRST, before any work, for accurate delta.
    local cleuDbp = debugprofilestop()
    self._state.ticksSoFar = self._state.ticksSoFar + 1

    -- Drift diagnostic: how long before/after the actual CLEU did the FQ exit?
    -- delta_ms < 0: FQ exited BEFORE this tick CLEU arrived (good, cast queued early)
    -- delta_ms > 0: FQ exited AFTER  this tick CLEU arrived (bad, visible delay)
    if self._fqExitDbp
       and self._fqTargetTickN == self._state.ticksSoFar then
        local delta_ms = self._fqExitDbp - cleuDbp   -- fqExit relative to CLEU arrival
        -- Running EMA (smoother: heavier history to reduce noise)
        if not self._fqDriftEMA then self._fqDriftEMA = delta_ms end
        local hist_w, samp_w = 0.85, 0.15
        self._fqDriftEMA = self._fqDriftEMA * hist_w + delta_ms * samp_w
        self._fqSampleCount = (self._fqSampleCount or 0) + 1
        -- Friendly summary for the user: show how long the FQ held and how
        -- long between release and the tick arrival. Color the number green
        -- when the tick occurred after the release (good), red when the
        -- tick occurred before the release (release too late) — see
        -- OnChannelStop for the case where the tick never occurred.
        if self._config.fqDiag then
            local held_ms = self._fqLastHeldMs or 0
            local rel_ms = math.floor((cleuDbp - self._fqExitDbp) + 0.5)  -- positive => tick after release
            local col = rel_ms >= 0 and "|cff00ff00" or "|cffff4444"
            local rel_text = string.format("%+dms", rel_ms)
            print(string.format("|cff8882d5SPHelper|r: FQ held |cffffcc00%dms|r  —  tick %s%s|r", held_ms, col, rel_text))
        end

        -- No transient overlay action here; overlay is shown continuously
        -- for the clip window while channeling (handled in UpdateCastbarOverlay).

        -- Detailed diagnostics printed only when enabled.
        -- With latency baked in, ideal delta_ms = -(2*lat_ms) + fqFireOffsetMs.
        -- When offset=0: cast arrives AT the tick → delta = -(2*lat_ms).
        -- When offset=+N: cast arrives N ms after tick → delta = -(2*lat_ms)+N.
        if self._config.fqDiag then
            local lat_ms = math.floor(self._state.latency * 1000)
            -- SAFETY_MS is the built-in buffer above the tick boundary.
            local SAFETY_MS = 30
            local ideal = -(2 * lat_ms) + SAFETY_MS  -- e.g. lat=82 → -164+30 = -134ms
            print(string.format(
                "|cff8882d5SPHelper FQ diag|r t%d/%d  delta |cffffcc00%+.0fms|r  avg |cffffcc00%+.0fms|r  ideal %+dms  lat=%dms  off=%+dms",
                self._state.ticksSoFar, self._state.tickCount,
                delta_ms, self._fqDriftEMA, ideal, lat_ms,
                self._config.fqFireOffsetMs))
        end
        if self._config.fqAutoAdjust then
            local warmupSamples = 8
            local gain    = 0.15  -- fraction of error per step
            local maxStep = 10    -- ms cap per step
            local deadband = 5    -- ignore errors smaller than this (ms)
            -- SAFETY_MS: target cast arrival N ms after tick, not at the boundary.
            -- With latency baked in, ideal delta = -(2*lat) + SAFETY_MS.
            -- Offset = 0 is the minimum safe point; auto-tune aims for +SAFETY_MS.
            local SAFETY_MS = 30
            if (self._fqSampleCount or 0) >= warmupSamples then
                local lat_ms = math.floor(self._state.latency * 1000)
                local ideal  = -(2 * lat_ms) + SAFETY_MS
                -- Hard floor: by default offset must stay >= 0 to avoid early
                -- releases that bypass baked-in latency compensation.
                -- If the spec explicitly enables negative offsets, allow a
                -- reasonable negative range for advanced users.
                local hardFloor = (self._config.fqAllowNegative and -200) or 0
                local err = self._fqDriftEMA - ideal
                if math.abs(err) > deadband then
                    local raw = math.abs(err * gain)
                    local s = math.floor(raw + 0.5)
                    if s > maxStep then s = maxStep end
                    local step = (err >= 0) and s or -s
                    local newOff = math.min(200,
                        math.max(hardFloor,
                            self._config.fqFireOffsetMs - step))
                    if newOff ~= self._config.fqFireOffsetMs then
                        self._config.fqFireOffsetMs = newOff
                        if A.SetSpecVal then pcall(A.SetSpecVal, "fqFireOffsetMs", newOff) end
                        -- If the SpecUI is open on the CastBar tab, refresh it so
                        -- the slider reflects the new DB value immediately.
                        pcall(function()
                            if A.SpecUI and A.SpecUI.frame and A.SpecUI.frame:IsShown() and A.SpecUI._activeTab == 4 then
                                if A.SpecUI.RefreshCurrentTab then
                                    A.SpecUI:RefreshCurrentTab()
                                else
                                    A.SpecUI:SwitchTab(4, nil, true)
                                end
                            end
                        end)
                        if self._config.fqDiag then
                            print(string.format(
                                "|cff8882d5SPHelper FQ auto-tune|r: err |cffffcc00%+.0fms|r ideal %+dms step %+dms -> offset -> |cffffcc00%+dms|r",
                                err, ideal, step, newOff))
                        end
                    end
                end
            end
        end
    end
    -- Clear FQ state so we do not process diagnostics for ticks that had no FQ.
    self._fqExitDbp     = nil
    self._fqTargetTickN = nil
    self._fqLastHeldMs  = nil

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
        local fqExtend = self:GetEffectiveFakeQueueMaxMs() / 1000
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

    -- Render one persistent zone per shown tick marker.
    local overlayAfter = 0.1 -- seconds shown after the tick (100ms)
    local fqExtend = (self._config.fakeQueueEnabled and self:GetEffectiveFakeQueueMaxMs() / 1000) or 0
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
-- It will busy-wait up to fakeQueueMaxMs if MF is being channeled
-- and the clip window hasn't opened yet, so the next /cast fires
-- at the optimal moment.
------------------------------------------------------------------------

function CH:FakeQueue()
    if not self._state.active then return end
    if not self._config.fakeQueueEnabled then return end
    if self._activeChannelInfo and self._activeChannelInfo.fakeQueue == false then return end

    local s = self._state
    local maxWaitMs = self:GetEffectiveFakeQueueMaxMs()
    local maxWait = maxWaitMs / 1000
    if maxWait <= 0 then return end

    -- ---------------------------------------------------------------
    -- Compute the next upcoming tick time we should wait for.
    --
    -- The cast travels to the server in one-way latency (lat_s seconds).
    -- To arrive exactly AT the server tick:
    --   release at: T_tick - lat_s
    -- fqFireOffsetMs adds a fine-tune buffer ON TOP of that compensation:
    --   0ms   = release exactly at T_tick - lat_s  (boundary: cast arrives at tick)
    --   +30ms = release 30ms later   → cast arrives 30ms AFTER tick (safe)
    --   -20ms = release 20ms earlier → cast arrives 20ms BEFORE tick (risky/clipped)
    -- Latency compensation (-lat_s) is baked in; offset is only a small adjustment.
    -- ---------------------------------------------------------------
    local lat_s      = s.latency            -- one-way latency in seconds
    local fineOffset = self._config.fqFireOffsetMs / 1000  -- fine-tune seconds
    local now        = GetTime()

    local targetTime = nil
    local targetTickN = nil
    for n = (s.ticksSoFar + 1), s.tickCount do
        -- T_tick - lat_s = exact release for cast to arrive at server tick.
        -- + fineOffset adds the small user/auto-tune buffer.
        local tickTime = s.startTime + (n * s.tickInterval) - lat_s + fineOffset
        if tickTime > now then
            targetTime  = tickTime
            targetTickN = n
            break
        end
    end

    if not targetTime then return end  -- no upcoming ticks

    local needed = targetTime - now

    -- Skip if the target is more than maxWait away (would freeze too long)
    -- or already past (nothing to wait for).
    if needed > maxWait then
        if self._config and self._config.fqDiag then
            local now2 = GetTime()
            if not self._lastFQSkipPrint or (now2 - self._lastFQSkipPrint) >= 2.0 then
                self._lastFQSkipPrint = now2
                print(string.format(
                    "|cff8882d5SPHelper|r: FQ skipped |cffffcc00%dms|r wait exceeds safe macro budget |cffffcc00%dms|r",
                    math.floor((needed * 1000) + 0.5),
                    maxWaitMs))
            end
        end
        return
    end
    if needed <= 0 then return end

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

    -- Record exit timestamp for drift diagnostic in OnTick().
    self._fqExitDbp     = debugprofilestop()
    self._fqTargetTickN = targetTickN
    -- Save held duration (ms) so OnTick / OnChannelStop can report it later
    self._fqLastHeldMs   = math.floor(needed_ms + 0.5)

    -- Throttled console notice (shows wait only; detailed tick timing printed in OnTick)
    local waited_ms = math.floor(needed_ms + 0.5)
    if waited_ms >= 1 and self._config and self._config.fqDiag then
        local now2 = GetTime()
        if not CH._lastFQPrint or (now2 - CH._lastFQPrint) >= 2.0 then
            CH._lastFQPrint = now2
            print(string.format("|cff8882d5SPHelper|r: FQ held |cffffcc00%dms|r", waited_ms))
        end
    end
end

-- Expose global function for macros
SPH_FQ = function()
    if A.ChannelHelper then
        A.ChannelHelper:FakeQueue()
    end
end

------------------------------------------------------------------------
-- Macro generator
------------------------------------------------------------------------

function CH:GetMacroText(spellName)
    if not spellName and self._channelSpellDefs and self._channelSpellDefs[1] then
        spellName = self._channelSpellDefs[1].spellName
    end
    return "/run SPH_FQ()\n/cast " .. (spellName or "Mind Blast")
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
function CH:GetMacroSpells()
    local spells = {}
    if self._channelSpellDefs and #self._channelSpellDefs > 0 then
        for _, cs in ipairs(self._channelSpellDefs) do
            if cs.spellName then
                spells[#spells + 1] = cs.spellName
            end
        end
    elseif self.KNOWN_CHANNELS then
        for spellName in pairs(self.KNOWN_CHANNELS) do
            spells[#spells + 1] = spellName
        end
        table.sort(spells)
    end
    if #spells == 0 then
        if self.GetChannelSpellDefinitions then
            local defs = self:GetChannelSpellDefinitions(nil)
            for _, cs in ipairs(defs or {}) do
                if cs.spellName then
                    spells[#spells + 1] = cs.spellName
                end
            end
        end
        if #spells == 0 then
            spells = { "Mind Flay" }
        end
    end
    return spells
end

--- Automatically create FQ macros for the active spec's rotation spells.
--- Uses CreateMacro() API. Only creates macros that don't already exist.
--- Returns the number of macros created.
function CH:CreateMacros()
    local spells = self:GetMacroSpells()
    local created = 0
    local skipped = 0
    local failed = 0

    for _, spellName in ipairs(spells) do
        local macroName = "SPH: " .. spellName
        -- Check if macro already exists
        local existingIdx = GetMacroIndexByName(macroName)
        if existingIdx and existingIdx > 0 then
            -- Update the existing macro body in case it changed
            local body = self:GetMacroText(spellName)
            local iconTexture = A.GetSpellIconCached and A.GetSpellIconCached(spellName) or select(3, GetSpellInfo(spellName))
            if not iconTexture then
                local spellData
                for _, sd in pairs(A.SPELLS) do
                    if sd.name == spellName then spellData = sd; break end
                end
                if spellData then
                    iconTexture = (A.GetSpellIconCached and A.GetSpellIconCached(spellData.id)) or select(3, GetSpellInfo(spellData.id))
                end
            end
            EditMacro(existingIdx, macroName, iconTexture or "INV_MISC_QUESTIONMARK", body)
            skipped = skipped + 1
        else
            local body = self:GetMacroText(spellName)
            -- Get the spell icon
            local iconTexture = A.GetSpellIconCached and A.GetSpellIconCached(spellName) or select(3, GetSpellInfo(spellName))
            if not iconTexture then
                local spellData
                for _, sd in pairs(A.SPELLS) do
                    if sd.name == spellName then spellData = sd; break end
                end
                if spellData then
                    iconTexture = (A.GetSpellIconCached and A.GetSpellIconCached(spellData.id)) or select(3, GetSpellInfo(spellData.id))
                end
            end
            -- Try per-character macros first (slot 19–36 in TBC), fallback to general
            local ok, result = pcall(CreateMacro, macroName,
                iconTexture or "INV_MISC_QUESTIONMARK", body, 1)
            if ok and result then
                created = created + 1
            else
                -- Try general macro slot
                local ok2, result2 = pcall(CreateMacro, macroName,
                    iconTexture or "INV_MISC_QUESTIONMARK", body, nil)
                if ok2 and result2 then
                    created = created + 1
                else
                    failed = failed + 1
                end
            end
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
