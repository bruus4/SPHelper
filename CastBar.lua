------------------------------------------------------------------------
-- SPHelper  –  CastBar.lua
-- Player cast / channel bar with tick markers & clip indicator.
-- Handles spell pushback via UNIT_SPELLCAST_DELAYED / CHANNEL_UPDATE.
-- CLIP shows when the ChannelHelper clip window is open.
------------------------------------------------------------------------
local A = SPHelper

-- Tick feedback (sound/flash) is handled by shared helpers in Core.lua
-- (`A.PlayTickSound`, `A.DoTickFlash`, `A.InitTickManager`). InitCastBar
-- will initialize the shared tick manager so ticks can be shown even when
-- the cast bar UI is disabled (if the setting is enabled).

function A:InitCastBar()
    local db = A.db.castBar
    if not db.enabled then return end

    local BAR_W = db.width
    local BAR_H = db.height

    ----------------------------------------------------------------
    -- Main frame
    ----------------------------------------------------------------
    local f = CreateFrame("Frame", "SPHelperCastBar", UIParent, "BackdropTemplate")
    f:SetSize(BAR_W + 2, BAR_H + 2)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) if not A.db.locked then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    A.CreateBackdrop(f)
    A.castBarFrame = f

    ----------------------------------------------------------------
    -- Status bar
    ----------------------------------------------------------------
    local bar = CreateFrame("StatusBar", nil, f)
    bar:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
    bar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar:SetStatusBarColor(unpack(A.COLORS.DEFAULT or A.COLORS.MF or {0.5, 0.5, 1, 1}))
    f.bar = bar

    local spark = bar:CreateTexture(nil, "OVERLAY")
    spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    spark:SetSize(16, BAR_H + 8)
    spark:SetBlendMode("ADD")
    spark:Hide()
    f.spark = spark

    ----------------------------------------------------------------
    -- Spell name text (left)
    ----------------------------------------------------------------
    local spellName = bar:CreateFontString(nil, "OVERLAY")
    spellName:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    spellName:SetPoint("LEFT", bar, "LEFT", 4, 0)
    spellName:SetJustifyH("LEFT")
    spellName:SetTextColor(unpack(A.COLORS.TEXT))
    f.spellNameText = spellName

    ----------------------------------------------------------------
    -- Timer text (right)
    ----------------------------------------------------------------
    local timer = bar:CreateFontString(nil, "OVERLAY")
    timer:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    timer:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    timer:SetJustifyH("RIGHT")
    timer:SetTextColor(unpack(A.COLORS.TEXT))
    f.timerText = timer

    ----------------------------------------------------------------
    -- Tick markers (created dynamically per channel spell tick count)
    ----------------------------------------------------------------
    f.tickMarkers = {}
    local MAX_TICK_MARKERS = 10
    for i = 1, MAX_TICK_MARKERS do
        local t = bar:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(1, 1, 1, 0.7)
        t:SetSize(2, BAR_H)
        t:SetPoint("CENTER", bar, "LEFT", 0, 0)
        t:Hide()
        f.tickMarkers[i] = t
    end

    ----------------------------------------------------------------
    -- "CLIP" text overlay
    ----------------------------------------------------------------
    local clipText = bar:CreateFontString(nil, "OVERLAY")
    clipText:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    clipText:SetPoint("TOP", f, "BOTTOM", 0, -2)
    clipText:SetTextColor(unpack(A.COLORS.SAFE))
    -- Do not show literal "CLIP" text; keep string empty so only the
    -- overlay/visual cue is used. The preview used to force this text,
    -- but users requested removing the label.
    clipText:SetText("")
    clipText:Hide()
    f.clipText = clipText

    ----------------------------------------------------------------
    -- Tick counter text e.g. "2/3"
    ----------------------------------------------------------------
    local tickCounter = bar:CreateFontString(nil, "OVERLAY")
    tickCounter:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    tickCounter:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", -2, -2)
    tickCounter:SetTextColor(unpack(A.COLORS.TEXT))
    tickCounter:Hide()
    f.tickCounterText = tickCounter

    

    ----------------------------------------------------------------
    -- State variables
    ----------------------------------------------------------------
    f.casting     = false
    f.channeling  = false
    f.isMindFlay  = false
    f.startTime   = 0
    f.endTime     = 0
    f.tickCount   = 0
    f.ticksDone   = 0
    f.spellName   = ""
    f.clipSafe    = false
    f._preview    = false

    ----------------------------------------------------------------
    -- Colour helper — built from spec's channelSpells color keys, or falls
    -- back to A.COLORS.DEFAULT for any spell not explicitly mapped.
    ----------------------------------------------------------------
    local function BuildColorMap()
        local map = {}
        local CH = A.ChannelHelper
        if CH and CH.KNOWN_CHANNELS then
            for spellName, info in pairs(CH.KNOWN_CHANNELS) do
                if info.spellKey and A.COLORS[info.spellKey] then
                    map[spellName] = A.COLORS[info.spellKey]
                end
            end
        end
        -- Also map any A.SPELLS entry that has a matching color key
        for key, spell in pairs(A.SPELLS) do
            if spell.name and A.COLORS[key] then
                map[spell.name] = A.COLORS[key]
            end
        end
        return map
    end
    local localColorMap = BuildColorMap()

    local function BarColorForSpell(name)
        return localColorMap[name] or A.COLORS.DEFAULT
    end

    ----------------------------------------------------------------
    -- Show / hide helpers
    ----------------------------------------------------------------
    local function ShowBar(name, startMS, endMS, isChannel)
        f.spellName  = name or ""
        f.startTime  = startMS / 1000
        f.endTime    = endMS   / 1000
        f.casting    = not isChannel
        f.channeling = isChannel
        f.ticksDone  = 0
        f.clipSafe   = false

        f.isMindFlay = false  -- kept for backward compat; use f.isTrackedChannel instead

        -- Check if this is any tracked channel spell (data-driven)
        local CH = A.ChannelHelper
        local channelInfo = isChannel and CH and CH.KNOWN_CHANNELS and CH.KNOWN_CHANNELS[name]
        f.isTrackedChannel = channelInfo ~= nil
        f.channelInfo      = channelInfo
        f.tickCount  = channelInfo and channelInfo.ticks or (f.isMindFlay and 3 or 0)
        f._earlyTickFired = {}  -- reset early tick feedback tracker

        local col
        if A.db and A.db.castBar and A.db.castBar.colorMode == "solid" and A.db.castBar.color then
            col = A.db.castBar.color
        else
            col = BarColorForSpell(name)
        end
        f.bar:SetStatusBarColor(unpack(col))
        f.spellNameText:SetText(name or "")

        for i, t in ipairs(f.tickMarkers) do
            local showMarkers = f.isTrackedChannel and (not f.channelInfo or f.channelInfo.tickMarkers ~= false)
            if showMarkers and i <= f.tickCount then
                local frac = (f.tickCount - i) / f.tickCount
                t:ClearAllPoints()
                t:SetPoint("CENTER", bar, "LEFT", BAR_W * frac, 0)
                t:SetColorTexture(1, 1, 1, 0.7)
                -- Per-spell tick marker mode (falls back to global setting)
                local mode = f.channelInfo and f.channelInfo.tickMarkerMode
                if not mode or mode == "" then
                    mode = A.SpecVal and A.SpecVal("tickMarkers", "all") or "all"
                end
                if mode == "all" then
                    t:Show()
                elseif mode == "remaining" then
                    t:Show()  -- will be hidden via OnUpdate as ticks complete
                elseif mode == "specific" then
                    local ticks = f.channelInfo and f.channelInfo.tickMarkerTicks or {}
                    local show = false
                    for _, tn in ipairs(ticks) do
                        if tonumber(tn) == i then show = true; break end
                    end
                    if show then t:Show() else t:Hide() end
                else
                    t:Hide()
                end
            else
                t:Hide()
            end
        end

        f.clipText:Hide()
        f.tickCounterText:Hide()
        if f.isTrackedChannel then
            f.tickCounterText:SetText("0/" .. f.tickCount)
            f.tickCounterText:Show()
        end

        f:Show()
    end

    local function HideBar()
        f.casting    = false
        f.channeling = false
        f.isMindFlay = false
        f.isTrackedChannel = false
        f.channelInfo = nil
        f.clipSafe   = false
        f._preview   = false
        f.clipText:Hide()
        f.tickCounterText:Hide()
        for _, t in ipairs(f.tickMarkers) do t:Hide() end
        f:Hide()
    end

    ----------------------------------------------------------------
    -- Resize helper (called from Config)
    ----------------------------------------------------------------
    A.CastBarResizeLayout = function()
        local db = A.db.castBar
        BAR_W = db.width
        BAR_H = db.height
        f:SetSize(BAR_W + 2, BAR_H + 2)
        f.spark:SetSize(16, BAR_H + 8)
        for i = 1, #f.tickMarkers do
            f.tickMarkers[i]:SetSize(2, BAR_H)
        end
    end

    ----------------------------------------------------------------
    -- Preview support
    ----------------------------------------------------------------
    A.CastBarPreviewOn = function()
        f._preview = true
        -- Find a tracked channel spell for the preview
        local previewName = nil
        local previewTicks = 3
        local CH = A.ChannelHelper
        if CH and CH.KNOWN_CHANNELS then
            for name, info in pairs(CH.KNOWN_CHANNELS) do
                previewName = name
                previewTicks = info.ticks or 3
                break
            end
        end
        if not previewName then
            previewName = "Channel"
        end
        f.spellName = previewName
        f.startTime = GetTime()
        f.endTime   = GetTime() + (previewTicks * 1.0)
        f.casting   = false
        f.channeling = true
        f.isMindFlay = false
        f.isTrackedChannel = true
        f.channelInfo = CH and CH.KNOWN_CHANNELS and CH.KNOWN_CHANNELS[previewName]
        f.tickCount  = previewTicks
        f.ticksDone  = 1
        f.clipSafe   = true
        local col
        if A.db and A.db.castBar and A.db.castBar.colorMode == "solid" and A.db.castBar.color then
            col = A.db.castBar.color
        else
            col = BarColorForSpell(previewName)
        end
        f.bar:SetStatusBarColor(unpack(col))
        f.spellNameText:SetText(previewName)
        f.tickCounterText:SetText("1/" .. previewTicks)
        f.tickCounterText:Show()
        -- Intentionally do not show textual "CLIP" label in preview.
        for i, t in ipairs(f.tickMarkers) do
            local frac = (previewTicks - i) / previewTicks
            t:ClearAllPoints()
            t:SetPoint("CENTER", bar, "LEFT", BAR_W * frac, 0)
            local mode = (A.db and A.db.castBar and A.db.castBar.tickMarkers) or "all"
            if mode == "all" and i <= previewTicks then
                if i <= f.ticksDone then
                    t:SetColorTexture(unpack(A.COLORS.SAFE))
                else
                    t:SetColorTexture(1, 1, 1, 0.7)
                end
                t:Show()
            else
                t:Hide()
            end
        end
        f.bar:SetValue(0.66)
        f.timerText:SetText("2.0")
        f:Show()
    end

    A.CastBarPreviewOff = function()
        if f._preview then HideBar() end
    end

    ----------------------------------------------------------------
    -- Channel clip logic
    -- Show CLIP whenever a tracked channel has hit at least 1 tick AND
    -- the ChannelHelper clip window is open (or no CH available — always show).
    ----------------------------------------------------------------
    local function ShouldClip()
        if not f.isTrackedChannel or f.ticksDone < 1 then return false end
        local CH = A.ChannelHelper
        if CH and CH._state and CH._state.active then
            local now = GetTime()
            return now >= CH._state.clipWindowStart
        end
        -- Fallback: show CLIP after first tick when CH is unavailable
        return true
    end

    ----------------------------------------------------------------
    -- Tick feedback offset state (for early sound/flash firing)
    ----------------------------------------------------------------
    f._earlyTickFired = {}  -- tracks which ticks had early feedback fired

    ----------------------------------------------------------------
    -- OnUpdate — animate the bar
    ----------------------------------------------------------------
    f:SetScript("OnUpdate", function(self, elapsed)
        if f._preview then return end  -- don't animate during preview

        local now = GetTime()

        -- Natural expiry check first
        if now > f.endTime and (f.casting or f.channeling) then
            HideBar()
            return
        end

        if f.casting then
            local progress = (now - f.startTime) / (f.endTime - f.startTime)
            progress = math.min(math.max(progress, 0), 1)
            f.bar:SetValue(progress)
            f.timerText:SetText(A.FormatTime(math.max(f.endTime - now, 0)))
            f.spark:ClearAllPoints()
            f.spark:SetPoint("CENTER", bar, "LEFT", BAR_W * progress, 0)
            f.spark:Show()

        elseif f.channeling then
            local progress = (f.endTime - now) / (f.endTime - f.startTime)
            progress = math.min(math.max(progress, 0), 1)
            f.bar:SetValue(progress)
            f.timerText:SetText(A.FormatTime(math.max(f.endTime - now, 0)))
            f.spark:ClearAllPoints()
            f.spark:SetPoint("CENTER", bar, "LEFT", BAR_W * progress, 0)
            f.spark:Show()

            -- Early tick feedback (offset-based)
            if f.isTrackedChannel and f.tickCount > 0 then
                local offsetMs = A.SpecVal and A.SpecVal("tickFeedbackOffsetMs", 0) or 0
                if offsetMs > 0 then
                    local offsetSec = offsetMs / 1000
                    local interval = (f.endTime - f.startTime) / f.tickCount
                    for tickNum = (f.ticksDone + 1), f.tickCount do
                        if not f._earlyTickFired[tickNum] then
                            local predictedTickTime = f.startTime + (tickNum * interval)
                            if now >= (predictedTickTime - offsetSec) then
                                f._earlyTickFired[tickNum] = true
                                -- Fire early feedback
                                local activeInfo = f.channelInfo
                                local doSound = not activeInfo or activeInfo.tickSound ~= false
                                local doFlash = not activeInfo or activeInfo.tickFlash ~= false
                                local ts = doSound and (A.SpecVal and A.SpecVal("tickSound", nil) or nil) or "none"
                                if not ts and A.db and A.db.castBar then ts = A.db.castBar.tickSound end
                                ts = ts or "click"
                                local tf = doFlash and (A.SpecVal and A.SpecVal("tickFlash", nil) or nil) or "none"
                                if not tf and A.db and A.db.castBar then tf = A.db.castBar.tickFlash end
                                tf = tf or "green"
                                if (ts and ts ~= "none") or (tf and tf ~= "none") then
                                    pcall(function() if A.PlayTickSound then A.PlayTickSound(ts) end end)
                                    pcall(function() if A.DoTickFlash then A.DoTickFlash(tf) end end)
                                end
                            end
                        end
                    end
                end
            end

            if f.isTrackedChannel then
                local clip = ShouldClip()
                f.clipSafe = clip
                if clip then
                    f.clipText:Show()
                else
                    f.clipText:Hide()
                end
            end
        end
    end)

    ----------------------------------------------------------------
    -- Event handling
    ----------------------------------------------------------------
    local events = CreateFrame("Frame")
    events:RegisterEvent("UNIT_SPELLCAST_START")
    events:RegisterEvent("UNIT_SPELLCAST_STOP")
    events:RegisterEvent("UNIT_SPELLCAST_FAILED")
    events:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
    events:RegisterEvent("UNIT_SPELLCAST_DELAYED")
    events:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
    events:RegisterEvent("UNIT_SPELLCAST_CHANNEL_UPDATE")
    events:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
    events:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

    events:SetScript("OnEvent", function(self, event, ...)
        if f._preview then return end  -- ignore during preview

        if event == "UNIT_SPELLCAST_START" then
            local unit = ...
            if unit ~= "player" then return end
            local name, _, _, startMS, endMS = UnitCastingInfo("player")
            if name then ShowBar(name, startMS, endMS, false) end

        elseif event == "UNIT_SPELLCAST_STOP"
            or event == "UNIT_SPELLCAST_FAILED"
            or event == "UNIT_SPELLCAST_INTERRUPTED" then
            local unit = ...
            if unit ~= "player" then return end
            -- Debounce hide: sometimes UnitCastingInfo can briefly report nil
            -- during target swaps or transient updates. Delay shortly and only
            -- hide if there's no active cast/channel to avoid flicker.
            if f.casting then
                C_Timer.After(0.06, function()
                    if not UnitCastingInfo("player") and not UnitChannelInfo("player") then
                        if f.casting then HideBar() end
                    end
                end)
            end

        elseif event == "UNIT_SPELLCAST_DELAYED" then
            -- Spell pushback: re-read cast end time
            local unit = ...
            if unit ~= "player" then return end
            if f.casting then
                local name, _, _, startMS, endMS = UnitCastingInfo("player")
                if name and endMS then
                    f.endTime = endMS / 1000
                end
            end

        elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
            local unit = ...
            if unit ~= "player" then return end
            local name, _, _, startMS, endMS = UnitChannelInfo("player")
            if name then ShowBar(name, startMS, endMS, true) end

        elseif event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
            -- Channel pushback: re-read channel end time
            local unit = ...
            if unit ~= "player" then return end
            if f.channeling then
                local name, _, _, startMS, endMS = UnitChannelInfo("player")
                if name and endMS then
                    f.endTime = endMS / 1000
                end
            end

        elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
            local unit = ...
            if unit ~= "player" then return end
            -- Debounce channel stop similarly to avoid transient hides.
            if f.channeling then
                C_Timer.After(0.06, function()
                    if not UnitChannelInfo("player") and not UnitCastingInfo("player") then
                        if f.channeling then HideBar() end
                    end
                end)
            end

        elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
            local _, subEvent, _, sourceGUID, _, _, _, _, _, _, _, spellId, cleuSpellName
                = CombatLogGetCurrentEventInfo()
            if sourceGUID ~= UnitGUID("player") then return end
            if subEvent == "SPELL_PERIODIC_DAMAGE"
               and f.isTrackedChannel then
                -- Check if this CLEU spell matches the active channel
                local activeInfo = f.channelInfo
                local matchesChannel = false
                if activeInfo and activeInfo.spellKey and A.SPELLS[activeInfo.spellKey] then
                    matchesChannel = cleuSpellName == A.SPELLS[activeInfo.spellKey].name
                end
                -- Fallback: match by f.spellName (for spells not in KNOWN_CHANNELS by spellKey)
                if not matchesChannel and f.spellName and cleuSpellName == f.spellName then
                    matchesChannel = true
                end
                if not matchesChannel then return end

                -- Tick occurred: update state and markers
                f.ticksDone = f.ticksDone + 1
                f.tickCounterText:SetText(f.ticksDone .. "/" .. f.tickCount)
                -- Update tick marker appearance for completed tick
                local markerMode = activeInfo and activeInfo.tickMarkerMode
                if not markerMode or markerMode == "" then
                    markerMode = A.SpecVal and A.SpecVal("tickMarkers", "all") or "all"
                end
                if f.tickMarkers[f.ticksDone] then
                    if markerMode == "remaining" then
                        f.tickMarkers[f.ticksDone]:Hide()
                    else
                        f.tickMarkers[f.ticksDone]:SetColorTexture(
                            unpack(A.COLORS.SAFE))
                    end
                end
                -- Tick feedback — check per-spell settings; skip if early offset already fired
                if not f._earlyTickFired[f.ticksDone] then
                    local doSound = not activeInfo or activeInfo.tickSound ~= false
                    local doFlash = not activeInfo or activeInfo.tickFlash ~= false
                    local ts = doSound and (A.SpecVal and A.SpecVal("tickSound", nil) or nil) or "none"
                    if not ts and A.db and A.db.castBar then ts = A.db.castBar.tickSound end
                    ts = ts or "click"
                    local tf = doFlash and (A.SpecVal and A.SpecVal("tickFlash", nil) or nil) or "none"
                    if not tf and A.db and A.db.castBar then tf = A.db.castBar.tickFlash end
                    tf = tf or "green"
                    if (ts and ts ~= "none") or (tf and tf ~= "none") then
                        pcall(function() if A.PlayTickSound then A.PlayTickSound(ts) end end)
                        pcall(function() if A.DoTickFlash then A.DoTickFlash(tf) end end)
                    end
                end
            end
        end
    end)

    f:Hide()
end

------------------------------------------------------------------------
-- Register as SpecManager helper
------------------------------------------------------------------------
if SPHelper.SpecManager then
    SPHelper.SpecManager:RegisterHelper("CastBar", {
        _initialized = false,
        OnSpecActivate = function(self, spec)
            if self._initialized then return end
            self._initialized = true
            if SPHelper.InitCastBar then SPHelper:InitCastBar() end
        end,
        OnSpecDeactivate = function(self, spec)
            self._initialized = false
            if SPHelper.castBarFrame then
                SPHelper.castBarFrame:UnregisterAllEvents()
                SPHelper.castBarFrame:Hide()
            end
        end,
    })
end
