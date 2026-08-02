------------------------------------------------------------------------
-- SPHelper  –  Rotation.lua
-- "What to cast next" advisor. Delegates to RotationEngine for all
-- spec-specific logic. Consumables/potions/runes handled as generic items.
------------------------------------------------------------------------
local A = SPHelper

local LIVE_FADE_PROFILE = {
    primaryOutStart = 0.00,
    primaryOutEnd = 0.75,
    secondaryInStart = 0.25,
    secondaryInEnd = 0.95,
    curve = "smooth",
}

local LIVE_FADE_SPEED = 1.5

local function ResolveTestSpell(spellKey)
    local spell = A.SPELLS and A.SPELLS[spellKey] or nil
    if spell then
        local spellId = spell.id or spell.baseId
        local icon = spell.icon or ((A.GetSpellIconCached and spellId) and A.GetSpellIconCached(spellId)) or (spellId and select(3, GetSpellInfo(spellId)))
        if icon then
            return icon, spell.label or spell.name or spellKey
        end
    end
    return "Interface\\Icons\\INV_Misc_QuestionMark", spellKey
end

local function ConfigureDualTexture(tex, icon, alpha)
    if not tex then return end

    tex:SetTexture(icon)
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    tex:SetBlendMode("BLEND")
    tex:SetAlpha(alpha or 1)
end

local function SetBadgePosition(tex, content, corner, size)
    tex:ClearAllPoints()
    tex:SetSize(size, size)
    if corner == "TR" then
        tex:SetPoint("TOPRIGHT", content, "TOPRIGHT", 3, -3)
    elseif corner == "BR" then
        tex:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 3, 3)
    elseif corner == "TL" then
        tex:SetPoint("TOPLEFT", content, "TOPLEFT", -3, -3)
    else
        tex:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", -3, 3)
    end
end

local function Clamp01(value)
    if value < 0 then
        return 0
    elseif value > 1 then
        return 1
    end
    return value
end

local function SmoothStep(value)
    value = Clamp01(value)
    return value * value * (3 - 2 * value)
end

local function SmootherStep(value)
    value = Clamp01(value)
    return value * value * value * (value * (value * 6 - 15) + 10)
end

local function ApplyFadeCurve(value, curve)
    if curve == "smooth" then
        return SmoothStep(value)
    elseif curve == "smoother" then
        return SmootherStep(value)
    end
    return value
end

local function FadeRamp(phase, startPhase, endPhase, curve)
    if endPhase <= startPhase then
        return phase >= endPhase and 1 or 0
    end

    local value = (phase - startPhase) / (endPhase - startPhase)
    value = Clamp01(value)
    return ApplyFadeCurve(value, curve)
end

-- Returns (primaryAlpha, secondaryAlpha) for the crossfade animation.
-- cycle ∈ [0,2): first half fades primary→secondary; second half reverses.
local function GetFadeAlphas(cfg, cycle)
    local firstHalf = cycle < 1
    local phase = firstHalf and cycle or (cycle - 1)
    if firstHalf then
        local primaryAlpha   = 1 - FadeRamp(phase, cfg.primaryOutStart,   cfg.primaryOutEnd,   cfg.curve)
        local secondaryAlpha =     FadeRamp(phase, cfg.secondaryInStart,  cfg.secondaryInEnd,  cfg.curve)
        return primaryAlpha, secondaryAlpha
    else
        -- Mirror: secondary (now leading) fades out; primary fades back in.
        local primaryAlpha   =     FadeRamp(phase, cfg.secondaryInStart,  cfg.secondaryInEnd,  cfg.curve)
        local secondaryAlpha = 1 - FadeRamp(phase, cfg.primaryOutStart,   cfg.primaryOutEnd,   cfg.curve)
        return primaryAlpha, secondaryAlpha
    end
end

-- Maximum number of bonus slots shown to the left of primary (trinkets, potions, runes, shadowfiend, etc.)
local MAX_BONUS_SLOTS = 6

function A:InitRotation()
    local db = A.db.rotation
    if not db.enabled then return end
    if db.showKeybinds == nil then db.showKeybinds = true end

    local ICON    = db.primaryIconSize or db.iconSize
    local SMALL   = math.floor((db.iconSize or 40) * 0.6)

    ----------------------------------------------------------------
    -- Anchor frame
    ----------------------------------------------------------------
    local f = CreateFrame("Frame", "SPHelperRotation", UIParent)
    f:SetSize(ICON + SMALL * 3 + 20, ICON + 4)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, -240)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        if not A.db.locked then self:StartMoving() end
    end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    local opacity = (A.db.rotation and A.db.rotation.opacity) or 100
    f:SetAlpha(opacity / 100)
    f:Show()
    A.rotFrame = f
    A.RotationRefreshOpacity = function()
        local o = (A.db.rotation and A.db.rotation.opacity) or 100
        if A.rotFrame then A.rotFrame:SetAlpha(o / 100) end
    end
    if A.RegisterMovableFrame then
        A.RegisterMovableFrame(f, "rotation",
            { point = "CENTER", relPoint = "CENTER", x = 0, y = -240 })
    end

    

    ----------------------------------------------------------------
    -- Helper: create an icon frame
    ----------------------------------------------------------------
    local function MakeIcon(parent, size, anchorTo, xOff, yOff)
        local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        frame:SetSize(size, size)
        if anchorTo then
            frame:SetPoint("LEFT", anchorTo, "RIGHT", xOff or 4, yOff or 0)
        else
            frame:SetPoint("LEFT", parent, "LEFT", xOff or 0, yOff or 0)
        end
        A.CreateBackdrop(frame, 0, 0, 0, 0.85)

        local icon = frame:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", 1, -1)
        icon:SetPoint("BOTTOMRIGHT", -1, 1)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        frame.icon = icon

        local cdText = frame:CreateFontString(nil, "OVERLAY")
        cdText:SetFont("Fonts\\FRIZQT__.TTF", math.max(9, math.floor(size * 0.28)), "OUTLINE")
        cdText:SetPoint("CENTER")
        cdText:SetTextColor(1, 1, 1, 1)
        cdText:SetText("")
        frame.cdText = cdText

        -- GCD / cooldown sweep overlay (CooldownFrameTemplate)
        local cdOverlay = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
        cdOverlay:SetAllPoints(frame)
        cdOverlay:SetDrawSwipe(true)
        cdOverlay:SetDrawBling(false)
        cdOverlay:SetDrawEdge(true)
        pcall(function() cdOverlay:SetHideCountdownNumbers(true) end)
        frame.cdOverlay = cdOverlay

        -- Raised frame for keybind text (after cdOverlay so it renders on top)
        local bindFrame = CreateFrame("Frame", nil, frame)
        bindFrame:SetAllPoints(frame)
        bindFrame:SetFrameLevel(frame:GetFrameLevel() + 2)
        local bindText = bindFrame:CreateFontString(nil, "OVERLAY")
        bindText:SetFont("Fonts\\FRIZQT__.TTF", math.max(9, math.floor(size * 0.26)), "OUTLINE")
        bindText:SetPoint("TOPRIGHT", bindFrame, "TOPRIGHT", -1, -1)
        bindText:SetJustifyH("RIGHT")
        bindText:SetTextColor(1, 1, 0.8, 1)
        bindText:SetText("")
        frame.bindText = bindText

        return frame
    end

    local BASE_ICON_LEFT = 0.08
    local BASE_ICON_RIGHT = 0.92
    local BASE_ICON_TOP = 0.08
    local BASE_ICON_BOTTOM = 0.92

    local function SetTextureColor(tex, live, inRange)
        if not tex then return end
        if live and live > 0 then
            if not inRange then
                tex:SetVertexColor(0.7, 0.2, 0.2)
            else
                tex:SetVertexColor(0.6, 0.6, 0.6)
            end
        else
            if not inRange then
                tex:SetVertexColor(0.8, 0.2, 0.2)
            else
                tex:SetVertexColor(1, 1, 1)
            end
        end
    end

    local function HideFadeVisual(frame)
        if frame.fadePrimaryTex then frame.fadePrimaryTex:Hide() end
        if frame.fadeSecondaryTex then frame.fadeSecondaryTex:Hide() end
    end

    local function ResetPrimaryVisual(frame)
        HideFadeVisual(frame)
        frame.icon:Show()
        frame.icon:SetTexture(nil)
        frame.icon:SetVertexColor(1, 1, 1)
        frame.fadeStart = nil
        frame.fadeKey1 = nil
        frame.fadeKey2 = nil
    end

    -- Returns true if the spell is blocked by its own cooldown (> 1.5 s),
    -- i.e. not just a GCD but a real multi-second spell CD.  Used by
    -- UseFadePrimary to decide whether the two paired spells are genuinely
    -- interchangeable right now (energy / GCD blocks are fine; a 6-second
    -- Mangle CD means it's NOT interchangeable at this moment).
    local function IsSpellCDBlocking(key)
        local spell = A.SPELLS and A.SPELLS[key]
        if not spell or not spell.id then return false end
        return A.GetSpellCDReal and (A.GetSpellCDReal(spell.id) or 0) > 0
    end

    local function UseFadePrimary(spec, firstRec, secondRec)
        if not spec or not firstRec or not secondRec then return false end
        if not A.SpecVal then return false end

        local enabled = A.SpecVal("fade_primary_icon", nil)
        if enabled == nil then
            enabled = A.SpecVal("split_primary_icon", false)
        end
        if not enabled then return false end

        local key1 = type(firstRec) == "table" and firstRec.key or firstRec
        local key2 = type(secondRec) == "table" and secondRec.key or secondRec
        if not key1 or not key2 then return false end

        if type(firstRec) == "table" and type(secondRec) == "table" then
            local bucket1 = firstRec.priorityBucket
            local bucket2 = secondRec.priorityBucket
            -- Fade whenever both spells share a priority bucket and neither is
            -- blocked by a real spell cooldown.  Energy / GCD blocks are
            -- intentionally allowed so the fade is visible during active combat
            -- (not only after standing still for 1.5 s waiting for energy regen).
            return bucket1 ~= nil
                and bucket2 ~= nil
                and not IsSpellCDBlocking(key1)
                and not IsSpellCDBlocking(key2)
                and tostring(bucket1) == tostring(bucket2)
        end
        return false
    end

    local function UpdatePrimaryVisual(frame, key1, key2, fadeActive, getDisplayIcon, state1, state2, now)
        if not fadeActive then
            HideFadeVisual(frame)
            frame.icon:Show()
            frame.icon:SetTexture(getDisplayIcon(key1 or ""))
            frame.icon:SetTexCoord(BASE_ICON_LEFT, BASE_ICON_RIGHT, BASE_ICON_TOP, BASE_ICON_BOTTOM)
            SetTextureColor(frame.icon, state1 and state1.live, state1 and state1.inRange)
            frame.fadeStart = nil
            frame.fadeKey1 = nil
            frame.fadeKey2 = nil
            return false
        end

        local icon1 = getDisplayIcon(key1 or "")
        local icon2 = getDisplayIcon(key2 or "")
        if not icon1 or not icon2 or not frame.fadePrimaryTex or not frame.fadeSecondaryTex then
            HideFadeVisual(frame)
            frame.icon:Show()
            frame.icon:SetTexture(icon1 or icon2)
            frame.icon:SetTexCoord(BASE_ICON_LEFT, BASE_ICON_RIGHT, BASE_ICON_TOP, BASE_ICON_BOTTOM)
            SetTextureColor(frame.icon, state1 and state1.live, state1 and state1.inRange)
            frame.fadeStart = nil
            frame.fadeKey1 = nil
            frame.fadeKey2 = nil
            return false
        end

        now = now or GetTime()
        if frame.fadeKey1 ~= key1 or frame.fadeKey2 ~= key2 or not frame.fadeStart then
            frame.fadeStart = now
            frame.fadeKey1 = key1
            frame.fadeKey2 = key2
        end

        local cycle = ((now - frame.fadeStart) * LIVE_FADE_SPEED) % 2
        local primaryAlpha, secondaryAlpha = GetFadeAlphas(LIVE_FADE_PROFILE, cycle)

        frame.icon:Hide()
        frame.fadePrimaryTex:SetTexture(icon1)
        frame.fadeSecondaryTex:SetTexture(icon2)
        frame.fadePrimaryTex:ClearAllPoints()
        frame.fadePrimaryTex:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        frame.fadePrimaryTex:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        frame.fadeSecondaryTex:ClearAllPoints()
        frame.fadeSecondaryTex:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        frame.fadeSecondaryTex:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        frame.fadePrimaryTex:SetTexCoord(BASE_ICON_LEFT, BASE_ICON_RIGHT, BASE_ICON_TOP, BASE_ICON_BOTTOM)
        frame.fadeSecondaryTex:SetTexCoord(BASE_ICON_LEFT, BASE_ICON_RIGHT, BASE_ICON_TOP, BASE_ICON_BOTTOM)
        frame.fadePrimaryTex:SetAlpha(primaryAlpha)
        frame.fadeSecondaryTex:SetAlpha(secondaryAlpha)
        frame.fadePrimaryTex:Show()
        frame.fadeSecondaryTex:Show()
        SetTextureColor(frame.fadePrimaryTex, state1 and state1.live, state1 and state1.inRange)
        SetTextureColor(frame.fadeSecondaryTex, state2 and state2.live, state2 and state2.inRange)
        return true
    end

    ----------------------------------------------------------------
    -- Primary (big) icon
    ----------------------------------------------------------------
    local primary = MakeIcon(f, ICON, nil, 0, 0)
    primary.fadePrimaryTex = primary:CreateTexture(nil, "ARTWORK")
    primary.fadePrimaryTex:SetPoint("TOPLEFT", primary, "TOPLEFT", 0, 0)
    primary.fadePrimaryTex:SetPoint("BOTTOMRIGHT", primary, "BOTTOMRIGHT", 0, 0)
    primary.fadePrimaryTex:Hide()
    primary.fadeSecondaryTex = primary:CreateTexture(nil, "ARTWORK")
    primary.fadeSecondaryTex:SetPoint("TOPLEFT", primary, "TOPLEFT", 0, 0)
    primary.fadeSecondaryTex:SetPoint("BOTTOMRIGHT", primary, "BOTTOMRIGHT", 0, 0)
    primary.fadeSecondaryTex:Hide()

    f.primary = primary

    ----------------------------------------------------------------
    -- Queue icons (3 smaller)
    ----------------------------------------------------------------
    f.queue = {}
    local prev = primary
    for i = 1, 3 do
        local q = MakeIcon(f, SMALL, prev, 3, 0)
        q:Hide()
        f.queue[i] = q
        prev = q
    end

    ----------------------------------------------------------------
    -- Bonus slots (optional actions: trinkets, potions, runes, shadowfiend, etc.)
    -- Up to MAX_BONUS_SLOTS static frames, positioned left of primary by
    -- RotationResizeLayout, shown/hidden in the display loop.
    ----------------------------------------------------------------
    f.bonusSlots = {}
    for i = 1, MAX_BONUS_SLOTS do
        local b = MakeIcon(f, SMALL, nil, -SMALL - 3, 0)
        b:Hide()
        f.bonusSlots[i] = b
    end

    ----------------------------------------------------------------
    -- Spell icon cache
    ----------------------------------------------------------------
    local spellIcons = {}
    local function GetCachedSpellIcon(key)
        local spell = key and A.SPELLS and A.SPELLS[key]
        if spell then
            local currentId = spell.id or spell.baseId
            local currentIcon = spell.icon or ((A.GetSpellIconCached and currentId) and A.GetSpellIconCached(currentId)) or (currentId and select(3, GetSpellInfo(currentId)))
            if currentIcon then
                spellIcons[key] = currentIcon
                return currentIcon
            end
        end

        local cached = key and spellIcons[key] or nil
        if cached then return cached end

        local baseKey = type(key) == "string" and key:match("^([A-Z]+)") or nil
        if baseKey and baseKey ~= key then
            return GetCachedSpellIcon(baseKey)
        end
        return nil
    end

    for key in pairs(A.SPELLS) do
        GetCachedSpellIcon(key)
    end
    -- Consumable icons
    spellIcons["POTION"] = (A.GetItemIconCached and A.GetItemIconCached(22832)) or GetItemIcon(22832) or "Interface\\Icons\\INV_Potion_76"
    spellIcons["RUNE"]   = (A.GetItemIconCached and A.GetItemIconCached(20520)) or GetItemIcon(20520) or "Interface\\Icons\\INV_Misc_Rune_04"
    spellIcons["TRINKET1"] = "Interface\\Icons\\INV_Jewelry_Trinket_01"
    spellIcons["TRINKET2"] = "Interface\\Icons\\INV_Jewelry_Trinket_02"
    spellIcons["WAND"] = "Interface\\Icons\\INV_Wand_01"

    ----------------------------------------------------------------
    -- Apply full layout (fixes bonus slot size/position at startup)
    ----------------------------------------------------------------
    if A.RotationResizeLayout then A.RotationResizeLayout() end

    ----------------------------------------------------------------
    -- Recently-cast tracking (prevents re-suggesting mid-travel spells)
    ----------------------------------------------------------------
    local recentCast = {}  -- key = spellName, value = GetTime()
    A._rotRecentCast = recentCast  -- expose for RotationEngine
    local RECENT_WINDOW = 1.0  -- seconds to suppress after cast finishes

    local recentEv = CreateFrame("Frame")
    recentEv:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    recentEv:SetScript("OnEvent", function(self, event, unit, _, spellId)
        if unit ~= "player" then return end
        if spellId then
            local name = (A.GetSpellInfoCached and A.GetSpellInfoCached(spellId)) or GetSpellInfo(spellId)
            if name then
                recentCast[name] = GetTime()
                A.DebugLog("CAST", "succeeded: " .. name .. " (id=" .. spellId .. ")")
            end
        end
    end)

    local function WasRecentlyCast(spellName)
        local t = recentCast[spellName]
        if t and (GetTime() - t) < RECENT_WINDOW then return true end
        return false
    end

    -- Helper: return current casting/channeling spell name and remaining seconds
    local function GetPlayerCastInfo()
        local name, _, _, _, endMS = UnitCastingInfo("player")
        if name and endMS then
            return name, math.max(endMS / 1000 - GetTime(), 0)
        end
        local cname, _, _, _, cendMS = UnitChannelInfo("player")
        if cname and cendMS then
            return cname, math.max(cendMS / 1000 - GetTime(), 0)
        end
        return nil, 0
    end

    ----------------------------------------------------------------
    -- Priority engine  (time-aware, rank-agnostic)
    --
    -- All spell comparisons use base spell NAMES from GetSpellInfo(),
    -- which are identical regardless of spell rank.  Cooldown lookups
    -- use spell IDs, but all ranks share the same cooldown in TBC.
    --
    -- Core idea: project every timer forward by `castRemaining`
    -- (time until current cast / channel finishes) so the list
    -- always answers "what should I cast NEXT?"
    ----------------------------------------------------------------
    local function GetActiveRotationSpec()
        if not A.SpecManager then return nil end
        local activeSpecs = A.SpecManager:GetActiveSpecs()
        for _, spec in pairs(activeSpecs) do
            if spec.rotation then
                return spec
            end
        end
        return nil
    end

    local function GetPriority()
        -- Delegate to RotationEngine for all spec-specific logic.
        local spec = GetActiveRotationSpec()
        if A.RotationEngine and spec then
            local ok, result = pcall(A.RotationEngine.Evaluate, A.RotationEngine, spec)
            if ok and result then return result, spec end
            -- Spec has a rotation but engine returned nil — no match found.
            if ok then return {}, spec end
        end

        -- No active spec with a rotation — nothing to display.
        return nil, spec
    end

    ----------------------------------------------------------------
    -- Resize layout (called from Config)
    ----------------------------------------------------------------
    A.RotationResizeLayout = function()
        local db = A.db.rotation
        ICON  = db.primaryIconSize or db.iconSize
        SMALL = math.floor((db.iconSize or 40) * 0.6)

        local bonusEnabled = db.enableBonusSlot ~= false
        local bonusSpacing = db.bonusSpacing or 4

        local maxBonusSlots = bonusEnabled and MAX_BONUS_SLOTS or 0
        local extraW = maxBonusSlots > 0 and (SMALL + bonusSpacing) * maxBonusSlots or 0

        f:SetSize(ICON + SMALL * 3 + 20 + extraW, ICON + 4)

        primary:SetSize(ICON, ICON)
        primary.cdText:SetFont("Fonts\\FRIZQT__.TTF",
            math.max(9, math.floor(ICON * 0.28)), "OUTLINE")

        -- Position bonus slots to the left of primary
        if f.bonusSlots then
            local prev = primary
            for i = 1, 4 do
                local slot = f.bonusSlots[i]
                if slot then
                    slot:SetSize(SMALL, SMALL)
                    slot:ClearAllPoints()
                    slot:SetPoint("RIGHT", prev, "LEFT", -bonusSpacing, 0)
                    slot.cdText:SetFont("Fonts\\FRIZQT__.TTF",
                        math.max(9, math.floor(SMALL * 0.28)), "OUTLINE")
                    -- Show/hide handled in the display loop, not here
                    prev = slot
                end
            end
        end

        local prev = primary
        for i = 1, 3 do
            local q = f.queue[i]
            q:SetSize(SMALL, SMALL)
            q:ClearAllPoints()
            q:SetPoint("LEFT", prev, "RIGHT", 3, 0)
            q.cdText:SetFont("Fonts\\FRIZQT__.TTF",
                math.max(9, math.floor(SMALL * 0.28)), "OUTLINE")
            prev = q
        end
        if A.RotationRefreshOpacity then A.RotationRefreshOpacity() end
    end

    ----------------------------------------------------------------
    -- Preview support
    ----------------------------------------------------------------
    local previewActive = false

    A.RotationPreviewOn = function()
        previewActive = true
        -- Build a preview from the active spec's rotation keys, or fall back to
        -- any known spells in A.SPELLS.
        local previewEntries = {}
        local activeSpec = GetActiveRotationSpec()
        if A.SpecManager then
            local activeSpecs = A.SpecManager:GetActiveSpecs()
            for _, spec in pairs(activeSpecs) do
                if spec.rotation then
                    for _, entry in ipairs(spec.rotation) do
                        if entry.key and spellIcons[entry.key] then
                            previewEntries[#previewEntries + 1] = {
                                key = entry.key,
                                priorityBucket = entry.priorityGroup or entry.explicitPriority or entry.priority,
                            }
                        end
                        if #previewEntries >= 4 then break end
                    end
                end
                if #previewEntries >= 4 then break end
            end
        end
        -- Fallback: use first 4 keys from A.SPELLS that have icons
        if #previewEntries == 0 then
            for k, _ in pairs(A.SPELLS) do
                if spellIcons[k] then
                    previewEntries[#previewEntries + 1] = { key = k }
                    if #previewEntries >= 4 then break end
                end
            end
        end
        local previewFade = UseFadePrimary(activeSpec, previewEntries[1], previewEntries[2])
        UpdatePrimaryVisual(primary, previewEntries[1] and previewEntries[1].key, previewEntries[2] and previewEntries[2].key, previewFade, function(key)
            return GetCachedSpellIcon(key)
        end, { live = 0, inRange = true }, { live = 0, inRange = true })
        primary.cdText:SetText("")
        if primary.cdOverlay then
            pcall(CooldownFrame_Set, primary.cdOverlay, 0, 0, 0)
        end
        A.CreateBackdrop(primary, 0, 0, 0, 0.85, 1, 0.85, 0, 1)
        f:Show()
        local queueOffset = previewFade and 3 or 2
        for i = 1, 3 do
            local q = f.queue[i]
            local previewEntry = previewEntries[i + queueOffset - 1]
            q.icon:SetTexture(GetCachedSpellIcon(previewEntry and previewEntry.key or ""))
            if i == 1 then
                q.cdText:SetText("2.1")
            else
                q.cdText:SetText("")
            end
            q:Show()
        end
    end

    A.RotationPreviewOff = function()
        if previewActive then
            previewActive = false
            ResetPrimaryVisual(primary)
            primary.cdText:SetText("")
            A.CreateBackdrop(primary, 0, 0, 0, 0.85)
            f:Hide()
        end
    end

    ----------------------------------------------------------------
    -- Map spell names → priority keys (for casting-spell filter)
    ----------------------------------------------------------------
    local nameToKey = {}
    for key, spell in pairs(A.SPELLS) do
        if spell.name then nameToKey[spell.name] = key end
    end

    ----------------------------------------------------------------
    -- Refresh display
    ----------------------------------------------------------------
    local lastPriSignature = nil
    local inCombat      = UnitAffectingCombat("player")
    local noTargetSince = nil   -- GetTime() when we first saw nil prio in combat
    local HYSTERESIS_WINDOW = 0.20
    local HYSTERESIS_ETA_LEEWAY = 0.15
    local hysteresisState = {
        signature = nil,
        shownAt = 0,
        firstKey = nil,
        secondKey = nil,
        targetGUID = nil,
    }

    local function ResetRecommendationHysteresis()
        hysteresisState.signature = nil
        hysteresisState.shownAt = 0
        hysteresisState.firstKey = nil
        hysteresisState.secondKey = nil
        hysteresisState.targetGUID = nil
    end

    local function FindRecommendationByKey(prio, key)
        if not key then return nil, nil end
        for idx, ent in ipairs(prio or {}) do
            if ent and ent.key == key then
                return idx, ent
            end
        end
        return nil, nil
    end

    local function FindRotationEntry(spec, key)
        if not spec or not key or not spec.rotation then return nil end
        for _, entry in ipairs(spec.rotation) do
            if entry and entry.key == key then
                return entry
            end
        end
        return nil
    end

    local function IsChannelSpell(spellRef, spec)
        if A.ChannelHelper and A.ChannelHelper.IsChannelSpell then
            return A.ChannelHelper:IsChannelSpell(spellRef, spec)
        end
        local def = A.GetSpellDefinition and A.GetSpellDefinition(spellRef) or nil
        return def and (def.castType == "channel" or def.channel == true or (def.flags and def.flags.channel)) or false
    end

    local function GetChannelDisplayPolicy(spec, spellRef)
        if not spellRef then return "default" end

        local policy = nil
        local entry = FindRotationEntry(spec, spellRef)
        if entry then
            policy = entry.channelPolicy
        end

        if not policy and A.GetSpellDefinition then
            local def = A.GetSpellDefinition(spellRef)
            policy = def and def.channelPolicy or nil
        end

        if not policy and A.SPELLS and A.SPELLS[spellRef] then
            policy = A.SPELLS[spellRef].channelPolicy
        end

        if policy == "keep_current" or policy == "replace_current" then
            return policy
        end
        return "default"
    end

    local function PromoteRecommendationsForDisplay(prio, firstKey, secondKey)
        if not prio or not firstKey then return prio end

        local reordered = {}
        local consumed = {}

        local function Take(key)
            if not key or consumed[key] then return end
            for _, ent in ipairs(prio) do
                if ent and ent.key == key then
                    reordered[#reordered + 1] = ent
                    consumed[key] = true
                    return
                end
            end
        end

        Take(firstKey)
        Take(secondKey)

        for _, ent in ipairs(prio) do
            if ent and not consumed[ent.key] then
                reordered[#reordered + 1] = ent
            end
        end

        return reordered
    end

    local function BuildDisplayCandidate(prio, spec)
        local first = prio and prio[1] or nil
        local second = prio and prio[2] or nil
        local paired = UseFadePrimary(spec, first, second)
        local signature = tostring(first and first.key or "nil")
        if paired and second then
            signature = signature .. "|" .. tostring(second.key)
        end
        return {
            first = first,
            second = paired and second or nil,
            paired = paired,
            signature = signature,
        }
    end

    local function CommitDisplayCandidate(candidate, now)
        if not candidate or not candidate.first then
            ResetRecommendationHysteresis()
            return
        end

        if hysteresisState.signature ~= candidate.signature then
            hysteresisState.shownAt = now
        end
        hysteresisState.signature = candidate.signature
        hysteresisState.firstKey = candidate.first and candidate.first.key or nil
        hysteresisState.secondKey = candidate.second and candidate.second.key or nil
        hysteresisState.targetGUID = UnitGUID("target")
    end

    local function ApplyRecommendationHysteresis(prio, spec)
        if not prio or #prio == 0 then return prio end

        local now = GetTime()
        local candidate = BuildDisplayCandidate(prio, spec)
        if not candidate.first then return prio end

        if candidate.paired and candidate.second and (candidate.first.key ~= hysteresisState.firstKey or candidate.second.key ~= hysteresisState.secondKey) then
            prio = PromoteRecommendationsForDisplay(prio, hysteresisState.firstKey, hysteresisState.secondKey)
            candidate = BuildDisplayCandidate(prio, spec)
        end

        local withinWindow = hysteresisState.signature
            and hysteresisState.signature ~= candidate.signature
            and hysteresisState.targetGUID == UnitGUID("target")
            and (now - (hysteresisState.shownAt or 0)) < HYSTERESIS_WINDOW

        if withinWindow then
            local _, heldFirst = FindRecommendationByKey(prio, hysteresisState.firstKey)
            if heldFirst then
                local keepHeld = (heldFirst.eta or 0) <= ((candidate.first.eta or 0) + HYSTERESIS_ETA_LEEWAY)
                if keepHeld and hysteresisState.secondKey then
                    local _, heldSecond = FindRecommendationByKey(prio, hysteresisState.secondKey)
                    keepHeld = heldSecond ~= nil
                        and (heldSecond.eta or 0) <= HYSTERESIS_ETA_LEEWAY
                        and UseFadePrimary(spec, heldFirst, heldSecond)
                end
                if keepHeld then
                    prio = PromoteRecommendationsForDisplay(prio, hysteresisState.firstKey, hysteresisState.secondKey)
                    candidate = BuildDisplayCandidate(prio, spec)
                end
            end
        end

        CommitDisplayCandidate(candidate, now)
        return prio
    end

    local function ClearDisplay()
        ResetPrimaryVisual(primary)
        primary.cdText:SetText("")
        A.CreateBackdrop(primary, 0, 0, 0, 0.85)
        lastPriSignature = nil
        ResetRecommendationHysteresis()
        A._rotDisplayState = nil
        for _, q in ipairs(f.queue) do q:Hide() end
        f:Hide()
    end

    -- Keybind lookup: cache spellId -> bound key(s) (e.g. "1", "F6", "ALT-1 / Q").
    -- Computes the paged action slot and binding command for each physical
    -- button position using the standard page variables (which always reflect
    -- the current action bar configuration without relying on frame fields).
    local BINDING_BARS = {
        { "ACTIONBUTTON",          function() return CURRENT_ACTIONBAR_PAGE end },
        { "MULTIACTIONBAR1BUTTON", function() return BOTTOMLEFT_ACTIONBAR_PAGE end },
        { "MULTIACTIONBAR2BUTTON", function() return BOTTOMRIGHT_ACTIONBAR_PAGE end },
        { "MULTIACTIONBAR3BUTTON", function() return RIGHT_ACTIONBAR_PAGE end },
        { "MULTIACTIONBAR4BUTTON", function() return LEFT_ACTIONBAR_PAGE end },
    }
    local bindCache = {}
    local function GetBindForKey(key)
        if bindCache[key] ~= nil then return bindCache[key] end
        local spell = A.SPELLS[key]
        -- TRINKET1/TRINKET2 are not in the spell catalog; resolve dynamically
        if not spell and (key == "TRINKET1" or key == "TRINKET2") then
            local invSlot = (key == "TRINKET1") and 13 or 14
            local _, itemId = pcall(GetInventoryItemID, "player", invSlot)
            if itemId then
                local _, _, spellId = pcall(GetItemSpell, itemId)
                if spellId then
                    spell = { id = spellId, name = GetSpellInfo(spellId) }
                end
            end
        end
        if not spell or not spell.id then
            bindCache[key] = ""
            return ""
        end
        local found = {}
        -- Regular bars: iterate buttons 1-12, compute paged slot from page var
        for _, bar in ipairs(BINDING_BARS) do
            local page = bar[2]()
            if page then
                for btn = 1, 12 do
                    local slot = btn + (page - 1) * 12
                    local actionType, actionId = GetActionInfo(slot)
                    local matched = false
                    if actionType == "spell" then
                        matched = (actionId == spell.id) or (GetSpellInfo(actionId) == spell.name)
                    elseif actionType == "item" then
                        local ok, _, sId = pcall(GetItemSpell, actionId)
                        if ok and sId then
                            matched = (sId == spell.id)
                        end
                    elseif actionType == "macro" then
                        local _, macroSpell = pcall(GetMacroSpell, actionId)
                        if macroSpell and macroSpell > 0 then
                            matched = (macroSpell == spell.id) or (GetSpellInfo(macroSpell) == spell.name)
                        end
                    end
                    if matched then
                        local cmd = bar[1] .. btn
                        local k1, k2 = GetBindingKey(cmd)
                        local bind = k1 or k2
                        if bind and not found[bind] then
                            found[bind] = true
                        end
                    end
                end
            end
        end
        -- Bonus/stance bar: only active when GetBonusBarOffset() > 0
        local bonusOff = GetBonusBarOffset()
        if bonusOff and bonusOff > 0 then
            local page = NUM_ACTIONBAR_PAGES + bonusOff
            for btn = 1, 12 do
                local slot = btn + (page - 1) * 12
                local actionType, actionId = GetActionInfo(slot)
                local matched = false
                if actionType == "spell" then
                    matched = (actionId == spell.id) or (GetSpellInfo(actionId) == spell.name)
                elseif actionType == "item" then
                    local ok, _, sId = pcall(GetItemSpell, actionId)
                    if ok and sId then
                        matched = (sId == spell.id)
                    end
                elseif actionType == "macro" then
                    local _, macroSpell = pcall(GetMacroSpell, actionId)
                    if macroSpell and macroSpell > 0 then
                        matched = (macroSpell == spell.id) or (GetSpellInfo(macroSpell) == spell.name)
                    end
                end
                if matched then
                    -- Stance bar shares keybinds with main bar (ACTIONBUTTON)
                    local k1, k2 = GetBindingKey("ACTIONBUTTON" .. btn)
                    local bind = k1 or k2
                    -- Some setups let you bind the stance bar separately
                    if not bind then
                        local b1, b2 = GetBindingKey("BONUSACTIONBUTTON" .. btn)
                        bind = b1 or b2
                    end
                    if bind and not found[bind] then
                        found[bind] = true
                    end
                end
            end
        end
        local keys = {}
        for bind in pairs(found) do
            keys[#keys + 1] = bind
        end
        table.sort(keys)
        local result = #keys > 0 and table.concat(keys, " / ") or ""
        bindCache[key] = result
        return result
    end

    local function Refresh()
        if previewActive then return end
        -- Clear keybind cache each tick so ability moves show up promptly
        wipe(bindCache)
        local now = GetTime()
        local SPELLS = A.SPELLS
        local dbRot = A.db.rotation
        local GetSpellCDReal = A.GetSpellCDReal
        local FindPlayerDebuff = A.FindPlayerDebuff
        local showBinds = dbRot and dbRot.showKeybinds

        if A.db.rotation and not A.db.rotation.enabled then
            ClearDisplay()
            return
        end

        local prio, activeSpec = GetPriority()

        -- Collect optional entries (trinkets, potions) for the bonus slot.
        -- Cross-reference against the spec file's `optional = true` flags
        -- to handle DB-saved rotations that strip the attribute.
        -- Ready optional entries go ONLY to the bonus slot (not queue).
        -- On-cooldown optional entries stay in the queue.
        local bonusDb = A.db and A.db.rotation
        local bonusEnabled = bonusDb and bonusDb.enableBonusSlot ~= false
        local optionalPrio
        if prio and activeSpec and activeSpec.rotation then
            local optKeys = {}
            for _, re in ipairs(activeSpec.rotation) do
                if re.optional and re.key then optKeys[re.key] = true end
            end
            if next(optKeys) then
                local now = GetTime()
                local normal, bonus, cooldownOpt = {}, {}, {}
                for _, ent in ipairs(prio) do
                    if optKeys[ent.key] then
                        local isReady = not ent.eta or ent.eta <= 0.05
                        if isReady then
                            bonus[#bonus + 1] = ent
                        else
                            cooldownOpt[#cooldownOpt + 1] = ent
                        end
                    else
                        normal[#normal + 1] = ent
                    end
                end
                -- Rebuild prio: normal → on-cooldown optional (ready optional are bonus-only)
                local ordered = {}
                for _, ent in ipairs(normal) do ordered[#ordered + 1] = ent end
                for _, ent in ipairs(cooldownOpt) do ordered[#ordered + 1] = ent end

                if #bonus > 0 and bonusEnabled then
                    local slotCount = math.min(#bonus, MAX_BONUS_SLOTS)
                    optionalPrio = {}
                    for i = 1, slotCount do
                        optionalPrio[i] = bonus[i]
                    end
                    -- Extras beyond capacity: stay bonus-only (not duplicated in queue)
                else
                    -- Bonus slot disabled: ready optionals fall back to normal queue
                    for _, ent in ipairs(bonus) do ordered[#ordered + 1] = ent end
                end
                prio = ordered
            end
        end

        -- nil = no valid target
        if prio == nil then
            if inCombat then
                -- Give a short grace period before clearing (avoids flicker on target swap)
                if not noTargetSince then
                    noTargetSince = now
                elseif (now - noTargetSince) > 0.5 then
                    ClearDisplay()
                end
            else
                ClearDisplay()
            end
            return
        end
        noTargetSince = nil   -- valid target, reset timer

        -- Empty prio — Evaluate already handled filler/nil internally.
        -- If we still get an empty list here it means the engine returned {}
        -- (no combat, no target) so clear the display.
        if #prio == 0 then
            ClearDisplay()
            return
        end

        -- Filter: if currently casting/channeling a spell, move it out of
        -- position 1 so the display always shows what to cast NEXT.
        do
            local castName = select(1, GetPlayerCastInfo())
            if castName then
                local castKey = nameToKey[castName]
                if castKey and prio[1] and prio[1].key == castKey then
                    -- Channel behavior is policy-driven now: default keeps the
                    -- current channel in slot 1 and can still promote instant
                    -- spells mid-channel.
                    local channelRef = castKey or castName
                    local isChannelKey = IsChannelSpell(channelRef, activeSpec)
                    local channelPolicy = GetChannelDisplayPolicy(activeSpec, channelRef)
                    if not isChannelKey or channelPolicy == "replace_current" then
                        A.DebugLog("ROT", "filter: casting " .. castKey .. ", removing from pos 1")
                        table.remove(prio, 1)
                    else
                        if channelPolicy ~= "keep_current" then
                            -- Channeling this spell — check if a high-priority instant is available
                            -- (e.g. execute-range SWD on a normal mob). If so, promote it.
                            for idx = 2, #prio do
                                local ent = prio[idx]
                                if ent and ent.eta == 0 then
                                    local class = UnitClassification("target") or ""
                                    if class == "normal" or class == "minus" then
                                        A.DebugLog("ROT", "filter: mid-channel promote " .. ent.key)
                                        table.remove(prio, idx)
                                        table.insert(prio, 1, ent)
                                        lastPriSignature = nil
                                    end
                                    break
                                end
                            end
                        end
                        A.DebugLog("ROT", "filter: channeling " .. castKey .. " — keep suggestion")
                    end
                end
            end
        end

        prio = ApplyRecommendationHysteresis(prio, activeSpec)



        f:Show()

        

        local function GetDisplayIcon(key)
            if key == "POTION" then
                local potId = A.db.selectedPotionItem
                if type(potId) == "string" then potId = tonumber(potId) end
                if potId and potId ~= "none" then
                    local icon = (A.GetItemIconCached and A.GetItemIconCached(potId)) or GetItemIcon(potId)
                    if icon then return icon end
                end
                return spellIcons["POTION"]
            elseif key == "RUNE" then
                local runeId = A.db.selectedRuneItem
                if type(runeId) == "string" then runeId = tonumber(runeId) end
                if runeId and runeId ~= "none" then
                    local icon = (A.GetItemIconCached and A.GetItemIconCached(runeId)) or GetItemIcon(runeId)
                    if icon then return icon end
                end
                return spellIcons["RUNE"]
            elseif key == "TRINKET1" or key == "TRINKET2" then
                local slot = (key == "TRINKET1") and 13 or 14
                local ok, itemId = pcall(GetInventoryItemID, "player", slot)
                if ok and itemId then
                    local icon = (A.GetItemIconCached and A.GetItemIconCached(itemId)) or GetItemIcon(itemId)
                    if icon then return icon end
                end
                return spellIcons[key] or spellIcons["TRINKET1"]
            elseif key == "WAND" then
                -- Wand is not in the spell catalog; show the equipped wand's icon
                local ok, itemId = pcall(GetInventoryItemID, "player", 18)
                if ok and itemId then
                    local icon = (A.GetItemIconCached and A.GetItemIconCached(itemId)) or GetItemIcon(itemId)
                    if icon then return icon end
                end
                return spellIcons["WAND"]
            else
                return GetCachedSpellIcon(key)
            end
        end

        -- Range check helper: returns true if the key's spell/item is in range for the current target.
        -- Only offensive spells (per spell database flag) are checked; self-buffs like Cat Form are always "in range".
        local function IsKeyInRange(key)
            if not UnitExists("target") then return true end
            if key == "POTION" or key == "RUNE" or key == "TRINKET1" or key == "TRINKET2" or key == "WAND" then return true end
            local spell = SPELLS[key]
            if spell and spell.id then
                if spell.meta and spell.meta.flags and not spell.meta.flags.offensive then
                    return true
                end
                local ok, inRange = pcall(IsSpellInRange, spell.name, "target")
                if ok and type(inRange) == "number" then
                    return (inRange == 1)
                end
            end
            return true
        end

        -- Recompute visible countdowns for keys so only DoT refresh entries
        -- show timer text. Regular spell icons stay clean; real cooldowns are
        -- represented by the gray sweep overlay instead.
        local function GetRemainingNowForKey(key)
            if key == "POTION" then
                local potId = A.db.selectedPotionItem
                if type(potId) == "string" then potId = tonumber(potId) end
                if potId and potId ~= "none" then
                    local s,d = A.GetItemCooldownSafe(potId)
                    if s and d and s > 0 then return math.max(s + d - now, 0) end
                end
                return 0
            elseif key == "RUNE" then
                local runeId = A.db.selectedRuneItem
                if type(runeId) == "string" then runeId = tonumber(runeId) end
                if runeId and runeId ~= "none" then
                    local s,d = A.GetItemCooldownSafe(runeId)
                    if s and d and s > 0 then return math.max(s + d - now, 0) end
                end
                return 0
            elseif key == "TRINKET1" or key == "TRINKET2" then
                local slot = (key == "TRINKET1") and 13 or 14
                local ok, itemId = pcall(GetInventoryItemID, "player", slot)
                if ok and itemId then
                    local s,d = A.GetItemCooldownSafe(itemId)
                    if s and d and s > 0 then return math.max(s + d - now, 0) end
                end
                return 0
            elseif key == "WAND" then
                -- Wands attack on their own timer; no cooldown to display
                return 0
            end
            -- Generic: try cooldown lookup via SPELLS[key]
            local spell = SPELLS[key]
            if spell then
                if spell.id then
                    local cd = GetSpellCDReal and GetSpellCDReal(spell.id)
                    if cd and cd > 0 then return math.max(cd, 0) end
                end
                -- Dot debuff: check remaining uptime on target (ID-first lookup by catalog key)
                if UnitExists("target") and FindPlayerDebuff then
                    local spec = nil
                    if A.SpecManager then
                        local activeSpecs = A.SpecManager:GetActiveSpecs()
                        for _, s in pairs(activeSpecs) do spec = s; break end
                    end
                    local isDot = spec and spec.rotation and (function()
                        for _, e in ipairs(spec.rotation) do
                            if e.key == key then
                                for _, c in ipairs(e.conditions or {}) do
                                    if c.type == "dot_missing" then return true end
                                end
                            end
                        end
                    end)()
                    if isDot then
                        local _,_,_,_,_,exp = FindPlayerDebuff("target", key)
                        if exp then return math.max(exp - now, 0) end
                        return 0
                    end
                end
            end
            return 0
        end

        local function LiveRemaining(ent)
            if not ent then return 0 end
            if ent.cooldownEnd then
                return math.max(ent.cooldownEnd - now, 0)
            end
            return (ent.eta and ent.eta > 0) and ent.eta or 0
        end

        local function VisibleRemaining(ent)
            if not ent then return 0 end
            if ent.showTimer and ent.timerRemaining then
                return math.max(ent.timerRemaining, 0)
            end
            if ent.cooldownEnd then
                return math.max(ent.cooldownEnd - now, 0)
            end
            return (ent.eta and ent.eta > 0) and ent.eta or 0
        end

        local p = prio[1]
        local p2 = prio[2]
        local primaryFade = UseFadePrimary(activeSpec, p, p2)

        local primaryLive = VisibleRemaining(p)
        local inRangePrimary = p and IsKeyInRange(p.key)
        local secondaryLive = VisibleRemaining(p2)
        local inRangeSecondary = p2 and IsKeyInRange(p2.key)

        local primaryShown = UpdatePrimaryVisual(primary, p and p.key, p2 and p2.key, primaryFade, GetDisplayIcon, {
            live = primaryLive,
            inRange = inRangePrimary,
        }, {
            live = secondaryLive,
            inRange = inRangeSecondary,
        }, now)

        local primarySignature = tostring(p and p.key or "nil")
        if primaryShown and p2 then
            primarySignature = primarySignature .. "|" .. tostring(p2.key)
        end

        -- GCD / cooldown display on the primary icon.
        --
        -- GCD is detected with the same probe the engine uses (id 29515,
        -- duration <= 2.5 s — see RotationEngine.GetGCDRemaining), so it only
        -- reflects a REAL global cooldown: channel ticks (e.g. Mind Flay) never
        -- light it up, and the active channel is never drawn with a fake
        -- cooldown sweep (CastBar shows channel state).
        --
        -- On TBC Anniversary, CooldownFrameTemplate draws the swipe but no
        -- countdown number (SetHideCountdownNumbers doesn't exist), so the
        -- countdown is rendered by our own cdText — number + swipe together,
        -- like retail.
        local gStart, gDur = GetSpellCooldown(29515)
        local gcdRem = 0
        if gStart and gStart > 0 and gDur and gDur > 0 and gDur <= 2.5 then
            gcdRem = math.max(gStart + gDur - now, 0)
        end
        local primarySpell = p and SPELLS[p.key]
        local sStart, sDur = 0, 0
        if primarySpell and primarySpell.id then
            local s, d = GetSpellCooldown(primarySpell.id)
            if s and d then sStart, sDur = s, d end
        end
        local castNameNow = select(1, GetPlayerCastInfo())
        local primaryIsActiveChannel = primarySpell and primarySpell.name and castNameNow
                                       and primarySpell.name == castNameNow
        local realCDRem = (sDur > 2.5 and not primaryIsActiveChannel) and math.max(sStart + sDur - now, 0) or 0

        local primaryOverlayActive = false
        if primary.cdOverlay then
            if primaryShown then
                -- Fade split active: suppress the overlay (it would hide the
                -- ARTWORK fade textures) and keep the live countdown text.
                pcall(CooldownFrame_Set, primary.cdOverlay, 0, 0, 0)
            elseif realCDRem > 0 then
                -- Real multi-second spell cooldown: swipe + countdown number.
                pcall(CooldownFrame_Set, primary.cdOverlay, sStart, sDur, 1)
                primaryOverlayActive = true
                primary.cdText:SetText(A.FormatTime(realCDRem))
            elseif gcdRem > 0 then
                -- Genuine global cooldown (probe-based; channel ticks never
                -- report one after the initial GCD): swipe + countdown number.
                pcall(CooldownFrame_Set, primary.cdOverlay, gStart, gDur, 1)
                primaryOverlayActive = true
                primary.cdText:SetText(A.FormatTime(gcdRem))
            else
                pcall(CooldownFrame_Set, primary.cdOverlay, 0, 0, 0)
            end
        end

        if not primaryOverlayActive then
            -- When actively channeling the primary spell, don't show remaining
            -- channel time on the rotation advisor icon — the CastBar already
            -- displays that. Only show GCD initially (handled above), then blank.
            if not primaryIsActiveChannel and primaryLive and primaryLive > 0 then
                primary.cdText:SetText(A.FormatTime(primaryLive))
                -- Dim the icon while it's still on cooldown; if out of range tint red
                if not inRangePrimary then
                    if not primaryShown then primary.icon:SetVertexColor(0.7, 0.2, 0.2) end
                end
            else
                if p.clip then
                    primary.cdText:SetText("Clip")
                else
                    primary.cdText:SetText("")
                end
                if not inRangePrimary then
                    if not primaryShown then primary.icon:SetVertexColor(0.8, 0.2, 0.2) end
                end
            end
        end
        if lastPriSignature ~= primarySignature then
            A.DebugLog("ROT", "display: " .. (lastPriSignature or "nil") .. " -> " .. primarySignature)
            A.CreateBackdrop(primary, 0, 0, 0, 0.85, 1, 0.85, 0, 1)
            lastPriSignature = primarySignature
        end
        -- Update keybind overlay on primary icon
        if showBinds then
            local primaryBind = (p and GetBindForKey(p.key)) or ""
            primary.bindText:SetText(primaryBind)
            primary.bindText:Show()
        else
            primary.bindText:SetText("")
            primary.bindText:Hide()
        end

        -- queueStart must be defined before the display state block and the
        -- queue rendering loop. When fade is active both prio[1] and prio[2]
        -- are consumed by the primary icon, so queue icons start at prio[3].
        local queueStart = primaryShown and 3 or 2

        for i = 1, 3 do
            local q   = f.queue[i]
            local ent = prio[i + queueStart - 1]
            if ent then
                q.icon:SetTexture(GetDisplayIcon(ent.key))
                -- Drive the cooldown sweep only from real spell CDs (dur > 1.5 s).
                -- Showing the GCD sweep on queue icons creates a confusing spinning
                -- overlay that competes with the energy countdown text.  The
                -- currently-channeled spell is also excluded (the client reports
                -- the channel as a fake cooldown; CastBar shows channel state).
                local qHasRealCD = false
                if q.cdOverlay then
                    local qspell = SPELLS[ent.key]
                    if qspell and qspell.id and not (castNameNow and qspell.name == castNameNow) then
                        local qstart, qdur = GetSpellCooldown(qspell.id)
                        if qstart and qdur and qdur > 1.5 then
                            pcall(CooldownFrame_Set, q.cdOverlay, qstart, qdur, 1)
                            qHasRealCD = true
                        else
                            pcall(CooldownFrame_Set, q.cdOverlay, 0, 0, 0)
                        end
                    else
                        pcall(CooldownFrame_Set, q.cdOverlay, 0, 0, 0)
                    end
                end
                local inRangeQ = IsKeyInRange(ent.key)
                if ent.clip then
                    q.cdText:SetText("Clip")
                    q.icon:SetVertexColor(1, 1, 1)
                else
                    local live = VisibleRemaining(ent)
                    if live and live > 0 then
                        if qHasRealCD then
                            q.cdText:SetText("")
                        else
                            q.cdText:SetText(A.FormatTime(live))
                        end
                        if not inRangeQ then
                            q.icon:SetVertexColor(0.8, 0.2, 0.2)
                        elseif ent.chained then
                            q.icon:SetVertexColor(1, 1, 1)
                        else
                            q.icon:SetVertexColor(0.6, 0.6, 0.6)
                        end
                    else
                        q.cdText:SetText("")
                        if not inRangeQ then
                            q.icon:SetVertexColor(0.8, 0.2, 0.2)
                        else
                            q.icon:SetVertexColor(1, 1, 1)
                        end
                    end
                end
                if showBinds then
                    local qBind = GetBindForKey(ent.key)
                    q.bindText:SetText(qBind)
                    q.bindText:Show()
                else
                    q.bindText:SetText("")
                    q.bindText:Hide()
                end
                q:Show()
            else
                q:Hide()
            end
        end

        -- Bonus slots: one slot per optional entry (trinkets, potions, etc.)
        -- Positioned to the left of the primary ability, additive to the queue.
        do
            local bonusDb = A.db.rotation
            local bonusEnabled = bonusDb.enableBonusSlot ~= false
            local entries = optionalPrio or {}
            for bi = 1, MAX_BONUS_SLOTS do
                local slot = f.bonusSlots[bi]
                local optEnt = entries[bi]
                if bonusEnabled and slot and optEnt then
                    slot.icon:SetTexture(GetDisplayIcon(optEnt.key))
                    local inRangeB = IsKeyInRange(optEnt.key)
                    -- Cooldown sweep (trinkets use item cooldown, potions use item, else spell)
                    if slot.cdOverlay then
                        if optEnt.key == "TRINKET1" or optEnt.key == "TRINKET2" then
                            local slotIdx = (optEnt.key == "TRINKET1") and 13 or 14
                            local ok, itemId = pcall(GetInventoryItemID, "player", slotIdx)
                            if ok and itemId then
                                local s, d = A.GetItemCooldownSafe(itemId)
                                if s and d and d > 0 then
                                    pcall(CooldownFrame_Set, slot.cdOverlay, s, d, 1)
                                else
                                    pcall(CooldownFrame_Set, slot.cdOverlay, 0, 0, 0)
                                end
                            end
                        elseif optEnt.key == "POTION" then
                            local potId = A.db.selectedPotionItem
                            if type(potId) == "string" then potId = tonumber(potId) end
                            if potId and potId ~= "none" then
                                local s, d = A.GetItemCooldownSafe(potId)
                                if s and d and d > 0 then
                                    pcall(CooldownFrame_Set, slot.cdOverlay, s, d, 1)
                                else
                                    pcall(CooldownFrame_Set, slot.cdOverlay, 0, 0, 0)
                                end
                            end
                        elseif optEnt.key == "RUNE" then
                            local runeId = A.db.selectedRuneItem
                            if type(runeId) == "string" then runeId = tonumber(runeId) end
                            if runeId and runeId ~= "none" then
                                local s, d = A.GetItemCooldownSafe(runeId)
                                if s and d and d > 0 then
                                    pcall(CooldownFrame_Set, slot.cdOverlay, s, d, 1)
                                else
                                    pcall(CooldownFrame_Set, slot.cdOverlay, 0, 0, 0)
                                end
                            end
                        else
                            local bSpell = SPELLS[optEnt.key]
                            if bSpell and bSpell.id then
                                local s, d = GetSpellCooldown(bSpell.id)
                                if s and d and d > 0 then
                                    pcall(CooldownFrame_Set, slot.cdOverlay, s, d, 1)
                                else
                                    pcall(CooldownFrame_Set, slot.cdOverlay, 0, 0, 0)
                                end
                            else
                                pcall(CooldownFrame_Set, slot.cdOverlay, 0, 0, 0)
                            end
                        end
                    end
                    local bLive = VisibleRemaining(optEnt)
                    if bLive and bLive > 0 then
                        slot.cdText:SetText(A.FormatTime(bLive))
                        slot.icon:SetVertexColor(0.6, 0.6, 0.6)
                    else
                        slot.cdText:SetText("")
                        slot.icon:SetVertexColor(1, 1, 1)
                    end
                    if not inRangeB then
                        slot.icon:SetVertexColor(0.8, 0.2, 0.2)
                    end
                    if showBinds then
                        local bBind = GetBindForKey(optEnt.key)
                        slot.bindText:SetText(bBind)
                        slot.bindText:Show()
                    else
                        slot.bindText:SetText("")
                        slot.bindText:Hide()
                    end
                    slot:Show()
                elseif slot then
                    slot:Hide()
                end
            end
        end

        -- Expose current display state so the Troubleshooter can report what
        -- the player is actually seeing vs. what the engine recommends.
        -- Written after the queue loop so the queue entries are accurate.
        do
            local qs = {}
            for i = 1, 3 do
                local ent = prio[i + queueStart - 1]
                if ent then
                    qs[i] = { key = ent.key, live = VisibleRemaining(ent) }
                end
            end
            A._rotDisplayState = {
                primaryKey    = p and p.key or nil,
                secondaryKey  = (primaryShown and p2) and p2.key or nil,
                primaryLive   = primaryLive,
                primaryTimer  = primary.cdText:GetText(),
                fadeActive    = primaryShown,
                queue         = qs,
                updatedAt     = now,
            }
        end
    end

    ----------------------------------------------------------------
    -- Throttled OnUpdate (separate ticker so f:Hide() doesn't kill it)
    -- Wrapped in pcall so a single error never kills the ticker.
    ----------------------------------------------------------------
    local acc = 0
    local ticker = CreateFrame("Frame")
    ticker:SetScript("OnUpdate", function(self, elapsed)
        acc = acc + elapsed
        if acc < 0.1 then return end
        acc = 0
        local ok, err = pcall(Refresh)
        if not ok then
            A.ReportError("ROT", "Refresh", err, { source = "ticker" })
        end
    end)

    ----------------------------------------------------------------
    -- Respond instantly to target / combat / aura changes
    ----------------------------------------------------------------
    local evRot = CreateFrame("Frame")
    evRot:RegisterEvent("PLAYER_TARGET_CHANGED")
    evRot:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    evRot:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
    evRot:RegisterEvent("UNIT_SPELLCAST_START")
    evRot:RegisterEvent("UNIT_AURA")
    evRot:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    evRot:RegisterEvent("PLAYER_REGEN_ENABLED")
    evRot:RegisterEvent("PLAYER_REGEN_DISABLED")
    evRot:RegisterEvent("UNIT_POWER_UPDATE")
    pcall(function() evRot:RegisterEvent("UPDATE_BINDINGS") end)
    pcall(function() evRot:RegisterEvent("UPDATE_ACTIONBAR") end)
    pcall(function() evRot:RegisterEvent("ACTIONBAR_PAGE_CHANGED") end)
    evRot:SetScript("OnEvent", function(self, event, arg1)
        if event == "UPDATE_BINDINGS" or event == "UPDATE_ACTIONBAR" or event == "ACTIONBAR_PAGE_CHANGED" then
            wipe(bindCache)
            return
        elseif event == "PLAYER_REGEN_DISABLED" then
            inCombat = true
            A.DebugLog("EVT", "combat START")
        elseif event == "PLAYER_REGEN_ENABLED" then
            inCombat = false
            A.DebugLog("EVT", "combat END")
            -- Clear recently-cast table on combat end
            wipe(recentCast)
            ResetRecommendationHysteresis()
        elseif event == "PLAYER_TARGET_CHANGED" then
            ResetRecommendationHysteresis()
        end
        if event == "UNIT_SPELLCAST_SUCCEEDED"
           or event == "UNIT_SPELLCAST_CHANNEL_START"
           or event == "UNIT_SPELLCAST_START"
           or event == "UNIT_POWER_UPDATE" then
            if arg1 ~= "player" then return end
        end
        if event == "UNIT_AURA" then
            if arg1 ~= "player" and arg1 ~= "target" then return end
        end
        acc = 0
        local ok, err = pcall(Refresh)
        if not ok then
            A.ReportError("ROT", "Refresh", err, { source = "event", event = event })
        end
    end)
end

------------------------------------------------------------------------
-- Register as SpecManager helper
------------------------------------------------------------------------
if SPHelper.SpecManager then
    SPHelper.SpecManager:RegisterHelper("Rotation", {
        _initialized = false,
        OnSpecActivate = function(self, spec)
            if self._initialized then return end
            self._initialized = true
            if SPHelper.InitRotation then SPHelper:InitRotation() end
        end,
        OnSpecDeactivate = function(self, spec)
            self._initialized = false
            if SPHelper.rotFrame then
                SPHelper.rotFrame:Hide()
            end
        end,
    })
end
