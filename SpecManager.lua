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

------------------------------------------------------------------------
-- Spec registration
------------------------------------------------------------------------

--- Register a spec table (called by spec files at load time).
function SM:RegisterSpec(spec)
    if not spec or not spec.meta or not spec.meta.id then
        print("|cffff4444[SPHelper] Spec rejected: missing meta.id|r")
        return false
    end
    -- Validate if SpecValidator is available
    if A.SpecValidator and A.SpecValidator.Validate then
        local ok, err = A.SpecValidator:Validate(spec)
        if not ok then
            print("|cffff4444[SPHelper] Spec rejected (" .. tostring(spec.meta.id) .. "): " .. tostring(err) .. "|r")
            return false
        end
    end
    -- Preserve file-defined loadConditions for Reset-to-Defaults
    spec._fileLoadConditions = {}
    if spec.loadConditions then
        for k, v in pairs(spec.loadConditions) do spec._fileLoadConditions[k] = v end
    end

    -- Apply any DB-stored override immediately so registration reflects runtime state
    if A.db and A.db.specs and A.db.specs[spec.meta.id] and A.db.specs[spec.meta.id].loadConditionsOverride then
        spec.loadConditions = A.db.specs[spec.meta.id].loadConditionsOverride
    end

    self._available[spec.meta.id] = spec
    print("|cff8882d5SPHelper|r: Spec registered: " .. tostring(spec.meta.id))
    -- Log effective loadConditions
    local lc = spec.loadConditions or {}
    local parts = {}
    for k, v in pairs(lc) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
    if #parts > 0 then
        print("|cff8882d5SPHelper|r: LoadConditions: " .. table.concat(parts, ", "))
    else
        print("|cff8882d5SPHelper|r: LoadConditions: (none)")
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

    print("|cff8882d5SPHelper|r: Activating spec: " .. tostring(id))
    if spec.helpers and #spec.helpers > 0 then
        print("|cff8882d5SPHelper|r: Spec helpers: " .. table.concat(spec.helpers, ", "))
    end

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
                print("|cffff4444[SPHelper] Helper '" .. hname .. "' OnSpecActivate error: " .. tostring(err) .. "|r")
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
                    print("|cffff4444[SPHelper] Helper '" .. hname .. "' OnSpecDeactivate error: " .. tostring(err) .. "|r")
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
    -- Deactivate ALL specs first, then pick the best match
    for id in pairs(self._active) do
        self:DeactivateSpec(id)
    end
    A._activeSpecID = nil

    -- Find all specs that pass load conditions, grouped by class
    local candidates = {}  -- list of { id, spec, specificity }
    local _, playerClass = UnitClass("player")
    for id, spec in pairs(self._available) do
        if spec.meta and spec.meta.class and playerClass and spec.meta.class ~= playerClass then
            -- Skip specs for other classes silently
        else
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

    -- Sort by specificity descending — most specific match wins
    table.sort(candidates, function(a, b) return a.specificity > b.specificity end)

    -- Activate only the most specific matching spec (one per class)
    local activatedClasses = {}
    for _, c in ipairs(candidates) do
        local cls = c.spec.meta and c.spec.meta.class or "UNKNOWN"
        if not activatedClasses[cls] then
            activatedClasses[cls] = true
            self:ActivateSpec(c.id)
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
            print("|cffff4444[SPHelper] Rotation override rejected: " .. tostring(err) .. "|r")
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
