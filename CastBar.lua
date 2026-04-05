------------------------------------------------------------------------
-- SPHelper  –  CastBar.lua
-- Player cast / channel bar with Mind Flay tick markers & clip indicator.
-- Handles spell pushback via UNIT_SPELLCAST_DELAYED / CHANNEL_UPDATE.
-- CLIP only shows when there's something worth clipping for.
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
    bar:SetStatusBarColor(unpack(A.COLORS.MF))
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
    -- Tick markers (3 vertical lines for Mind Flay)
    ----------------------------------------------------------------
    f.tickMarkers = {}
    for i = 1, 3 do
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
    clipText:SetText("CLIP")
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
    -- Colour helper
    ----------------------------------------------------------------
    local localColorMap = {
        [A.SPELLS.MF.name]  = A.COLORS.MF,
        [A.SPELLS.MB.name]  = A.COLORS.MB,
        [A.SPELLS.VT.name]  = A.COLORS.VT,
        [A.SPELLS.SWP.name] = A.COLORS.SWP,
        [A.SPELLS.SWD.name] = A.COLORS.SWD,
        [A.SPELLS.DP.name]  = A.COLORS.DP,
    }

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

        f.isMindFlay = (name == A.SPELLS.MF.name) and isChannel
        f.tickCount  = f.isMindFlay and 3 or 0

        local col
        if A.db and A.db.castBar and A.db.castBar.colorMode == "solid" and A.db.castBar.color then
            col = A.db.castBar.color
        else
            col = BarColorForSpell(name)
        end
        f.bar:SetStatusBarColor(unpack(col))
        f.spellNameText:SetText(name or "")

        for i, t in ipairs(f.tickMarkers) do
            if f.isMindFlay then
                local frac = (3 - i) / 3
                t:ClearAllPoints()
                t:SetPoint("CENTER", bar, "LEFT", BAR_W * frac, 0)
                t:SetColorTexture(1, 1, 1, 0.7)
                local mode = (A.db and A.db.castBar and A.db.castBar.tickMarkers) or "all"
                if mode == "all" then
                    t:Show()
                else
                    -- only show the second tick marker when in "second" mode
                    if i == 2 then t:Show() else t:Hide() end
                end
            else
                t:Hide()
            end
        end

        f.clipText:Hide()
        f.tickCounterText:Hide()
        if f.isMindFlay then
            f.tickCounterText:SetText("0/3")
            f.tickCounterText:Show()
        end

        f:Show()
    end

    local function HideBar()
        f.casting    = false
        f.channeling = false
        f.isMindFlay = false
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
        for i = 1, 3 do
            f.tickMarkers[i]:SetSize(2, BAR_H)
        end
    end

    ----------------------------------------------------------------
    -- Preview support
    ----------------------------------------------------------------
    A.CastBarPreviewOn = function()
        f._preview = true
        f.spellName = A.SPELLS.MF.name
        f.startTime = GetTime()
        f.endTime   = GetTime() + 3
        f.casting   = false
        f.channeling = true
        f.isMindFlay = true
        f.tickCount  = 3
        f.ticksDone  = 1
        f.clipSafe   = true
        local col
        if A.db and A.db.castBar and A.db.castBar.colorMode == "solid" and A.db.castBar.color then
            col = A.db.castBar.color
        else
            col = BarColorForSpell(A.SPELLS.MF.name)
        end
        f.bar:SetStatusBarColor(unpack(col))
        f.spellNameText:SetText(A.SPELLS.MF.name)
        f.tickCounterText:SetText("1/3")
        f.tickCounterText:Show()
        f.clipText:SetText("CLIP")
        f.clipText:Show()
        for i, t in ipairs(f.tickMarkers) do
            local frac = (3 - i) / 3
            t:ClearAllPoints()
            t:SetPoint("CENTER", bar, "LEFT", BAR_W * frac, 0)
            local mode = (A.db and A.db.castBar and A.db.castBar.tickMarkers) or "all"
            if mode == "all" then
                if i <= f.ticksDone then
                    t:SetColorTexture(unpack(A.COLORS.SAFE))
                else
                    t:SetColorTexture(1, 1, 1, 0.7)
                end
                t:Show()
            else
                -- only show second tick in "second" mode
                if i == 2 then
                    if f.ticksDone >= 2 then
                        t:SetColorTexture(unpack(A.COLORS.SAFE))
                    else
                        t:SetColorTexture(1, 1, 1, 0.7)
                    end
                    t:Show()
                else
                    t:Hide()
                end
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
    -- Mind Flay clip logic (research-based)
    -- Only show CLIP when there's something worth clipping for:
    -- MB off CD, VT expiring, SWP expiring, or SWD off CD (after 2 ticks)
    ----------------------------------------------------------------
    local function ShouldClip()
        if not f.isMindFlay or f.ticksDone < 1 then return false end

        local lat = A.GetLatency()
        local now = GetTime()

        -- Check dot emergencies: clip for expiring VT or SWP
        if UnitExists("target") then
            local _, _, _, _, _, vtExp = A.FindPlayerDebuff("target", A.SPELLS.VT.name)
            if vtExp then
                local vtRem = vtExp - now
                if vtRem > 0 and vtRem < (1.5 + lat + 0.3) then
                    return true  -- VT about to fall off, clip to recast
                end
            elseif A.KnowsSpell(A.SPELLS.VT.id) then
                return true  -- VT not up at all, clip to apply
            end

            local _, _, _, _, _, swpExp = A.FindPlayerDebuff("target", A.SPELLS.SWP.name)
            if swpExp then
                local swpRem = swpExp - now
                if swpRem > 0 and swpRem < (1.5 + lat) then
                    return true  -- SWP about to fall off
                end
            else
                return true  -- SWP not up, clip to apply
            end
        end

        -- MB is highest priority nuke — clip for MB
        local mbCD = A.GetSpellCDReal(A.SPELLS.MB.id)
        if f.ticksDone >= 1 and mbCD <= lat then
            return true  -- MB literally ready
        end
        if f.ticksDone >= 2 and mbCD <= (lat + 0.5) then
            return true  -- MB ready very soon, clip after 2nd tick
        end

        return false  -- nothing to clip for, let MF finish
    end

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

            if f.isMindFlay then
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
               and f.isMindFlay
               and cleuSpellName == A.SPELLS.MF.name then
                f.ticksDone = f.ticksDone + 1
                f.tickCounterText:SetText(f.ticksDone .. "/3")
                if f.tickMarkers[f.ticksDone] then
                    f.tickMarkers[f.ticksDone]:SetColorTexture(
                        unpack(A.COLORS.SAFE))
                end
                -- MF tick feedback (sound first, flash second). Enabled when tickSound or tickFlash not 'none'.
                local visualsEnabled = false
                if A.db and A.db.castBar then
                    local ts = A.db.castBar.tickSound
                    local tf = A.db.castBar.tickFlash
                    visualsEnabled = (ts and ts ~= "none") or (tf and tf ~= "none")
                end
                if visualsEnabled then
                    local mode = A.db and A.db.castBar and A.db.castBar.tickMarkers or "all"
                    if mode == "all" or f.ticksDone == 2 then
                        pcall(function() if A.PlayTickSound then A.PlayTickSound() end end)
                        pcall(function() if A.DoTickFlash then A.DoTickFlash() end end)
                    end
                end
            end
        end
    end)

    f:Hide()
end
