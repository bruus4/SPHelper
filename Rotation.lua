------------------------------------------------------------------------
-- SPHelper  –  Rotation.lua
-- "What to cast next" advisor for TBC Shadow Priest.
-- Priority accounts for expiring dots, per-content SWD mode,
-- configurable SF mana threshold, and consumable suggestions.
------------------------------------------------------------------------
local A = SPHelper

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

        return frame
    end

    ----------------------------------------------------------------
    -- Primary (big) icon
    ----------------------------------------------------------------
    local primary = MakeIcon(f, ICON, nil, 0, 0)

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
    for key, spell in pairs(A.SPELLS) do
        local _, _, ic = GetSpellInfo(spell.id)
        spellIcons[key] = ic
    end
    -- Consumable icons
    spellIcons["POTION"] = GetItemIcon(22832) or "Interface\\Icons\\INV_Potion_76"
    spellIcons["RUNE"]   = GetItemIcon(20520) or "Interface\\Icons\\INV_Misc_Rune_04"

    ----------------------------------------------------------------
    -- SW:D eligibility (per-content type)
    ----------------------------------------------------------------
    local function SWDAllowed()
        local contentType = A.GetContentType()
        local mode
        if contentType == "raid" then
            mode = A.db.swdRaid or "execute"
        elseif contentType == "dungeon" then
            mode = A.db.swdDungeon or "always"
        else
            mode = A.db.swdWorld or "always"
        end
        if mode == "never" then return false end
        if mode == "execute" then
            -- Use absolute damage calculation: compare predicted SWD non-crit hit to target HP
            local thp, tmax, tpct = A.GetTargetHP()
            if not UnitExists("target") or tmax == 0 then
                return false
            end
            local sp = (A.GetSpellPower and A.GetSpellPower()) or 0
            local swdHit = math.floor(sp * 1.55 + 0.5)
            local safety = (A.db and A.db.swdSafetyPct) and (A.db.swdSafetyPct) or 0
            local required = thp * (1 + (safety or 0) / 100)
            -- If predicted non-crit SWD hit can kill the target with safety margin, allow SWD execute
            return thp > 0 and (swdHit >= required)
        end
        return true
    end

    ----------------------------------------------------------------
    -- Recently-cast tracking (prevents re-suggesting mid-travel spells)
    ----------------------------------------------------------------
    local recentCast = {}  -- key = spellName, value = GetTime()
    local RECENT_WINDOW = 1.0  -- seconds to suppress after cast finishes

    local recentEv = CreateFrame("Frame")
    recentEv:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    recentEv:SetScript("OnEvent", function(self, event, unit, _, spellId)
        if unit ~= "player" then return end
        if spellId then
            local name = GetSpellInfo(spellId)
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
    local VT_CAST_TIME = 1.5   -- VT cast time (fixed in TBC shadow)
    local SAFETY       = 0.5   -- margin for latency spikes / travel time
    local MF_CAST_TIME = 3.0   -- Mind Flay cast time (TBC)
    local MIN_MF_DURATION = 1.0 -- Minimum time MF must be cast for advisor to allow it when clipping

    local function GetPriority()
        local now = GetTime()
        local inCombatNow = UnitAffectingCombat("player")

        -- Target validation
        local hasTarget = UnitExists("target")
                          and not UnitIsDead("target")
                          and UnitCanAttack("player", "target")
        if not hasTarget then
            A.DebugLog("ROT", "no valid target — checking consumables only")
            -- Allow consumable / SF suggestions even without a target
            local result = {}
            local seen = {}
            local function Add(key, eta)
                if seen[key] then return end
                result[#result + 1] = { key = key, eta = eta or 0 }
                seen[key] = true
            end

            local now = GetTime()
            -- Project cooldowns for spells we may suggest (SF depends only on cooldown)
            local sfCD  = A.KnowsSpell(A.SPELLS.SF.id)
                          and math.max(A.GetSpellCDReal(A.SPELLS.SF.id) - 0, 0) or 999

            -- Resources
            local manaPct = (UnitPower("player", 0) or 0) /
                            math.max(UnitPowerMax("player", 0) or 1, 1)

            -- Shadowfiend (mana emergency)
            local sfThresh = (A.db.sfManaThreshold or 35) / 100
            if inCombatNow and manaPct < sfThresh and A.KnowsSpell(A.SPELLS.SF.id) and sfCD == 0 then
                Add("SF")
            end

            -- Consumables (pots and runes)
            if A.db.suggestPot then
                local potThresh = (A.db.potManaThreshold or 70) / 100
                if manaPct < potThresh then
                    local potId = A.db.selectedPotionItem
                    if type(potId) == "string" then local n = tonumber(potId); if n then potId = n end end
                    if potId and potId ~= "none" then
                        local potStart, potDur = A.GetItemCooldownSafe(potId)
                        local potReady = (not potStart or not potDur or potStart == 0 or (potStart + potDur - now) <= 0)
                        if potReady and (GetItemCount(potId) or 0) > 0 then Add("POTION") end
                    end
                end
            end
            if A.db.suggestRune then
                local runeThresh = (A.db.runeManaThreshold or 40) / 100
                if manaPct < runeThresh then
                    local runeId = A.db.selectedRuneItem
                    if type(runeId) == "string" then local n = tonumber(runeId); if n then runeId = n end end
                    if runeId and runeId ~= "none" then
                        local start, dur = A.GetItemCooldownSafe(runeId)
                        local ready = (not start or not dur or start == 0 or (start + dur - now) <= 0)
                        if ready and (GetItemCount(runeId) or 0) > 0 then Add("RUNE") end
                    else
                        for _, id in ipairs(A.RUNE_IDS or {}) do
                            if (GetItemCount(id) or 0) > 0 then
                                local start, dur = A.GetItemCooldownSafe(id)
                                local ready = (not start or not dur or start == 0 or (start + dur - now) <= 0)
                                if ready then Add("RUNE"); break end
                            end
                        end
                    end
                end
            end

            -- If nothing else to suggest:
            -- - In combat: show MF filler so the advisor remains useful.
            -- - Out of combat: return nil so the display clears (no target/no combat).
            if #result == 0 then
                if inCombatNow then
                    Add("MF")
                else
                    return nil
                end
            end

            if A.debugEnabled then
                local parts = {}
                for i, r in ipairs(result) do
                    parts[i] = r.key .. (r.eta > 0 and ("(" .. string.format("%.1f", r.eta) .. ")") or "")
                end
                A.DebugLog("ROT", "prio(no-target)=[" .. table.concat(parts, ",") .. "]")
            end

            return result
        end

        -- Time remaining on current cast / channel
        local castingSpell, castRemaining = GetPlayerCastInfo()

        -- Haste-adjusted timings
        local hastePct, hasteMul = 0, 1
        if A.GetHaste then
            local ok, hp, hm = pcall(A.GetHaste)
            if ok and hp and hm then hastePct, hasteMul = hp, hm end
        end
        local gcd = math.max(1.0, 1.5 / hasteMul)
        local lat = A.GetLatency()

        ---- DoT timers on current target (name-based, rank-agnostic) ----
        local vtRem, swpRem = 0, 0
        do
            local n, _, _, _, _, exp = A.FindPlayerDebuff("target", A.SPELLS.VT.name)
            if n and exp then vtRem = math.max(exp - now, 0) end
        end
        do
            local n, _, _, _, _, exp = A.FindPlayerDebuff("target", A.SPELLS.SWP.name)
            if n and exp then swpRem = math.max(exp - now, 0) end
        end

        -- In-flight / recently-cast: debuff may not be scan-able yet
        if vtRem == 0 then
            if (castingSpell and castingSpell == A.SPELLS.VT.name)
               or WasRecentlyCast(A.SPELLS.VT.name) then
                vtRem = 15
            end
        end
        if swpRem == 0 then
            if WasRecentlyCast(A.SPELLS.SWP.name) then
                swpRem = 18
            end
        end

        -- Project to the moment the current cast finishes
        local vtAfter  = math.max(vtRem  - castRemaining, 0)
        local swpAfter = math.max(swpRem - castRemaining, 0)

        -- Project cooldowns (only for known spells)
        local mbCD  = A.KnowsSpell(A.SPELLS.MB.id)
                      and math.max(A.GetSpellCDReal(A.SPELLS.MB.id) - castRemaining, 0) or 999
        local swdCD = A.KnowsSpell(A.SPELLS.SWD.id)
                      and math.max(A.GetSpellCDReal(A.SPELLS.SWD.id) - castRemaining, 0) or 999
        local sfCD  = A.KnowsSpell(A.SPELLS.SF.id)
                      and math.max(A.GetSpellCDReal(A.SPELLS.SF.id) - castRemaining, 0) or 999
        local dpCD  = A.KnowsSpell(A.SPELLS.DP.id)
                      and math.max(A.GetSpellCDReal(A.SPELLS.DP.id) - castRemaining, 0) or 999

        -- Resources
        local manaPct = (UnitPower("player", 0) or 0) /
                        math.max(UnitPowerMax("player", 0) or 1, 1)
        local hpPct   = (UnitHealth("player") or 1) /
                        math.max(UnitHealthMax("player") or 1, 1)

        ----------------------------------------------------------------
        -- Urgency thresholds
        --   VT:  will it fall off before we can re-cast it?
        --        Need VT_CAST_TIME + lat + SAFETY after current cast.
        --   SWP: instant, just needs one GCD + lat + SAFETY.
        ----------------------------------------------------------------
        local vtCastEff = VT_CAST_TIME / hasteMul
        local mfCastEff = MF_CAST_TIME / hasteMul
        local minMfEff  = MIN_MF_DURATION / hasteMul

        local vtUrgent  = A.KnowsSpell(A.SPELLS.VT.id)
                  and (vtAfter < vtCastEff + lat + SAFETY)
        local swpUrgent = (swpAfter < gcd + lat + SAFETY)

        ----------------------------------------------------------------
        -- Build ordered result
        ----------------------------------------------------------------
        local result = {}
        local seen   = {}

        local function Add(key, eta, clip)
            if seen[key] then return end
            local entry = { key = key, eta = eta or 0 }
            if clip then entry.clip = true end
            result[#result + 1] = entry
            seen[key] = true
        end

        -- Priority: if SW:D can outright kill the target, force it to primary
        local swdCanKill = false
        if A.KnowsSpell(A.SPELLS.SWD.id) then
            local sp = (A.GetSpellPower and A.GetSpellPower()) or 0
            local swdHit = math.floor(sp * 1.55 + 0.5)
            local thp = 0
            do
                local hp, maxhp = A.GetTargetHP()
                thp = hp or 0
            end
            local safety = (A.db and A.db.swdSafetyPct) and (A.db.swdSafetyPct) or 0
            local required = thp * (1 + (safety or 0) / 100)
            if thp > 0 and swdHit > 0 and swdHit >= required then swdCanKill = true end
        end
        if swdCanKill and swdCD == 0 then
            Add("SWD")
        end

        -- 1) VT urgent (must maintain — raid mana return)
        if not swdCanKill and vtUrgent then Add("VT") end

        -- 2) SWP urgent
        if swpUrgent then Add("SWP") end

        -- 3) MB ready
        if mbCD == 0 then
            Add("MB")
        else
            -- If we're currently casting Mind Flay, prefer casting another MF
            -- unless MB/SWD/dots are so close that MF couldn't be cast for at
            -- least `MIN_MF_DURATION`. If MB/SWD/dot will come off during MF
            -- we still allow MF but mark it as a clip candidate.
            local isCastingMF = (castingSpell and castingSpell == A.SPELLS.MF.name)
            if isCastingMF then
                -- Prefer MF unless MB/SWD/dots are within MF_CAST_TIME (i.e. will be ready
                -- or expire within the next MF cast). If they are within that window but
                -- still leave at least MIN_MF_DURATION of MF, we suggest MF with a clip flag.
                local mbTooClose = (mbCD > 0 and mbCD <= mfCastEff)
                local swdTooClose = (swdCD > 0 and swdCD <= mfCastEff)
                local vtTooClose = (vtAfter > 0 and vtAfter <= mfCastEff)
                local swpTooClose = (swpAfter > 0 and swpAfter <= mfCastEff)

                -- If none are too close, safe to continue MF without clipping
                if not (mbTooClose or swdTooClose or vtTooClose or swpTooClose) then
                    Add("MF", 0, false)
                else
                    -- They are close; only allow MF if there's at least MIN_MF_DURATION before the event
                    local willAllow = false
                    local clip = false
                    if (mbCD > 0 and mbCD >= minMfEff) then
                        willAllow = true
                        if mbCD < mfCastEff then clip = true end
                    end
                    if (swdCD > 0 and swdCD >= minMfEff) then
                        willAllow = true
                        if swdCD < mfCastEff then clip = true end
                    end
                    if (vtAfter > 0 and vtAfter >= minMfEff) then
                        willAllow = true
                        if vtAfter < mfCastEff then clip = true end
                    end
                    if (swpAfter > 0 and swpAfter >= minMfEff) then
                        willAllow = true
                        if swpAfter < mfCastEff then clip = true end
                    end
                    if willAllow then Add("MF", 0, clip) end
                end
            end
        end

        -- 3a) Early potion option: if enabled, suggest potion before Shadowfiend
        if A.db.potEarly and A.db.suggestPot and inCombatNow then
            local ok, err = pcall(function()
                local potThresh = (A.db.potManaThreshold or 70) / 100
                if manaPct < potThresh then
                    local potId = A.db.selectedPotionItem
                    if type(potId) == "string" then local n = tonumber(potId); if n then potId = n end end
                    if potId and potId ~= "none" then
                        local potStart, potDur = A.GetItemCooldownSafe(potId)
                        local potReady = (not potStart or not potDur or potStart == 0 or (potStart + potDur - now) <= 0)
                        local potCount = (GetItemCount(potId) or 0)
                        if A.debugEnabled then
                            A.DebugLog("POT", string.format("early pot check potId=%s count=%d ready=%s manaPct=%.2f thresh=%.2f", tostring(potId), potCount, tostring(potReady), manaPct, potThresh))
                        end
                        if potReady and potCount > 0 then Add("POTION") end
                    end
                end
            end)
            if not ok then A.DebugLog("ERR", "Early potion check failed: " .. tostring(err)) end
        end

        -- 4) Shadowfiend (mana emergency)
        local sfThresh = (A.db.sfManaThreshold or 35) / 100
        if manaPct < sfThresh and A.KnowsSpell(A.SPELLS.SF.id) and sfCD == 0 then
            Add("SF")
        end

        -- 5) SW:D (per-content mode)
        if A.KnowsSpell(A.SPELLS.SWD.id) and SWDAllowed()
           and hpPct > 0.20 and swdCD == 0 then
            -- If mode == "always", require player's absolute HP > 3000
            local contentType = A.GetContentType()
            local mode
            if contentType == "raid" then
                mode = A.db.swdRaid or "execute"
            elseif contentType == "dungeon" then
                mode = A.db.swdDungeon or "always"
            else
                mode = A.db.swdWorld or "always"
            end
            if mode == "always" then
                -- Dynamic threshold based on player's spell power.
                -- Use heuristic: SW:D hit ~= 1.55 * spellPower; crit multiplier 1.5
                local sp = (A.GetSpellPower and A.GetSpellPower()) or 0
                local swdHit = math.floor(sp * 1.55 + 0.5)
                local swdCrit = math.floor(swdHit * 1.5 + 0.5)
                local playerHP = (UnitHealth("player") or 0)
                if A.debugEnabled then
                    A.DebugLog("SWD", string.format("sp=%d swdHit=%d swdCrit=%d playerHP=%d", sp, swdHit, swdCrit, playerHP))
                end
                if playerHP > swdCrit then
                    Add("SWD")
                end
            else
                Add("SWD")
            end
        end

        -- 6) Devouring Plague (if not on target)
        if A.KnowsSpell(A.SPELLS.DP.id) then
            local dpUp = A.FindPlayerDebuff("target", A.SPELLS.DP.name)
            if not dpUp and dpCD == 0 then Add("DP") end
        end

        -- 7) Consumables — respect user selection and inventory
        -- If `potEarly` is enabled, potion already handled above.
        if A.db.suggestPot and not A.db.potEarly and inCombatNow then
            local ok, err = pcall(function()
                local potThresh = (A.db.potManaThreshold or 70) / 100
                if manaPct < potThresh then
                    local potId = A.db.selectedPotionItem
                    if type(potId) == "string" then
                        local n = tonumber(potId)
                        if n then potId = n end
                    end
                    if potId and potId ~= "none" then
                        local potStart, potDur = A.GetItemCooldownSafe(potId)
                        local potReady = (not potStart or not potDur
                            or potStart == 0
                            or (potStart + potDur - now) <= 0)
                        local potCount = (GetItemCount(potId) or 0)
                        if A.debugEnabled then
                            A.DebugLog("POT", string.format("potId=%s count=%d potReady=%s manaPct=%.2f thresh=%.2f", tostring(potId), potCount, tostring(potReady), manaPct, potThresh))
                        end
                        if potReady and potCount > 0 then
                            Add("POTION")
                        end
                    end
                end
            end)
            if not ok then A.DebugLog("ERR", "Potion check failed: " .. tostring(err)) end
        end
        if A.db.suggestRune then
            local ok, err = pcall(function()
                local runeThresh = (A.db.runeManaThreshold or 40) / 100
                if manaPct < runeThresh then
                    local runeId = A.db.selectedRuneItem
                    if type(runeId) == "string" then
                        local n = tonumber(runeId)
                        if n then runeId = n end
                    end
                    if runeId and runeId ~= "none" then
                        local start, dur = A.GetItemCooldownSafe(runeId)
                        local ready = (not start or not dur or start == 0 or (start + dur - now) <= 0)
                        local runeCount = (GetItemCount(runeId) or 0)
                        if A.debugEnabled then
                            A.DebugLog("RUNE", string.format("runeId=%s count=%d ready=%s manaPct=%.2f thresh=%.2f", tostring(runeId), runeCount, tostring(ready), manaPct, runeThresh))
                        end
                        if ready and runeCount > 0 then Add("RUNE") end
                    else
                        -- auto-detect: check any rune in the known list
                        for _, id in ipairs(A.RUNE_IDS or {}) do
                            local cnt = (GetItemCount(id) or 0)
                            if cnt > 0 then
                                local start, dur = A.GetItemCooldownSafe(id)
                                local ready = (not start or not dur or start == 0 or (start + dur - now) <= 0)
                                if A.debugEnabled then
                                    A.DebugLog("RUNE", string.format("auto id=%s count=%d ready=%s manaPct=%.2f thresh=%.2f", tostring(id), cnt, tostring(ready), manaPct, runeThresh))
                                end
                                if ready then Add("RUNE"); break end
                            end
                        end
                    end
                end
            end)
            if not ok then A.DebugLog("ERR", "Rune check failed: " .. tostring(err)) end
        end

        -- 8) MF filler (always available) — but prefer MF when it can be clipped
        do
            local clip = false
            -- Clip because MB will come off during MF cast
            if mbCD > 0 and mbCD < mfCastEff and mbCD >= minMfEff then
                clip = true
            end
            -- Clip because a DOT will expire during MF cast
            if (vtAfter > 0 and vtAfter < mfCastEff and vtAfter >= minMfEff)
               or (swpAfter > 0 and swpAfter < mfCastEff and swpAfter >= minMfEff) then
                clip = true
            end
            Add("MF", 0, clip)
        end

        -- Append upcoming (not-yet-ready) spells for queue display
        local upcoming = {}
        if not vtUrgent and A.KnowsSpell(A.SPELLS.VT.id) then
            local vtNow = vtRem
            local vtProj = math.max(vtAfter - vtCastEff - lat - SAFETY, 0)
            upcoming[#upcoming + 1] = { key = "VT", eta = vtProj, displayEta = vtNow }
        end
        if not swpUrgent then
            local swpNow = swpRem
            local swpProj = math.max(swpAfter - gcd - lat - SAFETY, 0)
            upcoming[#upcoming + 1] = { key = "SWP", eta = swpProj, displayEta = swpNow }
        end
        if mbCD > 0 then
            local mbNow = math.max(A.GetSpellCDReal(A.SPELLS.MB.id), 0)
            upcoming[#upcoming + 1] = { key = "MB", eta = mbCD, displayEta = mbNow }
        end
        if A.KnowsSpell(A.SPELLS.SWD.id) and SWDAllowed()
           and hpPct > 0.20 and swdCD > 0 then
            local swdNow = math.max(A.GetSpellCDReal(A.SPELLS.SWD.id), 0)
            upcoming[#upcoming + 1] = { key = "SWD", eta = swdCD, displayEta = swdNow }
        end

        table.sort(upcoming, function(a, b) return a.eta < b.eta end)
        for _, v in ipairs(upcoming) do Add(v.key, v.eta) end

        -- Debug log / Inner Focus insertion (tunable via DB)
        do
            local db = A.db.rotation or {}
            local ifCfg = db.ifInsert or { enabled = true, onlyForBoss = true, before = "MB" }
            if ifCfg.enabled and A.KnowsSpell(A.SPELLS.IF.id) then
                local class = UnitClassification("target") or ""
                local isBoss = (class == "worldboss" or class == "elite" or class == "rareelite")
                if (not ifCfg.onlyForBoss) or isBoss then
                    local ifCD = math.max(A.GetSpellCDReal(A.SPELLS.IF.id), 0)
                    local function PlayerHasBuff(buffName)
                        if not buffName then return false end
                        for i = 1, 40 do
                            local name = UnitBuff("player", i)
                            if not name then break end
                            if name == buffName then return true end
                        end
                        return false
                    end
                    if ifCD == 0 and not PlayerHasBuff(A.SPELLS.IF.name) then
                        local beforeKey = ifCfg.before or "MB"
                        -- find the requested target spell in the result
                        local idx = nil
                        for i = 1, #result do if result[i] and result[i].key == beforeKey then idx = i; break end end
                        -- allow insertion if the target spell will be available soon
                        local IF_WINDOW = 4.0 -- seconds window to consider "soon"
                        local allowInsert = false
                        if idx then
                            local ent = result[idx]
                            local eta = (ent and ent.eta) or 0
                            if beforeKey == "MB" then
                                -- Mind Blast: allow if MB is ready now or will be ready within IF_WINDOW
                                if mbCD == 0 or eta <= IF_WINDOW then allowInsert = true end
                            elseif beforeKey == "SWP" then
                                -- SWP: urgent or will be ready soon
                                if swpUrgent or eta <= IF_WINDOW then allowInsert = true end
                            elseif beforeKey == "DP" then
                                -- DP: allow if DP off cooldown or will be ready soon
                                if dpCD == 0 or eta <= IF_WINDOW then allowInsert = true end
                            else
                                if eta <= IF_WINDOW then allowInsert = true end
                            end
                        end

                        if allowInsert and idx then
                            -- remove any existing IF entries
                            for i = #result, 1, -1 do if result[i] and result[i].key == "IF" then table.remove(result, i) end end
                            table.insert(result, idx, { key = "IF", eta = 0 })
                            A.DebugLog("IF", "Inserted Inner Focus before " .. tostring(beforeKey) .. " (eta=" .. tostring((result[idx] and result[idx].eta) or 0) .. ")")
                            lastPriKey = nil
                        end
                    end
                end
            end
        end
        if A.debugEnabled then
            local parts = {}
            for i, r in ipairs(result) do
                parts[i] = r.key .. (r.eta > 0
                    and ("(" .. string.format("%.1f", r.eta) .. ")") or "")
            end
            A.DebugLog("ROT", "prio=[" .. table.concat(parts, ",") .. "]"
                .. " vtR=" .. string.format("%.1f", vtRem)
                .. " vtA=" .. string.format("%.1f", vtAfter)
                .. " swpR=" .. string.format("%.1f", swpRem)
                .. " swpA=" .. string.format("%.1f", swpAfter)
                .. " castRem=" .. string.format("%.1f", castRemaining)
                .. " cast=" .. tostring(castingSpell)
                .. " mbCD=" .. string.format("%.1f", mbCD))
        end

        return result
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
        primary.icon:SetTexture(spellIcons["VT"])
        primary.cdText:SetText("")
        A.CreateBackdrop(primary, 0, 0, 0, 0.85, 1, 0.85, 0, 1)
        f:Show()

        local dummyQueue = { "MB", "SWP", "MF" }
        for i = 1, 3 do
            local q = f.queue[i]
            q.icon:SetTexture(spellIcons[dummyQueue[i]])
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
    local lastPriKey    = nil
    local inCombat      = UnitAffectingCombat("player")
    local noTargetSince = nil   -- GetTime() when we first saw nil prio in combat

    local function ClearDisplay()
        primary.icon:SetTexture(nil)
        primary.cdText:SetText("")
        A.CreateBackdrop(primary, 0, 0, 0, 0.85)
        lastPriKey = nil
        for _, q in ipairs(f.queue) do q:Hide() end
        f:Hide()
    end

    local function Refresh()
        if previewActive then return end

        local prio = GetPriority()

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

        -- Empty prio (target exists but nothing to cast) — show MF filler
        if #prio == 0 then
            prio = {{ key = "MF", eta = 0 }}
        end

        -- Filter: if currently casting/channeling a spell, move it out of
        -- position 1 so the display always shows what to cast NEXT.
        do
            local castName = select(1, GetPlayerCastInfo())
            if castName then
                local castKey = nameToKey[castName]
                if castKey and prio[1] and prio[1].key == castKey then
                    -- When channeling Mind Flay, don't remove the MF entry: the advisor's
                    -- priorities are projected to the moment the current cast finishes,
                    -- so an MF entry while channeling MF represents the NEXT MF and
                    -- should be displayed. For other spells, remove the currently
                    -- casting spell so the display shows the actual NEXT cast.
                    if castKey ~= "MF" then
                        A.DebugLog("ROT", "filter: casting " .. castKey .. ", removing from pos 1")
                        table.remove(prio, 1)
                        if #prio == 0 then
                            prio = {{ key = "MF", eta = 0 }}
                        end
                    else
                        -- If channeling MF, normally keep the next-MF suggestion. However,
                        -- if the target reaches execute range for SW:D and the target is a
                        -- normal mob (not elite/boss), prefer SW:D even mid-channel.
                        local swdIndex = nil
                        for idx,entry in ipairs(prio) do
                            if entry.key == "SWD" then swdIndex = idx; break end
                        end
                        if swdIndex and swdIndex > 1 then
                            local class = UnitClassification("target") or ""
                            if class == "normal" or class == "minus" then
                                A.DebugLog("ROT", "filter: casting MF but SWD present and target normal; switching to SWD")
                                -- remove the current MF entry so SWD becomes primary
                                table.remove(prio, 1)
                                if #prio == 0 then
                                    prio = {{ key = "MF", eta = 0 }}
                                end
                            else
                                A.DebugLog("ROT", "filter: casting MF — target not normal (" .. tostring(class) .. ") keep MF")
                            end
                        else
                            A.DebugLog("ROT", "filter: casting MF — keep next-MF suggestion")
                        end
                    end
                end
            end
        end

        -- Additional handling: if channeling MF and SWD becomes available in the
        -- priority list (e.g. target reached execute while channeling), move SWD
        -- to the front so the primary updates immediately (but only for normal/minus targets).
        do
            local castName = select(1, GetPlayerCastInfo())
            if castName and castName == A.SPELLS.MF.name then
                for idx = 1, #prio do
                    if prio[idx] and prio[idx].key == "SWD" then
                        local class = UnitClassification("target") or ""
                        if class == "normal" or class == "minus" then
                            local swdent = table.remove(prio, idx)
                            table.insert(prio, 1, swdent)
                            A.DebugLog("ROT", "mid-channel: moved SWD to primary (target normal)")
                            lastPriKey = nil
                        end
                        break
                    end
                end
            end
        end

        f:Show()

        

        local function GetDisplayIcon(key)
            if key == "POTION" then
                local potId = A.db.selectedPotionItem
                if type(potId) == "string" then potId = tonumber(potId) end
                if potId and potId ~= "none" then
                    local icon = GetItemIcon(potId)
                    if icon then return icon end
                end
                return spellIcons["POTION"]
            elseif key == "RUNE" then
                local runeId = A.db.selectedRuneItem
                if type(runeId) == "string" then runeId = tonumber(runeId) end
                if runeId and runeId ~= "none" then
                    local icon = GetItemIcon(runeId)
                    if icon then return icon end
                end
                return spellIcons["RUNE"]
            else
                return spellIcons[key]
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
            if key == "MB" then
                return math.max(A.GetSpellCDReal(A.SPELLS.MB.id), 0)
            elseif key == "SWD" then
                return math.max(A.GetSpellCDReal(A.SPELLS.SWD.id), 0)
            elseif key == "SF" then
                return math.max(A.GetSpellCDReal(A.SPELLS.SF.id), 0)
            elseif key == "DP" then
                return math.max(A.GetSpellCDReal(A.SPELLS.DP.id), 0)
            elseif key == "VT" then
                local n,_,_,_,_,exp = A.FindPlayerDebuff("target", A.SPELLS.VT.name)
                if exp then return math.max(exp - now, 0) end
                return 0
            elseif key == "SWP" then
                local n,_,_,_,_,exp = A.FindPlayerDebuff("target", A.SPELLS.SWP.name)
                if exp then return math.max(exp - now, 0) end
                return 0
            elseif key == "POTION" then
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
            return 0
        end

        local p = prio[1]
        primary.icon:SetTexture(GetDisplayIcon(p.key))
        -- Show live remaining cooldown on primary when present; otherwise show Clip
        local primaryLive = (p and GetRemainingNowForKey and GetRemainingNowForKey(p.key)) or 0
        local inRangePrimary = p and IsKeyInRange(p.key)
        if primaryLive and primaryLive > 0 then
            primary.cdText:SetText(A.FormatTime(primaryLive))
            -- Dim the icon while it's still on cooldown; if out of range tint red
            if not inRangePrimary then
                primary.icon:SetVertexColor(0.7, 0.2, 0.2)
            else
                primary.icon:SetVertexColor(0.6, 0.6, 0.6)
            end
        else
            if p.clip then
                primary.cdText:SetText("Clip")
            else
                primary.cdText:SetText("")
            end
            if not inRangePrimary then
                primary.icon:SetVertexColor(0.8, 0.2, 0.2)
            else
                primary.icon:SetVertexColor(1, 1, 1)
            end
        end
        if lastPriKey ~= p.key then
            A.DebugLog("ROT", "display: " .. (lastPriKey or "nil") .. " -> " .. p.key)
            A.CreateBackdrop(primary, 0, 0, 0, 0.85, 1, 0.85, 0, 1)
            lastPriKey = p.key
        end

        -- GetRemainingNowForKey moved above so primary can use it

        for i = 1, 3 do
            local q   = f.queue[i]
            local ent = prio[i + 1]
            if ent then
                q.icon:SetTexture(GetDisplayIcon(ent.key))
                if ent.clip then
                    q.cdText:SetText("Clip")
                    q.icon:SetVertexColor(1, 1, 1)
                else
                    -- Recompute a live remaining time so countdowns tick during casts
                    local live = GetRemainingNowForKey(ent.key)
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
