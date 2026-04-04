------------------------------------------------------------------------
-- SPHelper  –  DotTracker.lua
-- Tracks SW:P, VT, Mind Soothe, and Shackle Undead on multiple targets.
-- Only tracks creatures during combat (via CLEU).
-- Applied DoT icons overlaid on bottom-right of the health bar.
-- Borders blink when an applied DoT is about to expire.
-- Portrait is cached when the mob is targeted/focused so it persists.
-- The currently-targeted mob gets a highlighted portrait border.
-- Supports dummy preview data when the settings panel is open.
------------------------------------------------------------------------
local A = SPHelper

-- Tracked debuff definitions
local TRACKED_DEBUFFS = {
    { key = "swp", spell = function() return A.SPELLS.SWP end, dur = 18, color = "SWP" },
    { key = "vt",  spell = function() return A.SPELLS.VT  end, dur = 15, color = "VT"  },
    { key = "ms",  spell = function() return A.SPELLS.MS  end, dur = 15, color = "MS"  },
    { key = "su",  spell = function() return A.SPELLS.SU  end, dur = 50, color = "SU"  },
}

-- Raid target icon textures (indices 1-8)
local RAID_ICONS = {
    "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1",
    "Interface\\TargetingFrame\\UI-RaidTargetingIcon_2",
    "Interface\\TargetingFrame\\UI-RaidTargetingIcon_3",
    "Interface\\TargetingFrame\\UI-RaidTargetingIcon_4",
    "Interface\\TargetingFrame\\UI-RaidTargetingIcon_5",
    "Interface\\TargetingFrame\\UI-RaidTargetingIcon_6",
    "Interface\\TargetingFrame\\UI-RaidTargetingIcon_7",
    "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8",
}

local spellIconCache = {}

function A:InitDotTracker()
    local db = A.db.dotTracker
    if not db.enabled then return end

    local ROW_W       = db.width       or 300
    local ROW_H       = db.rowHeight   or 40
    local MAX         = db.maxTargets  or 8
    local WARN_SEC    = db.warnSeconds or 3
    local BLINK_SPD   = db.blinkSpeed  or 4
    local PORTRAIT_SZ = ROW_H
    local DOT_ICON_SZ = db.dotIconSize or math.max(14, math.floor(ROW_H * 0.45))
    local HP_BAR_W    = ROW_W - PORTRAIT_SZ - 2
    local playerGUID  = UnitGUID("player")
    local TOMB_LIFE   = 12 -- seconds to keep a tombstone preventing re-adds

    local NAME_FONT  = math.max(9, math.floor(ROW_H * 0.28))
    local HP_FONT    = math.max(8, math.floor(ROW_H * 0.24))
    local TIMER_FONT = math.max(7, math.floor(DOT_ICON_SZ * 0.55))

    -- Build lookups
    local nameToKey = {}
    local nameToDur = {}
    for _, def in ipairs(TRACKED_DEBUFFS) do
        local sp = def.spell()
        if sp and sp.name then
            nameToKey[sp.name] = def.key
            nameToDur[sp.name] = def.dur
            local _, _, ic = GetSpellInfo(sp.id)
            spellIconCache[def.key] = ic
        end
    end

    ----------------------------------------------------------------
    -- Anchor frame (title bar / drag handle)
    ----------------------------------------------------------------
    local anchor = CreateFrame("Frame", "SPHelperDotTracker", UIParent, "BackdropTemplate")
    anchor:SetSize(ROW_W + 2, 14)
    anchor:SetPoint("CENTER", UIParent, "CENTER", 220, -100)
    anchor:SetMovable(true)
    anchor:EnableMouse(true)
    anchor:SetClampedToScreen(true)
    anchor:RegisterForDrag("LeftButton")
    anchor:SetScript("OnDragStart", function(self)
        if not A.db.locked then self:StartMoving() end
    end)
    anchor:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    A.CreateBackdrop(anchor, 0.12, 0.10, 0.18, 0.9)

    local title = anchor:CreateFontString(nil, "OVERLAY")
    title:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
    title:SetPoint("CENTER")
    title:SetText("|cff8882d5DoTs|r")
    -- Show anchor only if player is in combat or preview will be active.
    if UnitAffectingCombat("player") or previewActive then
        anchor:Show()
    else
        anchor:Hide()
    end
    A.dotAnchor = anchor

    ----------------------------------------------------------------
    -- Data store
    ----------------------------------------------------------------
    local targets = {}
    local rows    = {}
    -- tombstones prevent recently-removed targets from being re-added
    local tombstones = {}
    -- tombstoneNames records names of recently-removed mobs
    local tombstoneNames = {}
    -- recentNames marks names currently/just-active to disambiguate same-name spawns
    local recentNames = {}
    A.dotTargets  = targets

    ----------------------------------------------------------------
    -- Preview / dummy data support
    ----------------------------------------------------------------
    local previewActive = false
    -- Expose preview state for other modules
    A.dotTrackerPreviewActive = false

    local function InjectDummyData()
        wipe(targets)
        local now = GetTime()
        local dummies = {
            { name = "Fel Reaver",        hp = 0.85, ri = 8, swp = 12, vt = 9 },
            { name = "Void Reaver",       hp = 0.62, ri = 7, swp = 3,  vt = 2 },
            { name = "Shade of Aran",     hp = 0.41, ri = 1, swp = 16 },
            { name = "Hydross the Unstable", hp = 0.23 },
        }
        for i, d in ipairs(dummies) do
            local guid = "preview-" .. i
            targets[guid] = {
                name = d.name,
                _addedAt = now - (i * 2),
                _inCombat = true,
                _preview  = true,
                hpPct = d.hp,
                raidIcon = d.ri,
            }
            if d.swp then targets[guid].swp_exp = now + d.swp; targets[guid].swp_dur = 18 end
            if d.vt  then targets[guid].vt_exp  = now + d.vt;  targets[guid].vt_dur  = 15 end
        end
        previewActive = true
        A.dotTrackerPreviewActive = true
        -- Ensure the anchor is visible for preview even when out of combat
        if anchor then anchor:Show() end
    end

    local function ClearDummyData()
        if not previewActive then return end
        for guid in pairs(targets) do
            if targets[guid]._preview then targets[guid] = nil end
        end
        previewActive = false
        A.dotTrackerPreviewActive = false
        -- If player is not in combat, hide the anchor after clearing preview
        if not playerInCombat and anchor then anchor:Hide() end
    end

    -- Expose for Config.lua
    A.DotTrackerPreviewOn  = InjectDummyData
    A.DotTrackerPreviewOff = ClearDummyData

    ----------------------------------------------------------------
    -- Create one row
    ----------------------------------------------------------------
    local function CreateRow(index)
        local row = CreateFrame("Frame", "SPHelperDotRow"..index, anchor, "BackdropTemplate")
        row:SetSize(ROW_W, ROW_H)
        row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(index - 1) * (ROW_H + 2))
        row:SetBackdrop({
            bgFile   = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeSize = 2,
        })
        row:SetBackdropColor(0.06, 0.06, 0.06, 0.85)
        row:SetBackdropBorderColor(0, 0, 0, 1)

        ---- Portrait container with border ----
        local ptFrame = CreateFrame("Frame", nil, row, "BackdropTemplate")
        ptFrame:SetSize(PORTRAIT_SZ, PORTRAIT_SZ)
        ptFrame:SetPoint("LEFT", row, "LEFT", 0, 0)
        ptFrame:SetBackdrop({
            bgFile   = "Interface\\BUTTONS\\WHITE8X8",
            edgeFile = "Interface\\BUTTONS\\WHITE8X8",
            edgeSize = 2,
        })
        ptFrame:SetBackdropColor(0, 0, 0, 1)
        ptFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        row.ptFrame = ptFrame

        local portrait = ptFrame:CreateTexture(nil, "ARTWORK")
        portrait:SetPoint("TOPLEFT", 2, -2)
        portrait:SetPoint("BOTTOMRIGHT", -2, 2)
        portrait:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        portrait:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        row.portrait = portrait

        -- Raid marker overlay on portrait
        local raidIcon = ptFrame:CreateTexture(nil, "OVERLAY")
        raidIcon:SetSize(PORTRAIT_SZ * 0.45, PORTRAIT_SZ * 0.45)
        raidIcon:SetPoint("TOPLEFT", ptFrame, "TOPLEFT", 1, -1)
        raidIcon:Hide()
        row.raidIcon = raidIcon

        ---- Health bar (fills remaining width) ----
        local hpBar = CreateFrame("StatusBar", nil, row)
        hpBar:SetSize(HP_BAR_W, ROW_H - 2)
        hpBar:SetPoint("LEFT", ptFrame, "RIGHT", 2, 0)
        hpBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        hpBar:SetStatusBarColor(0.2, 0.8, 0.2, 1)
        hpBar:SetMinMaxValues(0, 1)
        hpBar:SetValue(1)
        row.hpBar = hpBar

        local hpBg = hpBar:CreateTexture(nil, "BACKGROUND")
        hpBg:SetAllPoints()
        hpBg:SetColorTexture(0.12, 0.12, 0.12, 0.85)

        -- Name text (top-left of health bar)
        local nameText = hpBar:CreateFontString(nil, "OVERLAY")
        nameText:SetFont("Fonts\\FRIZQT__.TTF", NAME_FONT, "OUTLINE")
        nameText:SetPoint("TOPLEFT", hpBar, "TOPLEFT", 4, -2)
        nameText:SetPoint("TOPRIGHT", hpBar, "TOPRIGHT", -36, -2)
        nameText:SetJustifyH("LEFT")
        nameText:SetWordWrap(false)
        nameText:SetTextColor(1, 1, 1, 1)
        row.nameText = nameText

        -- HP % text (top-right of health bar)
        local hpText = hpBar:CreateFontString(nil, "OVERLAY")
        hpText:SetFont("Fonts\\FRIZQT__.TTF", HP_FONT, "OUTLINE")
        hpText:SetPoint("TOPRIGHT", hpBar, "TOPRIGHT", -3, -3)
        hpText:SetJustifyH("RIGHT")
        hpText:SetTextColor(1, 1, 1, 1)
        row.hpText = hpText

        ---- Pre-create DoT icon frames (hidden by default) ----
        row.dotIcons  = {}
        row.dotTimers = {}
        for bi, def in ipairs(TRACKED_DEBUFFS) do
            local iconFrame = CreateFrame("Frame", nil, hpBar, "BackdropTemplate")
            iconFrame:SetSize(DOT_ICON_SZ, DOT_ICON_SZ)
            iconFrame:SetBackdrop({
                bgFile   = "Interface\\BUTTONS\\WHITE8X8",
                edgeFile = "Interface\\BUTTONS\\WHITE8X8",
                edgeSize = 1,
            })
            iconFrame:SetBackdropColor(0, 0, 0, 0.7)
            iconFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
            iconFrame:SetFrameLevel(hpBar:GetFrameLevel() + 2)
            iconFrame:Hide()
            row.dotIcons[bi] = iconFrame

            local tex = iconFrame:CreateTexture(nil, "ARTWORK")
            tex:SetPoint("TOPLEFT", 1, -1)
            tex:SetPoint("BOTTOMRIGHT", -1, 1)
            tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            tex:SetTexture(spellIconCache[def.key])
            iconFrame.icon = tex

            local timer = iconFrame:CreateFontString(nil, "OVERLAY")
            timer:SetFont("Fonts\\FRIZQT__.TTF", TIMER_FONT, "OUTLINE")
            timer:SetPoint("CENTER", iconFrame, "CENTER", 0, 0)
            timer:SetTextColor(1, 1, 1, 1)
            row.dotTimers[bi] = timer
        end

        row.targetGUID = nil
        row.lastGUID   = nil
        row:Hide()
        rows[index] = row
        return row
    end

    for i = 1, MAX do CreateRow(i) end

    ----------------------------------------------------------------
    -- Resize layout (called from Config when sliders change)
    ----------------------------------------------------------------
    A.DotTrackerResizeLayout = function()
        local db = A.db.dotTracker
        ROW_W       = db.width       or 300
        ROW_H       = db.rowHeight   or 40
        PORTRAIT_SZ = ROW_H
        DOT_ICON_SZ = db.dotIconSize or math.max(14, math.floor(ROW_H * 0.45))
        HP_BAR_W    = ROW_W - PORTRAIT_SZ - 2
        NAME_FONT   = math.max(9, math.floor(ROW_H * 0.28))
        HP_FONT     = math.max(8, math.floor(ROW_H * 0.24))
        TIMER_FONT  = math.max(7, math.floor(DOT_ICON_SZ * 0.55))

        anchor:SetSize(ROW_W + 2, 14)

        for i = 1, MAX do
            local row = rows[i]
            row:SetSize(ROW_W, ROW_H)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(i - 1) * (ROW_H + 2))

            row.ptFrame:SetSize(PORTRAIT_SZ, PORTRAIT_SZ)
            row.raidIcon:SetSize(PORTRAIT_SZ * 0.45, PORTRAIT_SZ * 0.45)

            row.hpBar:SetSize(HP_BAR_W, ROW_H - 2)

            row.nameText:SetFont("Fonts\\FRIZQT__.TTF", NAME_FONT, "OUTLINE")
            row.hpText:SetFont("Fonts\\FRIZQT__.TTF", HP_FONT, "OUTLINE")

            for bi = 1, #TRACKED_DEBUFFS do
                row.dotIcons[bi]:SetSize(DOT_ICON_SZ, DOT_ICON_SZ)
                row.dotTimers[bi]:SetFont("Fonts\\FRIZQT__.TTF", TIMER_FONT, "OUTLINE")
            end
        end

        -- Refresh dummy data timers if preview is active
        if previewActive and A.DotTrackerPreviewOn then
            A.DotTrackerPreviewOn()
        end
    end

    ----------------------------------------------------------------
    -- Scan a unit's debuffs and update tracker data
    -- Only updates existing tracked targets (doesn't add new ones)
    ----------------------------------------------------------------
    local function ScanUnit(unit)
        if not UnitExists(unit) then return end
        local guid = UnitGUID(unit)
        if not guid then return end
        local unitName = UnitName(unit)

        -- If we don't yet track this GUID, try to add it based on applied
        -- tracked debuffs or if the unit is hostile and currently in combat.
        if not targets[guid] then
            local now = GetTime()
            -- respect recent tombstones for the same GUID
            if tombstones[guid] and (now - tombstones[guid]) < TOMB_LIFE then
                return
            end

            local added = false
            for _, def in ipairs(TRACKED_DEBUFFS) do
                local sp = def.spell()
                if sp and sp.name then
                    local name, icon, count, debuffType, duration, expirationTime
                        = A.FindPlayerDebuff(unit, sp.name)
                    if name and expirationTime and expirationTime > 0 then
                        targets[guid] = {
                            name = unitName or name,
                            _addedAt = now,
                            _inCombat = UnitAffectingCombat(unit) or UnitAffectingCombat("player"),
                        }
                        local max = UnitHealthMax(unit) or 1
                        targets[guid].hpPct = (max > 0) and (UnitHealth(unit) / max) or 1
                        recentNames[targets[guid].name] = now
                        added = true
                        break
                    end
                end
            end

            if not added then
                -- Also add if the unit is hostile and in combat (chain-pull case)
                if UnitAffectingCombat(unit) and UnitCanAttack("player", unit) then
                    targets[guid] = {
                        name = unitName or "Unknown",
                        _addedAt = now,
                        _inCombat = true,
                    }
                    local max = UnitHealthMax(unit) or 1
                    targets[guid].hpPct = (max > 0) and (UnitHealth(unit) / max) or 1
                    recentNames[targets[guid].name] = now
                    added = true
                end
            end

            if not added then return end
        end

        for _, def in ipairs(TRACKED_DEBUFFS) do
            local sp = def.spell()
            if sp and sp.name then
                local name, icon, count, debuffType, duration, expirationTime
                    = A.FindPlayerDebuff(unit, sp.name)
                if name and expirationTime and expirationTime > 0 then
                    local t = targets[guid]
                    t.name = unitName or t.name
                    t[def.key .. "_dur"] = duration
                    t[def.key .. "_exp"] = expirationTime
                end
            end
        end

        targets[guid].raidIcon = GetRaidTargetIndex(unit)
        local hp  = UnitHealth(unit) or 0
        local max = UnitHealthMax(unit) or 1
        targets[guid].hpPct = (max > 0) and (hp / max) or 1
    end

    ----------------------------------------------------------------
    -- Update portrait on a row for a given unitID (target/focus)
    ----------------------------------------------------------------
    local function UpdatePortraitForUnit(unit)
        if not UnitExists(unit) then return end
        local guid = UnitGUID(unit)
        if not guid then return end
        for i = 1, MAX do
            local row = rows[i]
            if row.targetGUID == guid then
                SetPortraitTexture(row.portrait, unit)
                row.lastGUID = guid
                break
            end
        end
    end

    ----------------------------------------------------------------
    -- Refresh visual rows
    ----------------------------------------------------------------
    local sorted = {}
    local blinkTimer = 0

    local function RefreshRows(elapsed)
        blinkTimer = blinkTimer + (elapsed or 0)
        wipe(sorted)
        local now = GetTime()
        local warnThreshold = A.db.dotTracker.warnSeconds or WARN_SEC
        local blinkSpeed    = A.db.dotTracker.blinkSpeed  or BLINK_SPD

        -- Cleanup recently-dead targets: mark when hp reaches 0 and remove
        -- them after a short grace period so the UI doesn't linger forever.
        for guid, data in pairs(targets) do
            if not data._preview then
                if data._deadAt then
                    if (now - data._deadAt) >= 3 then
                        local nm = data.name
                        targets[guid] = nil
                        tombstones[guid] = now
                        if nm and nm ~= "" then tombstoneNames[nm] = now end
                    end
                else
                    if data.hpPct and data.hpPct <= 0 then
                        data._deadAt = now
                    end
                end
            end
        end

        -- Collect tracked targets (only those flagged as in-combat)
        for guid, data in pairs(targets) do
            if data._inCombat then
                sorted[#sorted + 1] = guid
            else
                -- Not in combat: only keep if has active dots
                local anyActive = false
                for _, def in ipairs(TRACKED_DEBUFFS) do
                    local exp = data[def.key .. "_exp"]
                    if exp and exp > now then anyActive = true; break end
                end
                if anyActive then
                    sorted[#sorted + 1] = guid
                else
                    targets[guid] = nil
                end
            end
        end

        -- Sort by insertion order for stable positions
        table.sort(sorted, function(a, b)
            local ta, tb = targets[a], targets[b]
            return (ta._addedAt or 0) < (tb._addedAt or 0)
        end)

        -- Blink alpha oscillator
        local blinkAlpha = 0.5 + 0.5 * math.sin(blinkTimer * blinkSpeed * math.pi * 2)
        local targetGUID = UnitGUID("target")
        local focusGUID  = UnitGUID("focus")

        for i = 1, MAX do
            local row  = rows[i]
            local guid = sorted[i]
            if guid then
                local data = targets[guid]
                row.nameText:SetText(data.name or "???")
                row.targetGUID = guid

                -- Portrait: update from unitID if available, otherwise keep
                if data._preview then
                    row.portrait:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                elseif guid == targetGUID then
                    SetPortraitTexture(row.portrait, "target")
                    row.lastGUID = guid
                elseif guid == focusGUID then
                    SetPortraitTexture(row.portrait, "focus")
                    row.lastGUID = guid
                elseif row.lastGUID ~= guid then
                    row.portrait:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                    row.lastGUID = guid
                end

                -- Highlight portrait border if this mob is the current target
                if guid == targetGUID then
                    row.ptFrame:SetBackdropBorderColor(1, 0.85, 0, 1)
                else
                    row.ptFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                end

                -- Raid marker
                if data.raidIcon and RAID_ICONS[data.raidIcon] then
                    row.raidIcon:SetTexture(RAID_ICONS[data.raidIcon])
                    row.raidIcon:Show()
                else
                    row.raidIcon:Hide()
                end

                -- Health bar
                local hpPct = data.hpPct or 1
                row.hpBar:SetValue(hpPct)
                if hpPct > 0.5 then
                    row.hpBar:SetStatusBarColor(0.2, 0.8, 0.2, 1)
                elseif hpPct > 0.25 then
                    row.hpBar:SetStatusBarColor(0.9, 0.7, 0.1, 1)
                else
                    row.hpBar:SetStatusBarColor(0.9, 0.2, 0.1, 1)
                end
                row.hpText:SetText(math.floor(hpPct * 100) .. "%")

                -- DoT icons: only show APPLIED dots, positioned bottom-right
                local worstState = "none"
                local worstColor = {0, 0, 0, 1}
                local visibleCount = 0

                for bi, def in ipairs(TRACKED_DEBUFFS) do
                    local exp = data[def.key .. "_exp"]
                    local iconFrame = row.dotIcons[bi]
                    local timerText = row.dotTimers[bi]

                    if exp and exp > now then
                        local rem = exp - now
                        local col = A.COLORS[def.color] or A.COLORS.DEFAULT
                        visibleCount = visibleCount + 1

                        iconFrame:ClearAllPoints()
                        iconFrame:SetPoint("BOTTOMRIGHT", row.hpBar, "BOTTOMRIGHT",
                            -(visibleCount - 1) * (DOT_ICON_SZ + 2) - 2, 2)

                        iconFrame.icon:SetDesaturated(false)
                        iconFrame.icon:SetAlpha(1)
                        timerText:SetText(A.FormatTime(rem))

                        if rem <= warnThreshold then
                            iconFrame:SetBackdropBorderColor(
                                col[1], col[2], col[3], blinkAlpha)
                            timerText:SetTextColor(1, 0.3, 0.3, 1)
                            worstState = "warning"
                            worstColor = {col[1], col[2], col[3], 1}
                        else
                            iconFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                            timerText:SetTextColor(1, 1, 1, 1)
                        end

                        iconFrame:Show()
                    else
                        iconFrame:Hide()
                    end
                end

                -- Row border blinks when any dot is about to expire
                if worstState == "warning" then
                    row:SetBackdropBorderColor(
                        worstColor[1], worstColor[2], worstColor[3], blinkAlpha)
                else
                    row:SetBackdropBorderColor(0, 0, 0, 1)
                end

                row:Show()
            else
                row:Hide()
                row.lastGUID = nil
            end
        end
    end

    ----------------------------------------------------------------
    -- OnUpdate: refresh + periodic scan
    ----------------------------------------------------------------
    local acc = 0
    local scanAcc = 0
    anchor:SetScript("OnUpdate", function(self, elapsed)
        acc = acc + elapsed
        if acc >= 0.05 then
            RefreshRows(acc)
            acc = 0
        end

        scanAcc = scanAcc + elapsed
        if scanAcc >= 0.5 then
            scanAcc = 0
            ScanUnit("target")
            if UnitExists("focus") then ScanUnit("focus") end
            -- Update health from all visible nameplates
            for _, guid in pairs(targets) do end  -- no-op to keep targets alive
            for i = 1, 40 do
                local np = "nameplate" .. i
                if UnitExists(np) then
                    local guid = UnitGUID(np)
                    if guid and targets[guid] then
                        local max = UnitHealthMax(np)
                        targets[guid].hpPct = (max > 0)
                            and (UnitHealth(np) / max) or 1
                    end
                else
                    break
                end
            end
        end
    end)

    ----------------------------------------------------------------
    -- Events
    ----------------------------------------------------------------
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    ev:RegisterEvent("PLAYER_TARGET_CHANGED")
    ev:RegisterEvent("UNIT_AURA")
    ev:RegisterEvent("UNIT_HEALTH")
    ev:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    ev:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    ev:RegisterEvent("PLAYER_REGEN_ENABLED")
    ev:RegisterEvent("PLAYER_REGEN_DISABLED")

    local playerInCombat = UnitAffectingCombat("player")

    ev:SetScript("OnEvent", function(self, event, arg1)
        if event == "PLAYER_TARGET_CHANGED" then
            ScanUnit("target")
            UpdatePortraitForUnit("target")
            local tGUID = UnitGUID("target")
            if tGUID and targets[tGUID] then
                local max = UnitHealthMax("target")
                targets[tGUID].hpPct = (max > 0)
                    and (UnitHealth("target") / max) or 1
            end
            return
        end

        if event == "UNIT_AURA" then
            if arg1 == "target" then ScanUnit("target")
            elseif arg1 == "focus" then ScanUnit("focus")
            elseif arg1 and arg1:match("^nameplate") then ScanUnit(arg1) end
            return
        end

        if event == "NAME_PLATE_UNIT_ADDED" then
            if arg1 and UnitExists(arg1) then
                local guid = UnitGUID(arg1)
                if guid and targets[guid] then
                    local max = UnitHealthMax(arg1)
                    targets[guid].hpPct = (max > 0)
                        and (UnitHealth(arg1) / max) or 1
                    UpdatePortraitForUnit(arg1)
                    ScanUnit(arg1)
                end
            end
            return
        end

        if event == "NAME_PLATE_UNIT_REMOVED" then
            return
        end

        if event == "UNIT_HEALTH" then
            if arg1 and UnitExists(arg1) then
                local guid = UnitGUID(arg1)
                if guid and targets[guid] then
                    local max = UnitHealthMax(arg1)
                    targets[guid].hpPct = (max > 0)
                        and (UnitHealth(arg1) / max) or 1
                end
            end
            return
        end

        if event == "PLAYER_REGEN_ENABLED" then
            playerInCombat = false
            wipe(targets)
            previewActive = false
            if anchor then anchor:Hide() end
            return
        end

        if event == "PLAYER_REGEN_DISABLED" then
            playerInCombat = true
            -- Only show if addon-level visibility isn't disabled
            if A._visible ~= false and anchor then anchor:Show() end
            return
        end

        -- COMBAT_LOG_EVENT_UNFILTERED
        -- Allow tracking even if PLAYER_REGEN_DISABLED hasn't fired yet
        -- (fixes race where first CLEU event arrives before combat flag)
        if not playerInCombat and UnitAffectingCombat("player") then
            playerInCombat = true
        end
        if not playerInCombat then return end

        local timestamp, subEvent, hideCaster, sourceGUID, sourceName,
              sourceFlags, sourceRaidFlags, destGUID, destName,
              destFlags, destRaidFlags, spellId, spellName, spellSchool
              = CombatLogGetCurrentEventInfo()

        if not subEvent then return end

        -- Remove dead mobs immediately
        if subEvent == "UNIT_DIED" or subEvent == "PARTY_KILL" then
                    if destGUID then
                        local deadName = nil
                        if targets[destGUID] and targets[destGUID].name then
                            deadName = targets[destGUID].name
                        end
                        targets[destGUID] = nil
                        tombstones[destGUID] = GetTime()
                        if deadName and deadName ~= "" then tombstoneNames[deadName] = GetTime() end
                    end
            return
        end

        -- Player as source: track dest as combat mob + debuffs
        -- Only track hostile NPCs/players (filter via destFlags)
        if sourceGUID == playerGUID then
            if destGUID and destGUID ~= playerGUID and destFlags then
                local isHostile = bit.band(destFlags, COMBATLOG_OBJECT_REACTION_HOSTILE) > 0
                local isNeutral = bit.band(destFlags, COMBATLOG_OBJECT_REACTION_NEUTRAL) > 0
                local isNPCorPlayer = bit.band(destFlags,
                    COMBATLOG_OBJECT_TYPE_NPC + COMBATLOG_OBJECT_TYPE_PLAYER) > 0
                if (isHostile or isNeutral) and isNPCorPlayer then
                    if not targets[destGUID] then
                    -- Skip re-adding very recently-removed (dead) targets by GUID
                    if tombstones[destGUID] then
                        local t = tombstones[destGUID]
                        if (GetTime() - t) < TOMB_LIFE then
                            -- still tombstoned; ignore
                            return
                        else
                            tombstones[destGUID] = nil
                        end
                    end
                    -- If there's a recent tombstone for this name but the name is
                    -- currently active (another spawn), prefer the active name and
                    -- ignore late events for the old/dead GUID.
                    if destName and tombstoneNames[destName] then
                        local tn = tombstoneNames[destName]
                        local rn = recentNames[destName]
                        if rn and (GetTime() - rn) < TOMB_LIFE and (GetTime() - tn) < TOMB_LIFE then
                            return
                        end
                    end
                    if destName and destName ~= "" then
                        targets[destGUID] = {
                            name = destName,
                            _addedAt = GetTime(),
                            _inCombat = true,
                        }
                        -- Mark this name as recently active
                        if destName and destName ~= "" then recentNames[destName] = GetTime() end
                        -- Try to resolve immediate HP from common unit tokens
                        local now = GetTime()
                        local function tryAssignHP(unit)
                            if UnitExists(unit) and UnitGUID(unit) == destGUID then
                                local hp = UnitHealth(unit) or 0
                                local max = UnitHealthMax(unit) or 1
                                targets[destGUID].hpPct = (max > 0) and (hp / max) or 1
                                return true
                            end
                            return false
                        end
                        if not tryAssignHP("target") and not tryAssignHP("focus") and not tryAssignHP("mouseover") then
                            -- If we had a recent tombstone, mark as dead so it won't show full HP
                            local t = tombstones[destGUID]
                            if t and (GetTime() - t) < TOMB_LIFE then
                                targets[destGUID].hpPct = 0
                                targets[destGUID]._deadAt = now
                            end
                        end
                    end
                    else
                        if destName and destName ~= "" then
                            targets[destGUID].name = destName
                        end
                        targets[destGUID]._inCombat = true
                    end

                    -- Debuff tracking (only for hostile targets we're tracking)
                    if targets[destGUID] and spellName then
                        local debuffKey = nameToKey[spellName]
                        if debuffKey then
                            if subEvent == "SPELL_AURA_APPLIED"
                            or subEvent == "SPELL_AURA_REFRESH" then
                                local t = targets[destGUID]
                                local dur = nameToDur[spellName] or 15
                                t[debuffKey .. "_dur"] = dur
                                t[debuffKey .. "_exp"] = GetTime() + dur

                                if destGUID == UnitGUID("target") then
                                    C_Timer.After(0.1, function()
                                        ScanUnit("target")
                                    end)
                                end
                            elseif subEvent == "SPELL_AURA_REMOVED" then
                                if targets[destGUID] then
                                    targets[destGUID][debuffKey .. "_exp"] = 0
                                end
                            end
                        end
                    end
                end  -- isHostile and isNPCorPlayer
            end  -- destGUID check
            return
        end

        -- Something attacking the player: track source as combat mob
        if destGUID == playerGUID and sourceGUID
           and sourceGUID ~= playerGUID then
            if sourceFlags
               and (bit.band(sourceFlags, COMBATLOG_OBJECT_REACTION_HOSTILE) > 0
                    or bit.band(sourceFlags, COMBATLOG_OBJECT_REACTION_NEUTRAL) > 0)
               and sourceName and sourceName ~= ""
            then
                if not targets[sourceGUID] then
                    targets[sourceGUID] = {
                        name = sourceName,
                        _addedAt = GetTime(),
                        _inCombat = true,
                    }
                else
                    targets[sourceGUID].name = sourceName
                    targets[sourceGUID]._inCombat = true
                end
            end
        end
    end)
end
