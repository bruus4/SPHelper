------------------------------------------------------------------------
-- SPHelper  –  SpecManager.lua
-- Centralises spec discovery, validation, activation, and helper
-- orchestration.  Loaded after Core.lua, before spec files.
------------------------------------------------------------------------
local A = SPHelper

A.SpecManager = {}
local SM = A.SpecManager

SM._available = {}   -- key = specID, value = spec table
SM._active    = {}   -- key = specID, value = spec table
SM._helpers   = {}   -- key = helperName, value = { obj, exports, depends, _refCount, _proxy }

------------------------------------------------------------------------
-- Helper registration
------------------------------------------------------------------------

--- Register a helper module.
-- @param name    string   Unique helper name (e.g. "CastBar", "ChannelHelper").
-- @param obj     table    Must implement OnSpecActivate(self, spec) and OnSpecDeactivate(self, spec).
-- @param opts    table?   { exports = {...}, depends = {...} }
function SM:RegisterHelper(name, obj, opts)
    opts = opts or {}
    local entry = {
        obj       = obj,
        exports   = opts.exports or {},
        depends   = opts.depends or {},
        _refCount = 0,
        _proxy    = nil,
    }
    -- Build proxy that only exposes declared exports
    if #entry.exports > 0 then
        local proxy = {}
        for _, method in ipairs(entry.exports) do
            proxy[method] = function(_, ...)
                if type(obj[method]) == "function" then
                    return obj[method](obj, ...)
                end
            end
        end
        entry._proxy = proxy
    else
        -- No export restrictions — expose the raw object
        entry._proxy = obj
    end
    self._helpers[name] = entry
end

--- Get a helper proxy (nil if helper is not active).
function SM:GetHelper(name)
    local h = self._helpers[name]
    if not h or h._refCount == 0 then return nil end
    return h._proxy
end

--- Call a method on a helper if it is active.  Returns nil if unavailable.
function SM:CallHelper(name, method, ...)
    local proxy = self:GetHelper(name)
    if proxy and type(proxy[method]) == "function" then
        return proxy[method](proxy, ...)
    end
    return nil
end

local function NormalizeVersion(version)
    if version == nil then return nil end
    if type(version) == "string" then
        local trimmed = version:match("^%s*(.-)%s*$")
        if trimmed == "" then return nil end
        local numeric = tonumber(trimmed)
        if numeric ~= nil then return numeric end
        return trimmed
    end

    local numeric = tonumber(version)
    if numeric ~= nil then return numeric end
    return version
end

------------------------------------------------------------------------
-- Spec registration
------------------------------------------------------------------------

--- Register a spec table (called by spec files at load time).
function SM:RegisterSpec(spec)
    if not spec or not spec.meta or not spec.meta.id then
        if A and A.ReportError then
            A.ReportError("SPEC", "Spec rejected", "missing meta.id", { phase = "RegisterSpec" })
        else
            print("|cffff4444[SPHelper] Spec rejected: missing meta.id|r")
        end
        return false
    end
    -- Validate if SpecValidator is available
    if A.SpecValidator and A.SpecValidator.Validate then
        local ok, err = A.SpecValidator:Validate(spec)
        if not ok then
            if A and A.ReportError then
                A.ReportError("SPEC", "Spec rejected", err, { spec = spec.meta.id, phase = "Validate" })
            else
                print("|cffff4444[SPHelper] Spec rejected (" .. tostring(spec.meta.id) .. "): " .. tostring(err) .. "|r")
            end
            return false
        end
    end
    -- Preserve file-defined loadConditions for Reset-to-Defaults
    spec._fileLoadConditions = {}
    if spec.loadConditions then
        for k, v in pairs(spec.loadConditions) do spec._fileLoadConditions[k] = v end
    end

    local specDB = A.db and A.db.specs and A.db.specs[spec.meta.id]
    -- Legacy or stale versions should fall back to the file rotation.
    local fileVersion = NormalizeVersion(spec.meta.version)
    local savedVersion = NormalizeVersion(specDB and specDB.metaOverride and specDB.metaOverride.version)
    local versionMatches = fileVersion ~= nil and savedVersion ~= nil and fileVersion == savedVersion

    if specDB and not versionMatches and specDB.rotation ~= nil then
        -- For premade specs (author == "SPHelper"), show confirmation popup
        if spec.meta.author == "SPHelper" then
            -- Defer popup to after addon load completes
            C_Timer.After(2, function()
                if StaticPopup_Show then
                    StaticPopup_Show("SPHELPER_SPEC_RESET", spec.meta.specName or spec.meta.id, nil, {
                        specID = spec.meta.id,
                        spec = spec,
                    })
                end
            end)
        else
            -- User-created spec: clear rotation silently
            specDB.rotation = nil
        end
    end

    -- Apply any DB-stored override immediately so registration reflects runtime state
    if specDB and specDB.loadConditionsOverride then
        spec.loadConditions = specDB.loadConditionsOverride
    end

    -- Apply DB-stored helpers override if present
    if specDB and specDB.helpers and type(specDB.helpers) == "table" and #specDB.helpers > 0 then
        spec.helpers = specDB.helpers
    end

    if specDB and type(specDB.metaOverride) == "table" then
        local metaOverride = specDB.metaOverride
        for _, field in ipairs({ "specName", "class", "author", "version", "description" }) do
            if metaOverride[field] ~= nil and (field ~= "version" or versionMatches) then
                spec.meta[field] = metaOverride[field]
            end
        end
    end

    local id = spec.meta.id
    local wasRegistered = self._available[id] ~= nil
    self._available[id] = spec
    if not wasRegistered then
        -- No chat spam: spec registration is internal bookkeeping.
        if A and A.DebugLog then pcall(A.DebugLog, "SPEC", "Spec registered: " .. tostring(id)) end
    else
        -- Avoid duplicate user-facing prints on re-registration; record debug entry
        if A and A.DebugLog then pcall(A.DebugLog, "SPEC", "Spec re-registered: " .. tostring(id)) end
    end
    return true
end

------------------------------------------------------------------------
-- Query API
------------------------------------------------------------------------

function SM:GetRegisteredSpecs()  return self._available end
function SM:GetActiveSpecs()      return self._active end
function SM:IsSpecActive(id)      return self._active[id] ~= nil end
function SM:GetSpecByID(id)       return self._available[id] end

------------------------------------------------------------------------
-- Activation / Deactivation
------------------------------------------------------------------------

--- Activate a registered spec and its helpers.
function SM:ActivateSpec(id)
    if self._active[id] then return end
    local spec = self._available[id]
    if not spec then return end

    if A and A.DebugLog then pcall(A.DebugLog, "SPEC", "Activating spec: " .. tostring(id)) end

    self._active[id] = spec
    A._activeSpecID = id

    -- Ensure per-spec DB namespace exists
    A.db.specs = A.db.specs or {}
    A.db.specs[id] = A.db.specs[id] or {}

    -- Activate requested helpers (respect dependency order)
    local activated = {}
    local function ActivateHelper(hname)
        if activated[hname] then return end
        activated[hname] = true
        local h = self._helpers[hname]
        if not h then return end
        -- Activate dependencies first
        for _, dep in ipairs(h.depends or {}) do
            ActivateHelper(dep)
        end
        h._refCount = (h._refCount or 0) + 1
        if h._refCount == 1 and h.obj.OnSpecActivate then
            local ok, err = pcall(h.obj.OnSpecActivate, h.obj, spec)
            if not ok then
                if A and A.ReportError then
                    A.ReportError("SPEC", "OnSpecActivate error", err, { helper = hname, spec = id })
                else
                    print("|cffff4444[SPHelper] Helper '" .. hname .. "' OnSpecActivate error: " .. tostring(err) .. "|r")
                end
            end
        end
    end
    for _, hname in ipairs(spec.helpers or {}) do
        ActivateHelper(hname)
    end
end

--- Deactivate a spec and release its helpers.
function SM:DeactivateSpec(id)
    if not self._active[id] then return end
    local spec = self._active[id]
    self._active[id] = nil

    for _, hname in ipairs(spec.helpers or {}) do
        local h = self._helpers[hname]
        if h then
            h._refCount = math.max((h._refCount or 1) - 1, 0)
            if h._refCount == 0 and h.obj.OnSpecDeactivate then
                local ok, err = pcall(h.obj.OnSpecDeactivate, h.obj, spec)
                if not ok then
                    if A and A.ReportError then
                        A.ReportError("SPEC", "OnSpecDeactivate error", err, { helper = hname, spec = id })
                    else
                        print("|cffff4444[SPHelper] Helper '" .. hname .. "' OnSpecDeactivate error: " .. tostring(err) .. "|r")
                    end
                end
            end
        end
    end
end

------------------------------------------------------------------------
-- Re-evaluate which specs should be active
------------------------------------------------------------------------

--- Count the specificity of a spec's loadConditions (more fields = more specific).
local function LoadConditionSpecificity(spec)
    local lc = spec.loadConditions
    if not lc then return 0 end
    local n = 0
    if lc.class then n = n + 1 end
    if lc.minLevel then n = n + 1 end
    if lc.talentTab then n = n + 2 end  -- talent tab is a strong discriminator
    if lc.requiredSpells and #lc.requiredSpells > 0 then n = n + #lc.requiredSpells end
    if lc.requiredTalents and #lc.requiredTalents > 0 then n = n + #lc.requiredTalents end
    return n
end

function SM:ReEvaluate()
    -- Determine desired active specs but avoid deactivating/re-activating
    -- everything on every reevaluation. Compute the set of specs that
    -- should be active, then only apply the diff against `self._active`.
    --
    -- Activation policy:
    --   • The built-in Shadow Priest spec (the reference spec) auto-activates
    --     when its load conditions match.
    --   • All OTHER built-in specs are opt-in: they only activate after the
    --     player explicitly enables them via /sph (A.db.specs[id].enabled).
    --   • User-created specs (author ~= "SPHelper") keep auto-activation by
    --     load conditions.
    local candidates = {}  -- list of { id, spec, specificity }
    local _, playerClass = UnitClass("player")
    for id, spec in pairs(self._available) do
        if spec.meta and spec.meta.class and playerClass and spec.meta.class ~= playerClass then
            -- Skip specs for other classes silently
        else
            local isBuiltin = spec.meta and spec.meta.author == "SPHelper"
            local optIn = isBuiltin and spec.meta.id ~= "shadow_priest"
            local enabled = true
            if optIn then
                local specDB = A.db and A.db.specs and A.db.specs[id]
                enabled = specDB ~= nil and specDB.enabled == true
            end
            if enabled then
                local shouldActivate = true
                if A.SpecValidator and A.SpecValidator.CheckLoadConditions then
                    shouldActivate = A.SpecValidator:CheckLoadConditions(spec)
                end
                if shouldActivate then
                    candidates[#candidates + 1] = {
                        id = id,
                        spec = spec,
                        specificity = LoadConditionSpecificity(spec),
                    }
                end
            end
        end
    end

    -- Sort by specificity descending — most specific match wins
    table.sort(candidates, function(a, b) return a.specificity > b.specificity end)

    -- Pick the most specific per class
    local desiredByClass = {}
    local desiredList = {}
    for _, c in ipairs(candidates) do
        local cls = c.spec.meta and c.spec.meta.class or "UNKNOWN"
        if not desiredByClass[cls] then
            desiredByClass[cls] = true
            desiredList[#desiredList + 1] = c.id
        end
    end

    local desiredSet = {}
    for _, id in ipairs(desiredList) do desiredSet[id] = true end

    -- Deactivate specs that are active but not desired
    for id in pairs(self._active) do
        if not desiredSet[id] then
            self:DeactivateSpec(id)
        end
    end

    -- Activate desired specs that are not already active
    for _, id in ipairs(desiredList) do
        if not self._active[id] then
            self:ActivateSpec(id)
        end
    end

    -- Ensure A._activeSpecID points at an active spec (or nil)
    if next(self._active) == nil then
        A._activeSpecID = nil
    else
        if not A._activeSpecID or not self._active[A._activeSpecID] then
            for id in pairs(self._active) do
                A._activeSpecID = id
                break
            end
        end
    end
end

------------------------------------------------------------------------
-- Update a spec from DB override (for rotation editor save)
------------------------------------------------------------------------

function SM:UpdateSpecFromDB(id)
    local override = A.db.specs and A.db.specs[id] and A.db.specs[id].rotation
    if not override then return end
    if A.SpecValidator and A.SpecValidator.ValidateRotation then
        local ok, err = A.SpecValidator:ValidateRotation(override)
        if not ok then
            if A and A.ReportError then
                A.ReportError("SPEC", "Rotation override rejected", err, { spec = id })
            else
                print("|cffff4444[SPHelper] Rotation override rejected: " .. tostring(err) .. "|r")
            end
            return false
        end
    end
    -- Re-activate to pick up the new rotation
    self:DeactivateSpec(id)
    self:ActivateSpec(id)
    return true
end

--- Reset a spec to its file-based defaults (remove DB override).
function SM:ResetSpecToDefault(id)
    if A.db and A.db.specs and A.db.specs[id] then
        A.db.specs[id].rotation = nil
    end
    self:DeactivateSpec(id)
    self:ActivateSpec(id)
end

--- Explicitly enable or disable a built-in spec (persisted opt-in).
-- Built-in specs other than the reference Shadow Priest spec are disabled
-- until the player opts in via /sph.  Returns true if the spec is active
-- after the change.
function SM:SetSpecEnabled(id, enabled)
    if not id then return false end
    A.db.specs = A.db.specs or {}
    A.db.specs[id] = A.db.specs[id] or {}
    A.db.specs[id].enabled = enabled == true
    self:ReEvaluate()
    return self._active[id] ~= nil
end

--- Is this spec currently enabled (opt-in flag) or auto-activated?
function SM:IsSpecEnabled(id)
    local spec = self._available[id]
    if not spec then return false end
    local isBuiltin = spec.meta and spec.meta.author == "SPHelper"
    if not isBuiltin or spec.meta.id == "shadow_priest" then
        -- Reference spec + user-created specs: auto by conditions
        return self._active[id] ~= nil
    end
    local specDB = A.db and A.db.specs and A.db.specs[id]
    return specDB ~= nil and specDB.enabled == true
end
