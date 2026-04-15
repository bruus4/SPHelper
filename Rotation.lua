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

local function GetFadeAlphas(cfg, cycle)
    local firstHalf = cycle < 1
    local phase = firstHalf and cycle or (cycle - 1)
    f:SetScript("OnHide", function(self)
        self.fadeSpeed = self.fadeSpeed or 1
    end)

    A._splitIconTestFrame = f
    UpdateFadeTestFrame(f, GetTime())
    f:Show()
    return f
end

function A:InitRotation()
    local db = A.db.rotation
    if not db.enabled then return end

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
    f:Show()
    A.rotFrame = f

    

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
            return bucket1 ~= nil
                and bucket2 ~= nil
                and (firstRec.eta or 0) <= 0
                and (secondRec.eta or 0) <= 0
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

        f:SetSize(ICON + SMALL * 3 + 20, ICON + 4)

        primary:SetSize(ICON, ICON)
        primary.cdText:SetFont("Fonts\\FRIZQT__.TTF",
            math.max(9, math.floor(ICON * 0.28)), "OUTLINE")

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
        for _, q in ipairs(f.queue) do q:Hide() end
        f:Hide()
    end

    local function Refresh()
        if previewActive then return end

        local prio, activeSpec = GetPriority()

        -- nil = no valid target
        if prio == nil then
            if inCombat then
                -- Give a short grace period before clearing (avoids flicker on target swap)
                if not noTargetSince then
                    noTargetSince = GetTime()
                elseif (GetTime() - noTargetSince) > 0.5 then
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
                    -- For channel spells (e.g. Mind Flay) keep the entry: the advisor
                    -- projects to the moment the current cast finishes, so the same spell
                    -- in slot 1 represents the NEXT cast. For other spells remove so the
                    -- display shows the actual NEXT cast.
                    local isChannelKey = A.ChannelHelper and A.ChannelHelper.KNOWN_CHANNELS
                        and (function()
                            for _, info in pairs(A.ChannelHelper.KNOWN_CHANNELS) do
                                if info.spellKey == castKey then return true end
                            end
                            -- also check by spell name
                            local spell = A.SPELLS[castKey]
                            if spell and spell.name and A.ChannelHelper.KNOWN_CHANNELS[spell.name] then return true end
                            return false
                        end)()
                    if not isChannelKey then
                        A.DebugLog("ROT", "filter: casting " .. castKey .. ", removing from pos 1")
                        table.remove(prio, 1)
                    else
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
            else
                return GetCachedSpellIcon(key)
            end
        end

        -- Range check helper: returns true if the key's spell/item is in range for the current target
        local function IsKeyInRange(key)
            if not UnitExists("target") then return true end
            if key == "POTION" or key == "RUNE" then return true end
            local spell = A.SPELLS[key]
            if spell and spell.name then
                local ok, inRange = pcall(IsSpellInRange, spell.name, "target")
                if ok and type(inRange) == "number" then
                    return (inRange == 1)
                end
            end
            -- If we cannot determine range, assume in-range to avoid false negatives
            return true
        end

        -- Recompute live remaining times for keys so primary can display live CD and dimming
        local function GetRemainingNowForKey(key)
            local now = GetTime()
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
            end
            -- Generic: try cooldown lookup via A.SPELLS[key]
            local spell = A.SPELLS[key]
            if spell then
                if spell.id then
                    local cd = A.GetSpellCDReal and A.GetSpellCDReal(spell.id)
                    if cd and cd > 0 then return math.max(cd, 0) end
                end
                -- Dot debuff: check remaining uptime on target
                if spell.name and UnitExists("target") and A.FindPlayerDebuff then
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
                        local _,_,_,_,_,exp = A.FindPlayerDebuff("target", spell.name)
                        if exp then return math.max(exp - now, 0) end
                        return 0
                    end
                end
            end
            return 0
        end

        local p = prio[1]
        local p2 = prio[2]
        local primaryFade = UseFadePrimary(activeSpec, p, p2)

        -- Use eta from the rotation engine: this is "time until cast window opens" for all
        -- spell types (DoT hold time, cooldown remaining, 0 = ready now). This avoids
        -- showing the full DoT remaining time (e.g. 5s) when what matters is "wait 2s more".
        local primaryLive = (p and p.eta and p.eta > 0) and p.eta or 0
        local inRangePrimary = p and IsKeyInRange(p.key)
        local secondaryLive = (p2 and p2.eta and p2.eta > 0) and p2.eta or 0
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

        -- GCD / spell cooldown sweep on primary icon
        if primary.cdOverlay then
            local spell = p and A.SPELLS[p.key]
            if spell then
                local start, dur = GetSpellCooldown(spell.id)
                if start and dur and dur > 0 then
                    pcall(CooldownFrame_Set, primary.cdOverlay, start, dur, 1)
                else
                    pcall(CooldownFrame_Set, primary.cdOverlay, 0, 0, 0)
                end
            else
                pcall(CooldownFrame_Set, primary.cdOverlay, 0, 0, 0)
            end
        end

        if primaryLive and primaryLive > 0 then
            primary.cdText:SetText(A.FormatTime(primaryLive))
            -- Dim the icon while it's still on cooldown; if out of range tint red
            if not inRangePrimary then
                if not primarySplit then primary.icon:SetVertexColor(0.7, 0.2, 0.2) end
            end
        else
            if p.clip then
                primary.cdText:SetText("Clip")
            else
                primary.cdText:SetText("")
            end
            if not inRangePrimary then
                if not primarySplit then primary.icon:SetVertexColor(0.8, 0.2, 0.2) end
            end
        end
        if lastPriSignature ~= primarySignature then
            A.DebugLog("ROT", "display: " .. (lastPriSignature or "nil") .. " -> " .. primarySignature)
            A.CreateBackdrop(primary, 0, 0, 0, 0.85, 1, 0.85, 0, 1)
            lastPriSignature = primarySignature
        end

        -- GetRemainingNowForKey moved above so primary can use it

        local queueStart = primaryShown and 3 or 2

        for i = 1, 3 do
            local q   = f.queue[i]
            local ent = prio[i + queueStart - 1]
            if ent then
                q.icon:SetTexture(GetDisplayIcon(ent.key))
                if ent.clip then
                    q.cdText:SetText("Clip")
                    q.icon:SetVertexColor(1, 1, 1)
                else
                    -- Recompute a live remaining time so countdowns tick during casts
                    local live = (ent.eta and ent.eta > 0) and ent.eta or 0
                    local inRangeQ = IsKeyInRange(ent.key)
                    if live and live > 0 then
                        q.cdText:SetText(A.FormatTime(live))
                        if not inRangeQ then
                            q.icon:SetVertexColor(0.8, 0.2, 0.2)
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
                q:Show()
            else
                q:Hide()
            end
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
            A.DebugLog("ERR", "Refresh: " .. tostring(err))
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
    evRot:SetScript("OnEvent", function(self, event, arg1)
        if event == "PLAYER_REGEN_DISABLED" then
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
            A.DebugLog("ERR", "Refresh(event=" .. event .. "): " .. tostring(err))
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
