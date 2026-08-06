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
                key      = def.key,
                spellKey = def.spellKey,
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
                key      = def.key,
                spellKey = def.spellKey,
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
        if A.DotTrackerUpdateVisibility then
            A.DotTrackerUpdateVisibility()
        elseif UnitAffectingCombat("player") or A.dotTrackerPreviewActive then
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
    local combatOrderCounter = 0
    local playerGUID  = UnitGUID("player")
    local TOMB_LIFE   = 12 -- seconds to keep a tombstone preventing re-adds
    local STALE_COMBAT_GRACE = 8

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
    -- Persist position across /reload.
    if A.RegisterMovableFrame then
        A.RegisterMovableFrame(anchor, "dotTracker",
            { point = "CENTER", relPoint = "CENTER", x = 220, y = -100 })
    end

    local title = anchor:CreateFontString(nil, "OVERLAY")
    title:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
    title:SetPoint("CENTER")
    title:SetText("|cff8882d5Targets|r")
    -- Show anchor only if player is in combat or preview will be active.
    if UnitAffectingCombat("player") or A.dotTrackerPreviewActive then
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
    -- Updated on PLAYER_TARGET_CHANGED and reset after combat ends.
    local tabHistory     = {}
    local tabRankCounter = 0
    A.dotTargets  = targets
    local playerInCombat = UnitAffectingCombat("player")

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

    local function IsAttackableLivingUnit(unit)
        if not unit or not UnitExists(unit) then return false end
        if not UnitCanAttack("player", unit) then return false end
        if UnitIsDeadOrGhost and UnitIsDeadOrGhost(unit) then return false end
        if (UnitHealthMax(unit) or 0) > 0 and (UnitHealth(unit) or 0) <= 0 then return false end
        return true
    end

    local function FindUnitForGUID(guid, preferredUnit)
        if not guid then return nil end
        if preferredUnit and UnitExists(preferredUnit) and UnitGUID(preferredUnit) == guid then
            return preferredUnit
        end
        local candidates = { "target", "focus", "mouseover" }
        for _, unit in ipairs(candidates) do
            if UnitExists(unit) and UnitGUID(unit) == guid then return unit end
        end
        for i = 1, 5 do
            local unit = "boss" .. i
            if UnitExists(unit) and UnitGUID(unit) == guid then return unit end
        end
        for i = 1, 40 do
            local unit = "nameplate" .. i
            if UnitExists(unit) and UnitGUID(unit) == guid then return unit end
        end
        return nil
    end
    A.FindUnitForGUID = FindUnitForGUID

    local function HasActiveDot(data, now)
        if not data then return false end
        for _, def in ipairs(TRACKED_DEBUFFS) do
            local exp = data[def.key .. "_exp"]
            if exp and exp > now then return true end
        end
        return false
    end

    local function MarkTargetEngaged(data, unit, now)
        if not data then return end
        now = now or GetTime()
        data._inCombat = true
        data._lastCombat = now
        local inCombatNow = playerInCombat or UnitAffectingCombat("player")
        if unit and UnitAffectingCombat(unit) then inCombatNow = true end
        if inCombatNow and not data._combatOrder then
            combatOrderCounter = combatOrderCounter + 1
            data._combatOrder = combatOrderCounter
            data._combatAt = now
        end
        if unit then data._unitToken = unit end
    end

    local function RemoveTrackedTarget(guid, tombstone)
        local data = guid and targets[guid]
        if not data then return end
        local name = data.name
        targets[guid] = nil
        if A.ClearTargetMetric then A.ClearTargetMetric(guid) end
        if tombstone then
            local now = GetTime()
            tombstones[guid] = now
            if name and name ~= "" then tombstoneNames[name] = now end
        end
    end

    local function IsTrackedTargetAlive(guid, data, now)
        if not data then return false end
        if data._preview then return true end
        if data._deadAt then return false end
        local unit = FindUnitForGUID(guid, data._unitToken)
        if unit then
            data._unitToken = unit
            if not IsAttackableLivingUnit(unit) then return false end
            SetTrackedTargetHPFromUnit(guid, unit)
        elseif data.hpPct and data.hpPct <= 0 then
            return false
        end
        return true
    end

    local function IsTrackedTargetEngaged(guid, data, now)
        if not data then return false end
        if data._preview then return true end
        -- Manually added entries are permanent while the mob is alive and are
        -- shown even out of combat, so they never need the combat/threat gate.
        if data._manual then return true end
        if not playerInCombat and not UnitAffectingCombat("player") then return false end
        local unit = FindUnitForGUID(guid, data._unitToken)
        if unit then
            data._unitToken = unit
            if UnitAffectingCombat(unit) then
                MarkTargetEngaged(data, unit, now)
                return true
            end
        end
        if data._lastCombat and (now - data._lastCombat) <= STALE_COMBAT_GRACE then
            return true
        end
        return data._inCombat and HasActiveDot(data, now) and playerInCombat
    end

    local function EnsureTrackedTarget(guid, name, unit, manual)
        if not guid then return nil end
        local now = GetTime()
        local data = targets[guid]
        if not data then
            addCounter = addCounter + 1
            data = {
                name = name or "Unknown",
                _addedAt = now,
                _addOrder = addCounter,
                _manual = manual or nil,
            }
            targets[guid] = data
        else
            data.name = name or data.name
            if manual then data._manual = true end
            if not data._addOrder then addCounter = addCounter + 1; data._addOrder = addCounter end
        end
        MarkTargetEngaged(data, unit, now)
        if name and name ~= "" then recentNames[name] = now end
        if unit then
            data.raidIcon = GetRaidTargetIndex(unit)
            SetTrackedTargetHPFromUnit(guid, unit)
        end
        return data
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
        combatOrderCounter = 0
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
            combatOrderCounter = combatOrderCounter + 1
            targets[guid] = {
                name = name,
                _addedAt = now - (i * 2),
                _inCombat = true,
                _preview  = true,
                raidIcon = ((i - 1) % #RAID_ICONS) + 1,
                _addOrder = addCounter,
                _combatOrder = combatOrderCounter,
                _combatAt = now - (i * 1.5),
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
    -- Visibility: the anchor is shown while in combat, while previewing, or
    -- whenever at least one manual (permanent) target is being tracked. This
    -- lets pre-combat manual entries remain visible out of combat.
    ----------------------------------------------------------------
    local function HasManualTargets()
        for _, data in pairs(targets) do
            if data._manual then return true end
        end
        return false
    end

    local function UpdateAnchorVisibility()
        if not anchor then return end
        if not (A.db.dotTracker and A.db.dotTracker.enabled) then
            anchor:Hide(); return
        end
        if previewActive or A.dotTrackerPreviewActive
            or UnitAffectingCombat("player") or HasManualTargets() then
            anchor:Show()
        else
            anchor:Hide()
        end
    end
    A.DotTrackerUpdateVisibility = UpdateAnchorVisibility

    ----------------------------------------------------------------
    -- Right-click context menu for a tracked row ("Remove from list").
    ----------------------------------------------------------------
    local rowContextMenu
    local function ShowRowContextMenu(guid)
        if not (guid and targets[guid]) then return end
        if not rowContextMenu then
            local menu = CreateFrame("Frame", "SPHelperDotRowMenu", UIParent, "BackdropTemplate")
            menu:SetSize(150, 30)
            menu:SetFrameStrata("TOOLTIP")
            menu:EnableMouse(true)
            A.CreateBackdrop(menu, 0.10, 0.09, 0.14, 0.98, 0.42, 0.40, 0.52, 1)

            -- Full-screen catcher so a click anywhere else dismisses the menu.
            local catcher = CreateFrame("Button", nil, UIParent)
            catcher:SetAllPoints(UIParent)
            catcher:SetFrameStrata("FULLSCREEN_DIALOG")
            catcher:RegisterForClicks("AnyUp")
            catcher:Hide()
            catcher:SetScript("OnClick", function() menu:Hide() end)
            menu.catcher = catcher

            local remove = CreateFrame("Button", nil, menu)
            remove:SetPoint("TOPLEFT", 4, -4)
            remove:SetPoint("BOTTOMRIGHT", -4, 4)
            local hl = remove:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0.12)
            local lbl = remove:CreateFontString(nil, "OVERLAY")
            lbl:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
            lbl:SetPoint("LEFT", 8, 0)
            lbl:SetText("Remove from list")
            lbl:SetTextColor(1, 0.55, 0.55, 1)
            remove:SetScript("OnClick", function()
                local g = menu._guid
                if g and targets[g] then
                    RemoveTrackedTarget(g, true)
                    if RefreshRows then RefreshRows(0) end
                    UpdateAnchorVisibility()
                end
                menu:Hide()
            end)
            menu:SetScript("OnHide", function(self)
                if self.catcher then self.catcher:Hide() end
                self._guid = nil
            end)
            rowContextMenu = menu
        end

        rowContextMenu._guid = guid
        rowContextMenu:ClearAllPoints()
        local scale = UIParent:GetEffectiveScale()
        local cx, cy = GetCursorPosition()
        rowContextMenu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx / scale, cy / scale)
        rowContextMenu.catcher:Show()
        rowContextMenu:Show()
    end

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

        -- Hover highlight: a subtle additive wash over the bar so the row
        -- remains easy to scan while mousing over the right-click menu target.
        local hoverHL = hpBar:CreateTexture(nil, "ARTWORK")
        hoverHL:SetAllPoints(hpBar)
        hoverHL:SetColorTexture(1, 1, 1, 0.12)
        hoverHL:SetBlendMode("ADD")
        hoverHL:Hide()
        row.hoverHL = hoverHL

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
        row:EnableMouse(true)
        row:SetScript("OnEnter", function(self)
            local guid = self.targetGUID
            local data = guid and targets[guid]
            if not data then return end
            if self.hoverHL then self.hoverHL:Show() end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(data.name or "Tracked target")
            GameTooltip:AddLine("Right-click for options (remove from list).", 0.85, 0.85, 0.85)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function(self)
            if row.hoverHL then row.hoverHL:Hide() end
            GameTooltip:Hide()
        end)
        row:SetScript("OnMouseUp", function(self, button)
            if button == "RightButton" then
                ShowRowContextMenu(self.targetGUID)
            end
        end)

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
    -- Scan a unit's debuffs and update tracker data.
    -- New targets are only added when they are alive, hostile, and engaged.
    ----------------------------------------------------------------
    local function ScanUnit(unit)
        if not UnitExists(unit) then return end
        local guid = UnitGUID(unit)
        if not guid then return end
        local now = GetTime()

        if tombstones[guid] and (now - tombstones[guid]) < TOMB_LIFE then
            return
        end

        if not IsAttackableLivingUnit(unit) then
            if targets[guid] then targets[guid]._deadAt = now end
            return
        end

        local unitName = UnitName(unit)
        local hasTrackedDebuff = false
        for _, def in ipairs(TRACKED_DEBUFFS) do
            local sp = def.spell()
            if sp and sp.name then
                -- ID-first lookup via the catalog key (all ranks/sibling IDs, name fallback)
                local _, _, _, _, _, expirationTime = A.FindPlayerDebuff(unit, def.spellKey or sp.name)
                if expirationTime and expirationTime > now then
                    hasTrackedDebuff = true
                    break
                end
            end
        end

        local data = targets[guid]
        local hasThreat = UnitThreatSituation("player", unit)
        local unitCombat = UnitAffectingCombat(unit)
        local engagedByUnit = hasTrackedDebuff or unitCombat or (hasThreat and hasThreat > 0)
        if not data then
            if not (playerInCombat and engagedByUnit) then
                return
            end
            data = EnsureTrackedTarget(guid, unitName or "Unknown", unit, false)
        else
            data.name = unitName or data.name
            data._unitToken = unit
            data._lastSeen = now
            if playerInCombat and engagedByUnit then
                MarkTargetEngaged(data, unit, now)
            end
        end

        for _, def in ipairs(TRACKED_DEBUFFS) do
            local sp = def.spell()
            if sp and sp.name then
                -- ID-first lookup via the catalog key (all ranks/sibling IDs, name fallback)
                local name, icon, count, debuffType, duration, expirationTime = A.FindPlayerDebuff(unit, def.spellKey or sp.name)
                if name and expirationTime and expirationTime > now then
                    data.name = unitName or data.name
                    data[def.key .. "_dur"] = duration
                    data[def.key .. "_exp"] = expirationTime
                    if not data._addOrder then addCounter = addCounter + 1; data._addOrder = addCounter end
                else
                    data[def.key .. "_exp"] = 0
                end
            end
        end

        data.raidIcon = GetRaidTargetIndex(unit)
        SetTrackedTargetHPFromUnit(guid, unit)
    end

    function A.DotTrackerAddUnit(unit)
        unit = unit or "target"
        if not UnitExists(unit) then
            print("|cff8882d5SPHelper|r: No target to add to the " .. (A.TRACKER_NAME or "Target Tracker") .. ".")
            return false
        end
        if not IsAttackableLivingUnit(unit) then
            print("|cff8882d5SPHelper|r: The " .. (A.TRACKER_NAME or "Target Tracker") .. " can only add living hostile targets.")
            return false
        end

        local guid = UnitGUID(unit)
        if not guid then return false end
        -- Adding clears any tombstone so the entry is allowed back immediately.
        tombstones[guid] = nil
        local data = EnsureTrackedTarget(guid, UnitName(unit) or "Unknown", unit, true)
        if not data then return false end
        data._manual = true
        ScanUnit(unit)
        UpdateAnchorVisibility()
        RefreshRows(0)
        print("|cff8882d5SPHelper|r: Added |cffffcc00" .. (data.name or "target") .. "|r to the " .. (A.TRACKER_NAME or "Target Tracker") .. ".")
        return true
    end

    function A.DotTrackerAddCurrentTarget()
        return A.DotTrackerAddUnit("target")
    end

    function A.DotTrackerRemoveCurrentTarget()
        local guid = UnitGUID("target")
        if guid and targets[guid] then
            local name = targets[guid].name or "target"
            RemoveTrackedTarget(guid, true)
            RefreshRows(0)
            UpdateAnchorVisibility()
            print("|cff8882d5SPHelper|r: Removed |cffffcc00" .. name .. "|r from the " .. (A.TRACKER_NAME or "Target Tracker") .. ".")
            return true
        end
        print("|cff8882d5SPHelper|r: Current target is not listed in the " .. (A.TRACKER_NAME or "Target Tracker") .. ".")
        return false
    end

    function A.DotTrackerClearManualTargets()
        local removed = 0
        for guid, data in pairs(targets) do
            if data._manual then
                RemoveTrackedTarget(guid, true)
                removed = removed + 1
            end
        end
        RefreshRows(0)
        UpdateAnchorVisibility()
        print("|cff8882d5SPHelper|r: Cleared " .. removed .. " manually added " .. (A.TRACKER_NAME or "Target Tracker") .. " target(s).")
        return removed
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

        -- Collect only targets that are still alive and engaged with the player.
        for guid, data in pairs(targets) do
            if data._preview then
                sorted[#sorted + 1] = guid
            else
                local unit = FindUnitForGUID(guid, data._unitToken)
                if unit then
                    data._unitToken = unit
                    if playerInCombat and UnitAffectingCombat(unit) then
                        MarkTargetEngaged(data, unit, now)
                    end
                end

                if not IsTrackedTargetAlive(guid, data, now) then
                    RemoveTrackedTarget(guid, true)
                elseif IsTrackedTargetEngaged(guid, data, now) then
                    sorted[#sorted + 1] = guid
                else
                    RemoveTrackedTarget(guid, false)
                end
            end
        end

        -- Sort modes. WoW does not expose the future tab-target candidate
        -- list; tab modes are based on observed PLAYER_TARGET_CHANGED order.
        local sortMode = A.db and A.db.dotTracker and A.db.dotTracker.sortMode or "tabOrder"
        local currentTargetGUID = UnitGUID("target")
        local currentTabRank = currentTargetGUID and tabHistory[currentTargetGUID]
        local function AddRank(guid)
            local data = targets[guid]
            return (data and data._addOrder) or 999999
        end
        local function CombatRank(guid)
            local data = targets[guid]
            return (data and data._combatOrder) or AddRank(guid) or 999999
        end
        local function TargetName(guid)
            local data = targets[guid]
            local name = data and data.name or ""
            return string.lower(name or "")
        end
        local function EarliestDebuffRemaining(guid)
            local data = targets[guid]
            if not data then return 999999 end
            local best = 999999
            for _, def in ipairs(TRACKED_DEBUFFS) do
                local exp = data[def.key .. "_exp"]
                if exp and exp > now then
                    local rem = exp - now
                    if rem < best then best = rem end
                end
            end
            return best
        end
        local function ObservedTabRank(guid)
            local rank = tabHistory[guid]
            if not rank then return nil end
            if currentTabRank and tabRankCounter > 0 then
                if rank > currentTabRank then
                    return rank - currentTabRank
                elseif rank < currentTabRank then
                    return (tabRankCounter - currentTabRank) + rank
                else
                    return tabRankCounter
                end
            end
            return rank
        end
        local function StableTabAssistRank(guid)
            -- Keep the combat-entry layout steady. Tab history is used only as
            -- a fallback for entries that have not yet received a combat rank.
            local data = targets[guid]
            if data and data._combatOrder then return data._combatOrder end
            return tabHistory[guid] or AddRank(guid) or 999999
        end
        table.sort(sorted, function(a, b)
            if sortMode == "alphabetical" then
                local na, nb = TargetName(a), TargetName(b)
                if na ~= nb then return na < nb end
            elseif sortMode == "combatOrder" then
                local ra, rb = CombatRank(a), CombatRank(b)
                if ra ~= rb then return ra < rb end
            elseif sortMode == "tabOrder" then
                local ra = ObservedTabRank(a) or 999999
                local rb = ObservedTabRank(b) or 999999
                if ra ~= rb then return ra < rb end
            elseif sortMode == "tabStable" then
                local ra, rb = StableTabAssistRank(a), StableTabAssistRank(b)
                if ra ~= rb then return ra < rb end
            elseif sortMode == "healthAsc" then
                local ta, tb = targets[a], targets[b]
                local ha = (ta and ta.hpPct) or 1
                local hb = (tb and tb.hpPct) or 1
                if ha ~= hb then return ha < hb end
            elseif sortMode == "raidIcon" then
                local ta, tb = targets[a], targets[b]
                local ia = (ta and ta.raidIcon) or 99
                local ib = (tb and tb.raidIcon) or 99
                if ia ~= ib then return ia < ib end
            elseif sortMode == "debuffExpiry" then
                local ea, eb = EarliestDebuffRemaining(a), EarliestDebuffRemaining(b)
                if ea ~= eb then return ea < eb end
            end
            local pa = AddRank(a)
            local pb = AddRank(b)
            if A.db and A.db.dotTracker and A.db.dotTracker.newTargetPosition == "top" then
                return pa > pb
            else
                return pa < pb
            end
        end)

        -- Blink alpha oscillator
        local blinkAlpha = 0.5 + 0.5 * math.sin(blinkTimer * blinkSpeed * math.pi * 2)
        local targetGUID = currentTargetGUID
        local focusGUID  = UnitGUID("focus")

        for i = 1, MAX do
            local row  = rows[i]
            local guid = sorted[i]
            if guid then
                local data = targets[guid]
                local unitToken = FindUnitForGUID(guid, data._unitToken)
                if unitToken then
                    data._unitToken = unitToken
                    data.raidIcon = GetRaidTargetIndex(unitToken)
                end
                row.nameText:SetText(data.name or "???")
                row.targetGUID = guid

                -- Portrait: update from unitID if available, otherwise keep
                if data._preview then
                    row.portrait:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                elseif unitToken then
                    SetPortraitTexture(row.portrait, unitToken)
                    row.lastGUID = guid
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
                row.targetGUID = nil
            end
        end

        -- Hide the anchor again once nothing (combat, preview, or a manual
        -- entry) keeps it alive; shows are driven by events / manual adds.
        UpdateAnchorVisibility()
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
            for i = 1, 40 do
                local np = "nameplate" .. i
                if UnitExists(np) then
                    ScanUnit(np)
                    local guid = UnitGUID(np)
                    if guid and targets[guid] then
                        SetTrackedTargetHPFromUnit(guid, np)
                    end
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

    playerInCombat = UnitAffectingCombat("player")

    ev:SetScript("OnEvent", function(self, event, arg1)
        -- Respect the runtime enable toggle: when the user disables the DoT
        -- Tracker from the dashboard we stop processing and hide the anchor
        -- without tearing down the (already-registered) event frame.
        if not (A.db.dotTracker and A.db.dotTracker.enabled) then
            if anchor then anchor:Hide() end
            return
        end

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
                ScanUnit(arg1)
                if guid and targets[guid] then
                    SetTrackedTargetHPFromUnit(guid, arg1)
                    UpdatePortraitForUnit(arg1)
                end
            end
            return
        end

        if event == "NAME_PLATE_UNIT_REMOVED" then
            if arg1 then
                local guid = UnitGUID(arg1)
                if guid and targets[guid] and targets[guid]._unitToken == arg1 then
                    targets[guid]._unitToken = nil
                end
            end
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
            -- Keep manual (permanent) entries so they stay visible out of
            -- combat while the mob is alive; drop only auto-tracked targets.
            for guid, data in pairs(targets) do
                if not data._manual and not data._preview then
                    RemoveTrackedTarget(guid, false)
                elseif data and not data._preview then
                    data._combatOrder = nil
                    data._combatAt = nil
                end
            end
            combatOrderCounter = 0
            if A.ResetTargetMetrics then A.ResetTargetMetrics() end
            wipe(tabHistory)
            tabRankCounter = 0
            UpdateAnchorVisibility()
            return
        end

        if event == "PLAYER_REGEN_DISABLED" then
            playerInCombat = true
            combatOrderCounter = 0
            for _, data in pairs(targets) do
                if data and not data._preview then
                    data._combatOrder = nil
                    data._combatAt = nil
                end
            end
            UpdateAnchorVisibility()
            return
        end

        -- COMBAT_LOG_EVENT_UNFILTERED
        local timestamp, subEvent, hideCaster, sourceGUID, sourceName,
              sourceFlags, sourceRaidFlags, destGUID, destName,
              destFlags, destRaidFlags, spellId, spellName, spellSchool
              = CombatLogGetCurrentEventInfo()

        if not subEvent then return end

        -- Remove dead mobs immediately. Handled before the combat gate so manual
        -- entries are cleared the moment the mob dies, even out of combat.
        if subEvent == "UNIT_DIED" or subEvent == "PARTY_KILL" then
            if destGUID and targets[destGUID] then
                RemoveTrackedTarget(destGUID, true)
                UpdateAnchorVisibility()
            end
            return
        end

        -- Allow tracking even if PLAYER_REGEN_DISABLED hasn't fired yet
        -- (fixes race where first CLEU event arrives before combat flag)
        if not playerInCombat and UnitAffectingCombat("player") then
            playerInCombat = true
        end
        if not playerInCombat then return end

        -- Player as source: track dest as combat mob + debuffs
        -- Only track hostile NPCs/players (filter via destFlags)
        if sourceGUID == playerGUID then
            if destGUID and destGUID ~= playerGUID and destFlags then
                local isHostile = bit.band(destFlags, COMBATLOG_OBJECT_REACTION_HOSTILE) > 0
                local isNeutral = bit.band(destFlags, COMBATLOG_OBJECT_REACTION_NEUTRAL) > 0
                local isNPCorPlayer = bit.band(destFlags,
                    COMBATLOG_OBJECT_TYPE_NPC + COMBATLOG_OBJECT_TYPE_PLAYER) > 0
                if (isHostile or isNeutral) and isNPCorPlayer then
                    local now = GetTime()
                    if tombstones[destGUID] and (now - tombstones[destGUID]) < TOMB_LIFE then
                        return
                    else
                        tombstones[destGUID] = nil
                    end
                    if destName and tombstoneNames[destName] then
                        local tombstoneTime = tombstoneNames[destName]
                        local recentTime = recentNames[destName]
                        if recentTime and (now - recentTime) < TOMB_LIFE and (now - tombstoneTime) < TOMB_LIFE then
                            return
                        end
                    end

                    local unit = FindUnitForGUID(destGUID)
                    local data = EnsureTrackedTarget(destGUID, destName or "Unknown", unit, false)
                    if data then
                        MarkTargetEngaged(data, unit, now)
                        if unit and not IsAttackableLivingUnit(unit) then
                            data._deadAt = now
                        end
                    end

                    -- Debuff tracking (only for hostile targets we're tracking)
                    if targets[destGUID] and spellName then
                        local debuffKey = nameToKey[spellName]
                        local debuffDef
                        if not debuffKey then
                            -- Non-English clients: CLEU spell names are localized
                            -- (e.g. German "Gedankenschlag"); the spell DB registers
                            -- localized names, so resolve and retry by catalog key.
                            debuffDef = A.GetSpellDefinition and A.GetSpellDefinition(spellName)
                            if debuffDef then
                                debuffKey = nameToKey[debuffDef.name] or nameToKey[debuffDef.key]
                            end
                        end
                        if debuffKey then
                            if subEvent == "SPELL_AURA_APPLIED"
                            or subEvent == "SPELL_AURA_REFRESH" then
                                local t = targets[destGUID]
                                local dur = nameToDur[spellName] or (debuffDef and nameToDur[debuffDef.name]) or 15
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
                local unit = FindUnitForGUID(sourceGUID)
                EnsureTrackedTarget(sourceGUID, sourceName, unit, false)
            end
        end
    end)

    A._dotTrackerCLEU = ev
    A._dotTrackerInitialized = true
end

------------------------------------------------------------------------
-- Unit right-click menu integration.
-- Adds an "Add to <Target Tracker>" entry to the target/focus unit menus
-- (the same dropdown that contains "Set Focus"), so the player can mark a
-- mob without using a slash command.  Uses the classic UnitPopup API that
-- ships with the 2.5.x (Anniversary) client.
------------------------------------------------------------------------
local function SetupUnitPopupIntegration()
    if A._dotTrackerPopupHooked then return end
    if type(UnitPopupButtons) ~= "table" or type(UnitPopupMenus) ~= "table" then return end
    if type(hooksecurefunc) ~= "function" then return end
    A._dotTrackerPopupHooked = true

    local TOKEN = "SPH_ADD_TO_TRACKER"
    UnitPopupButtons[TOKEN] = { text = "Add to " .. (A.TRACKER_NAME or "Target Tracker"), dist = 0 }

    local function InsertToken(menuName)
        local menu = UnitPopupMenus[menuName]
        if type(menu) ~= "table" then return end
        for _, tok in ipairs(menu) do
            if tok == TOKEN then return end
        end
        -- Insert just before the trailing CANCEL entry when present.
        local insertAt = #menu + 1
        for i = #menu, 1, -1 do
            if menu[i] == "CANCEL" then insertAt = i; break end
        end
        table.insert(menu, insertAt, TOKEN)
    end
    InsertToken("target")
    InsertToken("focus")

    -- Make sure the tracker module is initialized (its A.DotTracker* API is
    -- built inside InitDotTracker) before we try to add a unit.
    local function EnsureReady()
        if A.DotTrackerAddUnit then return true end
        if A.db and A.db.dotTracker and A.db.dotTracker.enabled and A.InitDotTracker then
            pcall(A.InitDotTracker, A)
        end
        return A.DotTrackerAddUnit ~= nil
    end

    hooksecurefunc("UnitPopup_OnClick", function(self)
        if self.value ~= TOKEN then return end
        local dd = UIDROPDOWNMENU_INIT_MENU or UIDROPDOWNMENU_OPEN_MENU
        local unit = dd and dd.unit
        if not unit or not UnitExists(unit) then unit = "target" end
        if EnsureReady() and A.DotTrackerAddUnit then
            A.DotTrackerAddUnit(unit)
        else
            print("|cff8882d5SPHelper|r: " .. (A.TRACKER_NAME or "Target Tracker")
                .. " is disabled for the active rotation.")
        end
    end)

    -- Hide the entry on units that cannot be added (friendly / dead / none).
    -- Wrapped in pcall because the UnitPopupShown layout varies slightly
    -- between client builds; if it ever fails the entry simply stays visible.
    if type(UnitPopup_HideButtons) == "function" then
        hooksecurefunc("UnitPopup_HideButtons", function()
            pcall(function()
                local dd = UIDROPDOWNMENU_INIT_MENU
                local which = dd and dd.which
                local unit = dd and dd.unit
                if not which or type(UnitPopupMenus[which]) ~= "table" then return end
                if type(UnitPopupShown) ~= "table" then return end
                local canAdd = unit and UnitExists(unit)
                    and UnitCanAttack("player", unit) and not UnitIsDead(unit)
                local level = UnitPopupShown[1]
                if type(level) ~= "table" then level = UnitPopupShown end
                for index, tok in ipairs(UnitPopupMenus[which]) do
                    if tok == TOKEN then
                        level[index] = canAdd and 1 or 0
                    end
                end
            end)
        end)
    end
end

SetupUnitPopupIntegration()

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
