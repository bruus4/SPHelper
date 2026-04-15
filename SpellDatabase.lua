------------------------------------------------------------------------
-- SPHelper  –  SpellDatabase.lua
-- Static spell catalog plus NAG-style spellbook resolution.
-- The catalog stores stable low-rank/base spell IDs and useful non-API
-- metadata; runtime entries resolve to the player's effective known rank.
------------------------------------------------------------------------
local A = SPHelper

A.SpellDatabase = A.SpellDatabase or {}
local DB = A.SpellDatabase

local ipairs = ipairs
local pairs = pairs
local sort = table.sort
local type = type
local tonumber = tonumber

local function RawIsSpellKnown(spellId)
    if type(spellId) ~= "number" then return false end
    if IsSpellKnown and IsSpellKnown(spellId) then
        return true
    end
    if type(IsPlayerSpell) == "function" then
        return IsPlayerSpell(spellId) and true or false
    end
    return false
end

local function GetRankNumber(rankText)
    if type(rankText) ~= "string" or rankText == "" then
        return nil
    end
    local numberText = rankText:match("(%d+)")
    return numberText and tonumber(numberText) or nil
end

DB.catalog = {
    VT = {
        class = "PRIEST",
        spec = "SHADOW",
        name = "Vampiric Touch",
        baseId = 34914,
        school = "shadow",
        schoolMask = 6,
        castType = "cast",
        castTime = 1.5,
        duration = 15,
        ticks = 5,
        tickInterval = 3,
        range = 30,
        flags = { offensive = true, dot = true, magical = true },
        coefficients = { spellPower = 1.0 },
        damage = { estimateBase = 650, perTickBase = 130 },
    },
    SWP = {
        class = "PRIEST",
        spec = "SHADOW",
        name = "Shadow Word: Pain",
        baseId = 589,
        school = "shadow",
        schoolMask = 6,
        castType = "instant",
        duration = 18,
        ticks = 6,
        tickInterval = 3,
        range = 30,
        flags = { offensive = true, dot = true, magical = true },
        coefficients = { spellPower = 1.10 },
        damage = { estimateBase = 1236, perTickBase = 206 },
    },
    MB = {
        class = "PRIEST",
        spec = "SHADOW",
        name = "Mind Blast",
        baseId = 8092,
        school = "shadow",
        schoolMask = 6,
        castType = "cast",
        castTime = 1.5,
        range = 30,
        flags = { offensive = true, direct = true, magical = true },
        coefficients = { spellPower = 0.429 },
        damage = { estimateBase = 731 },
    },
    MF = {
        class = "PRIEST",
        spec = "SHADOW",
        name = "Mind Flay",
        baseId = 15407,
        school = "shadow",
        schoolMask = 6,
        castType = "channel",
        castTime = 3.0,
        duration = 3,
        ticks = 3,
        tickInterval = 1,
        range = 20,
        flags = { offensive = true, channel = true, magical = true },
        coefficients = { spellPower = 0.57 },
        damage = { estimateBase = 528, perTickBase = 176 },
    },
    SWD = {
        class = "PRIEST",
        spec = "SHADOW",
        name = "Shadow Word: Death",
        baseId = 32379,
        school = "shadow",
        schoolMask = 6,
        castType = "instant",
        range = 30,
        flags = { offensive = true, direct = true, magical = true },
        coefficients = { spellPower = 0.429 },
        damage = { estimateBase = 572 },
    },
    DP = {
        class = "PRIEST",
        spec = "SHADOW",
        name = "Devouring Plague",
        baseId = 2944,
        school = "shadow",
        schoolMask = 6,
        castType = "instant",
        duration = 24,
        ticks = 8,
        tickInterval = 3,
        range = 30,
        flags = { offensive = true, dot = true, magical = true },
        coefficients = { spellPower = 0.80 },
        damage = { estimateBase = 1216, perTickBase = 152 },
    },
    SF = {
        class = "PRIEST",
        spec = "SHADOW",
        name = "Shadowfiend",
        baseId = 34433,
        school = "shadow",
        schoolMask = 6,
        castType = "instant",
        flags = { cooldown = true, summon = true, offensive = true },
    },
    VE = {
        class = "PRIEST",
        spec = "SHADOW",
        name = "Vampiric Embrace",
        baseId = 15286,
        school = "shadow",
        schoolMask = 6,
        castType = "instant",
        flags = { buff = true, magical = true },
    },
    SFORM = {
        class = "PRIEST",
        spec = "SHADOW",
        name = "Shadowform",
        baseId = 15473,
        school = "shadow",
        schoolMask = 6,
        castType = "instant",
        duration = -1,
        flags = { form = true, buff = true },
    },
    IF = {
        class = "PRIEST",
        spec = "SHADOW",
        name = "Inner Focus",
        baseId = 14751,
        school = "holy",
        castType = "instant",
        flags = { cooldown = true, buff = true },
    },
    MS = {
        class = "PRIEST",
        spec = "SHADOW",
        name = "Mind Soothe",
        baseId = 453,
        school = "holy",
        castType = "instant",
        range = 20,
        flags = { utility = true, debuff = true },
    },
    SU = {
        class = "PRIEST",
        spec = "SHADOW",
        name = "Shackle Undead",
        baseId = 9484,
        school = "holy",
        castType = "cast",
        castTime = 1.5,
        duration = 50,
        range = 30,
        flags = { control = true, magical = true },
    },
    SHRED = {
        class = "DRUID",
        spec = "FERAL",
        name = "Shred",
        baseId = 5221,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        flags = { offensive = true, builder = true, requiresBehind = true, requiresCatForm = true },
        coefficients = { attackPower = 1.0 },
        damage = { bonusVsBleeding = 224 },
    },
    MANGLE_CAT = {
        class = "DRUID",
        spec = "FERAL",
        name = "Mangle (Cat)",
        baseId = 33876,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        duration = 12,
        flags = { offensive = true, builder = true, debuff = true, requiresCatForm = true },
        coefficients = { attackPower = 1.0 },
        damage = { bleedBonusFlat = 159 },
    },
    RIP = {
        class = "DRUID",
        spec = "FERAL",
        name = "Rip",
        baseId = 1079,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        duration = 12,
        ticks = 6,
        tickInterval = 2,
        flags = { offensive = true, bleed = true, finisher = true, requiresCatForm = true },
        comboScaling = { pointsPerComboPoint = 4 },
    },
    FAERIE_FIRE = {
        class = "DRUID",
        spec = "FERAL",
        name = "Faerie Fire (Feral)",
        baseId = 16857,
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        duration = 40,
        flags = { offensive = true, debuff = true, armorReduction = true, requiresForm = true },
    },
    FEROCIOUS_BITE = {
        class = "DRUID",
        spec = "FERAL",
        name = "Ferocious Bite",
        baseId = 22568,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        flags = { offensive = true, finisher = true, requiresCatForm = true, consumesExtraEnergy = true },
        coefficients = { attackPower = 1.0 },
        comboScaling = { pointsPerComboPoint = 36 },
    },
    RAKE = {
        class = "DRUID",
        spec = "FERAL",
        name = "Rake",
        baseId = 1822,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        duration = 9,
        ticks = 3,
        tickInterval = 3,
        flags = { offensive = true, bleed = true, builder = true, requiresCatForm = true },
    },
    TIGERS_FURY = {
        class = "DRUID",
        spec = "FERAL",
        name = "Tiger's Fury",
        baseId = 5217,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        duration = 6,
        flags = { buff = true, requiresCatForm = true },
    },
    CLEARCASTING = {
        class = "DRUID",
        spec = "FERAL",
        name = "Clearcasting",
        baseId = 16870,
        school = "nature",
        schoolMask = 8,
        castType = "passive",
        flags = { buff = true, proc = true },
    },
    CAT_FORM = {
        class = "DRUID",
        spec = "FERAL",
        name = "Cat Form",
        baseId = 768,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        duration = -1,
        flags = { form = true, stance = true },
    },
    BEAR_FORM = {
        class = "DRUID",
        spec = "FERAL",
        name = "Bear Form",
        baseId = 5487,
        resolveIds = { 9634, 5487 },
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        duration = -1,
        flags = { form = true, stance = true },
    },
    DIRE_BEAR_FORM = {
        class = "DRUID",
        spec = "FERAL",
        name = "Dire Bear Form",
        baseId = 9634,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        duration = -1,
        flags = { form = true, stance = true },
    },
    MANGLE_BEAR = {
        class = "DRUID",
        spec = "FERAL",
        name = "Mangle (Bear)",
        baseId = 33987,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        duration = 12,
        flags = { offensive = true, builder = true, debuff = true, requiresBearForm = true },
    },
    LACERATE = {
        class = "DRUID",
        spec = "FERAL",
        name = "Lacerate",
        baseId = 33745,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        duration = 15,
        ticks = 5,
        tickInterval = 3,
        flags = { offensive = true, bleed = true, builder = true, requiresBearForm = true },
    },
    SWIPE_BEAR = {
        class = "DRUID",
        spec = "FERAL",
        name = "Swipe",
        baseId = 26997,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        flags = { offensive = true, builder = true, requiresBearForm = true },
    },
    MAUL = {
        class = "DRUID",
        spec = "FERAL",
        name = "Maul",
        baseId = 26996,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        flags = { offensive = true, builder = true, requiresBearForm = true },
    },
    DEMORALIZING_ROAR = {
        class = "DRUID",
        spec = "FERAL",
        name = "Demoralizing Roar",
        baseId = 26998,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        duration = 30,
        flags = { debuff = true, utility = true, requiresBearForm = true },
    },
    FRENZIED_REGENERATION = {
        class = "DRUID",
        spec = "FERAL",
        name = "Frenzied Regeneration",
        baseId = 26999,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        duration = 10,
        flags = { buff = true, cooldown = true, defensive = true, requiresBearForm = true },
    },
    BASH = {
        class = "DRUID",
        spec = "FERAL",
        name = "Bash",
        baseId = 8983,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        duration = 4,
        flags = { offensive = true, control = true, cooldown = true, requiresBearForm = true },
    },
    INNERVATE = {
        class = "DRUID",
        spec = "FERAL",
        name = "Innervate",
        baseId = 29166,
        school = "nature",
        schoolMask = 8,
        castType = "instant",
        duration = 20,
        flags = { buff = true, cooldown = true, utility = true },
    },
    PROWL = {
        class = "DRUID",
        spec = "FERAL",
        name = "Prowl",
        baseId = 5215,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        duration = -1,
        flags = { stealth = true, buff = true, requiresCatForm = true },
    },
    POUNCE = {
        class = "DRUID",
        spec = "FERAL",
        name = "Pounce",
        baseId = 9005,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        duration = 3,
        flags = { offensive = true, control = true, requiresStealth = true, requiresCatForm = true },
        damage = { triggerSpellId = 9007 },
    },
    RAVAGE = {
        class = "DRUID",
        spec = "FERAL",
        name = "Ravage",
        baseId = 6785,
        school = "physical",
        schoolMask = 1,
        castType = "instant",
        flags = { offensive = true, builder = true, requiresStealth = true, requiresBehind = true, requiresCatForm = true },
        coefficients = { attackPower = 1.0 },
        damage = { bonusFlat = 384 },
    },
}

DB.byBaseId = {}
DB.byName = {}
DB.sortedKeys = {}
for key, def in pairs(DB.catalog) do
    def.key = key
    DB.byBaseId[def.baseId] = def
    DB.byName[def.name] = def
    local localizedName = A.GetSpellInfoCached and A.GetSpellInfoCached(def.baseId)
    if localizedName then
        DB.byName[localizedName] = def
    end
    DB.sortedKeys[#DB.sortedKeys + 1] = key
end
sort(DB.sortedKeys, function(leftKey, rightKey)
    local left = DB.catalog[leftKey]
    local right = DB.catalog[rightKey]
    if left.name == right.name then
        return left.key < right.key
    end
    return left.name < right.name
end)

DB.spellbook = DB.spellbook or {
    byId = {},
    byName = {},
    dirty = true,
    scannedAt = 0,
}

local function SetSpellbookEntry(spellId)
    local name, rank, icon = A.GetSpellInfoCached(spellId)
    if not name then return end

    local entry = {
        id = spellId,
        name = name,
        rank = rank or "",
        rankNumber = GetRankNumber(rank) or -1,
        icon = icon,
    }

    DB.spellbook.byId[spellId] = entry

    local current = DB.spellbook.byName[name]
    if not current
        or entry.rankNumber > current.rankNumber
        or (entry.rankNumber == current.rankNumber and entry.id > current.id)
    then
        DB.spellbook.byName[name] = entry
    end
end

local function ScanPlayerSpellbook(force)
    if not force and not DB.spellbook.dirty and DB.spellbook.scannedAt > 0 then
        return
    end

    DB.spellbook.byId = {}
    DB.spellbook.byName = {}

    local numTabs = GetNumSpellTabs and GetNumSpellTabs() or 0
    for tabIndex = 1, numTabs do
        local _, _, offset, numEntries = GetSpellTabInfo(tabIndex)
        for index = 1, (numEntries or 0) do
            local spellBookIndex = (offset or 0) + index
            local spellType, spellId = GetSpellBookItemInfo(spellBookIndex, BOOKTYPE_SPELL)
            if spellType == "SPELL" and spellId then
                SetSpellbookEntry(spellId)
            end
        end
    end

    DB.spellbook.dirty = false
    DB.spellbook.scannedAt = GetTime and GetTime() or 0
end

local function ResolveKnownSpell(def)
    if not def then return nil end

    local resolveIds = def.resolveIds
    if resolveIds then
        for _, spellId in ipairs(resolveIds) do
            local entry = DB.spellbook.byId[spellId]
            if entry then
                return entry
            end
            if RawIsSpellKnown(spellId) then
                local name, rank, icon = A.GetSpellInfoCached(spellId)
                if name then
                    return {
                        id = spellId,
                        name = name,
                        rank = rank or "",
                        icon = icon,
                    }
                end
            end
        end
    end

    local names = {}
    local seen = {}

    local apiName = def.baseId and A.GetSpellInfoCached(def.baseId)
    if apiName then
        names[#names + 1] = apiName
        seen[apiName] = true
    end

    if def.resolveNames then
        for _, name in ipairs(def.resolveNames) do
            if name and not seen[name] then
                names[#names + 1] = name
                seen[name] = true
            end
        end
    end

    if def.name and not seen[def.name] then
        names[#names + 1] = def.name
        seen[def.name] = true
    end

    for _, name in ipairs(names) do
        local entry = DB.spellbook.byName[name]
        if entry then
            return entry
        end
    end

    local fallbackId = def.baseId
    if fallbackId then
        local name, rank, icon = A.GetSpellInfoCached(fallbackId)
        if name or def.name then
            return {
                id = fallbackId,
                name = name or def.name,
                rank = rank or "",
                icon = icon,
            }
        end
    end

    return nil
end

function A.GetSpellDefinition(spellRef)
    if spellRef == nil then return nil end

    if type(spellRef) == "table" then
        if spellRef.key and DB.catalog[spellRef.key] then
            return DB.catalog[spellRef.key]
        end
        if spellRef.meta then
            return spellRef.meta
        end
        spellRef = spellRef.baseId or spellRef.id or spellRef.spellId
    end

    if type(spellRef) == "string" then
        local direct = DB.catalog[spellRef]
        if direct then
            return direct
        end

        local spell = A.SPELLS and A.SPELLS[spellRef]
        if spell and spell.meta then
            return spell.meta
        end

        local numeric = tonumber(spellRef)
        if numeric then
            spellRef = numeric
        else
            return DB.byName[spellRef]
        end
    end

    if type(spellRef) == "number" then
        local direct = DB.byBaseId[spellRef]
        if direct then
            return direct
        end

        local spellName = A.GetSpellInfoCached(spellRef)
        if spellName then
            return DB.byName[spellName]
        end
    end

    return nil
end

function A.ResolveSpellID(spellRef)
    if spellRef == nil then return nil end

    if type(spellRef) == "table" then
        if spellRef.id then return A.ResolveSpellID(spellRef.id) end
        if spellRef.baseId then return A.ResolveSpellID(spellRef.baseId) end
        if spellRef.key then return A.ResolveSpellID(spellRef.key) end
        return nil
    end

    if type(spellRef) == "string" then
        local spell = A.SPELLS and A.SPELLS[spellRef]
        if spell then
            return spell.id or spell.baseId
        end

        local numeric = tonumber(spellRef)
        if numeric then
            spellRef = numeric
        else
            local def = DB.byName[spellRef]
            if not def then return nil end
            ScanPlayerSpellbook(false)
            local resolved = ResolveKnownSpell(def)
            return resolved and resolved.id or def.baseId
        end
    end

    if type(spellRef) == "number" then
        if RawIsSpellKnown(spellRef) then
            return spellRef
        end
        local def = A.GetSpellDefinition(spellRef)
        if def then
            ScanPlayerSpellbook(false)
            local resolved = ResolveKnownSpell(def)
            return resolved and resolved.id or def.baseId
        end
        return spellRef
    end

    return nil
end

function A.RebuildSpellCatalog()
    A.SPELLS = A.SPELLS or {}

    for _, key in ipairs(DB.sortedKeys) do
        local def = DB.catalog[key]
        local resolved = ResolveKnownSpell(def)
        local spell = A.SPELLS[key] or {}
        local resolvedId = resolved and resolved.id or def.baseId

        spell.key = key
        spell.baseId = def.baseId
        spell.id = resolvedId
        spell.name = (resolved and resolved.name) or (A.GetSpellInfoCached(def.baseId)) or def.name
        spell.label = def.name
        spell.rank = resolved and resolved.rank or ""
        spell.icon = (resolved and resolved.icon) or A.GetSpellIconCached(def.baseId)
        spell.known = RawIsSpellKnown(resolvedId) or (DB.spellbook.byId[resolvedId] ~= nil)
        spell.class = def.class
        spell.spec = def.spec
        spell.meta = def

        A.SPELLS[key] = spell
    end

    if A.SpellData and A.SpellData.RebuildCoefficientIndex then
        A.SpellData:RebuildCoefficientIndex()
    end
end

function A.RefreshSpellCatalog(force)
    DB.spellbook.dirty = true
    ScanPlayerSpellbook(force)
    A.RebuildSpellCatalog()
end

local refreshFrame = CreateFrame("Frame")
refreshFrame:RegisterEvent("PLAYER_LOGIN")
refreshFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
refreshFrame:RegisterEvent("SPELLS_CHANGED")
pcall(function() refreshFrame:RegisterEvent("LEARNED_SPELL_IN_TAB") end)
refreshFrame:SetScript("OnEvent", function()
    A.RefreshSpellCatalog(true)
end)

A.RebuildSpellCatalog()
if IsLoggedIn and IsLoggedIn() then
    A.RefreshSpellCatalog(true)
end