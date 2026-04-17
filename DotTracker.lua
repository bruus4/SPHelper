------------------------------------------------------------------------
-- SPHelper  –  DotTracker.lua
-- Tracks debuffs on multiple targets during combat (via CLEU).
-- Reads trackedDebuffs from the active spec; falls back to DEFAULT_TRACKED_DEBUFFS.
-- Applied DoT icons overlaid on bottom-right of the health bar.
-- Borders blink when an applied DoT is about to expire.
-- Portrait is cached when the mob is targeted/focused so it persists.
-- The currently-targeted mob gets a highlighted portrait border.
-- Supports dummy preview data when the settings panel is open.
------------------------------------------------------------------------
local A = SPHelper

-- Default tracked debuff definitions (empty — specs should provide their own via trackedDebuffs).
-- Kept as an empty fallback so DotTracker initializes safely for any spec.
local DEFAULT_TRACKED_DEBUFFS = {}

--- Build TRACKED_DEBUFFS from spec.trackedDebuffs or fall back to defaults.
local function BuildTrackedDebuffs()
    -- Check active spec for trackedDebuffs
    local specID = A._activeSpecID
    local spec = specID and A.SpecManager and A.SpecManager:GetSpecByID(specID)
    if spec and spec.trackedDebuffs then
        local result = {}
        for _, def in ipairs(spec.trackedDebuffs) do
            local spellData = A.SPELLS[def.spellKey]
            local spellDef = A.GetSpellDefinition and A.GetSpellDefinition(def.spellKey)
            result[#result + 1] = {
                key   = def.key,
                spell = function() return spellData end,
                dur   = def.duration or (spellDef and spellDef.duration) or 15,
                color = def.color or def.key:upper(),
            }
        end
        if #result > 0 then return result end
    end
    -- Also check DB overrides
    if A.db and A.db.specs and specID and A.db.specs[specID] and A.db.specs[specID].trackedDebuffs then
        local dbDefs = A.db.specs[specID].trackedDebuffs
        local result = {}
        for _, def in ipairs(dbDefs) do
            local spellData = A.SPELLS[def.spellKey]
            local spellDef = A.GetSpellDefinition and A.GetSpellDefinition(def.spellKey)
            result[#result + 1] = {
                key   = def.key,
                spell = function() return spellData end,
                dur   = def.duration or (spellDef and spellDef.duration) or 15,
                color = def.color or def.key:upper(),
            }
        end
        if #result > 0 then return result end
    end
    return DEFAULT_TRACKED_DEBUFFS
end

local TRACKED_DEBUFFS = BuildTrackedDebuffs()

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

    -- If the tracker is already built, reuse it instead of creating another
    -- frame set. This keeps placement/preview refreshes from duplicating the UI.
    if A.dotAnchor and A._dotTrackerCLEU then
        A._dotTrackerCLEU:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        A._dotTrackerCLEU:RegisterEvent("PLAYER_TARGET_CHANGED")
        A._dotTrackerCLEU:RegisterEvent("UNIT_AURA")
        A._dotTrackerCLEU:RegisterEvent("UNIT_HEALTH")
        A._dotTrackerCLEU:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        A._dotTrackerCLEU:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
        A._dotTrackerCLEU:RegisterEvent("PLAYER_REGEN_ENABLED")
        A._dotTrackerCLEU:RegisterEvent("PLAYER_REGEN_DISABLED")
        if UnitAffectingCombat("player") or A.dotTrackerPreviewActive then
            A.dotAnchor:Show()
        else
            A.dotAnchor:Hide()
        end
        if A.DotTrackerResizeLayout then
            pcall(A.DotTrackerResizeLayout)
        end
        return
    end

    local ROW_W       = db.width       or 300
    local ROW_H       = db.rowHeight   or 40
    local MAX         = db.maxTargets  or 8
    local WARN_SEC    = db.warnSeconds or 3
    local BLINK_SPD   = db.blinkSpeed  or 4
    local PORTRAIT_SZ = ROW_H
    local PORTRAIT_SIDE = db.portraitSide or "left"
    local WARN_MODE   = db.warnMode or "border" -- options: border, icon, bar, none
    local BORDER_SIZE = db.warnBorderSize or 2
    local ANCHOR_POS  = db.anchorPosition or "top"
    local DOT_ICON_SZ = db.dotIconSize or math.max(14, math.floor(ROW_H * 0.45))
    local HP_BAR_W    = (PORTRAIT_SIDE == "none") and (ROW_W - 2) or (ROW_W - PORTRAIT_SZ - 2)
    local addCounter   = 0
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
            local ic = A.GetSpellIconCached and A.GetSpellIconCached(sp.id) or select(3, GetSpellInfo(sp.id))
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
    local tombstones = {}
    -- tombstoneNames records names of recently-removed mobs
    local tombstoneNames = {}
    -- recentNames marks names currently/just-active to disambiguate same-name spawns
    local recentNames = {}
    -- Tab-order history: guid -> rank (lower rank = tabbed earlier in the cycle)
    -- Reset each combat. Updated on PLAYER_TARGET_CHANGED.
    local tabHistory     = {}
    local tabRankCounter = 0
    A.dotTargets  = targets

    local function SetTrackedTargetHP(guid, hpPct)
        if not guid or not targets[guid] then return false end
        hpPct = tonumber(hpPct) or 0
        if hpPct < 0 then hpPct = 0 end
        if hpPct > 1 then hpPct = 1 end
        targets[guid].hpPct = hpPct
        if A.UpdateTargetHealthSample then
            A.UpdateTargetHealthSample(guid, hpPct)
        end
        return true
    end

    local function SetTrackedTargetHPFromUnit(guid, unit)
        if not guid or not unit or not UnitExists(unit) then return false end
        local max = UnitHealthMax(unit) or 1
        local hpPct = (max > 0) and (UnitHealth(unit) / max) or 1
        return SetTrackedTargetHP(guid, hpPct)
    end

    ----------------------------------------------------------------
    -- Preview / dummy data support
    ----------------------------------------------------------------
    local previewActive = false
    local RefreshRows
    -- Expose preview state for other modules
    A.dotTrackerPreviewActive = false

    local function InjectDummyData()
        addCounter = 0
        wipe(targets)
        local now = GetTime()
        local sampleNames = { "Fel Reaver", "Void Reaver", "Shade of Aran", "Hydross the Unstable", "Doomwalker", "Warbringer" }
        -- Collect debuff keys and durations from the active tracked debuffs
        local dotKeys = {}
        for _, def in ipairs(TRACKED_DEBUFFS) do
            dotKeys[#dotKeys + 1] = { key = def.key, dur = def.dur }
        end
        for i = 1, MAX do
            local guid = "preview-" .. i
            local name = sampleNames[((i - 1) % #sampleNames) + 1] or ("Dummy " .. i)
            local hp = math.max(0.12, 0.95 - (i - 1) * 0.06)
            addCounter = addCounter + 1
            targets[guid] = {
                name = name,
                _addedAt = now - (i * 2),
                _inCombat = true,
                _preview  = true,
                raidIcon = ((i - 1) % #RAID_ICONS) + 1,
                _addOrder = addCounter,
            }
            SetTrackedTargetHP(guid, hp)
            -- Stagger debuffs across tracked dot keys for visual variety
            for dotIdx, dotDef in ipairs(dotKeys) do
                local bucket = ((i + dotIdx - 2) % 3)
                if bucket < 2 then
                    local t = targets[guid]
                    t[dotDef.key .. "_exp"] = now + (dotDef.dur * 0.3) + i + dotIdx
                    t[dotDef.key .. "_dur"] = dotDef.dur
                end
            end
        end
        previewActive = true
        A.dotTrackerPreviewActive = true
        -- Ensure the anchor is visible for preview even when out of combat
        if anchor then anchor:Show() end
        RefreshRows(0)
    end

    local function ClearDummyData()
        if not previewActive then return end
        for guid in pairs(targets) do
            if targets[guid]._preview then
                targets[guid] = nil
                if A.ClearTargetMetric then A.ClearTargetMetric(guid) end
            end
        end
        previewActive = false
        A.dotTrackerPreviewActive = false
        -- If player is not in combat, hide the anchor after clearing preview
        if not playerInCombat and anchor then anchor:Hide() end
        RefreshRows(0)
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
        if ANCHOR_POS == "top" then
            row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(index - 1) * (ROW_H + 2))
        else
            row:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, (index - 1) * (ROW_H + 2))
        end
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
        if PORTRAIT_SIDE == "left" then
            ptFrame:SetPoint("LEFT", row, "LEFT", 0, 0)
            ptFrame:Show()
        elseif PORTRAIT_SIDE == "right" then
            ptFrame:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            ptFrame:Show()
        else
            ptFrame:Hide()
        end
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

        -- Overlay used for a large flashing border so we don't alter layout
        local overlay = CreateFrame("Frame", nil, row, "BackdropTemplate")
        overlay:SetAllPoints(row)
        overlay:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8", edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = BORDER_SIZE })
        overlay:SetBackdropColor(0, 0, 0, 0)
        overlay:SetBackdropBorderColor(0, 0, 0, 0)
        overlay:SetFrameLevel(row:GetFrameLevel() + 6)
        overlay:Hide()
        row.borderOverlay = overlay

        ---- Health bar (fills remaining width) ----
        local hpBar = CreateFrame("StatusBar", nil, row)
        local hpWidth = (PORTRAIT_SIDE == "none") and (ROW_W - 2) or (ROW_W - PORTRAIT_SZ - 2)
        hpBar:SetSize(hpWidth, ROW_H - 2)
        if PORTRAIT_SIDE == "left" then
            hpBar:SetPoint("LEFT", ptFrame, "RIGHT", 2, 0)
        elseif PORTRAIT_SIDE == "right" then
            hpBar:SetPoint("RIGHT", ptFrame, "LEFT", -2, 0)
        else
            hpBar:SetPoint("LEFT", row, "LEFT", 1, 0)
        end
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
        PORTRAIT_SIDE = db.portraitSide or "left"
        WARN_MODE = db.warnMode or "border"
        BORDER_SIZE = db.warnBorderSize or 2
        ANCHOR_POS  = db.anchorPosition or "top"
        DOT_ICON_SZ = db.dotIconSize or math.max(14, math.floor(ROW_H * 0.45))
        HP_BAR_W    = ROW_W - PORTRAIT_SZ - 2
        NAME_FONT   = math.max(9, math.floor(ROW_H * 0.28))
        HP_FONT     = math.max(8, math.floor(ROW_H * 0.24))
        TIMER_FONT  = math.max(7, math.floor(DOT_ICON_SZ * 0.55))

        -- Update MAX and ensure rows exist/hide extras
        local newMax = db.maxTargets or 8
        local oldMax = MAX
        if newMax > oldMax then
            for i = oldMax + 1, newMax do CreateRow(i) end
        elseif newMax < oldMax then
            for i = newMax + 1, oldMax do
                if rows[i] then
                    rows[i]:Hide()
                    rows[i].lastGUID = nil
                    rows[i].targetGUID = nil
                end
            end
        end
        MAX = newMax

        anchor:SetSize(ROW_W + 2, 14)

        for i = 1, MAX do
            local row = rows[i]
            row:SetSize(ROW_W, ROW_H)
            row:ClearAllPoints()
            if ANCHOR_POS == "top" then
                row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(i - 1) * (ROW_H + 2))
            else
                row:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, (i - 1) * (ROW_H + 2))
            end

            row.ptFrame:SetSize(PORTRAIT_SZ, PORTRAIT_SZ)
            row.raidIcon:SetSize(PORTRAIT_SZ * 0.45, PORTRAIT_SZ * 0.45)
            -- keep a narrow permanent backdrop on the row itself; large flashing border uses overlay
            row:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8", edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 2 })

            local hpWidth = (PORTRAIT_SIDE == "none") and (ROW_W - 2) or (ROW_W - PORTRAIT_SZ - 2)
            row.hpBar:SetSize(hpWidth, ROW_H - 2)
            -- ensure overlay matches row size and uses configured border size
                if row.borderOverlay then
                row.borderOverlay:SetAllPoints(row)
                row.borderOverlay:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8", edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = BORDER_SIZE })
                row.borderOverlay:SetBackdropColor(0, 0, 0, 0)
                row.borderOverlay:SetFrameLevel(row:GetFrameLevel() + 6)
            end
            -- reposition portrait/hpBar depending on side
            if PORTRAIT_SIDE == "left" then
                row.ptFrame:ClearAllPoints(); row.ptFrame:SetPoint("LEFT", row, "LEFT", 0, 0); row.ptFrame:Show()
                row.hpBar:ClearAllPoints(); row.hpBar:SetPoint("LEFT", row.ptFrame, "RIGHT", 2, 0)
            elseif PORTRAIT_SIDE == "right" then
                row.ptFrame:ClearAllPoints(); row.ptFrame:SetPoint("RIGHT", row, "RIGHT", 0, 0); row.ptFrame:Show()
                row.hpBar:ClearAllPoints(); row.hpBar:SetPoint("RIGHT", row.ptFrame, "LEFT", -2, 0)
                else
                row.ptFrame:ClearAllPoints(); row.ptFrame:Hide()
                row.hpBar:ClearAllPoints(); row.hpBar:SetPoint("LEFT", row, "LEFT", 1, 0)
            end

            row.nameText:SetFont("Fonts\\FRIZQT__.TTF", NAME_FONT, "OUTLINE")
            row.hpText:SetFont("Fonts\\FRIZQT__.TTF", HP_FONT, "OUTLINE")

            for bi = 1, #TRACKED_DEBUFFS do
                row.dotIcons[bi]:SetSize(DOT_ICON_SZ, DOT_ICON_SZ)
                row.dotTimers[bi]:SetFont("Fonts\\FRIZQT__.TTF", TIMER_FONT, "OUTLINE")
            end
        end

        -- Refresh dummy data timers if preview is active (rebuild preview targets)
        if previewActive and A.DotTrackerPreviewOn then
            pcall(A.DotTrackerPreviewOn)
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
                        SetTrackedTargetHPFromUnit(guid, unit)
                        recentNames[targets[guid].name] = now
                        addCounter = addCounter + 1
                        targets[guid]._addOrder = addCounter
                        added = true
                        break
                    end
                end
            end

            if not added then
                -- Add if this unit is our target/focus, or we have threat on it
                local isMyTarget = UnitIsUnit(unit, "target") or UnitIsUnit(unit, "focus")
                local hasThreat = UnitThreatSituation("player", unit)
                if UnitCanAttack("player", unit) and (isMyTarget or (hasThreat and hasThreat > 0)) then
                    targets[guid] = {
                        name = unitName or "Unknown",
                        _addedAt = now,
                        _inCombat = true,
                    }
                    SetTrackedTargetHPFromUnit(guid, unit)
                    recentNames[targets[guid].name] = now
                    addCounter = addCounter + 1
                    targets[guid]._addOrder = addCounter
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
                        if not t._addOrder then addCounter = addCounter + 1; t._addOrder = addCounter end
                end
            end
        end

        targets[guid].raidIcon = GetRaidTargetIndex(unit)
        SetTrackedTargetHPFromUnit(guid, unit)
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

    RefreshRows = function(elapsed)
        blinkTimer = blinkTimer + (elapsed or 0)
        wipe(sorted)
        local now = GetTime()
        local warnThreshold = A.db.dotTracker.warnSeconds or WARN_SEC
        local blinkSpeed    = A.db.dotTracker.blinkSpeed  or BLINK_SPD
        local warnBorderSize = A.db.dotTracker.warnBorderSize or 4
        local warnBarAlpha   = A.db.dotTracker.warnBarAlpha   or 0.35
        local warnIconAlpha  = A.db.dotTracker.warnIconAlpha  or 0.6

        -- Cleanup recently-dead targets: mark when hp reaches 0 and remove
        -- them after a short grace period so the UI doesn't linger forever.
        for guid, data in pairs(targets) do
            if not data._preview then
                if data._deadAt then
                    if (now - data._deadAt) >= 3 then
                        local nm = data.name
                        targets[guid] = nil
                        if A.ClearTargetMetric then A.ClearTargetMetric(guid) end
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

        -- Sort: addOrder (default), tabOrder (tab-cycle order)
        local sortMode = A.db and A.db.dotTracker and A.db.dotTracker.sortMode or "addOrder"
        table.sort(sorted, function(a, b)
            if sortMode == "tabOrder" then
                -- Targets tabbed earlier appear first (lower rank = row 1).
                -- Fall back to addOrder for targets not yet tabbed to.
                local ra = tabHistory[a] or 999999
                local rb = tabHistory[b] or 999999
                if ra ~= rb then return ra < rb end
            end
            local ta, tb = targets[a], targets[b]
            local pa = (ta and ta._addOrder) or 0
            local pb = (tb and tb._addOrder) or 0
            if A.db and A.db.dotTracker and A.db.dotTracker.newTargetPosition == "top" then
                return pa > pb
            else
                return pa < pb
            end
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
                                if PORTRAIT_SIDE == "left" then
                                    iconFrame:SetPoint("BOTTOMRIGHT", row.hpBar, "BOTTOMRIGHT",
                                        -(visibleCount - 1) * (DOT_ICON_SZ + 2) - 2, 2)
                                else
                                    -- when portrait on right, keep icons on the right of the bar as well
                                    iconFrame:SetPoint("BOTTOMRIGHT", row.hpBar, "BOTTOMRIGHT",
                                        -(visibleCount - 1) * (DOT_ICON_SZ + 2) - 2, 2)
                                end

                        iconFrame.icon:SetDesaturated(false)
                        iconFrame.icon:SetAlpha(1)
                        timerText:SetText(A.FormatTime(rem))

                        if rem <= warnThreshold then
                            timerText:SetTextColor(1, 0.3, 0.3, 1)
                            worstState = "warning"
                            worstColor = {col[1], col[2], col[3], 1}
                            -- Apply per-mode visual cues
                            if WARN_MODE == "icon" then
                                iconFrame.icon:SetAlpha((1 - warnIconAlpha) + warnIconAlpha * blinkAlpha)
                            else
                                iconFrame.icon:SetAlpha(1)
                            end
                            -- border highlight for all modes (base)
                            iconFrame:SetBackdropBorderColor(col[1], col[2], col[3], 1)
                        else
                            iconFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                            timerText:SetTextColor(1, 1, 1, 1)
                            iconFrame.icon:SetAlpha(1)
                        end

                        iconFrame:Show()
                    else
                        iconFrame:Hide()
                    end
                end

                -- Row border blinks when any dot is about to expire
                -- Row visual feedback depending on WARN_MODE
                if worstState == "warning" then
                    if WARN_MODE == "border" then
                        -- show overlay border on top of the row so HP width remains constant
                        if row.borderOverlay then
                            row.borderOverlay:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8", edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = warnBorderSize })
                            row.borderOverlay:SetBackdropColor(0, 0, 0, 0)
                            row.borderOverlay:SetBackdropBorderColor(worstColor[1], worstColor[2], worstColor[3], blinkAlpha)
                            row.borderOverlay:Show()
                        else
                            row:SetBackdropBorderColor(worstColor[1], worstColor[2], worstColor[3], blinkAlpha)
                        end
                    elseif WARN_MODE == "bar" then
                        -- flash the hpBar background with the dot color
                        if not row.hpBar._flash then
                            local t = row.hpBar:CreateTexture(nil, "OVERLAY")
                            t:SetAllPoints(row.hpBar)
                            row.hpBar._flash = t
                        end
                        row.hpBar._flash:SetColorTexture(worstColor[1], worstColor[2], worstColor[3], warnBarAlpha * blinkAlpha)
                        row.hpBar._flash:Show()
                        -- keep normal border
                        row:SetBackdropBorderColor(0, 0, 0, 1)
                    elseif WARN_MODE == "icon" then
                        -- keep border normal, icon already animated
                        row:SetBackdropBorderColor(0, 0, 0, 1)
                    else
                        row:SetBackdropBorderColor(0, 0, 0, 1)
                    end
                else
                    -- clear any flash artifacts: hide overlay and restore small backdrop
                    if row.borderOverlay then row.borderOverlay:Hide() end
                    row:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8", edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 2 })
                    row:SetBackdropBorderColor(0, 0, 0, 1)
                    if row.hpBar._flash then row.hpBar._flash:Hide() end
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
                        SetTrackedTargetHPFromUnit(guid, np)
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
                SetTrackedTargetHPFromUnit(tGUID, "target")
                -- Record tab order: only register the first time this GUID is tabbed to.
                if not tabHistory[tGUID] then
                    tabRankCounter = tabRankCounter + 1
                    tabHistory[tGUID] = tabRankCounter
                end
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
                    SetTrackedTargetHPFromUnit(guid, arg1)
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
                    SetTrackedTargetHPFromUnit(guid, arg1)
                end
            end
            return
        end

        if event == "PLAYER_REGEN_ENABLED" then
            playerInCombat = false
            wipe(targets)
            if A.ResetTargetMetrics then A.ResetTargetMetrics() end
            wipe(tabHistory)
            tabRankCounter = 0
            previewActive = false
            if anchor then anchor:Hide() end
            return
        end

        if event == "PLAYER_REGEN_DISABLED" then
            playerInCombat = true
            -- Reset tab history each combat so stale tab order doesn't carry over
            wipe(tabHistory)
            tabRankCounter = 0
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
                        if A.ClearTargetMetric then A.ClearTargetMetric(destGUID) end
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
                                return SetTrackedTargetHPFromUnit(destGUID, unit)
                            end
                            return false
                        end
                        if not tryAssignHP("target") and not tryAssignHP("focus") and not tryAssignHP("mouseover") then
                            -- If we had a recent tombstone, mark as dead so it won't show full HP
                            local t = tombstones[destGUID]
                            if t and (GetTime() - t) < TOMB_LIFE then
                                SetTrackedTargetHP(destGUID, 0)
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

        -- Something attacking the player directly: track source as combat mob
        -- Only add mobs that are directly hitting us (we're on their threat table)
        if destGUID == playerGUID and sourceGUID
           and sourceGUID ~= playerGUID then
            if sourceFlags
               and (bit.band(sourceFlags, COMBATLOG_OBJECT_REACTION_HOSTILE) > 0
                    or bit.band(sourceFlags, COMBATLOG_OBJECT_REACTION_NEUTRAL) > 0)
               and sourceName and sourceName ~= ""
               and not (bit.band(sourceFlags, COMBATLOG_OBJECT_CONTROL_PLAYER) > 0)
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

    A._dotTrackerCLEU = ev
    A._dotTrackerInitialized = true
end

------------------------------------------------------------------------
-- Register as SpecManager helper
------------------------------------------------------------------------
if SPHelper.SpecManager then
    SPHelper.SpecManager:RegisterHelper("DotTracker", {
        _initialized = false,
        OnSpecActivate = function(self, spec)
            if self._initialized then return end
            self._initialized = true
            -- Rebuild tracked debuffs from spec before init
            TRACKED_DEBUFFS = BuildTrackedDebuffs()
            if SPHelper.InitDotTracker then SPHelper:InitDotTracker() end
        end,
        OnSpecDeactivate = function(self, spec)
            self._initialized = false
            if SPHelper.dotAnchor then
                SPHelper.dotAnchor:Hide()
            end
            -- Unregister the CLEU handler frame if it exists
            if SPHelper._dotTrackerCLEU then
                SPHelper._dotTrackerCLEU:UnregisterAllEvents()
            end
            SPHelper._dotTrackerInitialized = false
        end,
    })
end
