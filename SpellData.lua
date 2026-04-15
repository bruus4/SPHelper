------------------------------------------------------------------------
-- SPHelper  –  SpellData.lua
-- Enumerates player spellbook, provides damage/duration estimates,
-- and detects talent/set bonus modifiers for Shadow Priest spells.
------------------------------------------------------------------------
local A = SPHelper

A.SpellData = {}
local SD = A.SpellData

local function ResolveClassFilter(classFilter)
    if classFilter == false or classFilter == "*" then
        return nil
    end
    if type(classFilter) == "string" and classFilter ~= "" then
        return classFilter
    end
    local _, playerClass = UnitClass("player")
    return playerClass
end

local function MakeClassTaggedName(def)
    local classLabel = def and def.class and ("[" .. def.class .. "] ") or ""
    return classLabel .. (def and def.name or "Unknown")
end

------------------------------------------------------------------------
-- Shadow Priest spell coefficients (TBC values)
-- base = base damage (avg of min/max for max rank)
-- coeff = spell power coefficient
-- dur = base DoT duration (seconds, 0 for direct)
-- ticks = number of DoT ticks (0 for direct)
-- school = damage school index (6 = shadow)
------------------------------------------------------------------------
local BASE_SP_COEFFICIENTS = {
    [34914] = { name = "Vampiric Touch",    base = 650,  coeff = 1.0,   dur = 15, ticks = 5,  school = 6, castTime = 1.5 },
    [589]   = { name = "Shadow Word: Pain", base = 1236, coeff = 1.10,  dur = 18, ticks = 6,  school = 6, castTime = 0,   instant = true },
    [8092]  = { name = "Mind Blast",        base = 731,  coeff = 0.429, dur = 0,  ticks = 0,  school = 6, castTime = 1.5 },
    [15407] = { name = "Mind Flay",         base = 528,  coeff = 0.57,  dur = 3,  ticks = 3,  school = 6, castTime = 3,   channel = true },
    [32379] = { name = "Shadow Word: Death",base = 572,  coeff = 0.429, dur = 0,  ticks = 0,  school = 6, castTime = 0,   instant = true },
    [2944]  = { name = "Devouring Plague",  base = 1216, coeff = 0.80,  dur = 24, ticks = 8,  school = 6, castTime = 0,   instant = true },
}

SD.SP_COEFFICIENTS = {}

local function GetCatalogSpell(spellRef)
    return A.GetSpellDefinition and A.GetSpellDefinition(spellRef) or nil
end

function SD:RebuildCoefficientIndex()
    local coeffs = {}
    for spellId, data in pairs(BASE_SP_COEFFICIENTS) do
        coeffs[spellId] = data
    end

    if A.SPELLS then
        for _, spell in pairs(A.SPELLS) do
            local baseId = spell.baseId or spell.id
            local data = baseId and BASE_SP_COEFFICIENTS[baseId]
            if data and spell.id and spell.id ~= baseId then
                coeffs[spell.id] = data
            end
        end
    end

    self.SP_COEFFICIENTS = coeffs
end

local function BuildStaticTooltipText(def)
    if not def then return nil end

    local parts = {}
    if def.castType == "channel" then
        parts[#parts + 1] = string.format("Channel %.1fs", def.castTime or 0)
    elseif def.castType == "cast" then
        parts[#parts + 1] = string.format("Cast %.1fs", def.castTime or 0)
    elseif def.castType == "instant" then
        parts[#parts + 1] = "Instant"
    end

    if def.duration and def.duration > 0 then
        if def.ticks and def.ticks > 0 then
            parts[#parts + 1] = string.format("%.0fs / %d ticks", def.duration, def.ticks)
        else
            parts[#parts + 1] = string.format("Duration %.0fs", def.duration)
        end
    end

    if def.coefficients then
        if def.coefficients.spellPower then
            parts[#parts + 1] = string.format("SP coeff %.3f", def.coefficients.spellPower)
        end
        if def.coefficients.attackPower then
            parts[#parts + 1] = string.format("AP coeff %.3f", def.coefficients.attackPower)
        end
    end

    if def.comboScaling and def.comboScaling.pointsPerComboPoint then
        parts[#parts + 1] = string.format("+%d base per combo point", def.comboScaling.pointsPerComboPoint)
    end

    if def.damage then
        if def.damage.bonusVsBleeding then
            parts[#parts + 1] = string.format("+%d vs bleeding targets", def.damage.bonusVsBleeding)
        end
        if def.damage.bleedBonusFlat then
            parts[#parts + 1] = string.format("+%d bleed bonus", def.damage.bleedBonusFlat)
        end
        if def.damage.bonusFlat then
            parts[#parts + 1] = string.format("+%d flat bonus", def.damage.bonusFlat)
        end
        if def.damage.triggerSpellId then
            parts[#parts + 1] = string.format("Trigger spell %d", def.damage.triggerSpellId)
        end
    end

    if def.flags then
        if def.flags.requiresBehind then parts[#parts + 1] = "Behind target" end
        if def.flags.requiresStealth then parts[#parts + 1] = "Stealth opener" end
        if def.flags.requiresCatForm then parts[#parts + 1] = "Cat Form" end
        if def.flags.requiresBearForm then parts[#parts + 1] = "Bear Form" end
        if def.flags.finisher then parts[#parts + 1] = "Finisher" end
        if def.flags.builder then parts[#parts + 1] = "Builder" end
        if def.flags.bleed then parts[#parts + 1] = "Bleed" end
        if def.flags.dot then parts[#parts + 1] = "DoT" end
    end

    if #parts == 0 then return nil end
    return table.concat(parts, " | ")
end

------------------------------------------------------------------------
-- Talent modifiers for Shadow Priest (TBC)
-- tab, index = talent tree position
-- Each modifier has: talentTab, talentIndex, maxRank, perRank, affects
------------------------------------------------------------------------
SD.TALENT_MODIFIERS = {
    -- Shadow Weaving: +10% shadow damage (stacking debuff, simplified as personal)
    { name = "Shadow Weaving", tab = 3, index = 15, maxRank = 5, perRank = 0.02,   affects = "shadow_damage" },
    -- Darkness: +10% shadow damage
    { name = "Darkness",       tab = 3, index = 16, maxRank = 5, perRank = 0.02,   affects = "shadow_damage" },
    -- Shadow Focus: -10% miss chance (treat as +hit)
    { name = "Shadow Focus",   tab = 3, index = 2,  maxRank = 5, perRank = 0.02,   affects = "shadow_hit" },
    -- Improved SWP: +6 sec duration
    { name = "Improved SWP",   tab = 3, index = 4,  maxRank = 2, perRank = 3,      affects = "swp_duration" },
    -- Improved Mind Blast: -0.5s cooldown per rank
    { name = "Improved MB",    tab = 3, index = 12, maxRank = 5, perRank = -0.5,    affects = "mb_cooldown" },
    -- Shadow Power: +15% crit bonus damage on MB/MF/SWD
    { name = "Shadow Power",   tab = 3, index = 20, maxRank = 5, perRank = 0.03,   affects = "shadow_crit_bonus" },
    -- Misery: +5% spell damage taken by target
    { name = "Misery",         tab = 3, index = 21, maxRank = 5, perRank = 0.01,   affects = "target_spell_damage" },
}

------------------------------------------------------------------------
-- Known TBC set bonuses for Shadow Priest
------------------------------------------------------------------------
SD.SET_BONUSES = {
    -- T4 (Incarnate)
    { setName = "Incarnate Raiment",  pieces = { 29049, 29058, 29056, 29057, 29050 },
      bonuses = {
          [2] = { desc = "VT +2 ticks", affects = "vt_ticks",      value = 2 },
      }},
    -- T5 (Avatar)
    { setName = "Avatar Raiment",     pieces = { 30153, 30154, 30151, 30152, 30150 },
      bonuses = {
          [4] = { desc = "MB +10% damage", affects = "mb_damage",    value = 0.10 },
      }},
    -- T6 (Absolution)
    { setName = "Absolution Regalia", pieces = { 31064, 31068, 31065, 31067, 31066 },
      bonuses = {
          [4] = { desc = "SWP +3 sec", affects = "swp_duration",  value = 3 },
      }},
}

------------------------------------------------------------------------
-- Get the player's current rank of a talent
------------------------------------------------------------------------
function SD:GetTalentRank(tab, index)
    local ok, name, iconTexture, tier, column, rank, maxRank = pcall(GetTalentInfo, tab, index)
    if ok and rank then
        return rank, maxRank or 0
    end
    return 0, 0
end

------------------------------------------------------------------------
-- Calculate total talent modifier for a given affect type
------------------------------------------------------------------------
function SD:GetTalentModifier(affectType)
    local total = 0
    for _, tm in ipairs(self.TALENT_MODIFIERS) do
        if tm.affects == affectType then
            local rank = self:GetTalentRank(tm.tab, tm.index)
            total = total + rank * tm.perRank
        end
    end
    return total
end

------------------------------------------------------------------------
-- Count equipped set pieces for known sets
------------------------------------------------------------------------
function SD:GetSetBonusCount(setDef)
    local count = 0
    local equipped = {}
    for slot = 1, 19 do
        local link = GetInventoryItemLink("player", slot)
        if link then
            local itemId = tonumber(link:match("item:(%d+)"))
            if itemId then equipped[itemId] = true end
        end
    end
    for _, pieceId in ipairs(setDef.pieces) do
        if equipped[pieceId] then count = count + 1 end
    end
    return count
end

------------------------------------------------------------------------
-- Get all active set bonus effects
------------------------------------------------------------------------
function SD:GetActiveSetBonuses()
    local active = {}
    for _, setDef in ipairs(self.SET_BONUSES) do
        local count = self:GetSetBonusCount(setDef)
        for threshold, bonus in pairs(setDef.bonuses) do
            if type(threshold) == "number" and count >= threshold then
                active[#active + 1] = { set = setDef.setName, pieces = count, bonus = bonus }
            end
        end
    end
    return active
end

------------------------------------------------------------------------
-- Estimate damage for a spell (single cast/full DoT)
------------------------------------------------------------------------
function SD:EstimateDamage(spellId)
    local def = GetCatalogSpell(spellId)
    local baseSpellId = def and def.baseId or spellId
    local data = self.SP_COEFFICIENTS[spellId] or self.SP_COEFFICIENTS[baseSpellId]
    if not data then return nil end

    local sp = A.GetSpellPower and A.GetSpellPower() or 0

    -- Base multiplier from talents
    local shadowMod = 1 + self:GetTalentModifier("shadow_damage")
    local miseryMod = 1 + self:GetTalentModifier("target_spell_damage")

    -- Spell-specific set bonuses
    local mbBonus = 0
    for _, ab in ipairs(self:GetActiveSetBonuses()) do
        if ab.bonus.affects == "mb_damage" and baseSpellId == 8092 then
            mbBonus = mbBonus + ab.bonus.value
        end
    end

    local totalDamage = (data.base + sp * data.coeff) * shadowMod * miseryMod * (1 + mbBonus)

    return {
        damage   = math.floor(totalDamage),
        duration = self:GetEffectiveDuration(baseSpellId),
        ticks    = data.ticks,
        perTick  = data.ticks > 0 and math.floor(totalDamage / data.ticks) or 0,
        castTime = data.castTime,
        channel  = data.channel,
        instant  = data.instant,
    }
end

------------------------------------------------------------------------
-- Get effective duration accounting for talents and set bonuses
------------------------------------------------------------------------
function SD:GetEffectiveDuration(spellId)
    local def = GetCatalogSpell(spellId)
    local baseSpellId = def and def.baseId or spellId
    local data = self.SP_COEFFICIENTS[spellId] or self.SP_COEFFICIENTS[baseSpellId]
    if not data then
        return (def and def.duration) or 0
    end

    local dur = data.dur
    -- SWP duration extensions
    if baseSpellId == 589 then
        dur = dur + self:GetTalentModifier("swp_duration")
        for _, ab in ipairs(self:GetActiveSetBonuses()) do
            if ab.bonus.affects == "swp_duration" then dur = dur + ab.bonus.value end
        end
    end
    -- VT tick extensions (T4 2pc adds ticks = more duration at same tick interval)
    if baseSpellId == 34914 then
        local extraTicks = 0
        for _, ab in ipairs(self:GetActiveSetBonuses()) do
            if ab.bonus.affects == "vt_ticks" then extraTicks = extraTicks + ab.bonus.value end
        end
        if extraTicks > 0 and data.ticks > 0 then
            local interval = data.dur / data.ticks
            dur = dur + extraTicks * interval
        end
    end
    return dur
end

------------------------------------------------------------------------
-- Enumerate all player spells from the spellbook
-- Returns a sorted list of unique supported abilities for editor use.
------------------------------------------------------------------------
function SD:GetPlayerSpells(classFilter)
    local spells = {}
    local resolvedClass = ResolveClassFilter(classFilter)
    if A.SpellDatabase and A.SpellDatabase.sortedKeys and A.SpellDatabase.catalog then
        for _, key in ipairs(A.SpellDatabase.sortedKeys) do
            if key ~= "CLEARCASTING" then
                local def = A.SpellDatabase.catalog[key]
                if not resolvedClass or def.class == resolvedClass then
                    local spell = A.SPELLS and A.SPELLS[key] or nil
                    local displayName = MakeClassTaggedName(def)
                    local resolvedName = (spell and spell.name) or def.name
                    spells[#spells + 1] = {
                        key          = key,
                        id           = (spell and spell.id) or def.baseId,
                        baseId       = def.baseId,
                        name         = displayName,
                        resolvedName = resolvedName,
                        rank         = (spell and spell.rank) or "",
                        icon         = (spell and spell.icon) or (A.GetSpellIconCached and A.GetSpellIconCached(def.baseId)),
                        known        = spell and spell.known or false,
                        castTime     = def.castTime or 0,
                        class        = def.class,
                        spec         = def.spec,
                    }
                end
            end
        end
        return spells
    end

    if A.SPELLS then
        for key, spell in pairs(A.SPELLS) do
            if key ~= "CLEARCASTING" and (not resolvedClass or spell.class == resolvedClass) then
                spells[#spells + 1] = {
                    key          = key,
                    id           = spell.id,
                    baseId       = spell.baseId or spell.id,
                    name         = MakeClassTaggedName(spell),
                    resolvedName = spell.name,
                    rank         = spell.rank or "",
                    icon         = spell.icon or (A.GetSpellIconCached and A.GetSpellIconCached(spell.id or spell.baseId)),
                    known        = spell.known or false,
                    castTime     = 0,
                    class        = spell.class,
                    spec         = spell.spec,
                }
            end
        end
    end

    table.sort(spells, function(a, b)
        if a.name == b.name then
            return a.key < b.key
        end
        return a.name < b.name
    end)
    return spells
end

------------------------------------------------------------------------
-- Get a pre-built list of keys suitable for the rotation editor
-- matching the canonical spell database, one row per supported ability.
------------------------------------------------------------------------
function SD:GetSpellKeysForEditor(classFilter)
    return self:GetPlayerSpells(classFilter)
end

------------------------------------------------------------------------
-- Quick summary string for a spell (for tooltips in rotation editor)
------------------------------------------------------------------------
function SD:GetSpellTooltipText(spellId)
    local est = self:EstimateDamage(spellId)
    if not est then
        return BuildStaticTooltipText(GetCatalogSpell(spellId))
    end

    local parts = {}
    if est.channel then
        parts[#parts + 1] = string.format("Channel %.1fs", est.castTime)
    elseif est.instant then
        parts[#parts + 1] = "Instant"
    else
        parts[#parts + 1] = string.format("Cast %.1fs", est.castTime)
    end
    if est.ticks > 0 then
        parts[#parts + 1] = string.format("%d dmg over %.0fs (%d/tick)", est.damage, est.duration, est.perTick)
    else
        parts[#parts + 1] = string.format("%d dmg", est.damage)
    end
    return table.concat(parts, " | ")
end

SD:RebuildCoefficientIndex()

------------------------------------------------------------------------
-- Register as SpecManager helper
------------------------------------------------------------------------
if A.SpecManager then
    A.SpecManager:RegisterHelper("SpellData", {
        _initialized = false,
        OnSpecActivate = function(self, spec)
            self._initialized = true
        end,
        OnSpecDeactivate = function(self, spec)
            self._initialized = false
        end,
    }, {
        exports = { "GetPlayerSpells", "GetSpellKeysForEditor", "EstimateDamage", "GetSpellTooltipText", "GetEffectiveDuration", "GetActiveSetBonuses" },
        depends = {},
    })
end
