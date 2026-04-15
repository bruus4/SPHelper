------------------------------------------------------------------------
-- SPHelper  –  ChannelHelper.lua
-- Tracks channeled spell ticks, provides clip-window calculations,
-- and optionally implements a fake-queue (FQ) busy-wait for precise
-- Mind Flay clipping.
--
-- Can operate standalone (visual/audio cues only) or attach to the
-- existing CastBar frame for integrated clip-zone display.
------------------------------------------------------------------------
local A = SPHelper

A.ChannelHelper = {}
local CH = A.ChannelHelper

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------
CH._state = {
    active          = false,
    spellID         = nil,
    spellName       = nil,
    startTime       = 0,
    endTime         = 0,
    totalDuration   = 0,
    tickCount       = 3,      -- MF always has 3 ticks in TBC
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
    fakeQueueMaxMs   = 189,
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
    ["Mind Flay"] = { ticks = 3, fakeQueue = true, clipOverlay = true, tickSound = true, tickFlash = true, tickMarkers = true },
}

------------------------------------------------------------------------
-- Update KNOWN_CHANNELS from spec's channelSpells data
------------------------------------------------------------------------
function CH:LoadChannelSpells(spec)
    if not spec or not spec.channelSpells then return end
    self.KNOWN_CHANNELS = {}
    for _, cs in ipairs(spec.channelSpells) do
        local spellName = cs.spellName
        if not spellName and cs.spellKey and A.SPELLS[cs.spellKey] then
            spellName = A.SPELLS[cs.spellKey].name
        end
        if spellName then
            local prefix = "cs_" .. (cs.spellKey or "") .. "_"
            self.KNOWN_CHANNELS[spellName] = {
                ticks       = cs.ticks or 3,
                fakeQueue   = A.SpecVal(prefix .. "fakeQueue",   cs.fakeQueue ~= false),
                clipOverlay = A.SpecVal(prefix .. "clipOverlay", cs.clipOverlay ~= false),
                tickSound   = A.SpecVal(prefix .. "tickSound",  cs.tickSound ~= false),
                tickFlash   = A.SpecVal(prefix .. "tickFlash",  cs.tickFlash ~= false),
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
    if timing then
        -- Use spec-level settings first (from uiOptions/DB), fallback to spec constants
        self._config.fakeQueueMaxMs  = A.SpecVal("fakeQueueMaxMs",  timing.fakeQueueMaxMs  or 189)
        self._config.clipMarginMs    = A.SpecVal("clipMarginMs",    timing.clipMarginMs    or 50)
        self._config.fqFireOffsetMs  = A.SpecVal("fqFireOffsetMs",  timing.fqFireOffsetMs  or 0)
    else
        self._config.fakeQueueMaxMs  = A.SpecVal("fakeQueueMaxMs",  189)
        self._config.clipMarginMs    = A.SpecVal("clipMarginMs",    50)
        self._config.fqFireOffsetMs  = A.SpecVal("fqFireOffsetMs",  0)
    end
    -- Read from per-spec DB
    self._config.fakeQueueEnabled = A.SpecVal("channelFakeQueue", true)
    self._config.clipCues         = A.SpecVal("channelClipCues",  true)
    local diagVal = A.SpecVal("fqDiag", true)
    self._config.fqDiag = (diagVal == true or diagVal == 1)
    local autoVal = A.SpecVal("fqAutoAdjust", false)
    self._config.fqAutoAdjust = (autoVal == true or autoVal == 1)
    local allowNeg = A.SpecVal("fqAllowNegative", false)
    self._config.fqAllowNegative = (allowNeg == true or allowNeg == 1)
end

------------------------------------------------------------------------
-- Channel start / stop / update
------------------------------------------------------------------------

function CH:OnChannelStart(spellName, startTime, endTime, spellID)
    local info = self.KNOWN_CHANNELS[spellName]
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

    self._state.active = false
    self._activeChannelInfo = nil
    if self._clipOverlay then self._clipOverlay:Hide() end
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
                                A.SpecUI:SwitchTab(4)
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
        local fqExtend = self._config.fakeQueueMaxMs / 1000
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
    local spellClip = self._activeChannelInfo and self._activeChannelInfo.clipOverlay ~= false
    if not self._state.active or not self._config.clipCues or not spellClip then
        if self._clipOverlay then self._clipOverlay:Hide() end
        return
    end

    local parent = self._attachedFrame
    if not parent or not parent:IsShown() then
        if self._clipOverlay then self._clipOverlay:Hide() end
        return
    end

    -- Create overlay texture on first use
    if not self._clipOverlay then
        local tex = parent:CreateTexture(nil, "OVERLAY")
        tex:SetColorTexture(0.3, 0.9, 0.3, 0.35)
        tex:SetHeight(parent:GetHeight())
        self._clipOverlay = tex
    end

    local s = self._state
    local totalDur = s.totalDuration
    if totalDur <= 0 then
        self._clipOverlay:Hide()
        return
    end

    local barWidth = parent:GetWidth()

    -- The SPHelper castbar shows REMAINING time (value = remaining / total, draining
    -- from 1 → 0 as the channel progresses).  So the bar's visual x-position is:
    --   x = barWidth * remainingFraction
    -- The clip window is defined in elapsed-time fractions:
    --   clipStartFrac ≈ 0.67 (elapsed) = 0.33 (remaining)
    --   clipEndFrac   ≈ 1.00 (elapsed) = 0.00 (remaining)
    -- Convert to REMAINING fractions so the overlay aligns with the draining bar:
    -- Compute per-tick overlay windows and display only those ticks that
    -- are near enough in time to warrant a visual. We pre-show the next
    -- tick by a small adaptive lead so the overlay moves to the next
    -- segment before the castbar reaches it.
    local overlayAfter = 0.1 -- seconds shown after the tick (100ms)
    local fqExtend = (self._config.fakeQueueEnabled and (self._config.fakeQueueMaxMs or 0) / 1000) or 0
    -- Pre-show lead: a small fraction of the tick interval, capped to avoid
    -- extremely early showing on long channels. This controls how early the
    -- next tick zone appears before its base start.
    local preShowLead = math.min(0.25, s.tickInterval * 0.45)
    local now = GetTime()
    local overlayStartSec, overlayEndSec
    for i = 1, s.tickCount do
        local tickTime = s.startTime + (i * s.tickInterval)
        local baseStart = tickTime - fqExtend         -- visual begins at baseStart
        local showThreshold = baseStart - preShowLead -- when to start showing this tick
        local endSec = tickTime + overlayAfter
        -- Skip ticks that don't overlap the channel
        if endSec >= s.startTime and baseStart <= s.endTime then
            -- Only include this tick's visual if we're past the show threshold
            -- (i.e., proactively show upcoming tick) and not long after it
            if now >= showThreshold and now <= endSec then
                local ds = math.max(baseStart, s.startTime)
                local de = math.min(endSec, s.endTime)
                overlayStartSec = overlayStartSec and math.min(overlayStartSec, ds) or ds
                overlayEndSec   = overlayEndSec   and math.max(overlayEndSec,   de) or de
            end
        end
    end

    if not overlayStartSec then
        self._clipOverlay:Hide()
        return
    end

    local clipStartFrac = (overlayStartSec - s.startTime) / totalDur
    local clipEndFrac   = (overlayEndSec   - s.startTime) / totalDur
    clipStartFrac = math.max(0, math.min(1, clipStartFrac))
    clipEndFrac   = math.max(0, math.min(1, clipEndFrac))

    -- Invert: remaining = 1 - elapsed
    local startPx = barWidth * (1 - clipEndFrac)    -- left edge of zone (closer to bar-end)
    local endPx   = barWidth * (1 - clipStartFrac)  -- right edge of zone
    local width   = endPx - startPx

    if width < 1 then
        self._clipOverlay:Hide()
        return
    end

    self._clipOverlay:ClearAllPoints()
    self._clipOverlay:SetPoint("LEFT", parent, "LEFT", startPx, 0)
    self._clipOverlay:SetWidth(width)
    self._clipOverlay:SetHeight(parent:GetHeight())
    self._clipOverlay:Show()
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

    local s       = self._state
    local maxWait = self._config.fakeQueueMaxMs / 1000

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
    if needed > maxWait then return end
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
    local seen = {}
    -- Collect all spells from active spec's rotation
    if A.SpecManager then
        local activeSpecs = A.SpecManager:GetActiveSpecs()
        for _, spec in pairs(activeSpecs) do
            if spec.rotation then
                for _, entry in ipairs(spec.rotation) do
                    local key = entry.key
                    if key and A.SPELLS[key] and A.SPELLS[key].name and not seen[key] then
                        seen[key] = true
                        spells[#spells + 1] = A.SPELLS[key].name
                    end
                end
            end
            break  -- only use first active spec
        end
    end
    -- Fallback if no spec or empty rotation
    if #spells == 0 then
        spells = { "Mind Blast", "Shadow Word: Death", "Shadow Word: Pain",
                   "Vampiric Touch", "Devouring Plague", "Mind Flay" }
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
