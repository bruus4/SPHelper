------------------------------------------------------------------------
-- SPHelper  –  Config.lua
-- Settings panel + slash commands.
-- Uses the modern Settings API (Classic Anniversary modern client).
-- Falls back to legacy InterfaceOptions_AddCategory only on very old builds.
-- All UI elements are created manually — no deprecated templates.
------------------------------------------------------------------------
local A = SPHelper

local function EnsureDotTrackerReady()
    if A.DotTrackerAddCurrentTarget and A.DotTrackerRemoveCurrentTarget and A.DotTrackerClearManualTargets then
        return true
    end
    if not (A.db and A.db.dotTracker and A.db.dotTracker.enabled) then
        return false
    end
    if A.InitDotTracker then
        local ok, err = pcall(A.InitDotTracker, A)
        if not ok then
            if A.ReportError then
                A.ReportError("DOT", "InitDotTracker", err, { source = "Config" })
            else
                print("|cffff4444SPHelper|r: " .. (A.TRACKER_NAME or "Target Tracker") .. " failed to initialize: " .. tostring(err))
            end
            return false
        end
    end
    return A.DotTrackerAddCurrentTarget ~= nil
end

-- ====================================================================
-- UI helpers (work inside any parent frame, no templates needed)
-- ====================================================================

local function MakeHeader(parent, text, yOff)
    local h = parent:CreateFontString(nil, "OVERLAY")
    h:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    -- Sub-headers sit between section headers and settings
    h:SetPoint("TOPLEFT", parent, "TOPLEFT", 24, yOff)
    h:SetText("|cffffcc00" .. text .. "|r")
    -- Tooltip on header describing the section
    h:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(text)
        GameTooltip:AddLine("Configure " .. text .. " settings.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    h:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)
    return h
end

-- Larger section header for top-level groupings (more prominent)
local function MakeSectionHeader(parent, text, yOff)
    local h = parent:CreateFontString(nil, "OVERLAY")
    h:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    h:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, yOff)
    h:SetText("|cffffcc00" .. text .. "|r")
    h:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(text)
        GameTooltip:AddLine("Configure " .. text .. " settings.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    h:SetScript("OnLeave", function(self) GameTooltip:Hide() end)
    return h
end

-- Sub-header for sections (slightly smaller than section header)
local function MakeSubHeader(parent, text, yOff)
    local h = parent:CreateFontString(nil, "OVERLAY")
    h:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    -- Slightly more indented than MakeHeader
    h:SetPoint("TOPLEFT", parent, "TOPLEFT", 28, yOff)
    h:SetText("|cffbfbfdf" .. text .. "|r")
    return h
end

local function MakeSlider(parent, label, min, max, step, get, set, yOff)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(240, 36)
    -- Settings are indented to group under headers
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", 36, yOff)

    local lbl = container:CreateFontString(nil, "OVERLAY")
    lbl:SetFont("Fonts\\FRIZQT__.TTF", 10)
    lbl:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    lbl:SetTextColor(1, 0.82, 0, 1)

    local s = CreateFrame("Slider", nil, container, "BackdropTemplate")
    s:SetSize(200, 14)
    s:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -14)
    s:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        edgeSize = 8, tile = true, tileSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    s:SetOrientation("HORIZONTAL")
    s:SetMinMaxValues(min, max)
    s:SetValueStep(step)
    s:SetObeyStepOnDrag(true)
    s:SetValue(get())
    s:EnableMouse(true)

    lbl:SetText(label .. ": " .. get())

    local lo = s:CreateFontString(nil, "ARTWORK")
    lo:SetFont("Fonts\\FRIZQT__.TTF", 9)
    lo:SetPoint("TOPLEFT", s, "BOTTOMLEFT", 2, -1)
    lo:SetText(min)

    local hi = s:CreateFontString(nil, "ARTWORK")
    hi:SetFont("Fonts\\FRIZQT__.TTF", 9)
    hi:SetPoint("TOPRIGHT", s, "BOTTOMRIGHT", -2, -1)
    hi:SetText(max)

    s:SetScript("OnValueChanged", function(self, val)
        val = math.floor(val / step + 0.5) * step
        set(val)
        lbl:SetText(label .. ": " .. val)
    end)
    return container
end

local function MakeCheckbox(parent, label, get, set, yOff)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(240, 22)
    -- Settings are indented to group under headers
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", 36, yOff)

    local cb = CreateFrame("CheckButton", nil, container)
    cb:SetSize(22, 22)
    cb:SetPoint("LEFT", container, "LEFT", 0, 0)
    cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
    cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
    cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    cb:SetDisabledCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check-Disabled")
    cb:SetChecked(get())
    cb:SetScript("OnClick", function(self) set(self:GetChecked()) end)

    local text = container:CreateFontString(nil, "OVERLAY")
    text:SetFont("Fonts\\FRIZQT__.TTF", 10)
    text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    text:SetText(label)
    text:SetTextColor(1, 1, 1, 1)

    return container, cb
end
-- Return container and checkbox object when needed


local dropdownCounter = 0

local function MakeDropdown(parent, label, options, get, set, yOff, labels)
    dropdownCounter = dropdownCounter + 1
    local globalName = "SPHelperDropdown" .. dropdownCounter

    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(300, 40)
    -- Settings are indented to group under headers
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", 36, yOff)

    local lbl = container:CreateFontString(nil, "OVERLAY")
    lbl:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    lbl:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(1, 0.82, 0, 1)

    local dd = CreateFrame("Frame", globalName, container, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", -16, -2)

    local function DisplayText(key)
        if type(labels) == "function" then
            local ok, v = pcall(labels, key)
            if ok and v then return v end
        elseif labels and labels[key] then
            return labels[key]
        end
        return tostring(key)
    end

    local function InitDropdown()
        UIDropDownMenu_SetWidth(dd, 130)
        UIDropDownMenu_SetText(dd, DisplayText(get()))
        UIDropDownMenu_Initialize(dd, function(self, level)
            for _, opt in ipairs(options) do
                local info = UIDropDownMenu_CreateInfo()
                -- show icons for item-based options when available
                if type(opt) == "number" then
                    local ico = (A.GetItemIconCached and A.GetItemIconCached(opt)) or GetItemIcon(opt)
                    if ico then info.icon = ico end
                end
                info.text     = DisplayText(opt)
                info.value    = opt
                info.func     = function(self2)
                    set(self2.value)
                    UIDropDownMenu_SetText(dd, DisplayText(self2.value))
                    CloseDropDownMenus()
                end
                info.checked  = (opt == get())
                UIDropDownMenu_AddButton(info, level)
            end
        end)
    end

    container:SetScript("OnShow", function()
        -- Re-init labels and selection when the panel shows so counts update
        InitDropdown()
    end)

    -- Initialize immediately as well
    InitDropdown()

    return container
end

local function MakeCycleButton(parent, label, options, get, set, yOff, labels)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(300, 24)
    -- Settings are indented to group under headers
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", 36, yOff)

    local lbl = container:CreateFontString(nil, "OVERLAY")
    lbl:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    lbl:SetPoint("LEFT", container, "LEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(1, 0.82, 0, 1)

    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    btn:SetSize(100, 24)
    btn:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    A.CreateBackdrop(btn, 0.15, 0.15, 0.15, 0.9, 0.4, 0.4, 0.4, 1)

    local val = btn:CreateFontString(nil, "OVERLAY")
    val:SetFont("Fonts\\FRIZQT__.TTF", 10)
    val:SetPoint("CENTER")
    val:SetTextColor(1, 1, 1, 1)

    local function DisplayText(key)
        return (labels and labels[key]) or key
    end
    local function UpdateText() val:SetText(DisplayText(get())) end
    UpdateText()

    btn:SetScript("OnClick", function()
        local cur = get()
        for i, opt in ipairs(options) do
            if opt == cur then
                set(options[(i % #options) + 1])
                UpdateText()
                return
            end
        end
        set(options[1]); UpdateText()
    end)
    return container
end

local function MakeButton(parent, text, width, height, onClick, yOff)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(width or 140, height or 22)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yOff)
    A.CreateBackdrop(btn, 0.15, 0.15, 0.15, 0.95, 0.3, 0.3, 0.3, 1)
    local lbl = btn:CreateFontString(nil, "OVERLAY")
    lbl:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    lbl:SetPoint("CENTER")
    lbl:SetText(text)
    btn:SetScript("OnClick", onClick)
    return btn
end

-- ====================================================================
-- Build controls inside a scrollable content frame
-- ====================================================================
local function BuildControls(panel)
    local content = CreateFrame("Frame", nil, panel)
    content:SetAllPoints(panel)

    local width = 620
    local y = -16

    local function Tooltip(frame, title, body)
        frame:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(title or "SPHelper")
            if body and body ~= "" then
                GameTooltip:AddLine(body, 0.9, 0.9, 0.9, true)
            end
            GameTooltip:Show()
        end)
        frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    local function Text(parent, text, x, yOff, w, size, color)
        local fs = parent:CreateFontString(nil, "OVERLAY")
        fs:SetFont("Fonts\\FRIZQT__.TTF", size or 10, "")
        fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x or 0, yOff or 0)
        fs:SetWidth(w or width)
        fs:SetJustifyH("LEFT")
        fs:SetTextColor((color and color[1]) or 0.86, (color and color[2]) or 0.86, (color and color[3]) or 0.86, (color and color[4]) or 1)
        fs:SetText(text or "")
        return fs
    end

    local function Panel(parent, x, yOff, w, h, title)
        local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        box:SetSize(w, h)
        box:SetPoint("TOPLEFT", parent, "TOPLEFT", x, yOff)
        A.CreateBackdrop(box, 0.08, 0.08, 0.12, 0.92, 0.32, 0.30, 0.42, 1)
        if title then
            local titleFs = box:CreateFontString(nil, "OVERLAY")
            titleFs:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
            titleFs:SetPoint("TOPLEFT", box, "TOPLEFT", 10, -8)
            titleFs:SetTextColor(1, 0.82, 0, 1)
            titleFs:SetText(title)
            box._title = titleFs
        end
        return box
    end

    local function ActionButton(parent, text, x, yOff, w, onClick, tip)
        local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        btn:SetSize(w or 130, 26)
        btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, yOff)
        A.CreateBackdrop(btn, 0.14, 0.13, 0.18, 0.96, 0.38, 0.36, 0.48, 1)
        local lbl = btn:CreateFontString(nil, "OVERLAY")
        lbl:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
        lbl:SetPoint("LEFT", btn, "LEFT", 6, 0)
        lbl:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
        lbl:SetJustifyH("CENTER")
        lbl:SetText(text)
        btn._label = lbl
        btn:SetScript("OnClick", onClick)
        if tip then Tooltip(btn, text, tip) end
        return btn
    end

    local function StatusText(value)
        return value and "|cff66dd88Enabled|r" or "|cffff7777Disabled|r"
    end

    local function SafeGet(getter, fallback)
        local ok, value = pcall(getter)
        if ok and value ~= nil then return value end
        return fallback
    end

    local function OpenDebugTab()
        if not (A.SpecUI and A.SpecUI.Open) then
            print("|cff8882d5SPHelper|r: SpecUI not loaded.")
            return
        end
        A.SpecUI:Open()
        if C_Timer and C_Timer.After then
            C_Timer.After(0.06, function()
                if A.SpecUI and A.SpecUI.SwitchTab then
                    A.SpecUI:SwitchTab(7, A.SpecUI._spec)
                end
            end)
        end
    end

    local activeSpecID = A._activeSpecID
    local activeSpec = activeSpecID and A.SpecManager and A.SpecManager.GetSpecByID and A.SpecManager:GetSpecByID(activeSpecID)
    local specName = (activeSpec and activeSpec.meta and (activeSpec.meta.specName or activeSpec.meta.name or activeSpec.meta.id)) or "No active spec"
    local specClass = (activeSpec and activeSpec.meta and activeSpec.meta.class) or select(2, UnitClass("player")) or "Unknown"
    local rotation = nil
    if activeSpec and activeSpec.meta then
        local sdb = A.db and A.db.specs and A.db.specs[activeSpec.meta.id]
        rotation = (sdb and sdb.rotation) or activeSpec.rotation
    end
    local rotationCount, helperCount = 0, 0
    for _, entry in ipairs(rotation or {}) do
        if type(entry) == "table" and entry.key then
            rotationCount = rotationCount + 1
            local helpers = entry.helpers
            if type(helpers) == "table" and (helpers.fakeQueue or helpers.clipOverlay or helpers.tickMarkers or helpers.tickSound or helpers.tickFlash) then
                helperCount = helperCount + 1
            end
        end
    end

    local title = content:CreateFontString(nil, "OVERLAY")
    title:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE")
    title:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
    title:SetText("|cff8882d5SPHelper|r")
    y = y - 22

    Text(content, "Rotation, helper, and layout control center. The heavy editors stay in their own windows so this panel stays readable during setup.", 16, y, width, 10, {0.78, 0.78, 0.84, 1})
    y = y - 34

    local specPanel = Panel(content, 16, y, width, 92, "Active Rotation")
    Text(specPanel, specName, 12, -28, width - 24, 12, {1, 1, 1, 1})
    Text(specPanel, string.format("Class: %s     Abilities: %d     Helper-enabled channels: %d", tostring(specClass), rotationCount, helperCount), 12, -50, width - 24, 9, {0.75, 0.75, 0.80, 1})
    Text(specPanel, "Specs, conditions, metadata, load rules, imports, exports, and per-spell helper options belong in the Rotation Editor.", 12, -68, width - 24, 9, {0.62, 0.62, 0.70, 1})
    y = y - 104

    local actions = Panel(content, 16, y, width, 96, "Open Tools")
    ActionButton(actions, "Rotation Editor", 12, -30, 140, function()
        if A.SpecUI and A.SpecUI.Open then A.SpecUI:Open() else print("|cff8882d5SPHelper|r: Spec UI not available.") end
    end, "Edit rotations, conditions, metadata, load rules, imports, exports, and helper options.")
    ActionButton(actions, "New Rotation", 164, -30, 120, function()
        if A.SpecUI and A.SpecUI.OpenNewSpecDialog then
            A.SpecUI.OpenNewSpecDialog()
        elseif A.SpecUI and A.SpecUI.Open then
            pcall(function() A.SpecUI:Open(nil) end)
        else
            print("|cff8882d5SPHelper|r: Spec UI not available.")
        end
    end, "Create a new editable rotation profile.")
    ActionButton(actions, "Visual Layout", 296, -30, 120, function()
        if A.OpenVisualsWindow then A.OpenVisualsWindow() else print("|cff8882d5SPHelper|r: Visuals window not available.") end
    end, "Tune sizes, colors, row layout, frame scale, and previews.")
    ActionButton(actions, "Debug", 428, -30, 80, OpenDebugTab, "Open the rotation debugger tab.")
    ActionButton(actions, "Capture", 520, -30, 82, function()
        if A.TroubleshooterChatCapture then
            OpenDebugTab()
            if C_Timer and C_Timer.After then
                C_Timer.After(0.12, function() A.TroubleshooterChatCapture() end)
            else
                A.TroubleshooterChatCapture()
            end
        else
            print("|cff8882d5SPHelper|r: Troubleshooter not available.")
        end
    end, "Capture the current rotation state for debugging.")
    Text(actions, "Separate windows are intentional here: the editor, visuals, and debugger need more space than a single options page can give them cleanly.", 12, -68, width - 24, 9, {0.62, 0.62, 0.70, 1})
    y = y - 108

    local modules = Panel(content, 16, y, width, 132, "Modules")
    local rows = {
        { label = "Rotation Advisor", key = "rotation", get = function() return A.db.rotation.enabled end, set = function(v) A.db.rotation.enabled = v end, tip = "Shows the next recommended ability icons." },
        { label = "Cast Bar", key = "castBar", get = function() return A.db.castBar.enabled end, set = function(v) A.db.castBar.enabled = v end, tip = "Shows cast/channel progress and channel helper overlays." },
        {
            label = A.TRACKER_NAME or "Target Tracker",
            key = "dotTracker",
            get = function() return A.db.dotTracker.enabled end,
            set = function(v)
                A.db.dotTracker.enabled = v
                if v then
                    EnsureDotTrackerReady()
                elseif A.dotAnchor then
                    A.dotAnchor:Hide()
                end
            end,
            tip = "Tracks multiple enemies with their HP, debuffs and raid marks. Manually mark targets before a pull; right-click entries to remove them.",
        },
        { label = "Lock frame positions", key = "locked", get = function() return A.db.locked end, set = function(v) A.db.locked = v end, tip = "Lock prevents dragging; unlock lets you move SPHelper frames." },
    }
    local rowY = -30
    for _, row in ipairs(rows) do
        local enabled = SafeGet(row.get, false)
        local cbContainer = MakeCheckbox(modules, row.label,
            row.get,
            function(v)
                row.set(v)
                if row.status then
                    row.status:SetText(StatusText(v))
                end
            end,
            rowY)
        cbContainer:ClearAllPoints()
        cbContainer:SetPoint("TOPLEFT", modules, "TOPLEFT", 12, rowY)
        cbContainer:SetSize(260, 22)
        cbContainer:EnableMouse(true)
        Tooltip(cbContainer, row.label, row.tip)
        local status = modules:CreateFontString(nil, "OVERLAY")
        status:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
        status:SetPoint("TOPLEFT", modules, "TOPLEFT", 270, rowY - 3)
        status:SetWidth(110)
        status:SetJustifyH("LEFT")
        status:SetText(StatusText(enabled))
        row.status = status
        rowY = rowY - 24
    end
    Text(modules, "Module on/off changes apply after /reload. Frame locking updates immediately.", 12, -118, width - 24, 8, {0.58, 0.58, 0.64, 1})
    y = y - 144

    local utility = Panel(content, 16, y, width, 84, "Utilities")
    local lockBtn
    lockBtn = ActionButton(utility, A.db.locked and "Unlock Frames" or "Lock Frames", 12, -30, 118, function()
        A.db.locked = not A.db.locked
        lockBtn._label:SetText(A.db.locked and "Unlock Frames" or "Lock Frames")
        print(A.db.locked and "|cff8882d5SPHelper|r: Frames locked." or "|cff8882d5SPHelper|r: Frames unlocked - drag to reposition.")
    end, "Toggle frame dragging without leaving this panel.")
    ActionButton(utility, "Fake Queue Macros", 142, -30, 142, function()
        if A.ChannelHelper and A.ChannelHelper.PrintMacros then
            A.ChannelHelper:PrintMacros()
            print("|cff8882d5SPHelper|r: Use |cffffcc00/sph createmacros|r to choose which macros to create.")
        else
            print("|cff8882d5SPHelper|r: ChannelHelper not loaded.")
        end
    end, "Print macro templates for helper-enabled channel spells.")
    ActionButton(utility, "Create Macros", 296, -30, 112, function()
        if A.ChannelHelper and A.ChannelHelper.OpenMacroChooser then
            A.ChannelHelper:OpenMacroChooser()
        elseif A.ChannelHelper and A.ChannelHelper.CreateMacros then
            A.ChannelHelper:CreateMacros()
        else
            print("|cff8882d5SPHelper|r: ChannelHelper not loaded.")
        end
    end, "Choose which Fake Queue macros to create or update.")
    ActionButton(utility, "Reset", 520, -30, 82, function()
        SPHelperDB = nil
        A.InitDB()
        print("|cff8882d5SPHelper|r: Settings reset. /reload to apply.")
    end, "Reset saved SPHelper settings to defaults.")
    Text(utility, "Slash shortcuts: /sph spec, /sph visuals, /sph capture, /sph debug, /sph scale 0.5-3.0.", 12, -62, width - 24, 8, {0.62, 0.62, 0.70, 1})
end

-- ====================================================================
-- Init
-- ====================================================================
function A:InitConfig()
    -- Guard: Settings system calls this via Refresh; only register once.
    if A.optionsPanel then return end

    ----------------------------------------------------------------
    -- Register panel using whichever API is available
    ----------------------------------------------------------------
    local panel = CreateFrame("Frame", "SPHelperOptionsPanel")
    panel.name = "SPHelper"

    local built = false
    panel:SetScript("OnShow", function(self)
        if not built then
            local ok, err = pcall(function()
                BuildControls(self)
            end)
            if not ok then
                A.ReportError("CONFIG", "failed building options panel", err, { phase = "OnShow" })
                if not self._sph_errorLabel then
                    local lbl = self:CreateFontString(nil, "OVERLAY")
                    lbl:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
                    lbl:SetPoint("CENTER")
                    lbl:SetTextColor(1, 0.2, 0.2, 1)
                    lbl:SetText("SPHelper: failed to build options (see chat).")
                    self._sph_errorLabel = lbl
                end
            else
                built = true
            end
        end
        if A.DotTrackerPreviewOn then A.DotTrackerPreviewOn() end
        if A.CastBarPreviewOn    then A.CastBarPreviewOn()    end
        if A.RotationPreviewOn   then A.RotationPreviewOn()   end
    end)
    panel:SetScript("OnHide", function(self)
        if A.DotTrackerPreviewOff then A.DotTrackerPreviewOff() end
        if A.CastBarPreviewOff    then A.CastBarPreviewOff()    end
        if A.RotationPreviewOff   then A.RotationPreviewOff()   end
    end)

    -- Modern Settings API (10.0+ / Classic Anniversary on modern client)
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, "SPHelper")
        if category and Settings.RegisterAddOnCategory then
            Settings.RegisterAddOnCategory(category)
        end
        A.settingsCategory = category
        -- The Settings system calls Refresh on the frame; provide it so we build controls
        panel.Refresh = function(self)
            if not built then
                local ok, err = pcall(function() BuildControls(self) end)
                if not ok then
                    A.ReportError("CONFIG", "failed building options", err, { phase = "Refresh" })
                else
                    built = true
                end
            end
            if A.DotTrackerPreviewOn then A.DotTrackerPreviewOn() end
            if A.CastBarPreviewOn    then A.CastBarPreviewOn()    end
            if A.RotationPreviewOn   then A.RotationPreviewOn()   end
        end
    elseif InterfaceOptions_AddCategory then
        -- Legacy API (fallback for older clients)
        InterfaceOptions_AddCategory(panel)
    end
    A.optionsPanel = panel

    ----------------------------------------------------------------
    -- Visuals window (movable, small) — opened from settings via button
    ----------------------------------------------------------------
    A.OpenVisualsWindow = function()
        -- If already visible, just close it (use CloseVisualsWindow when available)
        if A.visualsWindow and A.visualsWindow:IsShown() then
            if A.CloseVisualsWindow then pcall(A.CloseVisualsWindow) else A.visualsWindow:Hide() end
            return
        end
        local w = A.visualsWindow
        if not w then
            w = CreateFrame("Frame", "SPHelperVisualsWindow", UIParent, "BackdropTemplate")
                w:SetSize(300, 600)
            w:SetToplevel(true)
            w:SetFrameStrata("DIALOG")
            w:EnableKeyboard(true)
            w:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
            w:SetMovable(true)
            w:EnableMouse(true)
            w:SetClampedToScreen(true)
            w:RegisterForDrag("LeftButton")
            w:SetScript("OnDragStart", function(self) if not A.db.locked then self:StartMoving() end end)
            w:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
            A.CreateBackdrop(w, 0.12, 0.10, 0.18, 0.95)

            local title = w:CreateFontString(nil, "OVERLAY")
            title:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
            title:SetPoint("TOP", w, "TOP", 0, -8)
            title:SetText("SPHelper Visuals")

            -- Close button
            local closeBtn = CreateFrame("Button", nil, w, "BackdropTemplate")
            closeBtn:SetSize(20, 20)
            closeBtn:SetPoint("TOPRIGHT", w, "TOPRIGHT", -6, -6)
            local xb = closeBtn:CreateFontString(nil, "OVERLAY")
            xb:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
            xb:SetPoint("CENTER")
            xb:SetText("X")
                closeBtn:SetScript("OnClick", function()
                    if A.CloseVisualsWindow then pcall(A.CloseVisualsWindow) else w:Hide() end
                end)

            -- Preview toggle state
            if A._visualsPreviewActive == nil then A._visualsPreviewActive = false end

            local function startAllPreviews()
                if A.DotTrackerPreviewOn then pcall(A.DotTrackerPreviewOn) end
                if A.CastBarPreviewOn then pcall(A.CastBarPreviewOn) end
                if A.RotationPreviewOn then pcall(A.RotationPreviewOn) end
                if A.PreviewTickSound then pcall(A.PreviewTickSound) end
                if A.PreviewTickFlash then pcall(A.PreviewTickFlash) end
                A._visualsPreviewActive = true
            end

            local function stopAllPreviews()
                if A.DotTrackerPreviewOff then pcall(A.DotTrackerPreviewOff) end
                if A.CastBarPreviewOff then pcall(A.CastBarPreviewOff) end
                if A.RotationPreviewOff then pcall(A.RotationPreviewOff) end
                A._visualsPreviewActive = false
            end

            -- Track whether settings were open so we can restore them on close
            local settingsWereOpen = false
            if (InterfaceOptionsFrame and InterfaceOptionsFrame:IsShown()) or (_G.SettingsPanel and _G.SettingsPanel:IsShown()) or (_G.SettingsDialog and _G.SettingsDialog:IsShown()) then
                settingsWereOpen = true
            end

            -- Hide settings panels now (we'll restore them on close if needed)
            if InterfaceOptionsFrame and InterfaceOptionsFrame:IsShown() then InterfaceOptionsFrame:Hide() end
            if _G.SettingsPanel and _G.SettingsPanel:IsShown() then _G.SettingsPanel:Hide() end
            if _G.SettingsDialog and _G.SettingsDialog:IsShown() then _G.SettingsDialog:Hide() end

            -- Ensure the window is listed for ESC while shown, remove on hide
            w:SetScript("OnShow", function(self)
                if type(UISpecialFrames) == "table" then
                    local exists = false
                    for _, v in ipairs(UISpecialFrames) do if v == "SPHelperVisualsWindow" then exists = true; break end end
                    if not exists then table.insert(UISpecialFrames, 1, "SPHelperVisualsWindow") end
                end
            end)

            w:SetScript("OnKeyDown", function(self, key)
                if key == "ESCAPE" then
                    if A.CloseVisualsWindow then pcall(A.CloseVisualsWindow) else self:Hide() end
                end
            end)

            -- Close (destroy) the visuals window and also close any settings frames we hid earlier
            A.CloseVisualsWindow = function()
                local wnd = A.visualsWindow
                if not wnd then return end
                -- hide first to run OnHide cleanup
                wnd:Hide()
                -- restore settings panels if they were open when visuals launched
                if settingsWereOpen then
                    if Settings and Settings.OpenToCategory and A.settingsCategory then
                        pcall(function() Settings.OpenToCategory(A.settingsCategory:GetID()) end)
                    elseif InterfaceOptionsFrame_OpenToCategory then
                        pcall(function() InterfaceOptionsFrame_OpenToCategory(A.optionsPanel) InterfaceOptionsFrame_OpenToCategory(A.optionsPanel) end)
                    end
                end
                -- unregister and clear
                pcall(function()
                    wnd:UnregisterAllEvents()
                    wnd:SetScript("OnShow", nil)
                    wnd:SetScript("OnHide", nil)
                    wnd:SetScript("OnKeyDown", nil)
                    wnd:ClearAllPoints()
                    wnd:SetParent(nil)
                end)
                A.visualsWindow = nil
            end

            w:SetScript("OnHide", function(self)
                -- stop any running previews
                stopAllPreviews()
                -- cleanup potential cursor/tooltip/focus state
                if CursorHasItem() then ClearCursor() end
                if GameTooltip and GameTooltip:IsShown() then GameTooltip:Hide() end
                -- remove from UISpecialFrames
                if type(UISpecialFrames) == "table" then
                    for i, v in ipairs(UISpecialFrames) do
                        if v == "SPHelperVisualsWindow" then
                            table.remove(UISpecialFrames, i)
                            break
                        end
                    end
                end
            end)

            -- Scrollable content for visual controls
            local scroll = CreateFrame("ScrollFrame", nil, w, "UIPanelScrollFrameTemplate")
            scroll:SetPoint("TOPLEFT", w, "TOPLEFT", 8, -36)
            scroll:SetPoint("BOTTOMRIGHT", w, "BOTTOMRIGHT", -28, 48)
            local content = CreateFrame("Frame", nil, scroll)
            content:SetWidth(scroll:GetWidth() or 640)
            scroll:SetScrollChild(content)
            scroll:SetScript("OnSizeChanged", function(self, ww, hh) content:SetWidth(ww) end)

            -- Visual controls placed into scroll content
            local yOff = -8
            -- Scale
            MakeSlider(content, "General scale", 0.5, 3.0, 0.1,
                function() return A.db.scale end,
                function(v)
                    A.db.scale = v
                    if A.castBarFrame then A.castBarFrame:SetScale(v) end
                    if A.dotAnchor   then A.dotAnchor:SetScale(v)   end
                    if A.rotFrame    then A.rotFrame:SetScale(v)    end
                end, yOff)
            yOff = yOff - 42

            -- Cast bar visuals
            MakeSectionHeader(content, "Cast Bar", yOff); yOff = yOff - 22
            -- Cast bar color mode + picker
            local modeCont = MakeCycleButton(content, "Color mode:", { "dynamic", "solid" },
                function() return (A.db.castBar and A.db.castBar.colorMode) or "dynamic" end,
                function(v)
                    if not A.db.castBar then A.db.castBar = {} end
                    A.db.castBar.colorMode = v
                    -- update swatch alpha when toggling (swatch is defined below)
                    if colorSwatch and type(colorSwatch.SetAlpha) == "function" then
                        colorSwatch:SetAlpha(v == "solid" and 1 or 0.6)
                    end
                    if A.CastBarPreviewOn then pcall(A.CastBarPreviewOn) end
                end, yOff)
            yOff = yOff - 30

            local colorLbl = content:CreateFontString(nil, "OVERLAY")
            colorLbl:SetFont("Fonts\\FRIZQT__.TTF", 10)
            colorLbl:SetPoint("TOPLEFT", content, "TOPLEFT", 38, yOff)
            colorLbl:SetText("Cast bar color:")
            local colorSwatch = CreateFrame("Button", nil, content, "BackdropTemplate")
            colorSwatch:SetSize(28, 18)
            colorSwatch:SetPoint("LEFT", colorLbl, "RIGHT", 8, 0)
            colorSwatch:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8" })
            colorSwatch:GetBackdrop().bgFile = "Interface\\BUTTONS\\WHITE8X8"
            local cr, cg, cb = unpack((A.db and A.db.castBar and A.db.castBar.color) or A.COLORS.MF)
            colorSwatch:SetBackdropColor(cr, cg, cb, 1)
            colorSwatch:SetAlpha(((A.db and A.db.castBar and A.db.castBar.colorMode) or "dynamic") == "solid" and 1 or 0.6)
            colorSwatch:SetScript("OnClick", function()
                if not (A.db and A.db.castBar and A.db.castBar.colorMode == "solid") then return end
                local cur = A.db.castBar.color or {0.58, 0.51, 0.79, 1}
                local prev = { cur[1], cur[2], cur[3] }
                -- Configure ColorPicker
                ColorPickerFrame:Hide()
                ColorPickerFrame.func = function(restore)
                    if restore then
                        local rr, rg, rb = unpack(restore)
                        A.db.castBar.color = { rr, rg, rb, 1 }
                        colorSwatch:SetBackdropColor(rr, rg, rb, 1)
                        if A.castBarFrame and A.castBarFrame.bar then A.castBarFrame.bar:SetStatusBarColor(rr, rg, rb, 1) end
                    else
                        local nr, ng, nb = ColorPickerFrame:GetColorRGB()
                        A.db.castBar.color = { nr, ng, nb, 1 }
                        colorSwatch:SetBackdropColor(nr, ng, nb, 1)
                        if A.castBarFrame and A.castBarFrame.bar then A.castBarFrame.bar:SetStatusBarColor(nr, ng, nb, 1) end
                    end
                end
                ColorPickerFrame.previousValues = prev
                ColorPickerFrame.cancelFunc = function()
                    local rr, rg, rb = unpack(ColorPickerFrame.previousValues or prev)
                    A.db.castBar.color = { rr, rg, rb, 1 }
                    colorSwatch:SetBackdropColor(rr, rg, rb, 1)
                    if A.castBarFrame and A.castBarFrame.bar then A.castBarFrame.bar:SetStatusBarColor(rr, rg, rb, 1) end
                end
                ColorPickerFrame:SetColorRGB(prev[1], prev[2], prev[3])
                ShowUIPanel(ColorPickerFrame)
            end)
            yOff = yOff - 28
            MakeSlider(content, "Width", 100, 500, 10,
                function() return A.db.castBar.width end,
                function(v)
                    A.db.castBar.width = v
                    if A.CastBarResizeLayout then A.CastBarResizeLayout() end
                    if A.CastBarPreviewOn then A.CastBarPreviewOn() end
                end, yOff)
            yOff = yOff - 42
            MakeSlider(content, "Height", 10, 50, 2,
                function() return A.db.castBar.height end,
                function(v)
                    A.db.castBar.height = v
                    if A.CastBarResizeLayout then A.CastBarResizeLayout() end
                    if A.CastBarPreviewOn then A.CastBarPreviewOn() end
                end, yOff)
            yOff = yOff - 42
            -- tick options removed from Visuals window

            -- Target Tracker visuals
            MakeSectionHeader(content, A.TRACKER_NAME or "Target Tracker", yOff); yOff = yOff - 22
            MakeSlider(content, "Row width", 200, 500, 10,
                function() return A.db.dotTracker.width end,
                function(v) A.db.dotTracker.width = v; if A.DotTrackerResizeLayout then A.DotTrackerResizeLayout() end end, yOff)
            yOff = yOff - 42
            MakeSlider(content, "Row height", 25, 60, 2,
                function() return A.db.dotTracker.rowHeight or 40 end,
                function(v) A.db.dotTracker.rowHeight = v; if A.DotTrackerResizeLayout then A.DotTrackerResizeLayout() end end, yOff)
            yOff = yOff - 42
            MakeSlider(content, "DoT icon size", 10, 30, 1,
                function() return A.db.dotTracker.dotIconSize or 18 end,
                function(v) A.db.dotTracker.dotIconSize = v; if A.DotTrackerResizeLayout then A.DotTrackerResizeLayout() end end, yOff)
            yOff = yOff - 42
            MakeSlider(content, "Warning threshold (sec)", 1, 10, 1,
                function() return A.db.dotTracker.warnSeconds or 3 end,
                function(v) A.db.dotTracker.warnSeconds = v; if A.DotTrackerResizeLayout then A.DotTrackerResizeLayout() end end, yOff)
            yOff = yOff - 42
            MakeSlider(content, "Blink speed", 1, 10, 1,
                function() return A.db.dotTracker.blinkSpeed or 4 end,
                function(v) A.db.dotTracker.blinkSpeed = v; if A.DotTrackerResizeLayout then A.DotTrackerResizeLayout() end end, yOff)
            yOff = yOff - 42

            -- Target Tracker additional visuals: max targets, portrait side, and expiry warning mode
            MakeSlider(content, "Max targets", 1, 20, 1,
                function() return (A.db.dotTracker and A.db.dotTracker.maxTargets) or 8 end,
                function(v) if not A.db.dotTracker then A.db.dotTracker = {} end; A.db.dotTracker.maxTargets = v; if A.DotTrackerResizeLayout then pcall(A.DotTrackerResizeLayout) end end, yOff)
            yOff = yOff - 42

            MakeCycleButton(content, "Portrait side:", { "left", "right", "none" },
                function() return (A.db.dotTracker and A.db.dotTracker.portraitSide) or "left" end,
                function(v) if not A.db.dotTracker then A.db.dotTracker = {} end; A.db.dotTracker.portraitSide = v; if A.DotTrackerResizeLayout then pcall(A.DotTrackerResizeLayout) end end, yOff, { left = "Left", right = "Right", none = "None" })
            yOff = yOff - 30

            local warnLabels = { border = "Border flash", icon = "Icon flash", bar = "Row flash", none = "None" }
            MakeDropdown(content, "Expiry warning mode:", { "border", "icon", "bar", "none" },
                function() return (A.db.dotTracker and A.db.dotTracker.warnMode) or "border" end,
                function(v) if not A.db.dotTracker then A.db.dotTracker = {} end; A.db.dotTracker.warnMode = v; if A.DotTrackerResizeLayout then pcall(A.DotTrackerResizeLayout) end end, yOff, warnLabels)
            yOff = yOff - 50

            MakeSlider(content, "Warning border size", 1, 12, 1,
                function() return A.db.dotTracker.warnBorderSize or 4 end,
                function(v) A.db.dotTracker.warnBorderSize = v; if A.DotTrackerResizeLayout then pcall(A.DotTrackerResizeLayout) end end, yOff)
            yOff = yOff - 42

            MakeSlider(content, "Warning bar alpha", 0.05, 1.0, 0.05,
                function() return A.db.dotTracker.warnBarAlpha or 0.35 end,
                function(v) A.db.dotTracker.warnBarAlpha = v; if A.DotTrackerResizeLayout then pcall(A.DotTrackerResizeLayout) end end, yOff)
            yOff = yOff - 42

            MakeSlider(content, "Warning icon alpha", 0.1, 1.0, 0.05,
                function() return A.db.dotTracker.warnIconAlpha or 0.6 end,
                function(v) A.db.dotTracker.warnIconAlpha = v; if A.DotTrackerResizeLayout then pcall(A.DotTrackerResizeLayout) end end, yOff)
            yOff = yOff - 42

            MakeCycleButton(content, "New target position:", { "bottom", "top" },
                function() return (A.db.dotTracker and A.db.dotTracker.newTargetPosition) or "bottom" end,
                function(v) if not A.db.dotTracker then A.db.dotTracker = {} end; A.db.dotTracker.newTargetPosition = v; if A.DotTrackerResizeLayout then pcall(A.DotTrackerResizeLayout) end end, yOff, { bottom = "Bottom", top = "Top" })
            yOff = yOff - 30
            MakeDropdown(content, "Sort order:", { "tabOrder", "tabStable", "combatOrder", "alphabetical", "healthAsc", "raidIcon", "debuffExpiry", "addOrder" },
                function() return (A.db.dotTracker and A.db.dotTracker.sortMode) or "tabOrder" end,
                function(v) if not A.db.dotTracker then A.db.dotTracker = {} end; A.db.dotTracker.sortMode = v end, yOff,
                {
                    tabOrder = "Tab cycle (next first)",
                    tabStable = "Stable tab assist",
                    combatOrder = "Combat entry",
                    alphabetical = "Alphabetical",
                    healthAsc = "Lowest health",
                    raidIcon = "Raid marker",
                    debuffExpiry = "Expiring debuffs",
                    addOrder = "Manual/add order",
                })
            yOff = yOff - 50
            MakeCycleButton(content, "Anchor position:", { "top", "bottom" },
                function() return (A.db.dotTracker and A.db.dotTracker.anchorPosition) or "top" end,
                function(v) if not A.db.dotTracker then A.db.dotTracker = {} end; A.db.dotTracker.anchorPosition = v; if A.DotTrackerResizeLayout then pcall(A.DotTrackerResizeLayout) end end, yOff, { top = "Top", bottom = "Bottom" })
            yOff = yOff - 30

            -- Rotation visuals
            MakeSectionHeader(content, "Rotation", yOff); yOff = yOff - 22
            MakeSlider(content, "Primary icon size", 20, 80, 2,
                function() return A.db.rotation.primaryIconSize or A.db.rotation.iconSize end,
                function(v)
                    A.db.rotation.primaryIconSize = v
                    if A.RotationResizeLayout then A.RotationResizeLayout() end
                    if A.RotationPreviewOn then A.RotationPreviewOn() end
                end, yOff)
            yOff = yOff - 42
            MakeSlider(content, "Queue icon size", 20, 80, 2,
                function() return A.db.rotation.iconSize end,
                function(v)
                    A.db.rotation.iconSize = v
                    if A.RotationResizeLayout then A.RotationResizeLayout() end
                    if A.RotationPreviewOn then A.RotationPreviewOn() end
                end, yOff)
            yOff = yOff - 42

            -- Inner Focus tuning removed from Visuals (moved to main settings)

            -- finalize scroll content size so controls are visible
            if content and type(content.SetHeight) == "function" then
                content:SetHeight(math.abs(yOff) + 40)
            end

            -- Preview button remains anchored to window bottom
            local previewAllBtn = CreateFrame("Button", nil, w, "BackdropTemplate")
            previewAllBtn:SetSize(120, 22)
            previewAllBtn:SetPoint("BOTTOM", w, "BOTTOM", 0, 12)
            local p2txt = previewAllBtn:CreateFontString(nil, "OVERLAY")
            p2txt:SetFont("Fonts\\FRIZQT__.TTF", 10)
            p2txt:SetPoint("CENTER")
            p2txt:SetText("Preview All")
            previewAllBtn:SetScript("OnClick", function()
                if A._visualsPreviewActive then
                    stopAllPreviews()
                    p2txt:SetText("Preview All")
                else
                    startAllPreviews()
                    p2txt:SetText("Stop Preview")
                end
            end)

            A.visualsWindow = w
        end
        A.visualsWindow:Show()
    end

    ----------------------------------------------------------------
    -- Slash commands
    ----------------------------------------------------------------
    SLASH_SPHELPER1 = "/sph"
    SLASH_SPHELPER2 = "/sphelper"

    SlashCmdList["SPHELPER"] = function(msg)
        msg = strtrim(msg or ""):lower()

        if msg == "" or msg == "options" or msg == "config" then
            -- Try modern Settings API first
            if Settings and Settings.OpenToCategory and A.settingsCategory then
                Settings.OpenToCategory(A.settingsCategory:GetID())
            elseif InterfaceOptionsFrame_OpenToCategory then
                InterfaceOptionsFrame_OpenToCategory(panel)
                InterfaceOptionsFrame_OpenToCategory(panel)
            else
                print("|cff8882d5SPHelper|r: Could not open settings panel.")
            end

        elseif msg == "lock" then
            A.db.locked = true
            print("|cff8882d5SPHelper|r: Frames locked.")

        elseif msg == "unlock" then
            A.db.locked = false
            print("|cff8882d5SPHelper|r: Frames unlocked — drag to reposition.")

        elseif msg == "reset" then
            SPHelperDB = nil
            A.InitDB()
            print("|cff8882d5SPHelper|r: Settings reset. /reload to apply.")

        elseif msg:find("^scale ") then
            local val = tonumber(msg:match("scale%s+(.+)"))
            if val and val >= 0.5 and val <= 3 then
                A.db.scale = val
                if A.castBarFrame then A.castBarFrame:SetScale(val) end
                if A.dotAnchor   then A.dotAnchor:SetScale(val)   end
                if A.rotFrame    then A.rotFrame:SetScale(val)    end
                print("|cff8882d5SPHelper|r: Scale → " .. val)
            else
                print("|cff8882d5SPHelper|r: Usage: /sph scale 0.5-3.0")
            end

        elseif msg:find("^swd ") then
            local mode = msg:match("swd%s+(.+)")
            if mode == "always" or mode == "execute" or mode == "never" then
                A.db.swdWorld   = mode
                A.db.swdDungeon = mode
                A.db.swdRaid    = mode
                print("|cff8882d5SPHelper|r: SW:D mode (all) → " .. mode)
            else
                print("|cff8882d5SPHelper|r: Usage: /sph swd always|execute|never")
            end



        elseif msg == "visuals" then
            if A.OpenVisualsWindow then
                A.OpenVisualsWindow()
            else
                print("|cff8882d5SPHelper|r: Visuals window not available.")
            end

        elseif msg == "spec" then
            if A.SpecUI and A.SpecUI.Open then
                A.SpecUI:Open()
            else
                print("|cff8882d5SPHelper|r: SpecUI not loaded.")
            end

        elseif msg == "capture" then
            -- Snapshot the troubleshooter: open the Spec UI, switch to the
            -- Debug tab, then run the chat-capture so the EditBox is
            -- populated. If SpecUI isn't available, fall back to the
            -- chat-only capture.
            if A.SpecUI and A.SpecUI.Open then
                A.SpecUI:Open()
                -- Give the UI a moment to open, then switch to tab 7 and
                -- invoke the capture so the troubleshooter's EditBox is
                -- guaranteed to exist and be filled.
                C_Timer.After(0.06, function()
                    if A.SpecUI and A.SpecUI.SwitchTab then
                        A.SpecUI:SwitchTab(7, A.SpecUI._spec)
                    end
                    C_Timer.After(0.06, function()
                        if A.TroubleshooterChatCapture then
                            A.TroubleshooterChatCapture()
                        else
                            print("|cff8882d5SPHelper|r: Troubleshooter not available.")
                        end
                    end)
                end)
            else
                if A.TroubleshooterChatCapture then
                    A.TroubleshooterChatCapture()
                else
                    print("|cff8882d5SPHelper|r: Troubleshooter not available.")
                end
            end

        elseif msg == "track" or msg:find("^track%s+") or msg == "tt" or msg:find("^tt%s+")
            or msg == "dot" or msg:find("^dot%s+") then
            local action = msg:match("^%S+%s+(%S+)") or "help"
            local trackerName = A.TRACKER_NAME or "Target Tracker"
            if action == "add" then
                if EnsureDotTrackerReady() and A.DotTrackerAddCurrentTarget then
                    A.DotTrackerAddCurrentTarget()
                else
                    print("|cff8882d5SPHelper|r: " .. trackerName .. " is disabled or unavailable for the active rotation.")
                end
            elseif action == "remove" then
                if EnsureDotTrackerReady() and A.DotTrackerRemoveCurrentTarget then
                    A.DotTrackerRemoveCurrentTarget()
                else
                    print("|cff8882d5SPHelper|r: " .. trackerName .. " is disabled or unavailable for the active rotation.")
                end
            elseif action == "clear" then
                if EnsureDotTrackerReady() and A.DotTrackerClearManualTargets then
                    A.DotTrackerClearManualTargets()
                else
                    print("|cff8882d5SPHelper|r: " .. trackerName .. " is disabled or unavailable for the active rotation.")
                end
            else
                print("|cff8882d5SPHelper|r " .. trackerName .. " commands:")
                print("  /sph track add     — Add your current target")
                print("  /sph track remove  — Remove your current target")
                print("  /sph track clear   — Clear manually added targets")
            end

        elseif msg == "debug" or msg:find("^debug%s+") then
            local args = {}
            for token in msg:gmatch("%S+") do
                args[#args + 1] = token
            end

            local function PrintDebugHelp()
                print("|cff8882d5SPHelper|r debug commands:")
                print("  /sph debug                 — List debug modules and states")
                print("  /sph debug MODULE on|off   — Enable or disable one module")
                print("  /sph debug dump [MODULE]   — Print recent debug entries")
                print("  /sph debug clear           — Clear the runtime debug buffer")
                print("  /sph debug echo on|off     — Mirror enabled debug entries to chat")
            end

            if #args == 1 or args[2] == "list" then
                local modules = (A.GetKnownDebugModules and A.GetKnownDebugModules()) or {}
                print("|cff8882d5SPHelper|r debug modules:")
                for _, module in ipairs(modules) do
                    local enabled = A.IsDebugModuleEnabled and A.IsDebugModuleEnabled(module)
                    print(string.format("  %s = %s", module, enabled and "on" or "off"))
                end
                PrintDebugHelp()
            elseif args[2] == "clear" then
                if A.ClearDebugLog then
                    A.ClearDebugLog()
                end
                print("|cff8882d5SPHelper|r: Debug log cleared.")
            elseif args[2] == "dump" then
                if A.DumpDebugLog then
                    A.DumpDebugLog(args[3])
                else
                    print("|cff8882d5SPHelper|r: Debug logging is unavailable.")
                end
            elseif args[2] == "echo" then
                local state = args[3]
                if state == "on" or state == "off" then
                    A.db.debug = A.db.debug or {}
                    A.db.debug.echo = (state == "on")
                    print("|cff8882d5SPHelper|r: Debug echo -> " .. state)
                else
                    print("|cff8882d5SPHelper|r: Usage: /sph debug echo on|off")
                end
            else
                local module = args[2]
                local state = args[3]
                if module and (state == "on" or state == "off") and A.SetDebugModuleEnabled then
                    A.SetDebugModuleEnabled(module, state == "on")
                    print(string.format("|cff8882d5SPHelper|r: Debug %s -> %s", tostring(module):upper(), state))
                else
                    PrintDebugHelp()
                end
            end

        elseif msg == "macros" then
            if A.ChannelHelper and A.ChannelHelper.PrintMacros then
                A.ChannelHelper:PrintMacros()
                print("|cff8882d5SPHelper|r: Use |cffffcc00/sph createmacros|r to choose which macros to create.")
            else
                print("|cff8882d5SPHelper|r: ChannelHelper not loaded.")
            end

        elseif msg == "createmacros" then
            if A.ChannelHelper and A.ChannelHelper.OpenMacroChooser then
                A.ChannelHelper:OpenMacroChooser()
            elseif A.ChannelHelper and A.ChannelHelper.CreateMacros then
                A.ChannelHelper:CreateMacros()
            else
                print("|cff8882d5SPHelper|r: ChannelHelper not loaded.")
            end

        else
            print("|cff8882d5SPHelper|r commands:")
            print("  /sph            — Open settings")
            print("  /sph spec       — Open spec & rotation editor")
            print("  /sph visuals    — Open visual layout options")
            print("  /sph capture    — Snapshot troubleshooter → chat + Debug tab")
            print("  /sph debug      — List or toggle module debug logging")
            print("  /sph track add  — Add current target to the Target Tracker")
            print("  /sph lock       — Lock all frames")
            print("  /sph unlock     — Unlock frames for dragging")
            print("  /sph scale N    — Set UI scale (0.5-3.0)")
            print("  /sph swd MODE   — SW:D mode: always / execute / never")
            print("  /sph macros     — Print fake-queue macro templates")
            print("  /sph createmacros — Choose FQ macros to create/update")
            print("  /sph reset      — Reset all settings")
        end
    end
end

------------------------------------------------------------------------
-- Register as SpecManager helper
------------------------------------------------------------------------
if SPHelper.SpecManager then
    SPHelper.SpecManager:RegisterHelper("Config", {
        _initialized = false,
        OnSpecActivate = function(self, spec)
            if self._initialized then return end
            self._initialized = true
            if SPHelper.InitConfig then SPHelper:InitConfig() end
        end,
        OnSpecDeactivate = function(self, spec)
            self._initialized = false
            -- Config panel is not destroyed; just stays dormant
        end,
    })
end
