------------------------------------------------------------------------
-- SPHelper  –  Core.lua
-- Shared constants, utilities, and event bus for the addon.
-- Only loads for Priests with the Shadowform talent.
------------------------------------------------------------------------
SPHelper = SPHelper or {}
local A = SPHelper

------------------------------------------------------------------------
-- Spell data  (TBC 2.5.x spell IDs – base rank names work for all ranks)
------------------------------------------------------------------------
A.SPELLS = {
    VT   = { id = 34914, name = GetSpellInfo(34914) or "Vampiric Touch"   },
    SWP  = { id = 589,   name = GetSpellInfo(589)   or "Shadow Word: Pain"},
    MB   = { id = 8092,  name = GetSpellInfo(8092)  or "Mind Blast"       },
    MF   = { id = 15407, name = GetSpellInfo(15407)  or "Mind Flay"       },
    SWD  = { id = 32379, name = GetSpellInfo(32379)  or "Shadow Word: Death"},
    DP   = { id = 2944,  name = GetSpellInfo(2944)   or "Devouring Plague" },
    SF   = { id = 34433, name = GetSpellInfo(34433)  or "Shadowfiend"      },
    VE   = { id = 15286, name = GetSpellInfo(15286)  or "Vampiric Embrace"  },
    SFORM= { id = 15473, name = GetSpellInfo(15473)  or "Shadowform"        },
    MS   = { id = 453,   name = GetSpellInfo(453)    or "Mind Soothe"       },
    SU   = { id = 9484,  name = GetSpellInfo(9484)   or "Shackle Undead"    },
}
-- Inner Focus (suggested for boss spellbatching with Mind Blast/SWD)
A.SPELLS.IF = { id = 14751, name = GetSpellInfo(14751) or "Inner Focus" }

------------------------------------------------------------------------
-- Consumable items (for mana suggestions)
------------------------------------------------------------------------
A.CONSUMABLES = {
    MANA_POT    = { itemId = 22832, name = "Super Mana Potion" },
    DARK_RUNE   = { itemId = 20520, name = "Dark Rune" },
    DEMONIC_RUNE= { itemId = 12662, name = "Demonic Rune" },
}

-- Common consumable IDs we offer in the UI for tracking
A.POTION_IDS = { 22832, 13444, 3385, 28101, 32948, 32902 }   -- Super, Major, Lesser, Unstable, Auchenai, Bottled Nethergon
A.RUNE_IDS   = { 20520, 12662 }         -- Dark Rune, Demonic Rune

------------------------------------------------------------------------
-- Colors
------------------------------------------------------------------------
A.COLORS = {
    VT      = { 0.45, 0.20, 0.55, 1 },
    SWP     = { 0.70, 0.30, 0.30, 1 },
    MB      = { 0.35, 0.58, 0.92, 1 },
    MF      = { 0.58, 0.51, 0.79, 1 },
    SWD     = { 0.85, 0.15, 0.15, 1 },
    DP      = { 0.40, 0.70, 0.30, 1 },
    SF      = { 0.80, 0.80, 0.20, 1 },
    MS      = { 0.30, 0.70, 0.85, 1 },
    SU      = { 0.80, 0.60, 0.20, 1 },
    POTION  = { 0.20, 0.50, 0.90, 1 },
    RUNE    = { 0.60, 0.20, 0.70, 1 },
    DEFAULT = { 0.85, 0.75, 0.36, 1 },
    BG      = { 0.08, 0.08, 0.08, 0.85 },
    BORDER  = { 0.0,  0.0,  0.0,  1 },
    SAFE    = { 0.30, 1.0,  0.30, 1 },
    WARN    = { 1.0,  0.85, 0.0,  1 },
    TEXT    = { 1, 1, 1, 1 },
}

------------------------------------------------------------------------
-- MF tick sound options — all entries are very short (< 0.4 s) unless
-- marked "medium". SoundKit IDs verified for the TBC Anniversary client.
------------------------------------------------------------------------
A.TICK_SOUNDS = {
    { key = "none",   label = "None",             id = nil  },
    -- Short, crisp clicks / pops
    { key = "click",  label = "Click",            id = 856  },
    { key = "tap",    label = "Tap",              id = 567  },
    { key = "pop",    label = "Pop",              id = 869  },
    { key = "snap",   label = "Snap",             id = 860  },
    { key = "blip",   label = "Blip",             id = 563  },
    -- Tonal / pitched
    { key = "coin",   label = "Coin",             id = 120  },
    { key = "beep",   label = "Beep",             id = 793  },
    { key = "ping",   label = "Ping",             id = 3175 },
    { key = "chime",  label = "Chime",            id = 879  },
    { key = "ding",   label = "Ding",             id = 855  },
    -- Medium-length (pleasant but audible)
    { key = "bell",   label = "Bell (medium)",    id = 5274 },
    { key = "alert",  label = "Alert (medium)",   id = 8959 },
}

function A.GetTickSoundId(key)
    for _, s in ipairs(A.TICK_SOUNDS) do
        if s.key == key then return s.id end
    end
    return nil
end

------------------------------------------------------------------------
-- MF tick screen-flash colour options
-- All five colours are available for every placement mode.
------------------------------------------------------------------------
A.TICK_FLASH_EFFECTS = {
    { key = "none",          label = "None",              color = nil,              mode = "full"  },
    -- Full-screen solid flash
    { key = "green",         label = "Green (full)",      color = {0.3, 0.9, 0.3}, mode = "full"  },
    { key = "purple",        label = "Purple (full)",     color = {0.7, 0.3, 0.9}, mode = "full"  },
    { key = "shadow",        label = "Shadow (full)",     color = {0.5, 0.2, 0.8}, mode = "full"  },
    { key = "white",         label = "White (full)",      color = {1.0, 1.0, 1.0}, mode = "full"  },
    { key = "red",           label = "Red (full)",        color = {0.9, 0.2, 0.2}, mode = "full"  },
    -- Top-edge gradient (bleeds downward from the top)
    { key = "green_top",     label = "Green (top)",       color = {0.3, 0.9, 0.3}, mode = "top"   },
    { key = "purple_top",    label = "Purple (top)",      color = {0.7, 0.3, 0.9}, mode = "top"   },
    { key = "shadow_top",    label = "Shadow (top)",      color = {0.5, 0.2, 0.8}, mode = "top"   },
    { key = "white_top",     label = "White (top)",       color = {1.0, 1.0, 1.0}, mode = "top"   },
    { key = "red_top",       label = "Red (top)",         color = {0.9, 0.2, 0.2}, mode = "top"   },
    -- Side-edge gradients (bleed inward from left and right)
    { key = "green_sides",   label = "Green (sides)",     color = {0.3, 0.9, 0.3}, mode = "sides" },
    { key = "purple_sides",  label = "Purple (sides)",    color = {0.7, 0.3, 0.9}, mode = "sides" },
    { key = "shadow_sides",  label = "Shadow (sides)",    color = {0.5, 0.2, 0.8}, mode = "sides" },
    { key = "white_sides",   label = "White (sides)",     color = {1.0, 1.0, 1.0}, mode = "sides" },
    { key = "red_sides",     label = "Red (sides)",       color = {0.9, 0.2, 0.2}, mode = "sides" },
}

function A.GetTickFlashColor(key)
    for _, e in ipairs(A.TICK_FLASH_EFFECTS) do
        if e.key == key then return e.color end
    end
    return nil
end

function A.GetTickFlashMode(key)
    for _, e in ipairs(A.TICK_FLASH_EFFECTS) do
        if e.key == key then return e.mode or "full" end
    end
    return "full"
end

------------------------------------------------------------------------
-- Utility helpers
------------------------------------------------------------------------

-- One-way world latency in seconds
function A.GetLatency()
    local _, _, _, latencyWorld = GetNetStats()
    return (latencyWorld or 50) / 1000
end

-- Remaining cooldown on a spell (0 if ready)
function A.GetSpellCD(spellId)
    local start, dur, enabled = GetSpellCooldown(spellId)
    if not start or start == 0 then return 0 end
    local remaining = start + dur - GetTime()
    return remaining > 0 and remaining or 0
end

-- Remaining cooldown IGNORING the GCD (treats GCD-only as 0)
function A.GetSpellCDReal(spellId)
    local start, dur, enabled = GetSpellCooldown(spellId)
    if not start or start == 0 then return 0 end
    -- If duration <= 1.5, the spell is only on GCD, not its own CD
    if dur and dur > 0 and dur <= 1.5 then return 0 end
    local remaining = start + dur - GetTime()
    return remaining > 0 and remaining or 0
end

-- Item cooldown accessor. `GetItemCooldown` is part of the TBC/Classic API
-- and is always available on the TBC Anniversary client.
function A.GetItemCooldownSafe(itemId)
    if type(itemId) ~= "number" then
        itemId = tonumber(itemId) or 0
    end
    local start, dur, enable = GetItemCooldown(itemId)
    return start or 0, dur or 0, enable
end

-- Return an estimated spell power for the player.
-- Tries common WoW APIs; as a heuristic we return the maximum
-- GetSpellBonusDamage(...) value across schools which captures
-- the player's highest spell-power (shadow for shadow priest).
function A.GetSpellPower()
    local max = 0
    if type(GetSpellBonusDamage) == "function" then
        for i = 1, 7 do
            local ok, v = pcall(GetSpellBonusDamage, i)
            v = (ok and v) and v or 0
            if v > max then max = v end
        end
        return max
    end
    -- Fallbacks could be added here if needed; return 0 when unknown
    return 0
end

-- Return player's haste percent and multiplier.
-- For TBC Anniversary (modern client) we rely on `UnitSpellHaste` only.
-- Caller receives: hastePercent (number), hasteMultiplier (1 + percent/100)
function A.GetHaste()
    if type(UnitSpellHaste) == "function" then
        local ok, v = pcall(UnitSpellHaste, "player")
        v = (ok and v) and v or 0
        return v, (1 + v / 100)
    end
    -- If the API is not present (very old clients), return zero haste.
    return 0, 1
end

-- Find a debuff by **spell name** on a unit cast by the player.
-- Uses the "PLAYER" filter which reliably restricts to your own debuffs.
-- Returns: name, icon, count, debuffType, duration, expirationTime, source, index
function A.FindPlayerDebuff(unit, spellName)
    for i = 1, 40 do
        local name, icon, count, debuffType, duration, expirationTime,
              source = UnitDebuff(unit, i, "PLAYER")
        if not name then break end
        if name == spellName then
            return name, icon, count, debuffType, duration, expirationTime, source or "player", i
        end
    end
    return nil
end

-- Find ANY debuff by spell name on a unit (regardless of caster).
-- Used for tracking debuffs on targets where we want to see all instances.
function A.FindDebuff(unit, spellName)
    for i = 1, 40 do
        local name, icon, count, debuffType, duration, expirationTime,
              source = UnitDebuff(unit, i)
        if not name then break end
        if name == spellName then
            return name, icon, count, debuffType, duration, expirationTime, source, i
        end
    end
    return nil
end

-- Check if player knows a spell (has it in spellbook)
function A.KnowsSpell(spellId)
    return IsSpellKnown(spellId)
end

------------------------------------------------------------------------
-- Detect current content type (for per-zone SWD settings)
------------------------------------------------------------------------
function A.GetContentType()
    local _, instanceType = IsInInstance()
    if instanceType == "raid" then return "raid" end
    if instanceType == "party" then return "dungeon" end
    return "world"
end

-- Return the target's raw HP, max HP, and percent (0-100)
function A.GetTargetHP()
    if not UnitExists("target") then return 0, 0, 0 end
    local hp = UnitHealth("target") or 0
    local maxHp = UnitHealthMax("target") or 0
    local pct = 0
    if maxHp > 0 then pct = (hp / maxHp) * 100 end
    return hp, maxHp, pct
end

------------------------------------------------------------------------
-- Check if player is a priest with Shadowform talent
------------------------------------------------------------------------
function A.IsShadowPriest()
    local _, class = UnitClass("player")
    if class ~= "PRIEST" then return false end
    return A.KnowsSpell(A.SPELLS.SFORM.id)
end

------------------------------------------------------------------------
-- Pixel-perfect backdrop helper
------------------------------------------------------------------------
function A.CreateBackdrop(frame, r, g, b, a, borderR, borderG, borderB, borderA)
    r, g, b, a = r or 0.08, g or 0.08, b or 0.08, a or 0.85
    borderR = borderR or 0
    borderG = borderG or 0
    borderB = borderB or 0
    borderA = borderA or 1

    frame:SetBackdrop({
        bgFile   = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(r, g, b, a)
    frame:SetBackdropBorderColor(borderR, borderG, borderB, borderA)
end

------------------------------------------------------------------------
-- Formatting
------------------------------------------------------------------------
function A.FormatTime(sec)
    if sec >= 60 then
        return string.format("%d:%02d", sec / 60, sec % 60)
    elseif sec >= 10 then
        return string.format("%d", sec)
    else
        return string.format("%.1f", sec)
    end
end

------------------------------------------------------------------------
-- Debug logging (ring buffer — capped at 500 entries)
------------------------------------------------------------------------
A.debugEnabled = false
A.debugLog     = {}
local DEBUG_MAX = 500

function A.DebugLog(category, msg)
    if not A.debugEnabled then return end
    local entry = string.format("[%.2f][%s] %s", GetTime(), category, msg)
    A.debugLog[#A.debugLog + 1] = entry
    if #A.debugLog > DEBUG_MAX then
        table.remove(A.debugLog, 1)
    end
end

------------------------------------------------------------------------
-- Saved-variables defaults
------------------------------------------------------------------------
A.defaults = {
    locked      = false,
    scale       = 1.0,
    debugEnabled = false,
    castBar     = { enabled = true, width = 250, height = 20, tickSound = "click", tickFlash = "green" },
    dotTracker  = { enabled = true, width = 300, height = 40, rowHeight = 40,
                    maxTargets = 8, warnSeconds = 3, blinkSpeed = 4, dotIconSize = 18 },
    rotation    = { enabled = true, iconSize = 40, primaryIconSize = 40,
                    ifInsert = { enabled = true, onlyForBoss = true, before = "MB" } },
    -- Selected consumables to track (item IDs). Use "none" to disable.
    selectedPotionItem = 22832,
    selectedRuneItem   = 20520,
    swdMode     = "always",
    swdWorld    = "always",
    swdDungeon  = "always",
    swdRaid     = "execute",
    -- Safety margin (%) applied to SW:D execute check. 0 = exact, 10 = require 10% extra damage.
    swdSafetyPct = 10,
    sfManaThreshold      = 35,
    suggestPot           = true,
    potManaThreshold     = 70,
    suggestRune          = true,
    runeManaThreshold    = 40,
    -- If true, use mana potion before Shadowfiend (early potting)
    potEarly             = false,
    -- Which potion/rune to track: "auto" = detect in bags, "none" = disabled,
    -- or set to an itemId string (e.g. "22832") to track a specific item.
    potionTrack = "auto",
    runeTrack   = "auto",
}

function A.InitDB()
    if not SPHelperDB then SPHelperDB = {} end
    for k, v in pairs(A.defaults) do
        if SPHelperDB[k] == nil then
            if type(v) == "table" then
                SPHelperDB[k] = {}
                for k2, v2 in pairs(v) do SPHelperDB[k][k2] = v2 end
            else
                SPHelperDB[k] = v
            end
        elseif type(v) == "table" then
            for k2, v2 in pairs(v) do
                if SPHelperDB[k][k2] == nil then
                    SPHelperDB[k][k2] = v2
                end
            end
        end
    end
    A.db = SPHelperDB

    -- Migrate old boolean tickSound/tickFlash to string keys
    if A.db.castBar then
        if A.db.castBar.tickSound == true  then A.db.castBar.tickSound = "click" end
        if A.db.castBar.tickSound == false then A.db.castBar.tickSound = "none"  end
        if A.db.castBar.tickFlash == true  then A.db.castBar.tickFlash = "green" end
        if A.db.castBar.tickFlash == false then A.db.castBar.tickFlash = "none"  end
    end
    -- Migrate old combined consumable setting
    if A.db.suggestConsumables ~= nil and A.db.suggestPot == nil then
        A.db.suggestPot  = A.db.suggestConsumables
        A.db.suggestRune = A.db.suggestConsumables
    end
    if A.db.consumableManaThreshold and not A.db.potManaThreshold then
        A.db.potManaThreshold  = A.db.consumableManaThreshold
        A.db.runeManaThreshold = A.db.consumableManaThreshold
    end

    -- Sync debug toggle from saved vars
    A.debugEnabled = A.db.debugEnabled or false
end

-- Play a tick sound (shared helper used by both the cast bar and tick manager)
function A.PlayTickSound(key)
    local k = key or (A.db and A.db.castBar and A.db.castBar.tickSound) or "click"
    if k == "none" or k == true or not k then return end
    local id = A.GetTickSoundId(k)
    if id then pcall(PlaySound, id, "SFX") end
end

-- Apply a gradient to a texture. Requires a base texture (WHITE8X8) to be
-- set on the texture beforehand so the tinting has content to operate on.
-- Orientation: "VERTICAL"   — min = bottom, max = top
--              "HORIZONTAL" — min = left,   max = right
local function ApplyGradient(tex, orient, r, g, b, a1, a2)
    -- Modern client (TBC Anniversary) uses SetGradientAlpha with nine args.
    -- If it's absent (newer retail-only removal) fall back to SetGradient.
    if not pcall(function()
        tex:SetGradientAlpha(orient, r, g, b, a1, r, g, b, a2)
    end) then
        pcall(function()
            tex:SetGradient(orient, CreateColor(r, g, b, a1), CreateColor(r, g, b, a2))
        end)
    end
end

-- Perform a tick screen-flash with proper gradient edges and smooth fade-out.
function A.DoTickFlash(key)
    local k = key or (A.db and A.db.castBar and A.db.castBar.tickFlash)
    if k == "none" or k == true or not k then return end
    local col = A.GetTickFlashColor(k)
    if not col then return end
    local mode = A.GetTickFlashMode(k)
    local r, g, b = col[1], col[2], col[3]

    -- Build the shared flash frame once.
    if not A._tickFlashFrame then
        local flash = CreateFrame("Frame", "SPHelper_TickFlash_Shared", UIParent)
        flash:SetAllPoints(UIParent)
        flash:SetFrameStrata("FULLSCREEN_DIALOG")
        flash:SetFrameLevel(100)
        flash:EnableMouse(false)
        flash:Hide()

        -- Full-screen solid texture
        local texFull = flash:CreateTexture(nil, "ARTWORK")
        texFull:SetAllPoints(UIParent)
        texFull:Hide()
        flash.texFull = texFull

        -- Top gradient (bleeds ~150px downward from the top edge)
        -- WHITE8X8 base is required so SetGradientAlpha has content to tint.
        local texTop = flash:CreateTexture(nil, "ARTWORK")
        texTop:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        texTop:SetPoint("TOPLEFT",  UIParent, "TOPLEFT",  0, 0)
        texTop:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", 0, 0)
        texTop:SetHeight(150)
        texTop:Hide()
        flash.texTop = texTop

        -- Left-side gradient (bleeds ~120px inward from the left edge)
        local texLeft = flash:CreateTexture(nil, "ARTWORK")
        texLeft:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        texLeft:SetPoint("TOPLEFT",    UIParent, "TOPLEFT",    0, 0)
        texLeft:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
        texLeft:SetWidth(120)
        texLeft:Hide()
        flash.texLeft = texLeft

        -- Right-side gradient (bleeds ~120px inward from the right edge)
        local texRight = flash:CreateTexture(nil, "ARTWORK")
        texRight:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        texRight:SetPoint("TOPRIGHT",    UIParent, "TOPRIGHT",    0, 0)
        texRight:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", 0, 0)
        texRight:SetWidth(120)
        texRight:Hide()
        flash.texRight = texRight

        -- Animate: fade from alpha 1 → 0 at ~10 units/sec (~0.1s total)
        local flashAlpha = 0
        local fading = false
        flash:SetScript("OnUpdate", function(self, elapsed)
            if not fading then return end
            flashAlpha = flashAlpha - elapsed * 10
            if flashAlpha <= 0 then
                flashAlpha = 0
                fading     = false
                texFull:Hide(); texTop:Hide(); texLeft:Hide(); texRight:Hide()
                self:Hide()
                return
            end
            self:SetAlpha(flashAlpha)
        end)

        flash._trigger = function()
            flashAlpha = 1.0
            fading     = true
            flash:SetAlpha(1.0)
            flash:Show()
        end

        A._tickFlashFrame = flash
    end

    local flash = A._tickFlashFrame
    -- Hide all layers before picking the right one
    flash.texFull:Hide(); flash.texTop:Hide()
    flash.texLeft:Hide(); flash.texRight:Hide()

    if mode == "full" then
        -- Solid semi-transparent overlay covering the entire screen
        flash.texFull:SetColorTexture(r, g, b, 0.45)
        flash.texFull:Show()
    elseif mode == "top" then
        -- Gradient: opaque at the top edge, fading to transparent downward
        -- SetGradientAlpha VERTICAL: min = bottom (transparent), max = top (opaque)
        ApplyGradient(flash.texTop, "VERTICAL", r, g, b, 0, 1.0)
        flash.texTop:Show()
    elseif mode == "sides" then
        -- Left strip: opaque on the left edge, fading right (HORIZONTAL min=left)
        ApplyGradient(flash.texLeft,  "HORIZONTAL", r, g, b, 1.0, 0)
        -- Right strip: opaque on the right edge, fading left (HORIZONTAL max=right)
        ApplyGradient(flash.texRight, "HORIZONTAL", r, g, b, 0, 1.0)
        flash.texLeft:Show(); flash.texRight:Show()
    end

    flash._trigger()
end

-- Preview hooks exposed for Config.lua dropdowns
A.PreviewTickFlash = function(key) A.DoTickFlash(key) end
A.PreviewTickSound = function(key) A.PlayTickSound(key) end

-- TickManager: fires shared tick feedback on every MF SPELL_PERIODIC_DAMAGE
-- event. When the cast bar UI is enabled and currently showing, the cast bar
-- handles tick feedback itself, so shared feedback is suppressed to avoid
-- double-firing.
function A.InitTickManager()
    if A._tickManagerInited then return end
    A._tickManagerInited = true

    local f = CreateFrame("Frame")
    f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    f:SetScript("OnEvent", function(self)
        local _, subEvent, _, sourceGUID, _, _, _, _, _, _, _, _, cleuSpellName = CombatLogGetCurrentEventInfo()
        if sourceGUID ~= UnitGUID("player") then return end
        if subEvent ~= "SPELL_PERIODIC_DAMAGE" then return end
        if cleuSpellName ~= (A.SPELLS and A.SPELLS.MF and A.SPELLS.MF.name) then return end
        -- Suppress if the cast bar UI is currently visible (it handles ticks itself)
        if A.castBarFrame and A.castBarFrame:IsShown() then return end
        pcall(A.PlayTickSound)
        pcall(A.DoTickFlash)
    end)
end

-- Error forwarding: capture Lua errors and forward relevant SPHelper errors to chat+print.
do
    local prevHandler = geterrorhandler()
    local lastSent = 0
    local throttleSec = 5
    seterrorhandler(function(err)
        -- Call previous handler first (safe)
        pcall(prevHandler, err)

        if not err then return end
        local s = tostring(err)
        -- Only forward errors that reference this addon's path/name
        if not (s:find("Interface\\AddOns\\SPHelper") or s:find("SPHelper")) then return end

        -- Throttle repeated sends
        local now = GetTime()
        if (now - lastSent) < throttleSec then return end
        lastSent = now

        local prefix = "[SPHelper Error] "
        local out = prefix .. s
        -- Truncate to safe length for chat
        if #out > 200 then out = out:sub(1, 197) .. "..." end

        -- Print locally
        pcall(print, out)

        -- Try to send to the previously-joined diagnostics channel; attempt
        -- to join if we haven't yet. If sending fails, store the error in
        -- saved variables so the user can inspect later.
        local sentToChannel = false
        pcall(function()
            if not A._sphelperChannelID then
                if A.EnsureSphelperChannel then pcall(A.EnsureSphelperChannel) end
            end
            if A._sphelperChannelID and A._sphelperChannelID > 0 then
                pcall(function() SendChatMessage(out, "CHANNEL", nil, A._sphelperChannelID) end)
                sentToChannel = true
            end
        end)

        -- Persist the error locally if it wasn't sent to channel
        if not sentToChannel then
            pcall(function()
                if not SPHelperDB then SPHelperDB = {} end
                SPHelperDB.recentErrors = SPHelperDB.recentErrors or {}
                local entry = { time = GetTime(), msg = s, stack = (debugstack and debugstack()) or "" }
                table.insert(SPHelperDB.recentErrors, 1, entry)
                -- keep it bounded
                while #SPHelperDB.recentErrors > 80 do table.remove(SPHelperDB.recentErrors) end
            end)
        end
    end)
end

------------------------------------------------------------------------
-- Visibility management (show/hide all frames based on spec)
------------------------------------------------------------------------
function A.SetAllVisible(visible)
    A._visible = visible
    if visible then
        -- CastBar is NOT shown here; it shows itself via ShowBar() on cast start
        -- Show DoT anchor only when in combat or when preview is active
        if A.dotAnchor then
            if UnitAffectingCombat("player") or A.dotTrackerPreviewActive then
                A.dotAnchor:Show()
            else
                A.dotAnchor:Hide()
            end
        end
    else
        if A.castBarFrame then A.castBarFrame:Hide() end
        if A.dotAnchor   then A.dotAnchor:Hide()   end
        if A.rotFrame    then A.rotFrame:Hide()    end
    end
end

-- Print recent stored errors to chat (call via: /script SPHelper.DumpRecentErrors())
function A.DumpRecentErrors()
    if not SPHelperDB or not SPHelperDB.recentErrors or #SPHelperDB.recentErrors == 0 then
        print("SPHelper: no recent errors recorded.")
        return
    end
    print("SPHelper: recent errors (most recent first):")
    for i, e in ipairs(SPHelperDB.recentErrors) do
        local t = e.time or 0
        local msg = e.msg or ""
        print(string.format("[%d] %s", i, msg))
        if e.stack and e.stack ~= "" then
            print(e.stack)
        end
    end
end

------------------------------------------------------------------------
-- Addon load event
------------------------------------------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, addon)
    if addon ~= "SPHelper" then return end
    A.InitDB()

    -- Class gate: only load for Priests
    local _, class = UnitClass("player")
    if class ~= "PRIEST" then
        self:UnregisterEvent("ADDON_LOADED")
        return
    end

    -- Fire module inits (always init so frames exist, visibility handled separately)
    if A.InitCastBar    then A:InitCastBar()    end
    if A.InitDotTracker then A:InitDotTracker() end
    if A.InitRotation   then A:InitRotation()   end
    if A.InitConfig     then A:InitConfig()     end
    if A.InitTickManager then A.InitTickManager() end

    -- Attempt to join a diagnostics channel for error forwarding
    A._sphelperChannelID = nil
    A._sphelperJoinAttempt = 0
    A.EnsureSphelperChannel = function()
        local now = GetTime()
        if A._sphelperChannelID and A._sphelperChannelID > 0 then return end
        if (now - (A._sphelperJoinAttempt or 0)) < 10 then return end
        A._sphelperJoinAttempt = now
        local chanName = "sphelper"
        local ok, cname, chanID = pcall(JoinChannelByName, chanName)
        if ok and chanID and chanID > 0 then
            A._sphelperChannelID = chanID
        end
    end
    -- Try immediately once
    pcall(A.EnsureSphelperChannel)

    -- Check shadow spec and set visibility (delay for talent data)
    C_Timer.After(1, function()
        local isShadow = A.IsShadowPriest()
        A.SetAllVisible(isShadow)
        if not isShadow then
            print("|cff8882d5SPHelper|r: Waiting for Shadowform talent (hidden).")
        else
            print("|cff8882d5SPHelper|r loaded.  /sph to configure.")
        end
    end)

    -- Watch for talent/spec changes (dual spec support)
    local specWatcher = CreateFrame("Frame")
    specWatcher:RegisterEvent("PLAYER_TALENT_UPDATE")
    specWatcher:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
    specWatcher:RegisterEvent("SPELLS_CHANGED")
    specWatcher:SetScript("OnEvent", function()
        C_Timer.After(0.5, function()
            local wasShadow = A._visible
            local isShadow = A.IsShadowPriest()
            A.SetAllVisible(isShadow)
            if isShadow and not wasShadow then
                print("|cff8882d5SPHelper|r: Shadow spec detected — enabled.")
            elseif not isShadow and wasShadow then
                print("|cff8882d5SPHelper|r: Non-shadow spec — hidden.")
            end
        end)
    end)

    self:UnregisterEvent("ADDON_LOADED")
end)
