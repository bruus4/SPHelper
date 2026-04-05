------------------------------------------------------------------------
-- SPHelper  –  Config.lua
-- Settings panel + slash commands.
-- Uses the modern Settings API (Classic Anniversary modern client).
-- Falls back to legacy InterfaceOptions_AddCategory only on very old builds.
-- All UI elements are created manually — no deprecated templates.
------------------------------------------------------------------------
local A = SPHelper

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
                    local ico = GetItemIcon(opt)
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
    local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -26, 4)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(scrollFrame:GetWidth() or 500)
    scrollFrame:SetScrollChild(content)

    scrollFrame:SetScript("OnSizeChanged", function(self, w, h)
        content:SetWidth(w)
    end)

    local y = -16

    local t = content:CreateFontString(nil, "OVERLAY")
    t:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    t:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
    t:SetText("|cff8882d5SPHelper|r Settings")
    y = y - 28

    -- Quick visuals window launcher
    local visBtn = MakeButton(content, "Visual Options", 180, 22, function()
        if A.OpenVisualsWindow then A.OpenVisualsWindow() end
    end, y)
    y = y - 30

    -- ============ General ============
    MakeHeader(content, "General", y); y = y - 22

    -- Scale moved to Visuals window

    MakeCheckbox(content, "Lock frame positions",
        function() return A.db.locked end,
        function(v) A.db.locked = v end, y)
    y = y - 28

    -- Mind Flay Tick visuals moved to Visuals window; keep enable checkbox here
    MakeSectionHeader(content, "Mind Flay Tick", y); y = y - 22
    local castContainer, castCB = MakeCheckbox(content, "Enable cast bar  (reload)",
        function() return A.db.castBar.enabled end,
        function(v) A.db.castBar.enabled = v end, y)
    y = y - 26

    -- Tick sound / flash moved out of Visuals into main settings
    do
        local soundKeys = {}
        local soundLabels = {}
        for _, s in ipairs(A.TICK_SOUNDS) do
            soundKeys[#soundKeys + 1] = s.key
            soundLabels[s.key] = s.label
        end
        MakeDropdown(content, "Tick sound:", soundKeys,
            function() return A.db.castBar.tickSound or "click" end,
            function(v)
                A.db.castBar.tickSound = v
                if v ~= "none" and A.PreviewTickSound then pcall(A.PreviewTickSound, v) end
                if A.CastBarPreviewOn then pcall(A.CastBarPreviewOn) end
            end, y, soundLabels)
        y = y - 50
    end
    do
        local flashKeys = {}
        local flashLabels = {}
        for _, e in ipairs(A.TICK_FLASH_EFFECTS) do
            flashKeys[#flashKeys + 1] = e.key
            flashLabels[e.key] = e.label
        end
        MakeDropdown(content, "Tick flash:", flashKeys,
            function() return A.db.castBar.tickFlash or "green" end,
            function(v)
                A.db.castBar.tickFlash = v
                if v ~= "none" and A.PreviewTickFlash then pcall(A.PreviewTickFlash, v) end
                if A.CastBarPreviewOn then pcall(A.CastBarPreviewOn) end
            end, y, flashLabels)
        y = y - 50
    end

    -- Mind Flay tick visuals

    local tickLabels = { all = "All ticks", second = "Second tick only" }
    MakeCycleButton(content, "Mind Flay tick mode:", { "all", "second" },
        function() return (A.db.castBar and A.db.castBar.tickMarkers) or "all" end,
        function(v)
            if not A.db.castBar then A.db.castBar = {} end
            A.db.castBar.tickMarkers = v
            if A.CastBarPreviewOn then pcall(A.CastBarPreviewOn) end
        end, y, tickLabels)
    y = y - 30

    -- ============ DoT Tracker ============
    -- DoT Tracker visuals moved to Visuals window; keep enable checkbox here
    MakeSectionHeader(content, "DoT Tracker", y); y = y - 22
    local dotContainer, dotCB = MakeCheckbox(content, "Enable DoT tracker  (reload)",
        function() return A.db.dotTracker.enabled end,
        function(v) A.db.dotTracker.enabled = v end, y)
    y = y - 26

    -- DoT Tracker visuals moved to Visuals window; main panel keeps only the enable checkbox

    -- ============ Rotation Advisor ============
    MakeSectionHeader(content, "Rotation Advisor", y); y = y - 22

    local rotContainer, rotCB = MakeCheckbox(content, "Enable rotation advisor  (reload)",
        function() return A.db.rotation.enabled end,
        function(v) A.db.rotation.enabled = v end, y)
    y = y - 26

    -- Inner Focus
    MakeHeader(content, "Inner Focus", y); y = y - 22
    MakeCheckbox(content, "Enable Inner Focus suggestion",
        function() return (A.db.rotation and A.db.rotation.ifInsert and A.db.rotation.ifInsert.enabled) end,
        function(v) if not A.db.rotation then A.db.rotation = {} end; if not A.db.rotation.ifInsert then A.db.rotation.ifInsert = {} end; A.db.rotation.ifInsert.enabled = v end, y)
    y = y - 26
    -- Suggest before dropdown (MB / SWP / DP when available)
    do
        local opts = { "MB", "SWP" }
        if A.KnowsSpell and A.KnowsSpell(A.SPELLS.DP.id) then opts[#opts + 1] = "DP" end
        local labels = {}
        labels["MB"] = A.SPELLS.MB.name or "Mind Blast"
        labels["SWP"] = A.SPELLS.SWP.name or "Shadow Word: Pain"
        labels["DP"] = A.SPELLS.DP.name or "Devouring Plague"
        MakeDropdown(content, "Suggest before:", opts,
            function() return (A.db.rotation and A.db.rotation.ifInsert and A.db.rotation.ifInsert.before) or "MB" end,
            function(v) if not A.db.rotation then A.db.rotation = {} end; if not A.db.rotation.ifInsert then A.db.rotation.ifInsert = {} end; A.db.rotation.ifInsert.before = v end, y, labels)
        y = y - 50
    end
    MakeCheckbox(content, "Only for boss targets",
        function() return (A.db.rotation and A.db.rotation.ifInsert and A.db.rotation.ifInsert.onlyForBoss) end,
        function(v) if not A.db.rotation then A.db.rotation = {} end; if not A.db.rotation.ifInsert then A.db.rotation.ifInsert = {} end; A.db.rotation.ifInsert.onlyForBoss = v end, y)
    y = y - 28

    -- ============ Shadowfiend ============
    MakeHeader(content, "Shadowfiend", y); y = y - 22

    MakeSlider(content, "Suggest below mana %", 10, 80, 5,
        function() return A.db.sfManaThreshold or 35 end,
        function(v) A.db.sfManaThreshold = v end, y)
    y = y - 42

    -- ============ Mana Potion ============
    MakeHeader(content, "Mana Potion", y); y = y - 22

    local potContainer, potCB = MakeCheckbox(content, "Suggest Mana Potion",
        function() return A.db.suggestPot end,
        function(v) A.db.suggestPot = v end, y)
    y = y - 26

    local potThresh = MakeSlider(content, "Pot below mana %", 10, 90, 5,
        function() return A.db.potManaThreshold or 70 end,
        function(v) A.db.potManaThreshold = v end, y)
    y = y - 42

    local potEarlyCont, potEarlyCB = MakeCheckbox(content, "Allow early pot (prioritise before Shadowfiend)",
        function() return A.db.potEarly end,
        function(v) A.db.potEarly = v end, y)
    y = y - 28

    -- Potion selection dropdown (show counts)
    local potDropdown
    do
        local potOptions = { "none" }
        for _, id in ipairs(A.POTION_IDS or {}) do potOptions[#potOptions + 1] = id end
        local function potLabelFunc(opt)
            if opt == "none" then return "None" end
            local name = GetItemInfo(opt) or ("Item " .. opt)
            local cnt = GetItemCount(opt) or 0
            return (name or ("Item " .. opt)) .. " (" .. cnt .. ")"
        end
        potDropdown = MakeDropdown(content, "Track potion:", potOptions,
            function() return A.db.selectedPotionItem or "none" end,
            function(v) A.db.selectedPotionItem = v end, y, potLabelFunc)
        y = y - 50
    end

    do
        local potControls = { potThresh, potEarlyCont, potDropdown }
        local function UpdatePotGroup(enabled)
            for _, c in ipairs(potControls) do
                if c and c.SetAlpha then c:SetAlpha(enabled and 1 or 0.5) end
                if c and c.GetNumChildren and c.GetChildren then
                    local n = c:GetNumChildren()
                    if n and n > 0 then
                        for i = 1, n do
                            local child = select(i, c:GetChildren())
                            if child and type(child.EnableMouse) == "function" then child:EnableMouse(enabled) end
                        end
                    end
                end
            end
        end
        if potCB then
            potCB:SetScript("OnClick", function(self)
                A.db.suggestPot = self:GetChecked()
                UpdatePotGroup(self:GetChecked())
            end)
        end
        UpdatePotGroup(A.db.suggestPot)
    end

    -- ============ Dark / Demonic Rune ============
    MakeHeader(content, "Dark / Demonic Rune", y); y = y - 22

    MakeCheckbox(content, "Suggest Dark / Demonic Rune",
        function() return A.db.suggestRune end,
        function(v) A.db.suggestRune = v end, y)
    y = y - 26

    MakeSlider(content, "Rune below mana %", 10, 80, 5,
        function() return A.db.runeManaThreshold or 40 end,
        function(v) A.db.runeManaThreshold = v end, y)
    y = y - 42

    -- Rune selection dropdown (show counts)
    do
        local runeOptions = { "none", 20520, 12662 }
        local function runeLabelFunc(opt)
            if opt == "none" then return "None" end
            local name = GetItemInfo(opt) or ("Item " .. opt)
            local cnt = GetItemCount(opt) or 0
            return (name or ("Item " .. opt)) .. " (" .. cnt .. ")"
        end
        MakeDropdown(content, "Track rune:", runeOptions,
            function() return A.db.selectedRuneItem or "none" end,
            function(v) A.db.selectedRuneItem = v end, y, runeLabelFunc)
        y = y - 50
    end

    -- ============ Shadow Word: Death ============
    MakeHeader(content, "Shadow Word: Death", y); y = y - 22

    MakeCycleButton(content, "Open World:", { "always", "execute", "never" },
        function() return A.db.swdWorld or "always" end,
        function(v) A.db.swdWorld = v end, y)
    y = y - 30

    MakeCycleButton(content, "Dungeon:", { "always", "execute", "never" },
        function() return A.db.swdDungeon or "always" end,
        function(v) A.db.swdDungeon = v end, y)
    y = y - 30

    MakeCycleButton(content, "Raid:", { "always", "execute", "never" },
        function() return A.db.swdRaid or "execute" end,
        function(v) A.db.swdRaid = v end, y)
    y = y - 30

    -- SW:D safety margin: require predicted SW:D hit >= target HP * (1 + safetyPct/100)
    MakeSlider(content, "SW:D safety margin (%)", 0, 50, 1,
        function() return A.db.swdSafetyPct or 10 end,
        function(v) A.db.swdSafetyPct = v end, y)
    y = y - 42
    local swdNote = content:CreateFontString(nil, "OVERLAY")
    swdNote:SetFont("Fonts\\FRIZQT__.TTF", 9)
    swdNote:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
    swdNote:SetTextColor(0.7, 0.7, 0.7, 1)
    swdNote:SetText("Safety margin ensures SW:D is only suggested if predicted damage\nexceeds target HP by this percent (accounts for estimation error).")
    y = y - 36

    local note = content:CreateFontString(nil, "OVERLAY")
    note:SetFont("Fonts\\FRIZQT__.TTF", 9)
    note:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
    note:SetTextColor(0.6, 0.6, 0.6, 1)
    note:SetText("Items marked (reload) require /reload to take effect.")
    y = y - 20

    content:SetHeight(math.abs(y) + 20)
end

-- ====================================================================
-- Init
-- ====================================================================
function A:InitConfig()

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
                print("SPHelper: failed building options panel:", err)
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
                    print("SPHelper: failed building options (Refresh):", err)
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

            -- DoT Tracker visuals
            MakeSectionHeader(content, "DoT Tracker", yOff); yOff = yOff - 22
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

            -- DoT Tracker additional visuals: max targets, portrait side, and expiry warning mode
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

        

        else
            print("|cff8882d5SPHelper|r commands:")
            print("  /sph            — Open settings")
            print("  /sph lock       — Lock all frames")
            print("  /sph unlock     — Unlock frames for dragging")
            print("  /sph scale N    — Set UI scale (0.5-3.0)")
            print("  /sph swd MODE   — SW:D mode: always / execute / never")
            print("  /sph reset      — Reset all settings")
        end
    end
end
