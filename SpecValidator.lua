------------------------------------------------------------------------
-- SPHelper  –  SpecValidator.lua
-- Validates spec tables and checks load conditions against the
-- current player state.
------------------------------------------------------------------------
local A = SPHelper

A.SpecValidator = {}
local SV = A.SpecValidator

------------------------------------------------------------------------
-- Allowed condition types for rotation entries
------------------------------------------------------------------------
SV.ALLOWED_CONDITION_TYPES = {
    cooldown_ready              = true,
    dot_missing                 = true,
    projected_dot_time_left_lt  = true,
    dot_time_left_lt            = true,
    resource_pct_lt             = true,
    resource_pct_gt             = true,
    item_ready_and_owned        = true,
    content_mode_allow          = true,
    not_recently_cast           = true,
    always                      = true,
    target_valid                = true,
    not_debuff_on_target        = true,
    not_buff_on_player          = true,
    predicted_kill              = true,
    threat_pct_lt               = true,
    threat_pct_ge               = true,
    target_classification       = true,
    -- Phase 8 additions
    buff_on_player              = true,
    buff_stacks_gte             = true,
    target_hp_pct_lt            = true,
    target_hp_pct_gt            = true,
    player_hp_pct_lt            = true,
    player_hp_pct_gt            = true,
    player_mana_pct_lt          = true,
    player_mana_pct_gt          = true,
    player_base_mana_pct_lt     = true,
    player_base_mana_pct_gt     = true,
    target_hp_lt                = true,
    resource_required_gte       = true,
    clearcasting                = true,
    spec_option_enabled         = true,
    spec_option_value           = true,
    in_combat                   = true,
    precombat                   = true,
    channeling                  = true,
    cooldown_lt                 = true,
    spell_usable                = true,
    group_size_gte              = true,
    -- Phase 9 additions
    cat_form                    = true,
    bear_form                   = true,
    behind_target               = true,
    not_behind_target           = true,
    combo_points_gte            = true,
    combo_points_lt             = true,
    debuff_on_target            = true,
    debuff_time_left_lt         = true,
    target_dying_fast           = true,
    target_ttd_gte              = true,
    target_ttd_lt               = true,
    resource_gte                = true,
    resource_lt                 = true,
    resource_at_gcd_lt          = true,
    resource_at_gcd_gt          = true,
    next_power_tick_with_gcd_lt = true,
    next_power_tick_with_gcd_gt = true,
    other_targets_with_debuff_lt = true,
    item_ready_by_key           = true,
    option_gated_classification = true,
    content_type                = true,
    state_compare               = true,
    spell_property_compare      = true,
    buff_property_compare       = true,
    debuff_property_compare     = true,
    unit_cast_compare           = true,
    unit_interruptible          = true,
    is_stealthed                = true,
    not_stealthed               = true,
    not_in_combat               = true,
    -- Logical grouping helpers used by RotationEngine
    any_of                      = true,
    all_of                      = true,
    ["not"]                    = true,
}

------------------------------------------------------------------------
-- Validate a full spec table
------------------------------------------------------------------------

--- Validate a spec table.
-- @return true on success; false, errorString on failure.
function SV:Validate(spec)
    if type(spec) ~= "table" then
        return false, "spec is not a table"
    end
    -- meta
    local m = spec.meta
    if type(m) ~= "table" then return false, "missing meta table" end
    if type(m.id) ~= "string" or m.id == "" then return false, "meta.id must be a non-empty string" end
    if type(m.class) ~= "string" then return false, "meta.class must be a string" end
    if type(m.specName) ~= "string" then return false, "meta.specName must be a string" end
    if m.version == nil then return false, "meta.version is required" end

    -- helpers list
    if spec.helpers ~= nil and type(spec.helpers) ~= "table" then
        return false, "helpers must be a table (list)"
    end

    -- rotation (optional at registration; required before activation)
    if spec.rotation ~= nil then
        local ok, err = self:ValidateRotation(spec.rotation)
        if not ok then return false, "rotation: " .. err end
    end

    return true
end

------------------------------------------------------------------------
-- Validate a rotation table (array of entries)
------------------------------------------------------------------------

function SV:ValidateRotation(rotation)
    if type(rotation) ~= "table" then
        return false, "rotation is not a table"
    end
    for i, entry in ipairs(rotation) do
        if type(entry) ~= "table" then
            return false, "entry " .. i .. " is not a table"
        end
        if type(entry.key) ~= "string" or entry.key == "" then
            return false, "entry " .. i .. ": key must be a non-empty string"
        end
        -- Validate conditions if present
        if entry.conditions then
            if type(entry.conditions) ~= "table" then
                return false, "entry " .. i .. ": conditions must be a table"
            end
            for j, cond in ipairs(entry.conditions) do
                if type(cond) ~= "table" then
                    return false, "entry " .. i .. " cond " .. j .. ": not a table"
                end
                if type(cond.type) ~= "string" then
                    return false, "entry " .. i .. " cond " .. j .. ": missing type"
                end
                if not self.ALLOWED_CONDITION_TYPES[cond.type] then
                    return false, "entry " .. i .. " cond " .. j .. ": unknown type '" .. cond.type .. "'"
                end
            end
        end
        -- Reject raw function values in DB-sourced entries (not _fromFile)
        if not rotation._fromFile then
            for k, v in pairs(entry) do
                if type(v) == "function" then
                    return false, "entry " .. i .. ": function values not allowed in DB rotation (key '" .. tostring(k) .. "')"
                end
            end
        end
    end
    return true
end

------------------------------------------------------------------------
-- Check if a spec's loadConditions match the current player
------------------------------------------------------------------------

function SV:CheckLoadConditions(spec)
    local lc = spec.loadConditions
    if not lc then return true end  -- no conditions = always active
    -- Class check
    if lc.class then
        local _, playerClass = UnitClass("player")
        if playerClass ~= lc.class then return false end
    end

    -- Minimum level (coerce to number for robustness)
    if lc.minLevel then
        local playerLvl = tonumber(UnitLevel("player")) or 0
        local minLvl = tonumber(lc.minLevel) or 0
        if playerLvl < minLvl then
            print("|cffff4444[SPHelper] CheckLoadConditions: level too low (" .. tostring(playerLvl) .. " < " .. tostring(minLvl) .. ")|r")
            return false
        end
    end

    -- Required spells (must know all)
    if lc.requiredSpells then
        for _, spellId in ipairs(lc.requiredSpells) do
            if not IsSpellKnown(spellId) then return false end
        end
    end

    -- Required talents: each entry is { tab=N, index=N, minRank=N }
    if lc.requiredTalents then
        for _, req in ipairs(lc.requiredTalents) do
            local ok, _, _, _, _, rank = pcall(GetTalentInfo, req.tab, req.index)
            local actualRank = (ok and rank) or 0
            if actualRank < (req.minRank or 1) then
                print("|cffff4444[SPHelper] CheckLoadConditions: missing required talent tab=" .. tostring(req.tab) .. " idx=" .. tostring(req.index) .. "|r")
                return false
            end
        end
    end

    -- Talent tab check: the tab with the most points must match
    if lc.talentTab then
        local maxPoints, maxTab = 0, 0
        local numTabs = tonumber(GetNumTalentTabs()) or 0

        -- Resolve requested tab (allow numeric index, label like "2: Feral", or tree name)
        local requiredRaw = lc.talentTab
        local requiredTab = nil
        if type(requiredRaw) == "number" then
            requiredTab = requiredRaw
        elseif type(requiredRaw) == "string" then
            -- Try direct numeric parse or leading-number label like "2: Feral"
            requiredTab = tonumber(requiredRaw:match("^%s*(%d+)") or requiredRaw)
            if not requiredTab then
                -- Try matching by tree name (case-insensitive)
                for tab = 1, numTabs do
                    local name = select(1, GetTalentTabInfo(tab)) or ""
                    if name and requiredRaw and name:lower() == requiredRaw:lower() then
                        requiredTab = tab
                        break
                    end
                end
            end
        end

        for tab = 1, numTabs do
            local name, _, pointsSpent = GetTalentTabInfo(tab)
            local pts = tonumber(pointsSpent) or 0
            if pts > maxPoints then
                maxPoints = pts
                maxTab    = tab
            end
        end

        if maxPoints == 0 then
            -- Talent information unavailable; skip talentTab check
            return true
        end

        if not requiredTab then
            print("|cffff4444[SPHelper] CheckLoadConditions: could not resolve talentTab '" .. tostring(lc.talentTab) .. "'|r")
            return false
        end
        if maxTab ~= requiredTab then
            print("|cffff4444[SPHelper] CheckLoadConditions: talentTab mismatch (primary=" .. tostring(maxTab) .. " required=" .. tostring(requiredTab) .. ")|r")
            return false
        end
    end

    return true
end
