------------------------------------------------------------------------
-- SPHelper  –  SpecUI.lua
-- Dynamic per-spec settings panel with 4 tabs:
--   1. General      – Auto-generated from spec.uiOptions
--   2. Rotation     – Entry editor with Move Up/Down/Add/Remove
--   3. Preview      – Live evaluator output against current target
--   4. Import/Export – Lua table serializer + validation on import
------------------------------------------------------------------------
local A = SPHelper

local SUI = {}
A.SpecUI = SUI

-- Fallback talent tree names (English) for cases where GetTalentTabInfo
-- returns nil or malformed values (some clients/locales may differ).
local CLASS_TALENT_FALLBACK = {
    DRUID  = { "Balance", "Feral", "Restoration" },
    PRIEST = { "Discipline", "Holy", "Shadow" },
    ROGUE  = { "Assassination", "Combat", "Subtlety" },
    WARRIOR= { "Arms", "Fury", "Protection" },
    PALADIN= { "Holy", "Protection", "Retribution" },
    HUNTER = { "Beast Mastery", "Marksmanship", "Survival" },
    SHAMAN = { "Elemental", "Enhancement", "Restoration" },
    MAGE   = { "Arcane", "Fire", "Frost" },
    WARLOCK= { "Affliction", "Demonology", "Destruction" },
}

local FRAME_W, FRAME_H = 680, 550
local TAB_H = 26
local FONT = "Fonts\\FRIZQT__.TTF"
local ROW_H = 22

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

-- Deep-copy a table (one level of nesting for rotation entries).
local function DeepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            out[k] = DeepCopy(v)
        else
            out[k] = v
        end
    end
    return out
end

-- Shallow serialize a Lua value to string (supports tables 2 levels).
local function Serialize(val, indent)
    indent = indent or ""
    if type(val) == "string" then
        return string.format("%q", val)
    elseif type(val) == "number" or type(val) == "boolean" then
        return tostring(val)
    elseif type(val) == "table" then
        local parts = {}
        local isArray = (#val > 0)
        local inner = indent .. "    "
        if isArray then
            for i, v in ipairs(val) do
                parts[#parts + 1] = inner .. Serialize(v, inner)
            end
        else
            local keys = {}
            for k in pairs(val) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b)
                if type(a) == type(b) then return tostring(a) < tostring(b) end
                return type(a) < type(b)
            end)
            for _, k in ipairs(keys) do
                if type(k) == "string" and k:match("^[%a_][%w_]*$") then

            -- Build options export (customOptions + deletedOptions + overridden values)
                    parts[#parts + 1] = inner .. "[" .. Serialize(k) .. "] = " .. Serialize(val[k], inner)
                end
            end
        end
        if #parts == 0 then return "{}" end
        return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. indent .. "}"
    end
    return "nil"
end

-- Safe deserialize via loadstring.  Returns table or nil, err.
local function Deserialize(str)
    if type(str) ~= "string" or str == "" then
        return nil, "empty input"
    end
    -- Wrap in return if not already
    local code = str
    if not code:match("^%s*return%s") then
        code = "return " .. code
    end
    -- Sandbox: only allow table/string/number/boolean literals
    local fn, loadErr = loadstring(code)
    if not fn then return nil, "syntax error: " .. tostring(loadErr) end
    -- Execute in empty environment to prevent access to globals
    setfenv(fn, {})
    local ok, result = pcall(fn)
    if not ok then return nil, "runtime error: " .. tostring(result) end
    if type(result) ~= "table" then return nil, "expected a table" end
    return result
end

------------------------------------------------------------------------
-- Widget builders (local, similar to Config.lua but scoped here)
------------------------------------------------------------------------

local suiDropdownCounter = 0

local function SUICheckbox(parent, label, get, set, x, y)
    local cb = CreateFrame("CheckButton", nil, parent)
    cb:SetSize(20, 20)
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
    cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
    cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    cb:SetChecked(get())
    cb:SetScript("OnClick", function(self) set(self:GetChecked()) end)
    local lbl = parent:CreateFontString(nil, "OVERLAY")
    lbl:SetFont(FONT, 10)
    lbl:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    lbl:SetText(label)
    lbl:SetTextColor(1, 1, 1, 1)
    return cb, lbl
end

local function SUISlider(parent, label, min, max, step, get, set, x, y)
    local lbl = parent:CreateFontString(nil, "OVERLAY")
    lbl:SetFont(FONT, 10)
    lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    lbl:SetTextColor(1, 0.82, 0, 1)

    local s = CreateFrame("Slider", nil, parent, "BackdropTemplate")
    s:SetSize(180, 14)
    s:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - 14)
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
    s:SetScript("OnValueChanged", function(self, val)
        val = math.floor(val / step + 0.5) * step
        set(val)
        lbl:SetText(label .. ": " .. val)
    end)
    return s, lbl
end

local function SUIDropdown(parent, label, options, get, set, x, y)
    suiDropdownCounter = suiDropdownCounter + 1
    local globalName = "SPHSpecUIDD" .. suiDropdownCounter

    local lbl = parent:CreateFontString(nil, "OVERLAY")
    lbl:SetFont(FONT, 10, "OUTLINE")
    lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    lbl:SetText(label)
    lbl:SetTextColor(1, 0.82, 0, 1)

    local dd = CreateFrame("Frame", globalName, parent, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", -16, -2)
    -- Auto-size the visible width to fit the longest option label so values
    -- like "boss_dungeon_raid" or "Always (Aggressive)" aren't clipped.
    -- Uses a hidden FontString to measure pixel width in the same font the
    -- dropdown text uses (GameFontHighlightSmall is what UIDropDownMenu_SetText draws).
    local function MeasureWidth(text)
        local probe = parent._sphDDProbe
        if not probe then
            probe = parent:CreateFontString(nil, "BACKGROUND", "GameFontHighlightSmall")
            probe:Hide()
            parent._sphDDProbe = probe
        end
        probe:SetText(tostring(text or ""))
        return probe:GetStringWidth() or 0
    end
    local maxTextWidth = MeasureWidth(get())
    for _, opt in ipairs(options or {}) do
        local w = MeasureWidth(opt)
        if w > maxTextWidth then maxTextWidth = w end
    end
    -- 24px padding accounts for the dropdown's left/right edges + the arrow button.
    local ddWidth = math.max(80, math.min(260, math.ceil(maxTextWidth) + 24))
    UIDropDownMenu_SetWidth(dd, ddWidth)
    UIDropDownMenu_SetText(dd, tostring(get()))
    UIDropDownMenu_Initialize(dd, function(self, level)
        for _, opt in ipairs(options) do
            local info = UIDropDownMenu_CreateInfo()
            info.text    = tostring(opt)
            info.value   = opt
            info.func    = function(self2)
                set(self2.value)
                UIDropDownMenu_SetText(dd, tostring(self2.value))
                CloseDropDownMenus()
            end
            info.checked = (opt == get())
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    return dd, lbl
end

local scrollMenuCounter = 0
local activeScrollMenu = nil

-- Close the active scroll menu, if any.
local function CloseActiveScrollMenu()
    if activeScrollMenu then
        activeScrollMenu:Hide()
        activeScrollMenu = nil
    end
end

--[[
  OpenScrollableListMenu(anchor, title, items, onSelect, selectedValue)
  Opens a scrollable, searchable picker anchored to `anchor`.
  - Items are sorted alphabetically by text.
  - A search box at the top filters the list as you type.
  - Press Enter to select the first visible item; Escape to close.
  - Clicking the same anchor again closes the menu (toggle).
  - Smart positioning: opens below the anchor by default; flips above
    if there is not enough room below.
--]]
local function OpenScrollableListMenu(anchor, title, items, onSelect, selectedValue)
    -- Toggle: clicking the same button again closes the menu.
    if activeScrollMenu and activeScrollMenu._anchor == anchor then
        CloseActiveScrollMenu()
        return
    end
    CloseActiveScrollMenu()

    -- Sort items alphabetically by display text.
    local sortedItems = {}
    for _, item in ipairs(items) do
        sortedItems[#sortedItems + 1] = item
    end
    table.sort(sortedItems, function(a, b)
        return tostring(a.text or a.value or "") < tostring(b.text or b.value or "")
    end)

    scrollMenuCounter = scrollMenuCounter + 1
    local frame = CreateFrame("Frame", "SPHScrollMenu" .. scrollMenuCounter, UIParent, "BackdropTemplate")
    activeScrollMenu = frame
    frame._anchor = anchor

    -- Use TOOLTIP strata so the menu is always above every other frame,
    -- including the condition editor (FULLSCREEN_DIALOG).
    frame:SetFrameStrata("TOOLTIP")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)

    local rowHeight  = 18
    local maxVisible = 14
    local titleH     = 22
    local searchH    = 24
    local visibleRows = math.min(#sortedItems, maxVisible)
    local menuW  = 320
    local menuH  = titleH + searchH + (visibleRows * rowHeight) + 8
    frame:SetSize(menuW, menuH)

    -- Smart positioning: prefer below anchor, flip above if near bottom.
    local function PositionMenu()
        frame:ClearAllPoints()
        local anchorBottom = anchor:GetBottom() or 0
        if anchorBottom - menuH < 20 then
            -- Not enough room below: open above the anchor.
            frame:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 2)
        else
            frame:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
        end
    end
    PositionMenu()

    A.CreateBackdrop(frame, 0.06, 0.06, 0.10, 0.98, 0.40, 0.40, 0.50, 1)

    -- ── Title row ──────────────────────────────────────────────────
    local titleFs = frame:CreateFontString(nil, "OVERLAY")
    titleFs:SetFont(FONT, 10, "OUTLINE")
    titleFs:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -5)
    titleFs:SetTextColor(1, 0.82, 0, 1)
    titleFs:SetText(title or "Select")

    local closeBtn = CreateFrame("Button", nil, frame, "BackdropTemplate")
    closeBtn:SetSize(16, 16)
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -3)
    A.CreateBackdrop(closeBtn, 0.35, 0.1, 0.1, 0.95, 0.6, 0.2, 0.2, 1)
    local closeLbl = closeBtn:CreateFontString(nil, "OVERLAY")
    closeLbl:SetFont(FONT, 9, "OUTLINE"); closeLbl:SetPoint("CENTER"); closeLbl:SetText("x")
    closeBtn:SetScript("OnClick", function() frame:Hide() end)

    -- ── Search box ─────────────────────────────────────────────────
    local searchEB = CreateFrame("EditBox", nil, frame, "BackdropTemplate")
    searchEB:SetSize(menuW - 12, 20)
    searchEB:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -(titleH))
    searchEB:SetFont(FONT, 9, "")
    searchEB:SetAutoFocus(false)
    searchEB:SetTextColor(1, 1, 1, 1)
    searchEB:SetTextInsets(6, 6, 0, 0)
    A.CreateBackdrop(searchEB, 0.04, 0.04, 0.08, 0.95, 0.25, 0.25, 0.35, 1)

    local placeholder = searchEB:CreateFontString(nil, "OVERLAY")
    placeholder:SetFont(FONT, 9, "")
    placeholder:SetTextColor(0.4, 0.4, 0.5, 1)
    placeholder:SetPoint("LEFT", searchEB, "LEFT", 6, 0)
    placeholder:SetText("Search…")

    searchEB:SetScript("OnEscapePressed", function() frame:Hide() end)

    -- ── Scroll area — plain ScrollFrame (no template) ──────────────
    -- Leave 10px on the right for the thumb track.
    local THUMB_W = 10
    local sf = CreateFrame("ScrollFrame", nil, frame)
    sf:SetPoint("TOPLEFT",     frame, "TOPLEFT",     6,            -(titleH + searchH))
    sf:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -(THUMB_W+4), 4)
    sf:EnableMouseWheel(true)

    local function DoScroll(delta)
        local step = rowHeight * 3
        local cur  = sf:GetVerticalScroll()
        sf:SetVerticalScroll(math.max(0, math.min(cur - delta * step, sf:GetVerticalScrollRange())))
    end
    sf:SetScript("OnMouseWheel", function(_, delta) DoScroll(delta) end)

    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(sf:GetWidth() or (menuW - THUMB_W - 10))
    sf:SetScrollChild(content)

    -- Bubble wheel events from the content + buttons up to sf.
    content:EnableMouseWheel(true)
    content:SetScript("OnMouseWheel", function(_, delta) DoScroll(delta) end)

    -- ── Thumb scrollbar (visual only, not draggable for simplicity) ─
    local trackBG = frame:CreateTexture(nil, "ARTWORK")
    trackBG:SetColorTexture(0.08, 0.08, 0.12, 0.9)
    trackBG:SetWidth(THUMB_W)
    trackBG:SetPoint("TOPRIGHT",    frame, "TOPRIGHT",    -2, -(titleH + searchH + 2))
    trackBG:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 4)

    local thumb = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    thumb:SetWidth(THUMB_W - 2)
    thumb:Hide()
    A.CreateBackdrop(thumb, 0.45, 0.45, 0.55, 0.95, 0.55, 0.55, 0.65, 1)

    local function UpdateThumb()
        local range = sf:GetVerticalScrollRange()
        if not range or range <= 0 then thumb:Hide(); return end
        local sfH      = sf:GetHeight()
        local contH    = content:GetHeight()
        if not sfH or sfH <= 0 or not contH or contH <= 0 then thumb:Hide(); return end
        local trackH   = sfH
        local thumbH   = math.max(16, sfH / contH * trackH)
        local scroll   = sf:GetVerticalScroll()
        local maxScroll = range
        local thumbTop = (scroll / maxScroll) * (trackH - thumbH)
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -(titleH + searchH + 2 + thumbTop))
        thumb:Show()
    end

    sf:SetScript("OnVerticalScroll", function() UpdateThumb() end)
    sf:SetScript("OnSizeChanged",    function() UpdateThumb() end)

    -- ── Pre-build all rows ─────────────────────────────────────────
    local rowBtns = {}
    for _, item in ipairs(sortedItems) do
        local btn = CreateFrame("Button", nil, content)
        btn:SetSize(menuW - 48, rowHeight)

        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        if item.value == selectedValue then
            bg:SetColorTexture(0.18, 0.28, 0.42, 0.95)
        else
            bg:SetColorTexture(0.10, 0.10, 0.14, 0.92)
        end

        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.10)

        local txt = btn:CreateFontString(nil, "OVERLAY")
        txt:SetFont(FONT, 9, "")
        txt:SetPoint("LEFT",  btn, "LEFT",  6, 0)
        txt:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
        txt:SetJustifyH("LEFT")
        txt:SetText(tostring(item.text or item.value or ""))

        btn:SetScript("OnClick", function()
            if onSelect then onSelect(item.value) end
            frame:Hide()
        end)

        -- Bubble mouse wheel from each row button up to the scroll frame.
        btn:EnableMouseWheel(true)
        btn:SetScript("OnMouseWheel", function(_, delta) DoScroll(delta) end)

        if item.tooltipText then
            btn:SetScript("OnEnter", function(self2)
                GameTooltip:SetOwner(self2, "ANCHOR_RIGHT")
                GameTooltip:SetText(item.tooltipTitle or tostring(item.text or item.value or ""))
                GameTooltip:AddLine(item.tooltipText, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end

        rowBtns[#rowBtns + 1] = { btn = btn, item = item }
    end

    -- ── Filter + layout ────────────────────────────────────────────
    local function RefreshList(filter)
        filter = filter and filter:lower() or ""
        local visY = 0
        for _, row in ipairs(rowBtns) do
            local itemText = tostring(row.item.text or row.item.value or ""):lower()
            if filter == "" or itemText:find(filter, 1, true) then
                row.btn:ClearAllPoints()
                row.btn:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -visY)
                row.btn:Show()
                visY = visY + rowHeight
            else
                row.btn:Hide()
            end
        end
        content:SetHeight(math.max(visY, rowHeight))
        sf:SetVerticalScroll(0)
        UpdateThumb()
    end
    RefreshList("")

    searchEB:SetScript("OnTextChanged", function(self)
        local txt = self:GetText()
        placeholder:SetShown(txt == "")
        RefreshList(txt)
    end)

    -- Enter: pick first visible row
    searchEB:SetScript("OnEnterPressed", function()
        for _, row in ipairs(rowBtns) do
            if row.btn:IsShown() then
                if onSelect then onSelect(row.item.value) end
                frame:Hide()
                return
            end
        end
    end)

    frame:SetScript("OnHide", function(self)
        GameTooltip:Hide()
        if activeScrollMenu == self then
            activeScrollMenu = nil
        end
    end)

    -- Focus search box so the user can type immediately.
    searchEB:SetFocus()

    return frame
end

local function SUIButton(parent, text, w, h, onClick, x, y)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(w or 80, h or 20)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    A.CreateBackdrop(btn, 0.18, 0.18, 0.18, 0.95, 0.35, 0.35, 0.35, 1)
    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    local lbl = btn:CreateFontString(nil, "OVERLAY")
    lbl:SetFont(FONT, 9, "OUTLINE")
    lbl:SetPoint("CENTER")
    lbl:SetText(text)
    btn:SetScript("OnClick", onClick)
    btn._label = lbl
    return btn
end

local function TickSelectionContains(selection, tickNum)
    if type(selection) ~= "table" or #selection == 0 then return false end
    for _, value in ipairs(selection) do
        if tonumber(value) == tickNum then
            return true
        end
    end
    return false
end

local function TickSelectionChecked(selection, tickNum, defaultAll)
    if type(selection) ~= "table" or #selection == 0 then
        return defaultAll ~= false
    end
    return TickSelectionContains(selection, tickNum)
end

local function BuildTickSelector(parent, label, x, y, tickCount, getSelection, setSelection, defaultAll)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(360, 22)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

    local lbl = row:CreateFontString(nil, "OVERLAY")
    lbl:SetFont(FONT, 9, "OUTLINE")
    lbl:SetPoint("LEFT", row, "LEFT", 0, 0)
    lbl:SetText(label)
    lbl:SetTextColor(1, 0.82, 0, 1)

    row._tickBoxes = {}
    local startX = 118
    local function ReadSelection()
        local selected = {}
        for i, cb in ipairs(row._tickBoxes) do
            if cb:GetChecked() then
                selected[#selected + 1] = i
            end
        end
        if defaultAll and #selected == tickCount then
            return {}
        end
        return selected
    end

    for i = 1, tickCount do
        local cb = CreateFrame("CheckButton", nil, row)
        cb:SetSize(18, 18)
        cb:SetPoint("LEFT", row, "LEFT", startX + (i - 1) * 40, 0)
        cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
        cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
        cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        cb:SetChecked(TickSelectionChecked(getSelection() or {}, i, defaultAll))

        local num = row:CreateFontString(nil, "OVERLAY")
        num:SetFont(FONT, 8, "OUTLINE")
        num:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        num:SetText(tostring(i))

        cb:SetScript("OnClick", function()
            setSelection(ReadSelection())
        end)
        row._tickBoxes[i] = cb
    end

    row.Refresh = function()
        local selection = getSelection() or {}
        for i, cb in ipairs(row._tickBoxes) do
            cb:SetChecked(TickSelectionChecked(selection, i, defaultAll))
        end
    end
    return row, 22
end

------------------------------------------------------------------------
-- Tab system
------------------------------------------------------------------------

local function CreateTabButton(parent, text, idx, onClick, tabWidth, tabSpacing)
    tabWidth = tabWidth or 110
    tabSpacing = tabSpacing or (tabWidth + 4)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(tabWidth, TAB_H)
    btn:SetPoint("BOTTOMLEFT", parent, "TOPLEFT", (idx - 1) * tabSpacing + 4, -1)
    A.CreateBackdrop(btn, 0.12, 0.12, 0.12, 0.95, 0.3, 0.3, 0.3, 1)
    local lbl = btn:CreateFontString(nil, "OVERLAY")
    lbl:SetFont(FONT, 10, "OUTLINE")
    lbl:SetPoint("CENTER")
    lbl:SetText(text)
    btn._label = lbl
    btn._idx   = idx
    btn:SetScript("OnClick", function(self) onClick(idx) end)
    return btn
end

local function SetTabActive(tabs, idx)
    for _, t in ipairs(tabs) do
        if t._idx == idx then
            t:SetBackdropColor(0.20, 0.18, 0.30, 1)
            t._label:SetTextColor(1, 0.85, 0.4, 1)
        else
            t:SetBackdropColor(0.10, 0.10, 0.10, 0.9)
            t._label:SetTextColor(0.6, 0.6, 0.6, 1)
        end
    end
end

------------------------------------------------------------------------
-- Custom config option creator modal
------------------------------------------------------------------------

local configCreatorFrame = nil
local ccState = {}  -- mutable state for specID/onSave/selectedType

local function OpenConfigCreator(specID, onSave)
    ccState.specID = specID
    ccState.onSave = onSave
    ccState.selectedType = "checkbox"

    if configCreatorFrame then
        -- Reset fields on re-open
        if ccState.keyEB   then ccState.keyEB:SetText("") end
        if ccState.lblEB   then ccState.lblEB:SetText("") end
        if ccState.defEB   then ccState.defEB:SetText("true") end
        if ccState.minEB   then ccState.minEB:SetText("0") end
        if ccState.maxEB   then ccState.maxEB:SetText("100") end
        if ccState.stepEB  then ccState.stepEB:SetText("5") end
        if ccState.valEB   then ccState.valEB:SetText("") end
        if ccState.statusLbl then ccState.statusLbl:SetText("") end
        if ccState.typeDD  then UIDropDownMenu_SetText(ccState.typeDD, "checkbox") end
        if ccState.defDD   then UIDropDownMenu_SetText(ccState.defDD, "true") end
        if ccState.updateVisibility then ccState.updateVisibility() end
        configCreatorFrame:Show()
        return
    end

    local f = CreateFrame("Frame", "SPHConfigCreator", UIParent, "BackdropTemplate")
    f:SetSize(320, 310)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    A.CreateBackdrop(f, 0.12, 0.10, 0.18, 0.98, 0.3, 0.25, 0.4, 1)
    configCreatorFrame = f

    local title = f:CreateFontString(nil, "OVERLAY")
    title:SetFont(FONT, 11, "OUTLINE")
    title:SetPoint("TOP", f, "TOP", 0, -8)
    title:SetText("|cff8882d5Create Config Option|r")

    local ly = -28

    -- Quick templates
    local tmplLbl = f:CreateFontString(nil, "OVERLAY")
    tmplLbl:SetFont(FONT, 8); tmplLbl:SetPoint("TOPLEFT", f, "TOPLEFT", 16, ly)
    tmplLbl:SetText("Templates:"); tmplLbl:SetTextColor(0.6, 0.6, 0.6)
    local templates = {
        { btn = "Toggle",   key = "use_spell",      label = "Use Spell",       tpe = "checkbox", def = "true" },
        { btn = "Mana %",   key = "mana_threshold", label = "Mana Threshold",  tpe = "slider",   def = "20", min = "0", max = "100", step = "5" },
        { btn = "Mode",     key = "content_mode",   label = "Content Mode",    tpe = "dropdown",  def = "always", vals = "always,boss,never" },
    }
    local tbx = 70
    for _, t in ipairs(templates) do
        SUIButton(f, t.btn, 60, 16, function()
            ccState.selectedType = t.tpe
            if ccState.typeDD then UIDropDownMenu_SetText(ccState.typeDD, t.tpe) end
            if ccState.keyEB  then ccState.keyEB:SetText(t.key or "") end
            if ccState.lblEB  then ccState.lblEB:SetText(t.label or "") end
            if ccState.defEB  then ccState.defEB:SetText(t.def or "true") end
            if ccState.defDD  then UIDropDownMenu_SetText(ccState.defDD, t.def or "true") end
            if ccState.minEB  then ccState.minEB:SetText(t.min or "0") end
            if ccState.maxEB  then ccState.maxEB:SetText(t.max or "100") end
            if ccState.stepEB then ccState.stepEB:SetText(t.step or "5") end
            if ccState.valEB  then ccState.valEB:SetText(t.vals or "") end
            if ccState.updateVisibility then ccState.updateVisibility() end
        end, tbx, ly)
        tbx = tbx + 66
    end
    ly = ly - 22

    -- Key
    local keyLbl = f:CreateFontString(nil, "OVERLAY")
    keyLbl:SetFont(FONT, 9); keyLbl:SetPoint("TOPLEFT", f, "TOPLEFT", 16, ly)
    keyLbl:SetText("Key:"); keyLbl:SetTextColor(1, 0.82, 0)
    local keyEB = CreateFrame("EditBox", nil, f, "BackdropTemplate")
    keyEB:SetSize(180, 18); keyEB:SetPoint("LEFT", keyLbl, "RIGHT", 8, 0)
    keyEB:SetFont(FONT, 9, ""); keyEB:SetAutoFocus(false)
    A.CreateBackdrop(keyEB, 0.1, 0.1, 0.1, 0.8, 0.3, 0.3, 0.3, 0.8)
    keyEB:SetTextInsets(4, 4, 0, 0)
    keyEB:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    ccState.keyEB = keyEB
    ly = ly - 24

    -- Label
    local lblLbl = f:CreateFontString(nil, "OVERLAY")
    lblLbl:SetFont(FONT, 9); lblLbl:SetPoint("TOPLEFT", f, "TOPLEFT", 16, ly)
    lblLbl:SetText("Label:"); lblLbl:SetTextColor(1, 0.82, 0)
    local lblEB = CreateFrame("EditBox", nil, f, "BackdropTemplate")
    lblEB:SetSize(180, 18); lblEB:SetPoint("LEFT", lblLbl, "RIGHT", 8, 0)
    lblEB:SetFont(FONT, 9, ""); lblEB:SetAutoFocus(false)
    A.CreateBackdrop(lblEB, 0.1, 0.1, 0.1, 0.8, 0.3, 0.3, 0.3, 0.8)
    lblEB:SetTextInsets(4, 4, 0, 0)
    lblEB:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    ccState.lblEB = lblEB
    ly = ly - 24

    -- Type dropdown
    local typeLbl = f:CreateFontString(nil, "OVERLAY")
    typeLbl:SetFont(FONT, 9); typeLbl:SetPoint("TOPLEFT", f, "TOPLEFT", 16, ly)
    typeLbl:SetText("Type:"); typeLbl:SetTextColor(1, 0.82, 0)
    suiDropdownCounter = suiDropdownCounter + 1
    local typeDD = CreateFrame("Frame", "SPHCCTypeDD" .. suiDropdownCounter, f, "UIDropDownMenuTemplate")
    typeDD:SetPoint("LEFT", typeLbl, "RIGHT", -12, -4)
    UIDropDownMenu_SetWidth(typeDD, 100)
    UIDropDownMenu_SetText(typeDD, "checkbox")
    UIDropDownMenu_Initialize(typeDD, function(self, level)
        for _, t in ipairs({"checkbox", "slider", "dropdown"}) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = t; info.value = t
            info.func = function(self2)
                ccState.selectedType = self2.value
                UIDropDownMenu_SetText(typeDD, self2.value)
                CloseDropDownMenus()
                if ccState.updateVisibility then ccState.updateVisibility() end
            end
            info.checked = (t == ccState.selectedType)
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    ccState.typeDD = typeDD
    ly = ly - 34

    -- Default (checkbox: true/false dropdown; slider: editbox; dropdown: editbox)
    local defLbl = f:CreateFontString(nil, "OVERLAY")
    defLbl:SetFont(FONT, 9); defLbl:SetPoint("TOPLEFT", f, "TOPLEFT", 16, ly)
    defLbl:SetText("Default:"); defLbl:SetTextColor(1, 0.82, 0)
    -- Text editbox for slider/dropdown defaults
    local defEB = CreateFrame("EditBox", nil, f, "BackdropTemplate")
    defEB:SetSize(130, 18); defEB:SetPoint("LEFT", defLbl, "RIGHT", 8, 0)
    defEB:SetFont(FONT, 9, ""); defEB:SetAutoFocus(false)
    A.CreateBackdrop(defEB, 0.1, 0.1, 0.1, 0.8, 0.3, 0.3, 0.3, 0.8)
    defEB:SetTextInsets(4, 4, 0, 0); defEB:SetText("true")
    defEB:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    ccState.defEB = defEB
    -- Dropdown for checkbox default (true/false)
    suiDropdownCounter = suiDropdownCounter + 1
    local defDD = CreateFrame("Frame", "SPHCCDefDD" .. suiDropdownCounter, f, "UIDropDownMenuTemplate")
    defDD:SetPoint("LEFT", defLbl, "RIGHT", -12, -4)
    UIDropDownMenu_SetWidth(defDD, 80)
    UIDropDownMenu_SetText(defDD, "true")
    UIDropDownMenu_Initialize(defDD, function(self, level)
        for _, v in ipairs({"true", "false"}) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = v; info.value = v
            info.func = function(self2)
                UIDropDownMenu_SetText(defDD, self2.value)
                ccState.defEB:SetText(self2.value)
                CloseDropDownMenus()
            end
            info.checked = (ccState.defEB:GetText() == v)
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    ccState.defDD = defDD
    ly = ly - 28

    -- Min / Max / Step (slider only)
    local minLbl = f:CreateFontString(nil, "OVERLAY")
    minLbl:SetFont(FONT, 9); minLbl:SetPoint("TOPLEFT", f, "TOPLEFT", 16, ly)
    minLbl:SetText("Min/Max/Step:"); minLbl:SetTextColor(0.7, 0.7, 0.7)
    local minEB = CreateFrame("EditBox", nil, f, "BackdropTemplate")
    minEB:SetSize(40, 18); minEB:SetPoint("LEFT", minLbl, "RIGHT", 4, 0)
    minEB:SetFont(FONT, 9, ""); minEB:SetAutoFocus(false)
    A.CreateBackdrop(minEB, 0.1, 0.1, 0.1, 0.8, 0.3, 0.3, 0.3, 0.8)
    minEB:SetTextInsets(4, 4, 0, 0); minEB:SetText("0")
    minEB:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    local maxEB = CreateFrame("EditBox", nil, f, "BackdropTemplate")
    maxEB:SetSize(40, 18); maxEB:SetPoint("LEFT", minEB, "RIGHT", 4, 0)
    maxEB:SetFont(FONT, 9, ""); maxEB:SetAutoFocus(false)
    A.CreateBackdrop(maxEB, 0.1, 0.1, 0.1, 0.8, 0.3, 0.3, 0.3, 0.8)
    maxEB:SetTextInsets(4, 4, 0, 0); maxEB:SetText("100")
    maxEB:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    local stepEB = CreateFrame("EditBox", nil, f, "BackdropTemplate")
    stepEB:SetSize(40, 18); stepEB:SetPoint("LEFT", maxEB, "RIGHT", 4, 0)
    stepEB:SetFont(FONT, 9, ""); stepEB:SetAutoFocus(false)
    A.CreateBackdrop(stepEB, 0.1, 0.1, 0.1, 0.8, 0.3, 0.3, 0.3, 0.8)
    stepEB:SetTextInsets(4, 4, 0, 0); stepEB:SetText("5")
    stepEB:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    ccState.minEB, ccState.maxEB, ccState.stepEB = minEB, maxEB, stepEB
    ly = ly - 24

    -- Values (dropdown only, comma-separated)
    local valLbl = f:CreateFontString(nil, "OVERLAY")
    valLbl:SetFont(FONT, 9); valLbl:SetPoint("TOPLEFT", f, "TOPLEFT", 16, ly)
    valLbl:SetText("Values (comma-sep):"); valLbl:SetTextColor(0.7, 0.7, 0.7)
    local valEB = CreateFrame("EditBox", nil, f, "BackdropTemplate")
    valEB:SetSize(160, 18); valEB:SetPoint("LEFT", valLbl, "RIGHT", 4, 0)
    valEB:SetFont(FONT, 9, ""); valEB:SetAutoFocus(false)
    A.CreateBackdrop(valEB, 0.1, 0.1, 0.1, 0.8, 0.3, 0.3, 0.3, 0.8)
    valEB:SetTextInsets(4, 4, 0, 0)
    valEB:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    ccState.valEB = valEB
    ly = ly - 28

    -- Visibility toggler: show/hide type-dependent fields
    ccState.updateVisibility = function()
        local tp = ccState.selectedType
        -- Checkbox: show defDD, hide defEB, hide slider/dropdown fields
        if tp == "checkbox" then
            defDD:Show(); defEB:Hide()
            minLbl:Hide(); minEB:Hide(); maxEB:Hide(); stepEB:Hide()
            valLbl:Hide(); valEB:Hide()
        elseif tp == "slider" then
            defDD:Hide(); defEB:Show()
            minLbl:Show(); minEB:Show(); maxEB:Show(); stepEB:Show()
            valLbl:Hide(); valEB:Hide()
        elseif tp == "dropdown" then
            defDD:Hide(); defEB:Show()
            minLbl:Hide(); minEB:Hide(); maxEB:Hide(); stepEB:Hide()
            valLbl:Show(); valEB:Show()
        end
    end
    ccState.updateVisibility()

    -- Status
    local statusLbl = f:CreateFontString(nil, "OVERLAY")
    statusLbl:SetFont(FONT, 9); statusLbl:SetPoint("TOPLEFT", f, "TOPLEFT", 16, ly)
    statusLbl:SetTextColor(0.7, 0.7, 0.7)
    ccState.statusLbl = statusLbl
    ly = ly - 20

    -- Save / Cancel
    SUIButton(f, "Save", 80, 22, function()
        local key = strtrim(keyEB:GetText())
        local label = strtrim(lblEB:GetText())
        if key == "" or label == "" then
            statusLbl:SetText("|cffff4444Key and Label are required.|r")
            return
        end
        -- Sanitize key: lowercase, underscores
        key = key:lower():gsub("%s+", "_"):gsub("[^%w_]", "")
        if key == "" then
            statusLbl:SetText("|cffff4444Invalid key (use letters/numbers/underscores).|r")
            return
        end
        local tp = ccState.selectedType
        local opt = { key = key, type = tp, label = label }
        if tp == "checkbox" then
            local dv = strtrim(defEB:GetText())
            opt.default = (dv == "true" or dv == "1")
        elseif tp == "slider" then
            opt.default = tonumber(defEB:GetText()) or 0
            opt.min = tonumber(minEB:GetText()) or 0
            opt.max = tonumber(maxEB:GetText()) or 100
            opt.step = tonumber(stepEB:GetText()) or 1
            if opt.min >= opt.max then
                statusLbl:SetText("|cffff4444Min must be less than Max.|r")
                return
            end
            if opt.step <= 0 then
                statusLbl:SetText("|cffff4444Step must be greater than 0.|r")
                return
            end
        elseif tp == "dropdown" then
            opt.default = strtrim(defEB:GetText())
            local vals = {}
            for v in valEB:GetText():gmatch("[^,]+") do
                vals[#vals + 1] = strtrim(v)
            end
            if #vals == 0 then
                statusLbl:SetText("|cffff4444Dropdown requires at least one value.|r")
                return
            end
            opt.values = vals
        end
        -- Store
        local sid = ccState.specID
        if not A.db.specs then A.db.specs = {} end
        if not A.db.specs[sid] then A.db.specs[sid] = {} end
        if not A.db.specs[sid].customOptions then A.db.specs[sid].customOptions = {} end
        A.db.specs[sid].customOptions[#A.db.specs[sid].customOptions + 1] = opt
        statusLbl:SetText("|cff00ff00Saved: " .. key .. "|r")
        if ccState.onSave then ccState.onSave() end
        f:Hide()
    end, 16, ly)

    SUIButton(f, "Cancel", 80, 22, function() f:Hide() end, 106, ly)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f)
    closeBtn:SetSize(20, 20)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
    local xl = closeBtn:CreateFontString(nil, "OVERLAY")
    xl:SetFont(FONT, 12, "OUTLINE"); xl:SetPoint("CENTER"); xl:SetText("X")
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    f:Show()
end

------------------------------------------------------------------------
-- Tab 1 – General (merged & fully configurable options)
------------------------------------------------------------------------

-- Check if optionKey is referenced in the current rotation entries
local function IsOptionKeyInUse(specID, optionKey)
    local entries = editorData
    if not entries then
        local sdb = A.db and A.db.specs and A.db.specs[specID]
        entries = sdb and sdb.rotation
    end
    if not entries then return false end
    for _, entry in ipairs(entries) do
        for _, cond in ipairs(entry.conditions or {}) do
            if (cond.type == "spec_option_enabled" or cond.type == "spec_option_value") and cond.optionKey == optionKey then
                return true
            end
        end
    end
    return false
end

------------------------------------------------------------------------
-- Collect all setting keys referenced inside a rotation's conditions.
-- This walks nested any_of/all_of/not groups recursively.
-- Returns a list of keys in first-encounter order (stable, no dupes).
------------------------------------------------------------------------
local function CollectRotationSettingKeys(rotation)
    local keys  = {}
    local seen  = {}
    local function Collect(cond)
        if type(cond) ~= "table" then return end
        -- Direct optionKey references (spec_option_enabled, setting_compare, etc.)
        if cond.optionKey and type(cond.optionKey) == "string" and not seen[cond.optionKey] then
            keys[#keys + 1] = cond.optionKey
            seen[cond.optionKey] = true
        end
        -- String values in numeric fields that refer to setting keys
        for _, f in ipairs({ "value", "pct", "seconds", "amount", "count", "points", "minTTD", "hp", "size", "safetyKey", "pctPerSec" }) do
            if type(cond[f]) == "string" and not seen[cond[f]] then
                keys[#keys + 1] = cond[f]
                seen[cond[f]] = true
            end
        end
        -- dbKey on content_mode_allow → generates per-content setting keys
        if cond.dbKey and type(cond.dbKey) == "string" then
            local prefix = cond.dbKey
            for _, suffix in ipairs({ "World", "Dungeon", "Raid" }) do
                local fk = prefix .. suffix
                if not seen[fk] then keys[#keys + 1] = fk; seen[fk] = true end
            end
        end
        -- Recurse into composite groups
        if cond.conditions then
            for _, sub in ipairs(cond.conditions) do Collect(sub) end
        end
        if cond.condition then Collect(cond.condition) end
    end
    for _, entry in ipairs(rotation or {}) do
        -- postCast.set references a setting key for the post-cast resource amount
        if entry.postCast and type(entry.postCast.set) == "string" and not seen[entry.postCast.set] then
            keys[#keys + 1] = entry.postCast.set
            seen[entry.postCast.set] = true
        end
        -- insertBeforeKey references a setting key whose value names the target spell
        if entry.insertBeforeKey and type(entry.insertBeforeKey) == "string" and not seen[entry.insertBeforeKey] then
            keys[#keys + 1] = entry.insertBeforeKey
            seen[entry.insertBeforeKey] = true
        end
        for _, cond in ipairs(entry.conditions or {}) do Collect(cond) end
    end
    return keys
end

-- Build the merged options list.
--
-- If the spec provides `settingDefs` (keyed dictionary), those are the
-- source of truth for labels, types, defaults, etc. Otherwise fall back
-- to the legacy `uiOptions` array.
--
-- **Rotation-referenced settings come first** (in rotation-encounter
-- order), then non-rotation settings, then DB custom options.
local function GetMergedOptions(spec, specID)
    local merged = {}
    local sdb    = A.db and A.db.specs and A.db.specs[specID]
    local deleted = sdb and sdb.deletedOptions or {}
    local seen   = {}

    local defs = spec.settingDefs  -- keyed dict or nil

    -- Helper: turn a settingDefs entry into the flat format RenderOption expects.
    local function DefToOpt(key, def)
        if not def then return nil end
        return {
            key     = key,
            type    = def.type or "checkbox",
            label   = def.label or key,
            default = def.default,
            min     = def.min,
            max     = def.max,
            step    = def.step,
            values  = def.values,
            tooltip = def.tooltip,
            _fromFile = true,
        }
    end

    -- Helper: add from defs or from legacy uiOptions
    local function AddKey(key)
        if seen[key] or deleted[key] then return end
        seen[key] = true
        if defs and defs[key] then
            merged[#merged + 1] = DefToOpt(key, defs[key])
        elseif spec.uiOptions then
            for _, opt in ipairs(spec.uiOptions) do
                if opt.key == key then
                    local copy = {}
                    for k, v in pairs(opt) do copy[k] = v end
                    copy._fromFile = true
                    merged[#merged + 1] = copy
                    return
                end
            end
        end
    end

    -- Phase 1: rotation-referenced settings (in encounter order).
    -- Priority: in-memory editor data (reflects unsaved deletions/additions)
    -- → DB-saved rotation.
    -- NOTE: spec.rotation (file default) is intentionally NOT used here so
    -- that deleting all rotation entries produces an empty General tab.
    local effectiveRotation =
        (editorData and editorSpecID == specID and editorData) or
        (sdb and sdb.rotation)
    local rotKeys = CollectRotationSettingKeys(effectiveRotation)
    for _, key in ipairs(rotKeys) do AddKey(key) end

    -- Phase 1.5: spec-declared extra General settings (settings read by
    -- engine logic rather than directly referenced in rotation conditions)
    if spec.generalSettings then
        for _, key in ipairs(spec.generalSettings) do AddKey(key) end
    end

    -- Phase 4: castBarOptions
    for _, opt in ipairs(spec.castBarOptions or {}) do
        if not deleted[opt.key] and not seen[opt.key] then
            seen[opt.key] = true
            local copy = {}
            for k, v in pairs(opt) do copy[k] = v end
            copy._fromFile = true
            copy._fromCastBar = true
            merged[#merged + 1] = copy
        end
    end

    -- Phase 5: DB custom options
    -- Skip any entry whose key is already defined in settingDefs — those were
    -- erroneously auto-created before Phase 10a knew about settingDefs.
    local customOpts = sdb and sdb.customOptions or {}
    for _, opt in ipairs(customOpts) do
        if not seen[opt.key] and not (defs and defs[opt.key]) then
            seen[opt.key] = true
            local copy = {}
            for k, v in pairs(opt) do copy[k] = v end
            copy._fromFile = false
            merged[#merged + 1] = copy
        end
    end

    return merged
end

local function BuildGeneralTab(container, spec)
    local y = -8
    local specID = spec.meta.id
    local sdb = A.db and A.db.specs and A.db.specs[specID]

    -- Informational header: settings are derived automatically from the rotation.
    local hdr = container:CreateFontString(nil, "OVERLAY")
    hdr:SetFont(FONT, 9, "")
    hdr:SetPoint("TOPLEFT", container, "TOPLEFT", 16, y)
    hdr:SetTextColor(0.6, 0.6, 0.6, 1)
    hdr:SetText("Settings are generated automatically from the Rotation tab.")
    y = y - 20

    local merged = GetMergedOptions(spec, specID)

    -- Render a single option with its control widget.
    local function RenderOption(opt, mergedIdx)
        local tooltip = opt.tooltip
        if opt.type == "checkbox" then
            local cb, lbl = SUICheckbox(container, opt.label,
                function() return A.SpecVal(opt.key, opt.default) end,
                function(v) A.SetSpecVal(opt.key, v) end,
                16, y)
            if tooltip and lbl then
                lbl:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(opt.label); GameTooltip:AddLine(tooltip, 1, 1, 1, true); GameTooltip:Show() end)
                lbl:SetScript("OnLeave", function() GameTooltip:Hide() end)
            end
            y = y - 26
        elseif opt.type == "slider" then
            local s, lbl = SUISlider(container, opt.label, opt.min or 0, opt.max or 100, opt.step or 1,
                function() return A.SpecVal(opt.key, opt.default) end,
                function(v) A.SetSpecVal(opt.key, v) end,
                16, y)
            if tooltip and lbl then
                lbl:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(opt.label); GameTooltip:AddLine(tooltip, 1, 1, 1, true); GameTooltip:Show() end)
                lbl:SetScript("OnLeave", function() GameTooltip:Hide() end)
            end
            y = y - 38
        elseif opt.type == "dropdown" then
            local dd, lbl = SUIDropdown(container, opt.label, opt.values or {},
                function() return A.SpecVal(opt.key, opt.default) end,
                function(v) A.SetSpecVal(opt.key, v) end,
                16, y)
            if tooltip and lbl then
                lbl:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(opt.label); GameTooltip:AddLine(tooltip, 1, 1, 1, true); GameTooltip:Show() end)
                lbl:SetScript("OnLeave", function() GameTooltip:Hide() end)
            end
            y = y - 50
        end
    end

    -- Render all merged options (skip castBar options — they live in tab 4)
    for i, opt in ipairs(merged) do
        if not opt._fromCastBar then
            RenderOption(opt, i)
        end
    end

    container:SetHeight(math.abs(y) + 20)
end

------------------------------------------------------------------------
-- Tab 2 – Rotation Editor
------------------------------------------------------------------------

-- Condition type metadata for UI
local COND_TYPES = {
    { type = "always",                     label = "Always",               fields = {} },
    { type = "cooldown_ready",             label = "Cooldown Ready",       fields = { "spellKey" } },
    { type = "dot_missing",                label = "DoT Missing",          fields = { "spellKey" } },
    { type = "projected_dot_time_left_lt", label = "DoT Proj < Seconds",   fields = { "spellKey", "seconds" } },
    { type = "dot_time_left_lt",           label = "DoT Rem < Seconds",    fields = { "spellKey", "seconds" } },
    { type = "resource_pct_lt",            label = "Resource % <",         fields = { "resource", "pct" } },
    { type = "resource_pct_gt",            label = "Resource % >",         fields = { "resource", "pct" } },
    { type = "item_ready_and_owned",       label = "Item Ready",           fields = { "itemId" } },
    { type = "content_mode_allow",         label = "Content Mode Allow",   fields = { "dbKey" } },
    { type = "not_recently_cast",          label = "Not Recently Cast",    fields = { "spellName", "window" } },
    { type = "target_valid",               label = "Target Valid",         fields = {} },
    { type = "not_debuff_on_target",       label = "Unit Missing Debuff",  fields = { "unit", "debuff", "debuffId" } },
    { type = "not_buff_on_player",         label = "Unit Missing Buff",    fields = { "unit", "buff", "buffId" } },
    { type = "spell_can_kill_target",      label = "Spell Can Kill Target", fields = { "spellKey", "safetyKey" } },
    { type = "threat_pct_lt",              label = "Threat % <",           fields = { "pct" } },
    { type = "threat_pct_ge",              label = "Threat % >=",          fields = { "pct" } },
    { type = "target_classification",      label = "Target Classification",fields = { "classification" } },
    { type = "option_gated_classification",label = "Option-Gated Class.",  fields = { "optionKey", "classification" } },
    { type = "buff_on_player",             label = "Unit Has Buff",        fields = { "unit", "buff", "buffId" } },
    { type = "buff_stacks_gte",            label = "Buff Stacks >=",       fields = { "buff", "stacks" } },
    { type = "target_hp_pct_lt",           label = "Target HP % <",        fields = { "pct" } },
    { type = "target_hp_pct_gt",           label = "Target HP % >",        fields = { "pct" } },
    { type = "player_hp_pct_lt",           label = "Player HP % <",        fields = { "pct" } },
    { type = "player_hp_pct_gt",           label = "Player HP % >",        fields = { "pct" } },
    { type = "spec_option_enabled",        label = "Spec Option Enabled",  fields = { "optionKey" } },
    { type = "spec_option_value",          label = "Spec Option = Value",  fields = { "optionKey", "value" } },
    { type = "in_combat",                  label = "In Combat",            fields = {} },
    { type = "precombat",                  label = "Pre-Combat",           fields = {} },
    { type = "channeling",                 label = "Is Channeling",        fields = {} },
    { type = "cooldown_lt",                label = "Cooldown < Seconds",   fields = { "spellKey", "seconds" } },
    { type = "spell_usable",               label = "Spell Ready",          fields = { "spellKey" } },
    { type = "group_size_gte",             label = "Group Size >=",         fields = { "size" } },
    -- Phase 9
    { type = "behind_target",              label = "Behind Target",         fields = {} },
    { type = "not_behind_target",          label = "Not Behind Target",    fields = {} },
    { type = "combo_points_gte",           label = "Combo Points >=",       fields = { "points" } },
    { type = "combo_points_lt",            label = "Combo Points <",        fields = { "points" } },
    { type = "debuff_on_target",           label = "Unit Has Debuff",       fields = { "unit", "debuff", "debuffId", "source" } },
    { type = "debuff_time_left_lt",        label = "Debuff Time < Seconds", fields = { "debuff", "seconds" } },
    { type = "target_dying_fast",          label = "Target Dying Fast",     fields = { "pctPerSec", "direction" } },
    { type = "target_ttd_gte",             label = "Target TTD >=",         fields = { "seconds" } },
    { type = "target_ttd_lt",              label = "Target TTD <",          fields = { "seconds" } },
    { type = "resource_gte",               label = "Resource >= Amount",    fields = { "amount" } },
    { type = "resource_lt",                label = "Resource < Amount",     fields = { "amount" } },
    { type = "other_targets_with_debuff_lt", label = "Other Targets Debuff <", fields = { "spellKey", "count", "seconds", "minTTD" } },
    { type = "item_ready_by_key",          label = "Item Ready (by Key)",   fields = { "itemKey" } },
    { type = "content_type",               label = "Content Type",          fields = { "contentType" } },
    { type = "state_compare",             label = "State Compare",         fields = { "subject", "resource", "unit", "op", "value", "minTTD" } },
    { type = "spell_property_compare",    label = "Spell Property Compare",fields = { "spellKey", "property", "op", "value" } },
    { type = "buff_property_compare",     label = "Buff Property Compare", fields = { "buff", "property", "op", "value" } },
    { type = "debuff_property_compare",   label = "Debuff Property Compare", fields = { "debuff", "source", "property", "op", "value" } },
    { type = "unit_cast_compare",         label = "Unit Cast Compare",     fields = { "unit", "op", "value" } },
    { type = "unit_interruptible",        label = "Unit Interruptible",    fields = { "unit" } },
    { type = "not_in_combat",              label = "Not In Combat",         fields = {} },
    { type = "any_of",                     label = "OR Group",             fields = {} },
    { type = "all_of",                     label = "AND Group",            fields = {} },
    { type = "not",                        label = "Not",                  fields = {} },
    -- Phase 10 additions
    { type = "player_mana_pct_lt",         label = "Player Mana % <",      fields = { "pct" } },
    { type = "player_mana_pct_gt",         label = "Player Mana % >",      fields = { "pct" } },
    { type = "player_base_mana_pct_lt",    label = "Player Base Mana % <", fields = { "pct" } },
    { type = "player_base_mana_pct_gt",    label = "Player Base Mana % >", fields = { "pct" } },
    { type = "target_hp_lt",               label = "Target HP <= Amount",   fields = { "hp" } },
    { type = "resource_required_gte",      label = "Resource Required >=",  fields = { "amount" } },
    { type = "resource_at_gcd_lt",         label = "Resource @ Ready <",    fields = { "amount" } },
    { type = "resource_at_gcd_gt",         label = "Resource @ Ready >",    fields = { "amount" } },
    { type = "next_power_tick_with_gcd_lt",label = "Next Tick @ Ready <",   fields = { "seconds" } },
    { type = "next_power_tick_with_gcd_gt",label = "Next Tick @ Ready >",   fields = { "seconds" } },
    { type = "setting_compare",            label = "Setting Compare",       fields = { "optionKey", "op", "value" } },
}

-- Fields that should render as dropdowns instead of free-text edit boxes
local function CollectSliderOptionKeys()
    local keys = {}
    local specID = A._activeSpecID
    local spec = specID and A.SpecManager and A.SpecManager:GetSpecByID(specID)
    if spec then
        -- New keyed settingDefs
        if spec.settingDefs then
            for key, def in pairs(spec.settingDefs) do
                if def.type == "slider" then
                    keys[#keys + 1] = key
                end
            end
        end
        -- Legacy uiOptions
        if spec.uiOptions then
            for _, opt in ipairs(spec.uiOptions) do
                if opt.type == "slider" then
                    keys[#keys + 1] = opt.key
                end
            end
        end
    end
    if A.db and A.db.specs and specID and A.db.specs[specID] and A.db.specs[specID].customOptions then
        for _, opt in ipairs(A.db.specs[specID].customOptions) do
            if opt.type == "slider" then
                keys[#keys + 1] = opt.key
            end
        end
    end
    -- Dedupe
    local seen = {}
    local deduped = {}
    for _, k in ipairs(keys) do
        if not seen[k] then seen[k] = true; deduped[#deduped + 1] = k end
    end
    table.sort(deduped)
    return deduped
end

local editorData = nil  -- array of rotation entries
local editorDirty = false
local editorSpecID = nil
local editorRefreshFn = nil  -- set by BuildRotationTab
local generalRefreshFn = nil  -- set when General tab (idx=1) is the active tab
local condEditorFrame = nil
local ceState = {}

local function GetEditorSpellClass()
    if ceState and ceState.spec and ceState.spec.meta and ceState.spec.meta.class then
        return ceState.spec.meta.class
    end
    if editorSpecID and A.SpecManager and A.SpecManager.GetSpecByID then
        local spec = A.SpecManager:GetSpecByID(editorSpecID)
        if spec and spec.meta and spec.meta.class then
            return spec.meta.class
        end
    end
    if A._activeSpecID and A.SpecManager and A.SpecManager.GetSpecByID then
        local spec = A.SpecManager:GetSpecByID(A._activeSpecID)
        if spec and spec.meta and spec.meta.class then
            return spec.meta.class
        end
    end
    local _, playerClass = UnitClass("player")
    return playerClass
end

local function NormalizeSpellValue(rawValue)
    if type(rawValue) ~= "string" then return rawValue end
    local def = A.GetSpellDefinition and A.GetSpellDefinition(rawValue)
    if def and def.name and def.name ~= "" then
        return def.name
    end
    return rawValue
end

local function GetSpellDropdownText(options, value)
    local normalizedValue = NormalizeSpellValue(value)
    for _, opt in ipairs(options or {}) do
        local optionValue = type(opt) == "table" and (opt.value or opt.key or opt.text) or opt
        if optionValue == value or optionValue == normalizedValue or NormalizeSpellValue(optionValue) == normalizedValue then
            return type(opt) == "table" and (opt.text or opt.name or opt.key or tostring(optionValue)) or tostring(optionValue)
        end
    end
    return tostring(value or "")
end

local FIELD_DROPDOWNS = {
    spellKey = function()
        local keys = {}
        local classFilter = GetEditorSpellClass()
        if A.SpellData and A.SpellData.GetSpellKeysForEditor then
            for _, spell in ipairs(A.SpellData:GetSpellKeysForEditor(classFilter) or {}) do
                if spell and spell.key then
                    local displayName = spell.resolvedName or spell.name or spell.key
                    keys[#keys + 1] = {
                        key = displayName,
                        text = displayName,
                        value = displayName,
                        class = spell.class,
                        resolvedName = spell.resolvedName,
                    }
                end
            end
        elseif A.SPELLS then
            for k in pairs(A.SPELLS) do
                if k ~= "CLEARCASTING" then
                    local spell = A.SPELLS[k]
                    local displayName = (spell and spell.label) or k
                    keys[#keys + 1] = {
                        key = displayName,
                        text = displayName,
                        value = displayName,
                        class = spell and spell.class,
                        resolvedName = spell and spell.name,
                    }
                end
            end
        end
        table.sort(keys, function(a, b)
            local at = type(a) == "table" and (a.text or a.key or a.value) or tostring(a)
            local bt = type(b) == "table" and (b.text or b.key or b.value) or tostring(b)
            return tostring(at) < tostring(bt)
        end)
        return keys
    end,
    resource = function()
        return { "mana", "hp", "energy", "rage", "focus" }
    end,
    subject = function()
        return {
            "resource_pct",
            "player_hp_pct",
            "player_hp",
            "target_hp_pct",
            "target_hp",
            "player_mana_pct",
            "player_base_mana_pct",
            "combo_points",
            "target_ttd",
            "resource",
            "resource_at_gcd",
            "next_power_tick_with_gcd",
            "threat_pct",
            "tracked_target_count",
            "tracked_targets_with_ttd",
            "channel_tick_interval",
            "channel_ticks_remaining",
            "channel_time_to_next_tick",
        }
    end,
    op = function()
        return { "<", "<=", ">", ">=", "==", "!=" }
    end,
    property = function(cond)
        if cond and cond.type == "spell_property_compare" then
            return { "time_to_ready", "cast_time", "travel_time", "dot_base_duration", "dot_tick_frequency", "channel_tick_interval" }
        end
        return { "remaining", "stacks" }
    end,
    unit = function()
        return { "player", "target", "focus", "mouseover" }
    end,
    source = function()
        return { "player", "any" }
    end,
    classification = function()
        return { "boss", "elite", "normal", "none" }
    end,
    optionKey = function()
        local keys = {}
        local seen = {}
        local specID = A._activeSpecID
        local spec = specID and A.SpecManager and A.SpecManager:GetSpecByID(specID)
        if spec then
            if spec.settingDefs then
                for key in pairs(spec.settingDefs) do
                    if not seen[key] then seen[key] = true; keys[#keys + 1] = key end
                end
            end
            if spec.uiOptions then
                for _, opt in ipairs(spec.uiOptions) do
                    if not seen[opt.key] then seen[opt.key] = true; keys[#keys + 1] = opt.key end
                end
            end
        end
        if A.db and A.db.specs and specID and A.db.specs[specID] and A.db.specs[specID].customOptions then
            for _, opt in ipairs(A.db.specs[specID].customOptions) do
                if not seen[opt.key] then seen[opt.key] = true; keys[#keys + 1] = opt.key end
            end
        end
        table.sort(keys)
        return keys
    end,
    buff = function()
        -- Common buffs/debuffs for Shadow Priest conditions, plus Feral form buffs.
        return { "Inner Focus", "Shadowform", "Power Word: Shield", "Power Word: Fortitude", "Shadow Weaving", "Cat Form", "Bear Form", "Dire Bear Form", "Tiger's Fury", "Prowl", "Clearcasting" }
    end,
    debuff = function()
        -- Common debuffs to check on target
        local names = {}
        local classFilter = GetEditorSpellClass()
        if A.SpellData and A.SpellData.GetSpellKeysForEditor then
            for _, spell in ipairs(A.SpellData:GetSpellKeysForEditor(classFilter) or {}) do
                if spell and spell.resolvedName then
                    names[#names + 1] = string.format("[%s] %s", spell.class or classFilter or "?", spell.resolvedName)
                end
            end
        elseif A.SPELLS then
            for _, v in pairs(A.SPELLS) do
                if v.name then names[#names + 1] = string.format("[%s] %s", v.class or classFilter or "?", v.name) end
            end
        end
        table.sort(names)
        return names
    end,
    dbKey = function()
        return { "swd", "mb", "mf", "vt", "swp", "dp" }
    end,
    direction = function()
        return { "faster", "slower" }
    end,
    contentType = function()
        return {
            { text = "Open World", value = "world" },
            { text = "Dungeon",    value = "dungeon" },
            { text = "Raid",       value = "raid" },
        }
    end,
    buffId = function() return nil end,
    debuffId = function() return nil end,
    safetyKey = function()
        -- Reuse the optionKey list so safetyKey can reference a spec setting.
        local keys = {}
        local seen = {}
        local specID = A._activeSpecID
        local spec = specID and A.SpecManager and A.SpecManager:GetSpecByID(specID)
        if spec then
            if spec.settingDefs then
                for key in pairs(spec.settingDefs) do
                    if not seen[key] then seen[key] = true; keys[#keys + 1] = key end
                end
            end
            if spec.uiOptions then
                for _, opt in ipairs(spec.uiOptions) do
                    if not seen[opt.key] then seen[opt.key] = true; keys[#keys + 1] = opt.key end
                end
            end
        end
        table.sort(keys)
        return #keys > 0 and keys or nil
    end,
    pct = function()
        -- Numeric literals + spec option keys that can be used as dynamic references
        return CollectSliderOptionKeys()
    end,
    count = function() return CollectSliderOptionKeys() end,
    minTTD = function() return CollectSliderOptionKeys() end,
    value = function(cond)
        local optionKey = cond and cond.optionKey
        if not optionKey then return nil end

        local specID = A._activeSpecID
        local spec = specID and A.SpecManager and A.SpecManager:GetSpecByID(specID)

        -- Check settingDefs first (keyed dictionary)
        if spec and spec.settingDefs and spec.settingDefs[optionKey] then
            local def = spec.settingDefs[optionKey]
            if def.type == "dropdown" and def.values and #def.values > 0 then
                return def.values
            end
            if def.type == "checkbox" then
                return { "true", "false" }
            end
        end

        local function CollectValues(options)
            for _, opt in ipairs(options or {}) do
                if opt.key == optionKey then
                    if opt.type == "dropdown" and opt.values and #opt.values > 0 then
                        return opt.values
                    end
                    if opt.type == "checkbox" then
                        return { "true", "false" }
                    end
                    return nil
                end
            end
            return nil
        end

        if spec then
            local values = CollectValues(spec.uiOptions)
            if values and #values > 0 then return values end
            values = CollectValues(spec.castBarOptions)
            if values and #values > 0 then return values end
        end

        local sdb = A.db and A.db.specs and specID and A.db.specs[specID]
        if sdb and sdb.customOptions then
            local values = CollectValues(sdb.customOptions)
            if values and #values > 0 then return values end
        end

        return nil
    end,
}

local function GetCondTypeIndex(typeName)
    for i, ct in ipairs(COND_TYPES) do
        if ct.type == typeName then return i end
    end
    return 1
end

local function GetCondTypeLabel(typeName)
    for _, ct in ipairs(COND_TYPES) do
        if ct.type == typeName then
            return ct.label
        end
    end
    return tostring(typeName or "Unknown")
end

local PREVIEW_FIELD_LABELS = {
    buffId        = "Buff ID",
    debuffId      = "Debuff ID",
    safetyKey     = "Safety %",
    spellKey      = "Spell",
    spellName     = "Spell Name",
    subject       = "Subject",
    property      = "Property",
    op            = "Op",
    unit          = "Unit",
    source        = "Source",
    optionKey     = "Option",
    resource      = "Resource",
    pct           = "Pct",
    seconds       = "Seconds",
    debuff        = "Debuff",
    buff          = "Buff",
    itemKey       = "Item",
    itemId        = "Item ID",
    dbKey         = "DB Key",
    classification= "Class",
    contentType   = "Content",
    direction     = "Direction",
    window        = "Window",
    size          = "Size",
    amount        = "Amount",
    points        = "Points",
    count         = "Count",
    pctPerSec     = "Pct/s",
    minTTD        = "Min TTD",
    hp            = "HP",
    value         = "Value",
}

local function ResolvePreviewValue(value, activeSpec)
    if type(value) == "function" then
        local db = nil
        if A.db and A.db.specs and activeSpec and activeSpec.meta and activeSpec.meta.id then
            db = A.db.specs[activeSpec.meta.id]
        end
        local ok, resolved = pcall(value, db)
        if ok and resolved ~= nil then
            return resolved
        end
        return tostring(value)
    end
    return value
end

local function FormatPreviewValue(field, value, activeSpec)
    value = ResolvePreviewValue(value, activeSpec)
    if field == "spellKey" then
        local spell = A.SPELLS and A.SPELLS[value]
        if spell and (spell.label or spell.name) then
            return spell.label or spell.name
        end
    end
    return tostring(value)
end

local function DescribeCondition(cond, activeSpec)
    if type(cond) ~= "table" then
        return "?"
    end

    -- Groups: (A OR B) / (A AND B) — no verbose type prefix.
    if cond.type == "any_of" or cond.type == "any" or cond.type == "or" then
        local parts = {}
        for _, subCond in ipairs(cond.conditions or {}) do
            parts[#parts + 1] = DescribeCondition(subCond, activeSpec)
        end
        if #parts == 0 then return "(empty OR)" end
        if #parts == 1 then return parts[1] end
        return "(" .. table.concat(parts, " OR ") .. ")"
    end

    if cond.type == "all_of" or cond.type == "all" or cond.type == "and" then
        local parts = {}
        for _, subCond in ipairs(cond.conditions or {}) do
            parts[#parts + 1] = DescribeCondition(subCond, activeSpec)
        end
        if #parts == 0 then return "(empty AND)" end
        if #parts == 1 then return parts[1] end
        return "(" .. table.concat(parts, " AND ") .. ")"
    end

    if cond.type == "not" then
        return "NOT " .. DescribeCondition(cond.condition or { type = "always" }, activeSpec)
    end

    -- setting_compare: "optionKey op value"  e.g. "swdWorld = execute"
    if cond.type == "setting_compare" then
        local opSym = cond.op or "="
        if opSym == "==" then opSym = "=" end
        return tostring(cond.optionKey or "?") .. " " .. opSym .. " "
               .. FormatPreviewValue("value", cond.value, activeSpec)
    end

    -- state_compare: "subject op value"  e.g. "player_mana_pct < sfManaThreshold"
    if cond.type == "state_compare" then
        local opSym = cond.op or "="
        if opSym == "==" then opSym = "=" end
        return tostring(cond.subject or "?") .. " " .. opSym .. " "
               .. FormatPreviewValue("value", cond.value, activeSpec)
    end

    -- content_type: "In open world" / "In dungeon" / "In raid"
    if cond.type == "content_type" then
        local ct = cond.contentType or "world"
        local display = (ct == "world") and "open world" or ct
        return "In " .. display
    end

    -- predicted_kill (legacy alias) and spell_can_kill_target
    if cond.type == "predicted_kill" then
        return "Predicted Kill"
    end
    if cond.type == "spell_can_kill_target" then
        local spellName = cond.spellKey or "spell"
        if A.SPELLS and A.SPELLS[spellName] then
            spellName = A.SPELLS[spellName].name or spellName
        end
        return spellName .. " can kill target"
    end

    -- buff_on_player / not_buff_on_player / debuff_on_target / not_debuff_on_target
    if cond.type == "buff_on_player" then
        local unit = cond.unit or "player"
        local name = cond.buff or (cond.buffId and ("ID:" .. tostring(cond.buffId))) or "?"
        if unit == "player" then
            return "Has " .. name
        end
        return unit .. " has " .. name
    end
    if cond.type == "not_buff_on_player" then
        local unit = cond.unit or "player"
        local name = cond.buff or (cond.buffId and ("ID:" .. tostring(cond.buffId))) or "?"
        if unit == "player" then
            return "Missing " .. name
        end
        return unit .. " missing " .. name
    end
    if cond.type == "debuff_on_target" then
        local unit = cond.unit or "target"
        local name = cond.debuff or (cond.debuffId and ("ID:" .. tostring(cond.debuffId))) or "?"
        if unit == "target" then
            return name .. " on target"
        end
        return name .. " on " .. unit
    end
    if cond.type == "not_debuff_on_target" then
        local unit = cond.unit or "target"
        local name = cond.debuff or (cond.debuffId and ("ID:" .. tostring(cond.debuffId))) or "?"
        if unit == "target" then
            return "No " .. name .. " on target"
        end
        return "No " .. name .. " on " .. unit
    end

    -- predicted_kill

    -- Generic fallback: label + key fields
    local label = GetCondTypeLabel(cond.type)
    local details = {}
    for _, field in ipairs({
        "spellKey", "spellName", "subject", "property", "op", "unit", "source",
        "optionKey", "resource", "pct", "seconds",
        "debuff", "buff", "itemKey", "itemId", "dbKey", "classification",
        "contentType", "direction", "window", "size", "amount", "points", "count", "pctPerSec",
        "minTTD",
        "hp", "value",
    }) do
        if cond[field] ~= nil then
            details[#details + 1] = string.format("%s=%s",
                PREVIEW_FIELD_LABELS[field] or field,
                FormatPreviewValue(field, cond[field], activeSpec))
        end
    end

    if #details == 0 then
        return label
    end
    return label .. " (" .. table.concat(details, ", ") .. ")"
end

local function InitEditorData(spec)
    editorSpecID = spec.meta.id
    -- Prefer DB override, else copy from spec file
    local src = (A.db.specs and A.db.specs[editorSpecID] and A.db.specs[editorSpecID].rotation)
                or spec.rotation
    editorData = DeepCopy(src) or {}
    -- Strip _fromFile from working copy
    editorData._fromFile = nil
    editorDirty = false
end
------------------------------------------------------------------------
-- Advanced Condition Editor Popup  (stack-based, recursive)
------------------------------------------------------------------------
local function RebuildCondEditor() end  -- forward declaration

-- Navigate the ceState.navStack to get the condition at the current depth.
-- navStack = {} means root (ceState.working.cond).
-- navStack = {3} means root is a group and we're editing subcondition 3.
-- navStack = {3, 2} means subcondition 3 is a group and we're in its child 2.
local function CE_ResolveCond(stack)
    local cond = ceState.working.cond
    for _, idx in ipairs(stack or {}) do
        -- Unwrap NOT wrappers to get to the group's conditions array
        local inner = cond
        if inner.type == "not" then inner = inner.condition end
        if inner and inner.conditions and inner.conditions[idx] then
            cond = inner.conditions[idx]
        else
            return cond  -- safety: bad index
        end
    end
    return cond
end

-- Get the parent condition and child index for the current nav level.
-- Returns nil, nil at root level.
local function CE_GetParentAndIndex()
    if #ceState.navStack == 0 then return nil, nil end
    local parentStack = {}
    for i = 1, #ceState.navStack - 1 do
        parentStack[i] = ceState.navStack[i]
    end
    local parent = CE_ResolveCond(parentStack)
    local inner = parent
    if inner.type == "not" then inner = inner.condition end
    return inner, ceState.navStack[#ceState.navStack]
end

-- Build a breadcrumb string for the current navigation path.
local function CE_Breadcrumb()
    local parts = { "Root" }
    local cond = ceState.working.cond
    for depth, idx in ipairs(ceState.navStack) do
        local inner = cond
        if inner.type == "not" then inner = inner.condition end
        if inner and inner.conditions and inner.conditions[idx] then
            cond = inner.conditions[idx]
            local label = GetCondTypeLabel(cond.type)
            parts[#parts + 1] = string.format("#%d %s", idx, label)
        end
    end
    return table.concat(parts, "  >  ")
end

-- Field editor row: label + scrollable picker (for lists) or edit box.
local function CEFieldEditor(parent, cond, field, x, y, onChanged)
    local flbl = parent:CreateFontString(nil, "OVERLAY")
    flbl:SetFont(FONT, 9)
    flbl:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    flbl:SetTextColor(0.8, 0.8, 0.8, 1)
    flbl:SetText((PREVIEW_FIELD_LABELS[field] or field) .. ":")

    local ddBuilder = FIELD_DROPDOWNS[field]
    local options = ddBuilder and ddBuilder(cond, field) or nil

    if ddBuilder and options and #options > 0 then
        -- Use a button that opens a scrollable picker (handles long lists)
        local currentText = GetSpellDropdownText(options, cond[field])
        local pickBtn = SUIButton(parent, currentText, 220, 16, nil, 0, 0)
        pickBtn:ClearAllPoints()
        pickBtn:SetPoint("LEFT", flbl, "RIGHT", 6, 0)
        pickBtn._label:SetJustifyH("LEFT")
        pickBtn._label:SetPoint("LEFT", pickBtn, "LEFT", 4, 0)
        pickBtn._label:SetPoint("RIGHT", pickBtn, "RIGHT", -4, 0)
        pickBtn:SetScript("OnClick", function(self)
            local menuItems = {}
            for _, opt in ipairs(options) do
                local optionText = type(opt) == "table" and (opt.text or opt.name or opt.key or opt.value) or tostring(opt)
                local optionValue = type(opt) == "table" and (opt.value or opt.key or opt.text) or opt
                menuItems[#menuItems + 1] = { text = tostring(optionText), value = optionValue }
            end
            local selectedValue = cond[field]
            if type(selectedValue) == "table" then selectedValue = selectedValue.value or selectedValue.key end
            OpenScrollableListMenu(self, PREVIEW_FIELD_LABELS[field] or field, menuItems, function(value)
                cond[field] = value
                pickBtn._label:SetText(GetSpellDropdownText(options, value))
                if onChanged then onChanged() end
            end, selectedValue)
        end)
        return 24
    else
        local eb = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
        eb:SetSize(220, 18)
        eb:SetPoint("LEFT", flbl, "RIGHT", 6, 0)
        eb:SetFont(FONT, 9, ""); eb:SetAutoFocus(false); eb:SetTextColor(1, 1, 1, 1)
        A.CreateBackdrop(eb, 0.1, 0.1, 0.1, 0.8, 0.3, 0.3, 0.3, 0.8)
        eb:SetTextInsets(4, 4, 0, 0)
        eb:SetText(tostring(cond[field] or ""))
        eb:SetScript("OnEnterPressed", function(s)
            local v = s:GetText()
            cond[field] = tonumber(v) or v
            if onChanged then onChanged() end
            s:ClearFocus()
        end)
        eb:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
        return 24
    end
end

-- Hidden frame used as a recycle bin for cleaned-up children.
local _ceRecycleBin = CreateFrame("Frame"); _ceRecycleBin:Hide()

RebuildCondEditor = function()
    local f = condEditorFrame
    if not f or not ceState.working then return end
    local c = f.ceContent
    -- Clear content — reparent to hidden bin so they don't eat clicks
    for _, ch in ipairs({c:GetChildren()}) do ch:Hide(); ch:SetParent(_ceRecycleBin) end
    for _, r in ipairs({c:GetRegions()}) do if r.Hide then r:Hide() end end

    local w = ceState.working
    local ic = CE_ResolveCond(ceState.navStack)
    if not ic then return end

    local isAtRoot = (#ceState.navStack == 0)

    -- Determine NOT state
    local isNot
    if isAtRoot then
        isNot = w.isNot
    else
        isNot = (ic.type == "not")
    end
    -- The condition we actually edit fields on (unwrap NOT)
    local editCond = ic
    if not isAtRoot and isNot then
        editCond = ic.condition or { type = "always" }
    end

    local y = -8

    -- Breadcrumb
    local bc = c:CreateFontString(nil, "OVERLAY")
    bc:SetFont(FONT, 9, "OUTLINE")
    bc:SetPoint("TOPLEFT", c, "TOPLEFT", 12, y)
    bc:SetWidth(420)
    bc:SetJustifyH("LEFT")
    bc:SetTextColor(0.5, 0.7, 1, 1)
    bc:SetText(CE_Breadcrumb())
    y = y - 16

    -- Back button (when not at root)
    if not isAtRoot then
        SUIButton(c, "<  Back", 60, 18, function()
            ceState.navStack[#ceState.navStack] = nil
            RebuildCondEditor()
        end, 12, y)
        y = y - 24
    end

    -- NOT toggle
    SUICheckbox(c, "NOT (negate this condition)",
        function() return isNot end,
        function(v)
            if isAtRoot then
                w.isNot = v
            else
                local parent, idx = CE_GetParentAndIndex()
                if parent and parent.conditions and parent.conditions[idx] then
                    if v then
                        -- Wrap in NOT
                        parent.conditions[idx] = { type = "not", condition = parent.conditions[idx] }
                    else
                        -- Unwrap NOT
                        local wr = parent.conditions[idx]
                        if wr.type == "not" and wr.condition then
                            parent.conditions[idx] = wr.condition
                        end
                    end
                end
            end
            RebuildCondEditor()
        end,
        12, y)
    y = y - 26

    -- Type selector (button opens scrollable picker)
    local tLbl = c:CreateFontString(nil, "OVERLAY")
    tLbl:SetFont(FONT, 9, "OUTLINE"); tLbl:SetPoint("TOPLEFT", c, "TOPLEFT", 12, y)
    tLbl:SetTextColor(1, 0.82, 0, 1); tLbl:SetText("Type:")
    local typePickBtn = SUIButton(c, GetCondTypeLabel(editCond.type), 260, 18, nil, 0, 0)
    typePickBtn:ClearAllPoints()
    typePickBtn:SetPoint("LEFT", tLbl, "RIGHT", 8, 0)
    typePickBtn._label:SetJustifyH("LEFT")
    typePickBtn._label:SetPoint("LEFT", typePickBtn, "LEFT", 6, 0)
    typePickBtn._label:SetPoint("RIGHT", typePickBtn, "RIGHT", -6, 0)
    typePickBtn:SetScript("OnClick", function(self)
        local menuItems = {}
        for _, ct in ipairs(COND_TYPES) do
            menuItems[#menuItems + 1] = { text = ct.label, value = ct.type }
        end
        OpenScrollableListMenu(self, "Condition Type", menuItems, function(value)
            local nc = { type = value }
            if value == "any_of" or value == "all_of" then
                nc.conditions = editCond.conditions or {}
            end
            if value == "not" then
                nc.condition = editCond.condition or { type = "always" }
            end
            -- Replace the condition at the current navigation level
            if isAtRoot then
                w.cond = nc
            else
                local parent, idx = CE_GetParentAndIndex()
                if parent and parent.conditions then
                    if isNot then
                        parent.conditions[idx] = { type = "not", condition = nc }
                    else
                        parent.conditions[idx] = nc
                    end
                end
            end
            RebuildCondEditor()
        end, editCond.type)
    end)
    y = y - 28

    -- Dynamic fields
    local ct = COND_TYPES[GetCondTypeIndex(editCond.type)]
    if ct and ct.fields and #ct.fields > 0 then
        for _, field in ipairs(ct.fields) do
            y = y - CEFieldEditor(c, editCond, field, 16, y)
        end
    end

    -- Group subconditions (any_of / all_of / any / all / or / and)
    local isGroup = (editCond.type == "any_of" or editCond.type == "all_of"
        or editCond.type == "any" or editCond.type == "all"
        or editCond.type == "or" or editCond.type == "and")
    if isGroup then
        y = y - 8
        local isOr = (editCond.type == "any_of" or editCond.type == "any" or editCond.type == "or")
        local joiner = isOr and "OR" or "AND"
        local shdr = c:CreateFontString(nil, "OVERLAY")
        shdr:SetFont(FONT, 10, "OUTLINE")
        shdr:SetPoint("TOPLEFT", c, "TOPLEFT", 12, y)
        shdr:SetTextColor(1, 0.85, 0.4, 1)
        shdr:SetText("Subconditions  (" .. joiner .. "):")
        y = y - 18

        if not editCond.conditions then editCond.conditions = {} end
        for si, sub in ipairs(editCond.conditions) do
            if si > 1 then
                local jl = c:CreateFontString(nil, "OVERLAY")
                jl:SetFont(FONT, 8, "OUTLINE")
                jl:SetPoint("TOPLEFT", c, "TOPLEFT", 24, y - 2)
                jl:SetTextColor(0.5, 0.8, 1, 1)
                jl:SetText(joiner)
                y = y - 14
            end

            -- Description text for subcondition
            local desc = DescribeCondition(sub, ceState.spec)
            local descFS = c:CreateFontString(nil, "OVERLAY")
            descFS:SetFont(FONT, 9)
            descFS:SetPoint("TOPLEFT", c, "TOPLEFT", 24, y)
            descFS:SetWidth(280)
            descFS:SetJustifyH("LEFT")
            descFS:SetWordWrap(true)
            descFS:SetTextColor(0.85, 0.85, 0.85, 1)
            descFS:SetText(desc)

            local textH = descFS:GetStringHeight() or 14
            local subRowH = math.max(18, math.ceil(textH) + 4)

            -- Edit button — pushes into this subcondition
            local csi = si
            SUIButton(c, "Edit", 32, 14, function()
                ceState.navStack[#ceState.navStack + 1] = csi
                RebuildCondEditor()
            end, 314, y)

            -- Move Up
            if si > 1 then
                SUIButton(c, "^", 16, 14, function()
                    editCond.conditions[csi], editCond.conditions[csi - 1] =
                        editCond.conditions[csi - 1], editCond.conditions[csi]
                    RebuildCondEditor()
                end, 350, y)
            end
            -- Move Down
            if si < #editCond.conditions then
                SUIButton(c, "v", 16, 14, function()
                    editCond.conditions[csi], editCond.conditions[csi + 1] =
                        editCond.conditions[csi + 1], editCond.conditions[csi]
                    RebuildCondEditor()
                end, 370, y)
            end

            -- Remove sub
            local sr = CreateFrame("Button", nil, c, "BackdropTemplate")
            sr:SetSize(16, 14)
            sr:SetPoint("TOPLEFT", c, "TOPLEFT", 392, y)
            A.CreateBackdrop(sr, 0.4, 0.1, 0.1, 0.9, 0.5, 0.2, 0.2, 1)
            local srl = sr:CreateFontString(nil, "OVERLAY")
            srl:SetFont(FONT, 9, "OUTLINE"); srl:SetPoint("CENTER"); srl:SetText("x")
            sr:SetScript("OnClick", function()
                table.remove(editCond.conditions, csi)
                RebuildCondEditor()
            end)

            y = y - subRowH
        end

        -- Add subcondition button
        SUIButton(c, "+ Add Subcondition", 130, 16, function()
            editCond.conditions[#editCond.conditions + 1] = { type = "always" }
            RebuildCondEditor()
        end, 24, y)
        y = y - 22
    end

    -- Wrap buttons (only at root or for non-group conditions)
    if not isGroup then
        y = y - 8
        local wx = 12
        SUIButton(c, "Wrap in OR Group", 120, 18, function()
            local nc = { type = "any_of", conditions = { DeepCopy(editCond) } }
            if isAtRoot then
                w.cond = nc
            else
                local parent, idx = CE_GetParentAndIndex()
                if parent and parent.conditions then
                    if isNot then
                        parent.conditions[idx] = { type = "not", condition = nc }
                    else
                        parent.conditions[idx] = nc
                    end
                end
            end
            RebuildCondEditor()
        end, wx, y)
        wx = wx + 128
        SUIButton(c, "Wrap in AND Group", 120, 18, function()
            local nc = { type = "all_of", conditions = { DeepCopy(editCond) } }
            if isAtRoot then
                w.cond = nc
            else
                local parent, idx = CE_GetParentAndIndex()
                if parent and parent.conditions then
                    if isNot then
                        parent.conditions[idx] = { type = "not", condition = nc }
                    else
                        parent.conditions[idx] = nc
                    end
                end
            end
            RebuildCondEditor()
        end, wx, y)
        y = y - 24
    end

    c:SetHeight(math.abs(y) + 20)
end

local function OpenConditionEditor(entryIdx, condIdx, spec)
    local cond = editorData[entryIdx].conditions[condIdx]
    if not cond then return end
    local isNot = (cond.type == "not")
    ceState.entryIdx = entryIdx
    ceState.condIdx = condIdx
    ceState.spec = spec
    ceState.navStack = {}
    ceState.working = {
        isNot = isNot,
        cond = DeepCopy(isNot and cond.condition or cond),
    }
    if not condEditorFrame then
        local f = CreateFrame("Frame", "SPHCondEditor", UIParent, "BackdropTemplate")
        f:SetSize(480, 460)
        f:SetPoint("CENTER"); f:SetMovable(true); f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", function(s) s:StartMoving() end)
        f:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)
        f:SetFrameStrata("FULLSCREEN_DIALOG"); f:SetToplevel(true)
        f:SetClampedToScreen(true)
        A.CreateBackdrop(f, 0.10, 0.10, 0.16, 0.98, 0.3, 0.25, 0.4, 1)
        condEditorFrame = f
        local t = f:CreateFontString(nil, "OVERLAY")
        t:SetFont(FONT, 11, "OUTLINE"); t:SetPoint("TOP", f, "TOP", 0, -8)
        t:SetText("|cff8882d5Edit Condition|r")
        local closeBtn = CreateFrame("Button", nil, f)
        closeBtn:SetSize(20, 20); closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
        local xl = closeBtn:CreateFontString(nil, "OVERLAY")
        xl:SetFont(FONT, 12, "OUTLINE"); xl:SetPoint("CENTER"); xl:SetText("X")
        closeBtn:SetScript("OnClick", function()
            CloseActiveScrollMenu()
            f:Hide()
        end)
        -- Also close any open picker when the editor hides (e.g. Save/Cancel).
        f:SetScript("OnHide", function() CloseActiveScrollMenu() end)
        local sc = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        sc:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -28)
        sc:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 44)
        local co = CreateFrame("Frame", nil, sc)
        co:SetSize(430, 800)
        sc:SetScrollChild(co)
        -- Raise scroll child so its children are above the backdrop
        co:SetFrameLevel(sc:GetFrameLevel() + 2)
        f.ceScroll = sc
        f.ceContent = co
        -- Bottom buttons: Save / Cancel
        local sv = SUIButton(f, "Save", 80, 22, function()
            local w = ceState.working; if not w then return end
            local result = w.isNot and { type = "not", condition = w.cond } or w.cond
            editorData[ceState.entryIdx].conditions[ceState.condIdx] = result
            editorDirty = true
            if editorRefreshFn then editorRefreshFn() end
            f:Hide()
        end, 0, 0)
        sv:ClearAllPoints(); sv:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 12)
        local cn = SUIButton(f, "Cancel", 80, 22, function() f:Hide() end, 0, 0)
        cn:ClearAllPoints(); cn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 106, 12)
    end
    -- Reset scroll position on each open
    if condEditorFrame.ceScroll then
        condEditorFrame.ceScroll:SetVerticalScroll(0)
    end
    RebuildCondEditor()
    condEditorFrame:Show()
end

------------------------------------------------------------------------
-- Condition row builder — shows a concise description with Edit + x.
-- Editing is done in the condition editor popup (OpenConditionEditor).
------------------------------------------------------------------------
local function BuildConditionRow(parent, cond, idx, entryIdx, y, spec)
    -- Description text (full recursive description via DescribeCondition)
    local desc = DescribeCondition(cond, spec)
    local descFS = parent:CreateFontString(nil, "OVERLAY")
    descFS:SetFont(FONT, 9)
    descFS:SetPoint("TOPLEFT", parent, "TOPLEFT", 36, y)
    descFS:SetWidth(390)
    descFS:SetJustifyH("LEFT")
    descFS:SetWordWrap(true)
    descFS:SetTextColor(0.85, 0.85, 0.85, 1)
    descFS:SetText(desc)

    -- Compute row height from text
    local textHeight = descFS:GetStringHeight() or 14
    local rowHeight = math.max(20, math.ceil(textHeight) + 6)

    -- Edit button (opens condition editor popup)
    SUIButton(parent, "Edit", 32, 14, function()
        OpenConditionEditor(entryIdx, idx, spec)
    end, 432, y)

    -- Remove button
    local rem = CreateFrame("Button", nil, parent, "BackdropTemplate")
    rem:SetSize(16, 14)
    rem:SetPoint("TOPLEFT", parent, "TOPLEFT", 468, y)
    A.CreateBackdrop(rem, 0.4, 0.1, 0.1, 0.9, 0.5, 0.2, 0.2, 1)
    local rl = rem:CreateFontString(nil, "OVERLAY")
    rl:SetFont(FONT, 9, "OUTLINE")
    rl:SetPoint("CENTER")
    rl:SetText("x")
    rem:SetScript("OnClick", function()
        table.remove(editorData[entryIdx].conditions, idx)
        editorDirty = true
        if editorRefreshFn then editorRefreshFn() end
    end)

    return rowHeight
end

local function BuildRotationTab(container, spec)
    -- Clear children
    local kids = { container:GetChildren() }
    for _, c in ipairs(kids) do c:Hide(); c:SetParent(nil) end
    local regions = { container:GetRegions() }
    for _, r in ipairs(regions) do if r.Hide then r:Hide() end end

    if not editorData then
        InitEditorData(spec)
    end

    local y = -8

    -- Status line
    local status = container:CreateFontString(nil, "OVERLAY")
    status:SetFont(FONT, 10)
    status:SetPoint("TOPLEFT", container, "TOPLEFT", 12, y)
    status:SetTextColor(0.7, 0.7, 0.7, 1)
    status:SetText(editorDirty and "|cffffcc00Unsaved changes|r" or "No changes")
    y = y - 22

    -- Buttons: Save / Cancel / Reset Default / Add Entry
    local bx = 12
    SUIButton(container, "Save", 60, 20, function()
        if not A.db.specs then A.db.specs = {} end
        if not A.db.specs[editorSpecID] then A.db.specs[editorSpecID] = {} end
        A.db.specs[editorSpecID].rotation = DeepCopy(editorData)
        -- RotationEngine reads DB rotation on every Evaluate() call, so no
        -- deactivate/reactivate needed — the next tick picks up the new data.
        editorDirty = false
        if editorRefreshFn then editorRefreshFn() end

        -- Phase 10a: auto-discover spec_option references and prompt for missing ones
        local referencedKeys = {}
        for _, entry in ipairs(editorData) do
            for _, cond in ipairs(entry.conditions or {}) do
                if (cond.type == "spec_option_enabled" or cond.type == "spec_option_value") and cond.optionKey then
                    referencedKeys[cond.optionKey] = true
                end
            end
        end
        -- Build lookup of existing keys (spec file + custom)
        local existingKeys = {}
        if spec.settingDefs then
            for key in pairs(spec.settingDefs) do existingKeys[key] = true end
        end
        for _, opt in ipairs(spec.uiOptions or {}) do existingKeys[opt.key] = true end
        local custOpts = A.db.specs[editorSpecID] and A.db.specs[editorSpecID].customOptions or {}
        for _, opt in ipairs(custOpts) do existingKeys[opt.key] = true end
        -- Collect missing
        local missing = {}
        for k in pairs(referencedKeys) do
            if not existingKeys[k] then missing[#missing + 1] = k end
        end
        if #missing > 0 then
            -- Auto-create as checkboxes with default=true for convenience
            if not A.db.specs[editorSpecID].customOptions then
                A.db.specs[editorSpecID].customOptions = {}
            end
            local co = A.db.specs[editorSpecID].customOptions
            for _, k in ipairs(missing) do
                co[#co + 1] = { key = k, type = "checkbox", label = k, default = true }
            end
            print("|cff8882d5SPHelper|r: Auto-created config options: " .. table.concat(missing, ", "))
        end

        print("|cff8882d5SPHelper|r: Rotation saved.")
    end, bx, y)
    bx = bx + 68

    SUIButton(container, "Cancel", 60, 20, function()
        InitEditorData(spec)
        if editorRefreshFn then editorRefreshFn() end
    end, bx, y)
    bx = bx + 68

    SUIButton(container, "Reset Default", 90, 20, function()
        -- Only clear the DB override; RotationEngine will revert to file defaults.
        if A.db.specs and A.db.specs[editorSpecID] then
            A.db.specs[editorSpecID].rotation = nil
        end
        InitEditorData(spec)
        if editorRefreshFn then editorRefreshFn() end
        print("|cff8882d5SPHelper|r: Rotation reset to spec defaults.")
    end, bx, y)
    bx = bx + 98

    SUIButton(container, "+ Add Entry", 80, 20, function()
        local newEntry = {
            key = "NEW",
            conditions = {{ type = "always" }},
        }
        editorData[#editorData + 1] = newEntry
        editorDirty = true
        if editorRefreshFn then editorRefreshFn() end
    end, bx, y)
    y = y - 30

    -- Rotation entries
    for i, entry in ipairs(editorData) do
        -- Entry header row
        local hdr = container:CreateFontString(nil, "OVERLAY")
        hdr:SetFont(FONT, 10, "OUTLINE")
        hdr:SetPoint("TOPLEFT", container, "TOPLEFT", 12, y)
        hdr:SetTextColor(1, 0.85, 0.4, 1)
        local hdrText = string.format("[%d] %s", i, entry.key)
        if entry.explicitPriority ~= nil then
            hdrText = hdrText .. string.format("  {P:%s}", tostring(entry.explicitPriority))
        end
        hdr:SetText(hdrText)

        -- Key edit (editbox + spell picker dropdown)
        local keyEB = CreateFrame("EditBox", nil, container, "BackdropTemplate")
        keyEB:SetSize(60, 16)
        keyEB:SetPoint("LEFT", hdr, "RIGHT", 8, 0)
        keyEB:SetFont(FONT, 9, "")
        keyEB:SetAutoFocus(false)
        keyEB:SetTextColor(1, 1, 1, 1)
        A.CreateBackdrop(keyEB, 0.1, 0.1, 0.1, 0.8, 0.3, 0.3, 0.3, 0.8)
        keyEB:SetTextInsets(4, 4, 0, 0)
        keyEB:SetText(entry.key)
        keyEB:SetScript("OnEnterPressed", function(self)
            entry.key = self:GetText()
            editorDirty = true
            self:ClearFocus()
            if editorRefreshFn then editorRefreshFn() end
        end)
        keyEB:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        -- Spell tooltip on key field
        keyEB:SetScript("OnEnter", function(self)
            local spellInfo = A.SPELLS and A.SPELLS[entry.key]
            if spellInfo and A.SpellData then
                local tip = A.SpellData:GetSpellTooltipText(spellInfo.id)
                if tip then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText(spellInfo.label or spellInfo.name or entry.key)
                    GameTooltip:AddLine(tip, 1, 1, 1, true)
                    local dur = A.SpellData:GetEffectiveDuration(spellInfo.id)
                    if dur > 0 then
                        GameTooltip:AddLine(string.format("Duration: %.1fs (talent/set adjusted)", dur), 0.5, 0.8, 1, true)
                    end
                    GameTooltip:Show()
                end
            end
        end)
        keyEB:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- Spell picker button (shows dropdown of known spell keys)
        local spellPickBtn = SUIButton(container, "...", 20, 16, function()
            local menuItems = {}
            local spellEntries = (A.SpellData and A.SpellData.GetSpellKeysForEditor and A.SpellData:GetSpellKeysForEditor(spec.meta.class)) or {}
            for _, spellEntry in ipairs(spellEntries) do
                local displayText = spellEntry.resolvedName or spellEntry.name or spellEntry.key
                if spellEntry.resolvedName and spellEntry.resolvedName ~= spellEntry.name then
                    displayText = string.format("%s (%s)", spellEntry.name, spellEntry.resolvedName)
                end
                local spellValue = spellEntry.resolvedName or spellEntry.name or spellEntry.key
                local item = {
                    text = displayText,
                    value = spellValue,
                }
                if A.SpellData then
                    local tip = A.SpellData:GetSpellTooltipText(spellEntry.id or spellEntry.baseId)
                    if tip then
                        item.tooltipTitle = spellEntry.resolvedName or spellEntry.name or spellEntry.key
                        item.tooltipText = tip
                    end
                end
                menuItems[#menuItems + 1] = item
            end
            table.sort(menuItems, function(a, b)
                return tostring(a.text) < tostring(b.text)
            end)
            local selectedSpellValue = NormalizeSpellValue(entry.key)
            OpenScrollableListMenu(spellPickBtn, "Pick Ability", menuItems, function(value)
                entry.key = value
                keyEB:SetText(value)
                editorDirty = true
                if editorRefreshFn then editorRefreshFn() end
            end, selectedSpellValue)
        end, 0, 0)  -- position will be anchored
        spellPickBtn:ClearAllPoints()
        spellPickBtn:SetPoint("LEFT", keyEB, "RIGHT", 2, 0)

        -- Move Up / Move Down / Duplicate / Remove buttons
        local btnX = 300
        if i > 1 then
            local up = SUIButton(container, "Up", 26, 16, function()
                editorData[i], editorData[i - 1] = editorData[i - 1], editorData[i]
                editorDirty = true
                if editorRefreshFn then editorRefreshFn() end
            end, btnX, y)
        end
        btnX = btnX + 30
        if i < #editorData then
            local dn = SUIButton(container, "Dn", 26, 16, function()
                editorData[i], editorData[i + 1] = editorData[i + 1], editorData[i]
                editorDirty = true
                if editorRefreshFn then editorRefreshFn() end
            end, btnX, y)
        end
        btnX = btnX + 30
        SUIButton(container, "Dup", 28, 16, function()
            local copy = DeepCopy(entry)
            table.insert(editorData, i + 1, copy)
            editorDirty = true
            if editorRefreshFn then editorRefreshFn() end
        end, btnX, y)
        btnX = btnX + 32
        SUIButton(container, "Del", 28, 16, function()
            table.remove(editorData, i)
            editorDirty = true
            if editorRefreshFn then editorRefreshFn() end
        end, btnX, y)

        y = y - 22

        -- insertBefore field (optional — for entries that should be inserted before another key)
        if entry.insertBefore or entry.key == "IF" or entry.key == "NEW" then
            local ibLbl = container:CreateFontString(nil, "OVERLAY")
            ibLbl:SetFont(FONT, 8)
            ibLbl:SetPoint("TOPLEFT", container, "TOPLEFT", 30, y)
            ibLbl:SetTextColor(0.6, 0.6, 0.6, 1)
            ibLbl:SetText("Insert before:")

            local ibEB = CreateFrame("EditBox", nil, container, "BackdropTemplate")
            ibEB:SetSize(60, 16)
            ibEB:SetPoint("LEFT", ibLbl, "RIGHT", 4, 0)
            ibEB:SetFont(FONT, 9, "")
            ibEB:SetAutoFocus(false)
            ibEB:SetTextColor(1, 1, 1, 1)
            A.CreateBackdrop(ibEB, 0.1, 0.1, 0.1, 0.8, 0.3, 0.3, 0.3, 0.8)
            ibEB:SetTextInsets(4, 4, 0, 0)
            ibEB:SetText(tostring(entry.insertBefore or ""))
            ibEB:SetScript("OnEnterPressed", function(self)
                local val = strtrim(self:GetText())
                entry.insertBefore = (val ~= "") and val or nil
                editorDirty = true
                self:ClearFocus()
            end)
            ibEB:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
            y = y - 20
        end

        local prLbl = container:CreateFontString(nil, "OVERLAY")
        prLbl:SetFont(FONT, 8)
        prLbl:SetPoint("TOPLEFT", container, "TOPLEFT", 30, y)
        prLbl:SetTextColor(0.6, 0.6, 0.6, 1)
        prLbl:SetText("Split bucket:")
        prLbl:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Split bucket")
            GameTooltip:AddLine("If the first two ready recommendations share the same explicitPriority, the primary icon auto-splits in list order.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        prLbl:SetScript("OnLeave", function() GameTooltip:Hide() end)

        local prEB = CreateFrame("EditBox", nil, container, "BackdropTemplate")
        prEB:SetSize(50, 16)
        prEB:SetPoint("LEFT", prLbl, "RIGHT", 4, 0)
        prEB:SetFont(FONT, 9, "")
        prEB:SetAutoFocus(false)
        prEB:SetTextColor(1, 1, 1, 1)
        A.CreateBackdrop(prEB, 0.1, 0.1, 0.1, 0.8, 0.3, 0.3, 0.3, 0.8)
        prEB:SetTextInsets(4, 4, 0, 0)
        prEB:SetText((entry.explicitPriority ~= nil) and tostring(entry.explicitPriority) or "")
        prEB:SetScript("OnEnterPressed", function(self)
            local raw = strtrim(self:GetText() or "")
            if raw == "" then
                entry.explicitPriority = nil
                self:SetText("")
            else
                local num = tonumber(raw)
                if num then
                    entry.explicitPriority = num
                    self:SetText(tostring(num))
                else
                    self:SetText((entry.explicitPriority ~= nil) and tostring(entry.explicitPriority) or "")
                end
            end
            editorDirty = true
            self:ClearFocus()
            if editorRefreshFn then editorRefreshFn() end
        end)
        prEB:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        y = y - 20

        -- Conditions
        if entry.conditions then
            for ci, cond in ipairs(entry.conditions) do
                if ci > 1 then
                    local andLbl = container:CreateFontString(nil, "OVERLAY")
                    andLbl:SetFont(FONT, 8, "OUTLINE")
                    andLbl:SetPoint("TOPLEFT", container, "TOPLEFT", 36, y - 2)
                    andLbl:SetTextColor(0.4, 0.7, 1, 1)
                    andLbl:SetText("AND")
                    y = y - 14
                end
                y = y - BuildConditionRow(container, cond, ci, i, y, spec)
            end
        end

        -- Add condition button
        SUIButton(container, "+ Cond", 50, 16, function()
            if not entry.conditions then entry.conditions = {} end
            entry.conditions[#entry.conditions + 1] = { type = "always" }
            editorDirty = true
            if editorRefreshFn then editorRefreshFn() end
        end, 30, y)
        y = y - 22

        -- Separator
        local sep = container:CreateTexture(nil, "ARTWORK")
        sep:SetColorTexture(0.3, 0.3, 0.3, 0.5)
        sep:SetSize(480, 1)
        sep:SetPoint("TOPLEFT", container, "TOPLEFT", 12, y)
        y = y - 6
    end

    container:SetHeight(math.abs(y) + 20)
end

------------------------------------------------------------------------
-- Tab 3 – Preview (live evaluator snapshot)
------------------------------------------------------------------------

local previewTicker = nil

local function BuildPreviewTab(container, spec)
    local title = container:CreateFontString(nil, "OVERLAY")
    title:SetFont(FONT, 10, "OUTLINE")
    title:SetPoint("TOPLEFT", container, "TOPLEFT", 12, -8)
    title:SetTextColor(1, 0.85, 0.4, 1)
    title:SetText("Live Rotation Evaluator Preview")

    local output = container:CreateFontString(nil, "OVERLAY")
    output:SetFont(FONT, 9)
    output:SetPoint("TOPLEFT", container, "TOPLEFT", 12, -28)
    output:SetTextColor(0.85, 0.85, 0.85, 1)
    output:SetWidth(560)
    output:SetJustifyH("LEFT")
    output:SetText("Waiting for data...")

    local function UpdatePreview()
        if not A.RotationEngine then
            output:SetText("RotationEngine not loaded.")
            return
        end
        local RE = A.RotationEngine
        local activeSpec = A.SpecManager and A.SpecManager:GetSpecByID(A._activeSpecID or "")
        if not activeSpec then
            output:SetText("No active spec.")
            return
        end

        local ok, debugData = pcall(function() return RE:DebugEvaluate(activeSpec) end)
        if not ok or not debugData or not debugData.ctx then
            output:SetText("Error evaluating rotation: " .. tostring(debugData))
            return
        end
        local ctx = debugData.ctx

        -- Scan rotation to discover which condition types / resources are used
        local rotation = debugData.rotation
        local usesResource = {}
        local usesComboPoints = false
        local usesDot = {}
        local usesCD = {}
        local usesHPDecay = false
        local usesClearcasting = false
        local usesSP = false
        local usesContentType = false
        local usesClassification = false
        local usesBehindTarget = false
        local usesBaseMana = false
        local usesReadyResource = false
        local usesReadyTick = false
        local usesTargetTTD = false
        local usesTargetCounts = false
        local usesThreatUnits = {}
        local usesCastUnits = {}
        local usesTravelSpells = {}
        local usesChannelMetrics = false
        local behindTargetDebug = nil
        local function ScanCondition(cond)
            if not cond or type(cond) ~= "table" then return end
            local ct = cond.type
            if ct == "resource_pct_lt" or ct == "resource_pct_gt" then
                usesResource[cond.resource or "mana"] = true
            end
            if ct == "resource_gte" or ct == "resource_lt" or ct == "resource_required_gte" then usesResource["flat"] = true end
            if ct == "resource_at_gcd_lt" or ct == "resource_at_gcd_gt" then usesReadyResource = true end
            if ct == "next_power_tick_with_gcd_lt" or ct == "next_power_tick_with_gcd_gt" then usesReadyTick = true end
            if ct == "combo_points_gte" or ct == "combo_points_lt" then usesComboPoints = true end
            if ct == "dot_missing" or ct == "projected_dot_time_left_lt" or ct == "dot_time_left_lt" then
                usesDot[cond.spellKey or "?"] = true
            end
            if ct == "debuff_on_target" or ct == "debuff_time_left_lt" then
                usesDot[cond.debuff or "?"] = true
            end
            if ct == "other_targets_with_debuff_lt" then
                usesDot[cond.spellKey or "?"] = true
            end
            if ct == "cooldown_ready" or ct == "cooldown_lt" then
                usesCD[cond.spellKey or "?"] = true
            end
            if ct == "threat_pct_lt" or ct == "threat_pct_ge" then
                usesThreatUnits[cond.unit or "target"] = true
            end
            if ct == "target_dying_fast" then usesHPDecay = true end
            if ct == "target_ttd_gte" or ct == "target_ttd_lt" then usesTargetTTD = true end
            if ct == "predicted_kill" then usesSP = true end
            if ct == "content_type" or ct == "content_mode_allow" then usesContentType = true end
            if ct == "target_classification" or ct == "option_gated_classification" then usesClassification = true end
            if ct == "behind_target" or ct == "not_behind_target" then usesBehindTarget = true end
            if ct == "clearcasting" then usesClearcasting = true end
            if ct == "player_base_mana_pct_lt" or ct == "player_base_mana_pct_gt" then usesBaseMana = true end
            if ct == "state_compare" then
                local subject = cond.subject
                if subject == "resource_pct" then
                    usesResource[cond.resource or "mana"] = true
                elseif subject == "player_mana_pct" then
                    usesResource["mana"] = true
                elseif subject == "player_base_mana_pct" then
                    usesBaseMana = true
                elseif subject == "resource" then
                    usesResource["flat"] = true
                elseif subject == "resource_at_gcd" then
                    usesReadyResource = true
                elseif subject == "next_power_tick_with_gcd" then
                    usesReadyTick = true
                elseif subject == "combo_points" then
                    usesComboPoints = true
                elseif subject == "target_ttd" then
                    usesTargetTTD = true
                elseif subject == "tracked_target_count" then
                    usesTargetCounts = true
                elseif subject == "tracked_targets_with_ttd" then
                    usesTargetCounts = true
                    usesTargetTTD = true
                elseif subject == "threat_pct" then
                    usesThreatUnits[cond.unit or "target"] = true
                elseif subject == "channel_tick_interval" or subject == "channel_ticks_remaining" or subject == "channel_time_to_next_tick" then
                    usesChannelMetrics = true
                end
            end
            if ct == "spell_property_compare" then
                if cond.property == "time_to_ready" then
                    usesCD[cond.spellKey or "?"] = true
                elseif cond.property == "travel_time" then
                    usesTravelSpells[cond.spellKey or "?"] = true
                elseif cond.property == "dot_base_duration" or cond.property == "dot_tick_frequency" then
                    usesDot[cond.spellKey or "?"] = true
                elseif cond.property == "channel_tick_interval" then
                    usesChannelMetrics = true
                end
            end
            if ct == "buff_property_compare" and cond.buff == "Clearcasting" then
                usesClearcasting = true
            end
            if ct == "debuff_property_compare" then
                usesDot[cond.debuff or cond.spellKey or "?"] = true
            end
            if ct == "unit_cast_compare" or ct == "unit_interruptible" then
                usesCastUnits[cond.unit or "target"] = true
            end
            if ct == "any_of" or ct == "all_of" then
                for _, subCond in ipairs(cond.conditions or {}) do
                    ScanCondition(subCond)
                end
            elseif ct == "not" then
                ScanCondition(cond.condition)
            end
        end
        if rotation then
            for _, entry in ipairs(rotation) do
                for _, cond in ipairs(entry.conditions or {}) do
                    ScanCondition(cond)
                end
            end
        end

        if usesBehindTarget and A.SpecVal and A.SpecVal("debug_behind_target", false) then
            local evalFn = RE._condEval and RE._condEval["behind_target"]
            if evalFn then
                local probeCtx = {}
                local probeDb = A.db and A.db.specs and A.db.specs[activeSpec.meta.id]
                local okProbe, probeErr = pcall(evalFn, { type = "behind_target" }, probeCtx, activeSpec, probeDb)
                if okProbe then
                    behindTargetDebug = probeCtx.behindTargetDebug or probeCtx
                    ctx.behindTargetDebug = behindTargetDebug
                else
                    behindTargetDebug = { reason = "probe_error", error = tostring(probeErr) }
                end
            else
                behindTargetDebug = { reason = "probe_unavailable" }
            end
        end

        local lines = {}
        lines[#lines + 1] = "|cffffcc00Context:|r"
        -- Always show basic info
        lines[#lines + 1] = string.format("  Casting: %s  InCombat: %s  GCD: %.2fs  Lat: %.0fms",
            ctx.castingSpell or "none",
            tostring(ctx.inCombat),
            ctx.gcd, ctx.lat * 1000)
        -- Target info
        if UnitExists("target") then
            lines[#lines + 1] = string.format("  Target HP: %.0f%%",
                (ctx.targetMaxHP > 0) and (ctx.targetHP / ctx.targetMaxHP * 100) or 0)
        else
            lines[#lines + 1] = "  Target: none"
        end
        -- Resources (only show relevant ones)
        if usesResource["mana"] then
            lines[#lines + 1] = string.format("  Mana: %.0f%%", ctx.manaPct * 100)
        end
        if usesBaseMana then
            lines[#lines + 1] = string.format("  Base Mana: %.0f%% (%d / %d)", (ctx.baseManaPct or 0) * 100,
                ctx.currentMana or 0, ctx.baseMana or 0)
        end
        if usesResource["energy"] or usesResource["rage"] or usesResource["focus"] or usesResource["flat"] then
            local max = UnitPowerMax("player") or 1
            if max <= 0 then max = 1 end
            lines[#lines + 1] = string.format("  Resource: %d / %d (%.0f%%)",
                ctx.resourcePower, max, (ctx.resourcePower / max) * 100)
        end
        if usesReadyResource then
            lines[#lines + 1] = string.format("  Resource @ Ready: %.1f  Ready In: %.2fs",
                ctx.resourceAtGCD or 0, ctx.readyIn or 0)
        end
        if usesReadyTick then
            lines[#lines + 1] = string.format("  Next Tick @ Ready: %s",
                (ctx.nextPowerTickWithGCD ~= nil) and string.format("%.2fs", ctx.nextPowerTickWithGCD) or "n/a")
        end
        if usesComboPoints then
            lines[#lines + 1] = string.format("  Combo Points: %d", ctx.comboPoints)
        end
        if usesSP then
            lines[#lines + 1] = string.format("  Spell Power: %d", ctx.sp)
        end
        if usesHPDecay then
            lines[#lines + 1] = string.format("  HP Decay Rate: %.1f%%/s", ctx.hpDecayRate * 100)
        end
        if usesTargetTTD then
            lines[#lines + 1] = string.format("  Target TTD: %s",
                (ctx.targetTTD ~= nil) and string.format("%.1fs", ctx.targetTTD) or "n/a")
        end
        if usesTargetCounts then
            local trackedCount = 0
            local seen = {}
            for guid, data in pairs(A.dotTargets or {}) do
                if type(data) == "table" and not data._deadAt and (data.hpPct or 0) > 0 then
                    seen[guid] = true
                    trackedCount = trackedCount + 1
                end
            end
            local targetGUID = UnitGUID("target")
            if targetGUID and not seen[targetGUID] and UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsDead("target") then
                trackedCount = trackedCount + 1
            end
            lines[#lines + 1] = string.format("  Tracked Targets: %d", trackedCount)
        end
        for unit in pairs(usesThreatUnits) do
            local threatPct = 0
            if UnitExists(unit) and type(UnitDetailedThreatSituation) == "function" then
                local _, _, scaledPct, rawPct = UnitDetailedThreatSituation("player", unit)
                threatPct = scaledPct or rawPct or 0
            end
            lines[#lines + 1] = string.format("  Threat[%s]: %.0f%%", unit, threatPct)
        end
        if usesChannelMetrics then
            local activeChannel = ctx.activeChannelSpellKey or "none"
            local nextTick = (ctx.channelTimeToNextTick or 0) > 0 and string.format("%.2fs", ctx.channelTimeToNextTick) or "n/a"
            lines[#lines + 1] = string.format(
                "  Channel: %s  Tick Int: %.2fs  Next Tick: %s  Ticks Left: %d",
                activeChannel,
                ctx.channelTickInterval or 0,
                nextTick,
                ctx.channelTicksRemaining or 0
            )
        end
        for spellKey in pairs(usesTravelSpells) do
            if spellKey ~= "?" then
                local travel = (A.GetSpellTravelTime and A.GetSpellTravelTime(spellKey)) or 0
                lines[#lines + 1] = string.format("  Travel[%s]: %.2fs", spellKey, travel)
            end
        end
        if usesContentType then
            lines[#lines + 1] = string.format("  Content: %s", A.GetContentType())
        end
        if usesClassification then
            lines[#lines + 1] = string.format("  Target Class.: %s", A.GetTargetClassification())
        end
        if usesClearcasting then
            lines[#lines + 1] = string.format("  Clearcasting: %s", tostring(ctx.clearcasting))
        end
        if usesBehindTarget and A.SpecVal and A.SpecVal("debug_behind_target", false) then
            local dbg = behindTargetDebug or ctx.behindTargetDebug
            if dbg then
                if dbg.reason == "target_position_unavailable" then
                    lines[#lines + 1] = "  Behind Debug: target position unavailable for this unit type"
                elseif dbg.reason == "no_facing_api" then
                    lines[#lines + 1] = "  Behind Debug: facing API unavailable for this client"
                elseif dbg.reason == "facing_api_error" then
                    lines[#lines + 1] = "  Behind Debug: facing API errored during probe"
                end
                local function fmtPos(pos)
                    if not pos or not pos.ok then return "nil" end
                    return string.format("y=%s x=%s inst=%s",
                        tostring(pos.y), tostring(pos.x), tostring(pos.instanceID))
                end
                local function fmtNum(n)
                    if n == nil then return "nil" end
                    return string.format("%.3f", tonumber(n) or 0)
                end
                lines[#lines + 1] = string.format(
                    "  Behind Debug: api=%s/%s source=%s reason=%s order=%s result=%s",
                    tostring(dbg.unitFacingAvailable),
                    tostring(dbg.objectFacingAvailable),
                    tostring(dbg.facingSource or "none"),
                    tostring(dbg.reason or "unknown"),
                    tostring(dbg.usedOrdering or "n/a"),
                    tostring(dbg.result)
                )
                lines[#lines + 1] = string.format(
                    "  Behind Pos: player[%s] target[%s] facing=%s",
                    fmtPos(dbg.playerPos),
                    fmtPos(dbg.targetPos),
                    fmtNum(dbg.targetFacing)
                )
                if dbg.dx ~= nil or dbg.dy ~= nil or dbg.angleToPlayer ~= nil or dbg.backAngle ~= nil or dbg.diff ~= nil then
                    lines[#lines + 1] = string.format(
                        "  Behind Math: dx=%s dy=%s angle=%s back=%s diff=%s",
                        fmtNum(dbg.dx), fmtNum(dbg.dy), fmtNum(dbg.angleToPlayer), fmtNum(dbg.backAngle), fmtNum(dbg.diff)
                    )
                end
            else
                lines[#lines + 1] = "  Behind Debug: no data yet"
            end
        end
        for unit in pairs(usesCastUnits) do
            if UnitExists(unit) then
                local castName, _, _, _, castEndMS, _, _, castNotInterruptible = UnitCastingInfo(unit)
                local channelName, _, _, _, channelEndMS, _, channelNotInterruptible
                if not castName then
                    channelName, _, _, _, channelEndMS, _, channelNotInterruptible = UnitChannelInfo(unit)
                end
                if castName and castEndMS then
                    lines[#lines + 1] = string.format(
                        "  Cast[%s]: %s %.1fs (%s)",
                        unit,
                        castName,
                        math.max((castEndMS / 1000) - ctx.now, 0),
                        castNotInterruptible and "not interruptible" or "interruptible"
                    )
                elseif channelName and channelEndMS then
                    lines[#lines + 1] = string.format(
                        "  Cast[%s]: %s %.1fs (%s)",
                        unit,
                        channelName,
                        math.max((channelEndMS / 1000) - ctx.now, 0),
                        channelNotInterruptible and "not interruptible" or "interruptible"
                    )
                else
                    lines[#lines + 1] = string.format("  Cast[%s]: none", unit)
                end
            else
                lines[#lines + 1] = string.format("  Cast[%s]: unavailable", unit)
            end
        end
        -- DoT timers (only show ones used in rotation)
        local dotLines = {}
        if usesDot["Vampiric Touch"] then dotLines[#dotLines + 1] = string.format("VT:%.1fs", ctx.vtRem) end
        if usesDot["Shadow Word: Pain"] then dotLines[#dotLines + 1] = string.format("SWP:%.1fs", ctx.swpRem) end
        -- Generic debuffs
        for dkey in pairs(usesDot) do
            if dkey ~= "Vampiric Touch" and dkey ~= "Shadow Word: Pain" and dkey ~= "?" then
                local debuffName = dkey
                -- Try resolve from A.SPELLS
                if A.SPELLS[dkey] then debuffName = A.SPELLS[dkey].name end
                local rem = 0
                if UnitExists("target") then
                    for i = 1, 40 do
                        local bname, _, _, _, _, expireTime = UnitDebuff("target", i)
                        if not bname then break end
                        if bname == debuffName then
                            rem = expireTime and math.max(expireTime - ctx.now, 0) or 0
                            break
                        end
                    end
                end
                dotLines[#dotLines + 1] = string.format("%s:%.1fs", dkey, rem)
            end
        end
        if #dotLines > 0 then
            lines[#lines + 1] = "  DoTs: " .. table.concat(dotLines, "  ")
        end
        -- Cooldowns (only show ones used in rotation)
        local cdLines = {}
        for cdKey in pairs(usesCD) do
            local cdVal = ctx[cdKey:lower() .. "CD"]
            if cdVal == nil then
                local spell = A.SPELLS[cdKey]
                if spell then
                    cdVal = math.max(A.GetSpellCDReal(spell.id) - ctx.castRemaining, 0)
                end
            end
            if cdVal then
                cdLines[#cdLines + 1] = string.format("%s:%.1fs", cdKey, cdVal)
            end
        end
        if #cdLines > 0 then
            lines[#lines + 1] = "  CDs: " .. table.concat(cdLines, "  ")
        end
        if debugData.result and #debugData.result > 0 then
            local queueBits = {}
            for i, rec in ipairs(debugData.result) do
                if i > 4 then break end
                queueBits[#queueBits + 1] = string.format("%s(%.1f)", rec.key, rec.eta or 0)
            end
            lines[#lines + 1] = "  Live Queue: " .. table.concat(queueBits, "  ")
        end
        lines[#lines + 1] = ""

        -- Evaluate each entry
        if rotation and debugData.entries then
            lines[#lines + 1] = "|cffffcc00Rotation entries:|r"
            local function FormatCondMark(status)
                if status == "pass" then return "|cff00ff00Y|r" end
                if status == "predict" then return "|cffffff00P|r" end
                if status == "unknown" then return "|cff888888?|r" end
                return "|cffff4444N|r"
            end
            for i, entry in ipairs(rotation) do
                local entryDiag = debugData.entries[i] or {}
                local condStrs = {}
                for ci, cond in ipairs(entry.conditions or {}) do
                    local condDiag = entryDiag.conditionResults and entryDiag.conditionResults[ci] or nil
                    local mark = condDiag and FormatCondMark(condDiag.status) or "|cff888888?|r"
                    condStrs[#condStrs + 1] = string.format("%s:%s", DescribeCondition(cond, activeSpec), mark)
                end
                local status = "|cffff4444FAIL|r"
                if entryDiag.status == "pass" then
                    status = "|cff00ff00PASS|r"
                elseif entryDiag.status == "predict" then
                    status = string.format("|cffffff00PREDICT %.1fs|r", entryDiag.eta or 0)
                elseif entryDiag.status == "no_target" then
                    status = "|cff888888NO TARGET|r"
                elseif entryDiag.status == "unknown_spell" then
                    status = "|cff888888UNKNOWN SPELL|r"
                end
                -- Render the entry across multiple lines: header line with
                -- spell name and status, followed by one indented line per
                -- condition. Long conditions wrap inside the FontString's
                -- 560px width, and the leading "      |  " indent + the
                -- FontString's natural wrap visually groups continuations
                -- under the originating condition.
                lines[#lines + 1] = string.format("  [%d] %s  %s", i, entry.key, status)
                if #condStrs > 0 then
                    for _, c in ipairs(condStrs) do
                        lines[#lines + 1] = "      |  " .. c
                    end
                else
                    lines[#lines + 1] = "      |  (no conditions)"
                end
            end
        else
            lines[#lines + 1] = "No rotation data."
        end

        output:SetText(table.concat(lines, "\n"))
        container:SetHeight(math.max(400, 28 + 14 * #lines + 20))
    end

    -- Start ticker immediately (content frame OnShow is unreliable for scroll children)
    container._updatePreview = UpdatePreview
    UpdatePreview()
    if not previewTicker then
        previewTicker = C_Timer.NewTicker(0.5, function()
            if A.SpecUI and A.SpecUI.frame and A.SpecUI.frame:IsShown()
               and A.SpecUI._activeTab == 3 then
                UpdatePreview()
            else
                previewTicker:Cancel()
                previewTicker = nil
            end
        end)
    end
end

------------------------------------------------------------------------
-- Tab 4 – CastBar & FQ (per-spell channel config + global options)
------------------------------------------------------------------------

local function BuildCastBarTab(container, spec)
    local y = -8
    local specID = spec.meta.id
    local function RefreshCastBarTab()
        if A.SpecUI and A.SpecUI.RefreshCurrentTab then
            A.SpecUI:RefreshCurrentTab()
        elseif A.SpecUI and A.SpecUI.SwitchTab then
            A.SpecUI:SwitchTab(4, spec, true)
        end
    end

    local function GetChannelSpellList()
        if A.ChannelHelper and A.ChannelHelper.GetChannelSpellDefinitions then
            local defs = A.ChannelHelper:GetChannelSpellDefinitions(spec)
            if defs and #defs > 0 then
                return defs
            end
        end
        return spec.channelSpells or {}
    end

    -- Section header: Channel Spells
    local hdr1 = container:CreateFontString(nil, "OVERLAY")
    hdr1:SetFont(FONT, 10, "OUTLINE")
    hdr1:SetPoint("TOPLEFT", container, "TOPLEFT", 12, y)
    hdr1:SetTextColor(1, 0.85, 0.4, 1)
    hdr1:SetText("Channel Spells")
    y = y - 18

    local desc1 = container:CreateFontString(nil, "OVERLAY")
    desc1:SetFont(FONT, 8)
    desc1:SetPoint("TOPLEFT", container, "TOPLEFT", 12, y)
    desc1:SetTextColor(0.7, 0.7, 0.7, 1)
    desc1:SetText("Configure per-spell FQ, clip overlay, and tick feedback.")
    y = y - 16

    -- Read channel spells from the spec, then auto-augment from the shared
    -- spell catalog so any future channeled spells defined in SpellDatabase
    -- are exposed automatically.
    local channelSpells = GetChannelSpellList()

    local function PushChannelField(spellLabel, cs, field, value)
        cs[field] = value
        if A.ChannelHelper and A.ChannelHelper.KNOWN_CHANNELS then
            local info = A.ChannelHelper.KNOWN_CHANNELS[spellLabel]
            if info then info[field] = value end
        end
    end

    local sectionWidth = math.max((container:GetWidth() or 0) - 24, 520)

    -- Per-spell config entries
    for idx, cs in ipairs(channelSpells) do
        local spellLabel = cs.spellName or (cs.spellKey and A.SPELLS[cs.spellKey] and A.SPELLS[cs.spellKey].name) or cs.spellKey or "Unknown"
        local prefix = "cs_" .. (cs.spellKey or tostring(idx)) .. "_"

        local collapsed = A.SpecVal and A.SpecVal(prefix .. "collapsed", false) or false

        local spellHdr = CreateFrame("Button", nil, container, "BackdropTemplate")
        spellHdr:SetSize(sectionWidth, 18)
        spellHdr:SetPoint("TOPLEFT", container, "TOPLEFT", 16, y)
        A.CreateBackdrop(spellHdr, 0.12, 0.12, 0.12, 0.95, 0.3, 0.3, 0.3, 1)
        local spellHdrLbl = spellHdr:CreateFontString(nil, "OVERLAY")
        spellHdrLbl:SetFont(FONT, 9, "OUTLINE")
        spellHdrLbl:SetPoint("LEFT", spellHdr, "LEFT", 6, 0)
        spellHdrLbl:SetTextColor(0.9, 0.8, 1, 1)
        spellHdrLbl:SetText(string.format("%s (%d ticks)", spellLabel, cs.ticks or 3))
        local spellHdrHint = spellHdr:CreateFontString(nil, "OVERLAY")
        spellHdrHint:SetFont(FONT, 8, "OUTLINE")
        spellHdrHint:SetPoint("RIGHT", spellHdr, "RIGHT", -6, 0)
        spellHdrHint:SetTextColor(0.7, 0.7, 0.7, 1)
        spellHdrHint:SetText(collapsed and "expand" or "collapse")
        spellHdr:SetScript("OnClick", function()
            A.SetSpecVal(prefix .. "collapsed", not collapsed)
            RefreshCastBarTab()
        end)
        y = y - 22

        if not collapsed then
            -- Per-spell toggles (stored as channelSpell_<spellKey>_<setting>)
            local toggles = {
                { key = prefix .. "fakeQueue",   label = "Fake Queue",     default = cs.fakeQueue ~= false,
                  tooltip = "Enable busy-wait FQ for this spell.", refresh = false },
                { key = prefix .. "clipOverlay", label = "Clip Overlay",   default = cs.clipOverlay ~= false,
                  tooltip = "Show green clip zone on cast bar during this channel.", refresh = false },
                { key = prefix .. "tickSound",   label = "Tick Sound",     default = cs.tickSound ~= false,
                  tooltip = "Play sound on tick events for this spell.", refresh = true },
                { key = prefix .. "tickFlash",   label = "Tick Flash",     default = cs.tickFlash ~= false,
                  tooltip = "Flash screen on tick events for this spell.", refresh = true },
                { key = prefix .. "tickMarkers", label = "Tick Markers",   default = cs.tickMarkers ~= false,
                  tooltip = "Show tick markers on cast bar for this spell.", refresh = true },
            }

            for _, tog in ipairs(toggles) do
                local cb, lbl = SUICheckbox(container, tog.label,
                    function() return A.SpecVal(tog.key, tog.default) end,
                    function(v)
                        A.SetSpecVal(tog.key, v)
                        local settingName = tog.key:gsub(prefix, "")
                        cs[settingName] = v
                        if A.ChannelHelper and A.ChannelHelper.KNOWN_CHANNELS then
                            local info = A.ChannelHelper.KNOWN_CHANNELS[spellLabel]
                            if info then info[settingName] = v end
                        end
                        if tog.refresh then RefreshCastBarTab() end
                    end,
                    30, y)
                if tog.tooltip and lbl then
                    lbl:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(tog.label); GameTooltip:AddLine(tog.tooltip, 1, 1, 1, true); GameTooltip:Show() end)
                    lbl:SetScript("OnLeave", function() GameTooltip:Hide() end)
                end
                y = y - 22
            end

            local tickMarkersEnabled = A.SpecVal and A.SpecVal(prefix .. "tickMarkers", cs.tickMarkers ~= false)
            local tickMarkerMode = A.SpecVal and A.SpecVal(prefix .. "tickMarkerMode", cs.tickMarkerMode or "all") or "all"
            if tickMarkersEnabled then
                local markerModeValues = { "all", "remaining", "none", "specific" }
                local markerModeLabels = { all = "All", remaining = "Remaining", none = "None", specific = "Specific" }
                local markerModeDD, markerModeLbl = SUIDropdown(container, "Tick markers mode", markerModeValues,
                    function() return A.SpecVal(prefix .. "tickMarkerMode", cs.tickMarkerMode or "all") end,
                    function(v)
                        A.SetSpecVal(prefix .. "tickMarkerMode", v)
                        PushChannelField(spellLabel, cs, "tickMarkerMode", v)
                        RefreshCastBarTab()
                    end,
                    30, y, markerModeLabels)
                y = y - 50

                if cs.ticks and cs.ticks > 0 and tickMarkerMode == "specific" then
                    local markerTickRow = BuildTickSelector(container, "Marker ticks", 30, y, cs.ticks,
                        function() return A.SpecVal(prefix .. "tickMarkerTicks", cs.tickMarkerTicks or {}) end,
                        function(values)
                            A.SetSpecVal(prefix .. "tickMarkerTicks", values)
                            PushChannelField(spellLabel, cs, "tickMarkerTicks", values)
                        end,
                        false)
                    y = y - 22
                end
            end

            local tickSoundEnabled = A.SpecVal and A.SpecVal(prefix .. "tickSound", cs.tickSound ~= false)
            if tickSoundEnabled and cs.ticks and cs.ticks > 0 then
                local soundTickRow = BuildTickSelector(container, "Sound ticks", 30, y, cs.ticks,
                    function() return A.SpecVal(prefix .. "tickSoundTicks", cs.tickSoundTicks or {}) end,
                    function(values)
                        A.SetSpecVal(prefix .. "tickSoundTicks", values)
                        PushChannelField(spellLabel, cs, "tickSoundTicks", values)
                    end,
                    true)
                y = y - 22
            end

            local tickFlashEnabled = A.SpecVal and A.SpecVal(prefix .. "tickFlash", cs.tickFlash ~= false)
            if tickFlashEnabled and cs.ticks and cs.ticks > 0 then
                local flashTickRow = BuildTickSelector(container, "Flash ticks", 30, y, cs.ticks,
                    function() return A.SpecVal(prefix .. "tickFlashTicks", cs.tickFlashTicks or {}) end,
                    function(values)
                        A.SetSpecVal(prefix .. "tickFlashTicks", values)
                        PushChannelField(spellLabel, cs, "tickFlashTicks", values)
                    end,
                    true)
                y = y - 22
            end
        end

        y = y - 6
    end

    if #channelSpells == 0 then
        local noSpells = container:CreateFontString(nil, "OVERLAY")
        noSpells:SetFont(FONT, 9)
        noSpells:SetPoint("TOPLEFT", container, "TOPLEFT", 16, y)
        noSpells:SetTextColor(0.5, 0.5, 0.5, 1)
        noSpells:SetText("No channel spells configured for this spec.")
        y = y - 18
    end

    -- Section header: Global CastBar & FQ Options
    y = y - 10
    local hdr2 = container:CreateFontString(nil, "OVERLAY")
    hdr2:SetFont(FONT, 10, "OUTLINE")
    hdr2:SetPoint("TOPLEFT", container, "TOPLEFT", 12, y)
    hdr2:SetTextColor(1, 0.85, 0.4, 1)
    hdr2:SetText("Global CastBar & FQ Options")
    y = y - 18

    -- Render castBarOptions from spec
    local castBarOpts = spec.castBarOptions or {}
    for _, opt in ipairs(castBarOpts) do
        local tooltip = opt.tooltip
        if opt.type == "checkbox" then
            local cb, lbl = SUICheckbox(container, opt.label,
                function() return A.SpecVal(opt.key, opt.default) end,
                function(v)
                    A.SetSpecVal(opt.key, v)
                    -- Push to ChannelHelper config live
                    if A.ChannelHelper then
                        local CH = A.ChannelHelper
                        if opt.key == "channelFakeQueue" then CH._config.fakeQueueEnabled = v end
                        if opt.key == "channelClipCues"  then CH._config.clipCues         = v end
                        if opt.key == "fqDiag"           then CH._config.fqDiag = (v == true or v == 1) end
                        if opt.key == "fqAutoAdjust"     then CH._config.fqAutoAdjust = (v == true or v == 1) end
                    end
                end,
                16, y)
            if tooltip and lbl then
                lbl:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(opt.label); GameTooltip:AddLine(tooltip, 1, 1, 1, true); GameTooltip:Show() end)
                lbl:SetScript("OnLeave", function() GameTooltip:Hide() end)
            end
            y = y - 26
        elseif opt.type == "slider" then
            local s, lbl = SUISlider(container, opt.label, opt.min or 0, opt.max or 100, opt.step or 1,
                function() return A.SpecVal(opt.key, opt.default) end,
                function(v)
                    A.SetSpecVal(opt.key, v)
                    if A.ChannelHelper then
                        local CH = A.ChannelHelper
                        if opt.key == "fakeQueueMaxMs"  then CH._config.fakeQueueMaxMs  = v end
                        if opt.key == "clipMarginMs"    then CH._config.clipMarginMs    = v end
                        if opt.key == "fqFireOffsetMs"  then CH._config.fqFireOffsetMs  = v end
                    end
                end,
                16, y)
            if tooltip and lbl then
                lbl:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(opt.label); GameTooltip:AddLine(tooltip, 1, 1, 1, true); GameTooltip:Show() end)
                lbl:SetScript("OnLeave", function() GameTooltip:Hide() end)
            end
            y = y - 38
        elseif opt.type == "dropdown" then
            local dd, lbl = SUIDropdown(container, opt.label, opt.values or {},
                function() return A.SpecVal(opt.key, opt.default) end,
                function(v) A.SetSpecVal(opt.key, v) end,
                16, y)
            if tooltip and lbl then
                lbl:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(opt.label); GameTooltip:AddLine(tooltip, 1, 1, 1, true); GameTooltip:Show() end)
                lbl:SetScript("OnLeave", function() GameTooltip:Hide() end)
            end
            y = y - 50
        end
    end

    -- FQ macro help
    y = y - 10
    local macroHdr = container:CreateFontString(nil, "OVERLAY")
    macroHdr:SetFont(FONT, 9, "OUTLINE")
    macroHdr:SetPoint("TOPLEFT", container, "TOPLEFT", 12, y)
    macroHdr:SetTextColor(1, 0.85, 0.4, 1)
    macroHdr:SetText("FQ Macro Template")
    y = y - 16
    local macroText = container:CreateFontString(nil, "OVERLAY")
    macroText:SetFont(FONT, 8)
    macroText:SetPoint("TOPLEFT", container, "TOPLEFT", 16, y)
    macroText:SetTextColor(0.7, 0.7, 0.7, 1)
    -- Show example using the first channel spell when available
    local exampleSpell = (channelSpells[1] and channelSpells[1].spellName) or "Mind Blast"
    if exampleSpell == "Mind Blast" and spec.rotation and spec.rotation[1] and spec.rotation[1].key then
        local key = spec.rotation[1].key
        if A.SPELLS[key] and A.SPELLS[key].name then
            exampleSpell = A.SPELLS[key].name
        end
    end
    macroText:SetText("/run SPH_FQ()\n/cast " .. exampleSpell)
    y = y - 24

    SUIButton(container, "Print All Macros", 100, 18, function()
        if A.ChannelHelper and A.ChannelHelper.PrintMacros then
            A.ChannelHelper:PrintMacros()
        else
            print("|cff8882d5SPHelper|r: ChannelHelper not loaded.")
        end
    end, 16, y)

    SUIButton(container, "Create FQ Macros", 110, 18, function()
        if A.ChannelHelper and A.ChannelHelper.CreateMacros then
            A.ChannelHelper:CreateMacros()
        else
            print("|cff8882d5SPHelper|r: ChannelHelper not loaded.")
        end
    end, 130, y)
    y = y - 26

    container:SetHeight(math.abs(y) + 20)
end

------------------------------------------------------------------------
-- Tab 5 – Import / Export
------------------------------------------------------------------------

local function BuildImportExportTab(container, spec)
    local y = -8
    local specID = spec.meta.id
    local lbl = container:CreateFontString(nil, "OVERLAY")
    lbl:SetFont(FONT, 10, "OUTLINE")
    lbl:SetPoint("TOPLEFT", container, "TOPLEFT", 12, y)
    lbl:SetTextColor(1, 0.85, 0.4, 1)
    lbl:SetText("Spec Import / Export  (Rotation + Options)")
    y = y - 22

    local statusText = container:CreateFontString(nil, "OVERLAY")
    statusText:SetFont(FONT, 9)
    statusText:SetPoint("TOPLEFT", container, "TOPLEFT", 12, y)
    statusText:SetTextColor(0.7, 0.7, 0.7, 1)
    statusText:SetText("")
    y = y - 20

    -- EditBox for import/export text
    local scrollFrame = CreateFrame("ScrollFrame", nil, container, "UIPanelScrollFrameTemplate")
    scrollFrame:SetSize(470, 280)
    scrollFrame:SetPoint("TOPLEFT", container, "TOPLEFT", 12, y)

    local editBox = CreateFrame("EditBox", nil, scrollFrame)
    editBox:SetFont(FONT, 9, "")
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetWidth(460)
    editBox:SetTextColor(0.9, 0.9, 0.9, 1)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scrollFrame:SetScrollChild(editBox)
    y = y - 290

    -- Export button
    SUIButton(container, "Export Current", 100, 20, function()
        local rotation = editorData
            or (A.db.specs and A.db.specs[specID] and A.db.specs[specID].rotation)
            or spec.rotation
        if not rotation then
            statusText:SetText("|cffff4444No rotation to export.|r")
            return
        end
        local exportCopy = DeepCopy(rotation)
        exportCopy._fromFile = nil

        -- Build options export (customOptions + deletedOptions + overridden values)
        local sdb = A.db.specs and A.db.specs[specID]
        local optionsExport = {}
        if sdb and sdb.customOptions and #sdb.customOptions > 0 then
            optionsExport.customOptions = DeepCopy(sdb.customOptions)
        end
        if sdb and sdb.deletedOptions then
            optionsExport.deletedOptions = DeepCopy(sdb.deletedOptions)
        end
        -- Collect option value overrides
        local optionValues = {}
        local merged = GetMergedOptions(spec, specID)
        for _, opt in ipairs(merged) do
            if sdb and sdb[opt.key] ~= nil then
                optionValues[opt.key] = sdb[opt.key]
            end
        end
        if next(optionValues) then
            optionsExport.values = optionValues
        end

        local exportData = { rotation = exportCopy }
        if next(optionsExport) then exportData.options = optionsExport end

        local text = Serialize(exportData)
        editBox:SetText(text)
        editBox:HighlightText()
        editBox:SetFocus()
        statusText:SetText("|cff00ff00Exported rotation + options. Copy the text above.|r")
    end, 12, y)

    -- Import button
    SUIButton(container, "Import", 70, 20, function()
        local text = editBox:GetText()
        local tbl, err = Deserialize(text)
        if not tbl then
            statusText:SetText("|cffff4444Import failed: " .. tostring(err) .. "|r")
            return
        end

        -- Support both old format (flat rotation array) and new format ({rotation=..., options=...})
        local rotation, options
        if tbl.rotation then
            rotation = tbl.rotation
            options = tbl.options
        else
            rotation = tbl
        end

        -- Validate rotation
        if A.SpecValidator and A.SpecValidator.ValidateRotation then
            local ok, valErr = A.SpecValidator:ValidateRotation(rotation)
            if not ok then
                statusText:SetText("|cffff4444Validation failed: " .. tostring(valErr) .. "|r")
                return
            end
        end

        -- Apply rotation to editor
        editorData = rotation
        editorData._fromFile = nil
        editorDirty = true

        -- Apply options to DB
        if options then
            local sdb = A.db.specs and A.db.specs[specID]
            if sdb then
                if options.customOptions then
                    sdb.customOptions = options.customOptions
                end
                if options.deletedOptions then
                    sdb.deletedOptions = options.deletedOptions
                end
                if options.values then
                    for k, v in pairs(options.values) do
                        sdb[k] = v
                    end
                end
            end
        end

        local msg = "|cff00ff00Imported " .. #rotation .. " entries"
        if options then msg = msg .. " + options" end
        msg = msg .. ". Switch to Rotation tab to review, then Save.|r"
        statusText:SetText(msg)
    end, 120, y)

    -- Validate button
    SUIButton(container, "Validate", 70, 20, function()
        local text = editBox:GetText()
        local tbl, err = Deserialize(text)
        if not tbl then
            statusText:SetText("|cffff4444Parse error: " .. tostring(err) .. "|r")
            return
        end
        local rotation = tbl.rotation or tbl
        if A.SpecValidator and A.SpecValidator.ValidateRotation then
            local ok, valErr = A.SpecValidator:ValidateRotation(rotation)
            if not ok then
                statusText:SetText("|cffff4444Validation: " .. tostring(valErr) .. "|r")
            else
                statusText:SetText("|cff00ff00Valid rotation with " .. #rotation .. " entries.|r")
            end
        else
            statusText:SetText("|cffffcc00Validator not loaded; cannot check.|r")
        end
    end, 198, y)

    container:SetHeight(math.abs(y) + 40)
end

------------------------------------------------------------------------
-- Tab 6 – Load Conditions (when this spec auto-activates)
------------------------------------------------------------------------

local function BuildLoadConditionsTab(container, spec)
    local y = -8
    local specID = spec.meta.id
    local lc = spec.loadConditions or {}

    local hdr = container:CreateFontString(nil, "OVERLAY")
    hdr:SetFont(FONT, 10, "OUTLINE")
    hdr:SetPoint("TOPLEFT", container, "TOPLEFT", 12, y)
    hdr:SetTextColor(1, 0.85, 0.4, 1)
    hdr:SetText("Load Conditions for: " .. (spec.meta.specName or specID))
    y = y - 20

    local desc = container:CreateFontString(nil, "OVERLAY")
    desc:SetFont(FONT, 8)
    desc:SetPoint("TOPLEFT", container, "TOPLEFT", 12, y)
    desc:SetTextColor(0.7, 0.7, 0.7, 1)
    desc:SetText("These conditions determine when this spec auto-activates. Changes are stored in your DB.")
    y = y - 18

    -- Read overrides from DB if any
    local sdb = A.db and A.db.specs and A.db.specs[specID]
    local lcOverride = sdb and sdb.loadConditionsOverride
    local effective = lcOverride or lc

    -- Class (read-only)
    local classLbl = container:CreateFontString(nil, "OVERLAY")
    classLbl:SetFont(FONT, 9)
    classLbl:SetPoint("TOPLEFT", container, "TOPLEFT", 16, y)
    classLbl:SetTextColor(1, 0.82, 0, 1)
    classLbl:SetText("Class: " .. (effective.class or "(any)"))
    y = y - 22

    -- Talent tab (show as "index: name" where possible)
    local talentTabValue = effective.talentTab
    local tabOptions = {}
    local tabNames = {}
    local nTabs = GetNumTalentTabs and GetNumTalentTabs() or 3
    local fallback = CLASS_TALENT_FALLBACK[effective.class or spec.meta.class]
    for t = 1, nTabs do
        local rawName = nil
        if GetTalentTabInfo then rawName = select(1, GetTalentTabInfo(t)) end
        local name = nil
        if type(rawName) == "string" and rawName:match("%S") then
            -- Some clients may return numeric-looking strings; prefer readable names
            if not rawName:match("^%s*%d+%s*$") then
                name = rawName
            end
        end
        if not name and fallback and fallback[t] then name = fallback[t] end
        tabNames[t] = name
        local label = tostring(t)
        if name and name ~= "" then label = tostring(t) .. ": " .. name end
        tabOptions[#tabOptions + 1] = label
    end
    tabOptions[#tabOptions + 1] = "(any)"

    -- Build displayed value from stored talentTab (index or name/label)
    local displayedValue = "(any)"
    if talentTabValue then
        if type(talentTabValue) == "number" then
            local nm = tabNames[talentTabValue]
            displayedValue = nm and (tostring(talentTabValue) .. ": " .. nm) or tostring(talentTabValue)
        elseif type(talentTabValue) == "string" then
            local asNum = tonumber(talentTabValue:match("^%s*(%d+)") or talentTabValue)
            if asNum and tabNames[asNum] then
                displayedValue = tostring(asNum) .. ": " .. tabNames[asNum]
            else
                local found = false
                for idx, nm in ipairs(tabNames) do
                    if nm and nm:lower() == talentTabValue:lower() then
                        displayedValue = tostring(idx) .. ": " .. nm
                        found = true
                        break
                    end
                end
                if not found then displayedValue = talentTabValue end
            end
        end
    end
    SUIDropdown(container, "Primary talent tree (most points)", tabOptions,
        function() return displayedValue or "(any)" end,
        function(v)
            if v == "(any)" then v = nil end
            talentTabValue = v
        end, 16, y)
    y = y - 50

    -- Required spells (comma-separated list of spell IDs)
    local reqSpellsLbl = container:CreateFontString(nil, "OVERLAY")
    reqSpellsLbl:SetFont(FONT, 9)
    reqSpellsLbl:SetPoint("TOPLEFT", container, "TOPLEFT", 16, y)
    reqSpellsLbl:SetTextColor(1, 0.82, 0, 1)
    reqSpellsLbl:SetText("Required spells (comma-separated IDs):")
    y = y - 16
    local reqEB = CreateFrame("EditBox", nil, container, "BackdropTemplate")
    reqEB:SetSize(300, 18)
    reqEB:SetPoint("TOPLEFT", container, "TOPLEFT", 16, y)
    reqEB:SetFont(FONT, 9, "")
    reqEB:SetAutoFocus(false)
    A.CreateBackdrop(reqEB, 0.1, 0.1, 0.1, 0.8, 0.3, 0.3, 0.3, 0.8)
    reqEB:SetTextInsets(4, 4, 0, 0)
    local reqSpellStr = ""
    if effective.requiredSpells then
        local parts = {}
        for _, sid in ipairs(effective.requiredSpells) do parts[#parts + 1] = tostring(sid) end
        reqSpellStr = table.concat(parts, ", ")
    end
    reqEB:SetText(reqSpellStr)
    reqEB:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    reqEB:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)
    y = y - 26

    -- Min level
    local minLevelLbl = container:CreateFontString(nil, "OVERLAY")
    minLevelLbl:SetFont(FONT, 9)
    minLevelLbl:SetPoint("TOPLEFT", container, "TOPLEFT", 16, y)
    minLevelLbl:SetTextColor(1, 0.82, 0, 1)
    minLevelLbl:SetText("Minimum level:")
    local minLevelEB = CreateFrame("EditBox", nil, container, "BackdropTemplate")
    minLevelEB:SetSize(40, 18)
    minLevelEB:SetPoint("LEFT", minLevelLbl, "RIGHT", 8, 0)
    minLevelEB:SetFont(FONT, 9, "")
    minLevelEB:SetAutoFocus(false)
    A.CreateBackdrop(minLevelEB, 0.1, 0.1, 0.1, 0.8, 0.3, 0.3, 0.3, 0.8)
    minLevelEB:SetTextInsets(4, 4, 0, 0)
    minLevelEB:SetText(tostring(effective.minLevel or ""))
    minLevelEB:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    minLevelEB:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)
    y = y - 28

    -- Status
    local statusLbl = container:CreateFontString(nil, "OVERLAY")
    statusLbl:SetFont(FONT, 9)
    statusLbl:SetPoint("TOPLEFT", container, "TOPLEFT", 16, y)
    statusLbl:SetTextColor(0.7, 0.7, 0.7, 1)
    y = y - 20

    -- Save button
    SUIButton(container, "Save Load Conditions", 140, 22, function()
        local newLC = { class = effective.class or spec.meta.class }
        -- Talent tab: allow selecting by name (map back to numeric tab index)
        if talentTabValue and talentTabValue ~= "(any)" then
            local chosen = talentTabValue
            -- Labels are formatted as "N: Name" — extract the leading number first.
            local chosenIndex = tonumber(chosen:match("^%s*(%d+)"))
            -- Fallback: bare numeric string
            if not chosenIndex then chosenIndex = tonumber(chosen) end
            -- Fallback: match by tree name (strip leading "N: " prefix for comparison)
            if not chosenIndex then
                local numTabs = GetNumTalentTabs and GetNumTalentTabs() or 3
                local chosenName = (chosen:match("^%s*%d+%s*:%s*(.+)$") or chosen):lower()
                for t = 1, numTabs do
                    local name = select(1, GetTalentTabInfo(t)) or tostring(t)
                    if name and name:lower() == chosenName then
                        chosenIndex = t
                        break
                    end
                end
            end
            if chosenIndex then newLC.talentTab = chosenIndex end
        end
        -- Required spells
        local spellText = strtrim(reqEB:GetText())
        if spellText ~= "" then
            newLC.requiredSpells = {}
            for sid in spellText:gmatch("(%d+)") do
                newLC.requiredSpells[#newLC.requiredSpells + 1] = tonumber(sid)
            end
            if #newLC.requiredSpells == 0 then newLC.requiredSpells = nil end
        end
        -- Min level
        local ml = tonumber(strtrim(minLevelEB:GetText()))
        if ml and ml > 1 then newLC.minLevel = ml end

        -- Store override in DB
        if not A.db.specs then A.db.specs = {} end
        if not A.db.specs[specID] then A.db.specs[specID] = {} end
        A.db.specs[specID].loadConditionsOverride = newLC
        -- Apply to spec
        spec.loadConditions = newLC
        -- Re-evaluate
        if A.SpecManager then A.SpecManager:ReEvaluate() end
        statusLbl:SetText("|cff00ff00Load conditions saved.|r")
        print("|cff8882d5SPHelper|r: Load conditions updated for " .. (spec.meta.specName or specID) .. ".")
        -- Print the exact saved loadConditions for debugging
        if Serialize then
            print("|cff8882d5SPHelper|r: Saved loadConditions: " .. Serialize(newLC))
        end
    end, 16, y)

    SUIButton(container, "Reset to File Defaults", 140, 22, function()
        if A.db.specs and A.db.specs[specID] then
            A.db.specs[specID].loadConditionsOverride = nil
        end
        -- Restore from file-defined loadConditions (need to look at _available)
        local origSpec = A.SpecManager and A.SpecManager:GetSpecByID(specID)
        if origSpec and origSpec._fileLoadConditions then
            origSpec.loadConditions = origSpec._fileLoadConditions
        end
        if A.SpecManager then A.SpecManager:ReEvaluate() end
        statusLbl:SetText("|cff00ff00Reset to file defaults.|r")
        if SUI.frame and SUI.frame:IsShown() and SUI._activeTab == 5 then
            SUI:SwitchTab(5, spec)
        end
    end, 170, y)

    y = y - 30

    -- Current status
    local isActive = A.SpecManager and A.SpecManager:IsSpecActive(specID)
    local activeLbl = container:CreateFontString(nil, "OVERLAY")
    activeLbl:SetFont(FONT, 9, "OUTLINE")
    activeLbl:SetPoint("TOPLEFT", container, "TOPLEFT", 16, y)
    if isActive then
        activeLbl:SetTextColor(0, 1, 0, 1)
        activeLbl:SetText("Status: ACTIVE (conditions match)")
    else
        activeLbl:SetTextColor(1, 0.4, 0.4, 1)
        activeLbl:SetText("Status: INACTIVE (conditions do not match current character)")
    end
    y = y - 22

    -- Force activate/deactivate buttons
    if not isActive then
        SUIButton(container, "Force Activate", 100, 20, function()
            if A.SpecManager then
                A.SpecManager:ActivateSpec(specID)
            end
            print("|cff8882d5SPHelper|r: Force-activated " .. (spec.meta.specName or specID))
            if SUI.frame and SUI.frame:IsShown() and SUI._activeTab == 5 then
                SUI:SwitchTab(5, spec)
            end
        end, 16, y)
        y = y - 26
    end

    container:SetHeight(math.abs(y) + 20)
end

------------------------------------------------------------------------
-- Main frame builder
------------------------------------------------------------------------

------------------------------------------------------------------------
-- "Create New Spec" modal (shown when /sph is used without an active spec)
------------------------------------------------------------------------

local newSpecFrame = nil

local function OpenNewSpecDialog()
    if newSpecFrame and newSpecFrame:IsShown() then
        newSpecFrame:Show()
        return
    end
    if not newSpecFrame then
        local f = CreateFrame("Frame", "SPHNewSpecDialog", UIParent, "BackdropTemplate")
        f:SetSize(300, 180)
        f:SetPoint("CENTER")
        f:SetMovable(true); f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", function(self) self:StartMoving() end)
        f:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetToplevel(true)
        A.CreateBackdrop(f, 0.12, 0.10, 0.18, 0.98, 0.3, 0.25, 0.4, 1)
        newSpecFrame = f

        local title = f:CreateFontString(nil, "OVERLAY")
        title:SetFont(FONT, 11, "OUTLINE")
        title:SetPoint("TOP", f, "TOP", 0, -8)
        title:SetText("|cff8882d5SPHelper – Create New Spec|r")

        local ly = -30
        local descLbl = f:CreateFontString(nil, "OVERLAY")
        descLbl:SetFont(FONT, 9)
        descLbl:SetPoint("TOPLEFT", f, "TOPLEFT", 16, ly)
        descLbl:SetTextColor(0.7, 0.7, 0.7, 1)
        descLbl:SetText("Creates a blank spec for your current class.")
        ly = ly - 22

        local nameLbl = f:CreateFontString(nil, "OVERLAY")
        nameLbl:SetFont(FONT, 9)
        nameLbl:SetPoint("TOPLEFT", f, "TOPLEFT", 16, ly)
        nameLbl:SetText("Spec name:")
        nameLbl:SetTextColor(1, 0.82, 0, 1)
        local nameEB = CreateFrame("EditBox", nil, f, "BackdropTemplate")
        nameEB:SetSize(160, 18)
        nameEB:SetPoint("LEFT", nameLbl, "RIGHT", 8, 0)
        nameEB:SetFont(FONT, 9, "")
        nameEB:SetAutoFocus(true)
        A.CreateBackdrop(nameEB, 0.1, 0.1, 0.1, 0.8, 0.3, 0.3, 0.3, 0.8)
        nameEB:SetTextInsets(4, 4, 0, 0)
        nameEB:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        ly = ly - 28

        local statusLbl = f:CreateFontString(nil, "OVERLAY")
        statusLbl:SetFont(FONT, 9)
        statusLbl:SetPoint("TOPLEFT", f, "TOPLEFT", 16, ly)
        statusLbl:SetTextColor(0.7, 0.7, 0.7, 1)
        ly = ly - 26

        SUIButton(f, "Create", 80, 22, function()
            local specName = strtrim(nameEB:GetText())
            if specName == "" then
                statusLbl:SetText("|cffff4444Enter a spec name.|r")
                return
            end
            -- Derive class from current player
            local _, playerClass = UnitClass("player")
            if not playerClass then
                statusLbl:SetText("|cffff4444Could not detect player class.|r")
                return
            end
            -- Generate a safe ID
            local specID = playerClass:lower() .. "_" .. specName:lower():gsub("%s+", "_"):gsub("[^%w_]", "")
            -- Guard against already-registered IDs
            if A.SpecManager and A.SpecManager:GetSpecByID(specID) then
                statusLbl:SetText("|cffff4444Spec '" .. specID .. "' already exists.|r")
                return
            end
            -- Build minimal spec
            local newSpec = {
                meta = {
                    id       = specID,
                    class    = playerClass,
                    specName = specName,
                    version  = 1,
                    author   = "(custom)",
                },
                loadConditions  = { class = playerClass },
                helpers         = { "RotationEngine", "SpecUI", "Config" },
                uiOptions       = {},
                castBarOptions  = {},
                channelSpells   = {},
                rotation        = {},
            }
            -- Register and activate
            if A.SpecManager then
                A.SpecManager:RegisterSpec(newSpec)
                A.SpecManager:ActivateSpec(specID)
            end
            f:Hide()
            print("|cff8882d5SPHelper|r: Created and activated spec '" .. specName .. "'. Use /sph to configure.")
            -- Open the UI
            if A.SpecUI then A.SpecUI:Open(specID) end
        end, 16, ly)

        SUIButton(f, "Cancel", 80, 22, function() f:Hide() end, 106, ly)

        -- Close (X)
        local closeBtn = CreateFrame("Button", nil, f)
        closeBtn:SetSize(20, 20)
        closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
        local xl = closeBtn:CreateFontString(nil, "OVERLAY")
        xl:SetFont(FONT, 12, "OUTLINE"); xl:SetPoint("CENTER"); xl:SetText("X")
        closeBtn:SetScript("OnClick", function() f:Hide() end)
    end
    newSpecFrame:Show()
end

-- Expose the new-spec dialog so external callers can open it directly
-- This allows other UI (e.g., the main options panel) to always open
-- the Create New Spec modal regardless of active spec state.
A.SpecUI.OpenNewSpecDialog = OpenNewSpecDialog

function SUI:Open(specID)
    specID = specID or A._activeSpecID
    if not specID then
        -- No active spec — offer to create a new one
        OpenNewSpecDialog()
        return
    end
    local spec = A.SpecManager and A.SpecManager:GetSpecByID(specID)
    if not spec then
        print("|cffff4444[SPHelper] Spec '" .. tostring(specID) .. "' not found. Use /sph to create one.|r")
        OpenNewSpecDialog()
        return
    end

    -- Reuse or create the window
    if self.frame then
        local prevID = self._spec and self._spec.meta and self._spec.meta.id
        self._spec = spec
        if prevID ~= spec.meta.id then
            editorData = nil  -- reset editor only when switching to a different spec
        end
        self.frame:Show()
        -- Update title
        if self._title then
            self._title:SetText("|cff8882d5SPHelper|r \226\128\147 " .. (spec.meta.specName or specID))
        end
        self:SwitchTab(1, spec)
        return
    end

    local f = CreateFrame("Frame", "SPHelperSpecUIFrame", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_W, FRAME_H)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetResizable(true)
    if f.SetResizeBounds then
        f:SetResizeBounds(520, 400, 1200, 900)
    elseif f.SetMinResize then
        f:SetMinResize(520, 400)
        f:SetMaxResize(1200, 900)
    end
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    A.CreateBackdrop(f, 0.10, 0.08, 0.16, 0.95, 0.25, 0.20, 0.35, 1)
    self.frame = f

    -- Resize grip (bottom-right corner)
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() f:StopMovingOrSizing() end)

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY")
    title:SetFont(FONT, 12, "OUTLINE")
    title:SetPoint("TOP", f, "TOP", 0, -8)
    title:SetText("|cff8882d5SPHelper|r – " .. (spec.meta.specName or specID))
    self._title = title

    -- Spec switcher dropdown (shows all specs for current class)
    local _, playerClass = UnitClass("player")
    local classSpecs = {}
    if A.SpecManager then
        for sid, s in pairs(A.SpecManager:GetRegisteredSpecs()) do
            if s.meta and s.meta.class == playerClass then
                classSpecs[#classSpecs + 1] = { id = sid, name = s.meta.specName or sid }
            end
        end
    end
    if #classSpecs > 1 then
        suiDropdownCounter = suiDropdownCounter + 1
        local specDD = CreateFrame("Frame", "SPHSpecSwitchDD" .. suiDropdownCounter, f, "UIDropDownMenuTemplate")
        specDD:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -2)
        UIDropDownMenu_SetWidth(specDD, 120)
        UIDropDownMenu_SetText(specDD, spec.meta.specName or specID)
        UIDropDownMenu_Initialize(specDD, function(self2, level)
            for _, cs in ipairs(classSpecs) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = cs.name
                info.value = cs.id
                info.func = function(self3)
                    local newSpec = A.SpecManager:GetSpecByID(self3.value)
                    if newSpec then
                        SUI._spec = newSpec
                        -- If not active, temporarily set for editing
                        UIDropDownMenu_SetText(specDD, cs.name)
                        if SUI._title then
                            local activeTag = A._activeSpecID == self3.value and "" or " |cff888888(inactive)|r"
                            SUI._title:SetText("|cff8882d5SPHelper|r – " .. (newSpec.meta.specName or self3.value) .. activeTag)
                        end
                        editorData = nil  -- reset rotation editor
                        SUI:SwitchTab(SUI._activeTab or 1, newSpec)
                    end
                    CloseDropDownMenus()
                end
                info.checked = (cs.id == (SUI._spec and SUI._spec.meta.id))
                UIDropDownMenu_AddButton(info, level)
            end
        end)
    end

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    closeBtn:SetSize(20, 20)
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
    local xl = closeBtn:CreateFontString(nil, "OVERLAY")
    xl:SetFont(FONT, 12, "OUTLINE")
    xl:SetPoint("CENTER")
    xl:SetText("X")
    closeBtn:SetScript("OnClick", function()
        f:Hide()
        if previewTicker then previewTicker:Cancel(); previewTicker = nil end
    end)

    -- ESC to close
    f:SetScript("OnShow", function()
        if type(UISpecialFrames) == "table" then
            local found = false
            for _, v in ipairs(UISpecialFrames) do
                if v == "SPHelperSpecUIFrame" then found = true; break end
            end
            if not found then table.insert(UISpecialFrames, "SPHelperSpecUIFrame") end
        end
    end)
    f:SetScript("OnHide", function()
        if type(UISpecialFrames) == "table" then
            for i, v in ipairs(UISpecialFrames) do
                if v == "SPHelperSpecUIFrame" then
                    table.remove(UISpecialFrames, i)
                    break
                end
            end
        end
    end)

    -- Tab body area (scroll frame)
    local body = CreateFrame("Frame", nil, f, "BackdropTemplate")
    body:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -(TAB_H + 28))
    body:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 6)
    A.CreateBackdrop(body, 0.08, 0.06, 0.12, 0.6, 0.2, 0.2, 0.3, 0.5)

    local scroll = CreateFrame("ScrollFrame", nil, body, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", body, "TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -24, 4)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetWidth(scroll:GetWidth() or (FRAME_W - 60))
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(self, w, h) content:SetWidth(w) end)
    self._content = content
    self._scroll  = scroll

    -- Tabs
    local tabNames = { "General", "Rotation", "Preview", "CastBar & FQ", "Load Cond.", "Import/Export" }
    local tabCount = #tabNames
    local tabWidth = math.floor((FRAME_W - 8 - (tabCount - 1) * 4) / tabCount)
    local tabSpacing = tabWidth + 4
    local tabs = {}
    for i, name in ipairs(tabNames) do
        tabs[i] = CreateTabButton(f, name, i, function(idx)
            self:SwitchTab(idx)
        end, tabWidth, tabSpacing)
    end
    self._tabs = tabs
    self._spec = spec

    self:SwitchTab(1, spec)
    f:Show()
end

function SUI:SwitchTab(idx, spec, preserveScroll)
    spec = spec or self._spec
    if not spec or not self._content then return end

    local scrollPos = 0
    if preserveScroll and self._scroll then
        scrollPos = self._scroll:GetVerticalScroll() or 0
    end

    self._activeTab = idx
    SetTabActive(self._tabs, idx)

    -- Clear content
    local content = self._content
    local kids = { content:GetChildren() }
    for _, c in ipairs(kids) do c:Hide(); c:SetParent(nil) end
    local regions = { content:GetRegions() }
    for _, r in ipairs(regions) do if r.Hide then r:Hide() end end
    content:SetHeight(400)

    -- Reset ticker
    if previewTicker then previewTicker:Cancel(); previewTicker = nil end

    -- Always clear the cross-tab refresh functions before rebuilding.
    generalRefreshFn = nil
    if idx ~= 2 then editorRefreshFn = nil end

    if idx == 1 then
        -- Keep a live-refresh handle so anything that mutates the rotation
        -- (e.g. the Config Creator save, a future inline edit) can call
        -- generalRefreshFn() to rebuild the General tab without a /reload.
        local function RebuildGeneral()
            local kids = { content:GetChildren() }
            for _, c in ipairs(kids) do c:Hide(); c:SetParent(nil) end
            local regions = { content:GetRegions() }
            for _, r in ipairs(regions) do if r.Hide then r:Hide() end end
            content:SetHeight(400)
            BuildGeneralTab(content, spec)
        end
        generalRefreshFn = RebuildGeneral
        BuildGeneralTab(content, spec)
    elseif idx == 2 then
        editorRefreshFn = function()
            BuildRotationTab(content, spec)
        end
        BuildRotationTab(content, spec)
    elseif idx == 3 then
        BuildPreviewTab(content, spec)
    elseif idx == 4 then
        BuildCastBarTab(content, spec)
    elseif idx == 5 then
        BuildLoadConditionsTab(content, spec)
    elseif idx == 6 then
        BuildImportExportTab(content, spec)
    end

    -- Reset scroll
    if self._scroll then
        self._scroll:SetVerticalScroll(preserveScroll and scrollPos or 0)
    end
end

function SUI:RefreshCurrentTab()
    if self._activeTab then
        self:SwitchTab(self._activeTab, self._spec, true)
    end
end

function SUI:Close()
    if self.frame then
        self.frame:Hide()
    end
end

------------------------------------------------------------------------
-- Register as SpecManager helper + slash command
------------------------------------------------------------------------
if A.SpecManager then
    A.SpecManager:RegisterHelper("SpecUI", {
        OnSpecActivate   = function(self, spec) end,
        OnSpecDeactivate = function(self, spec)
            if A.SpecUI and A.SpecUI.frame then
                A.SpecUI:Close()
            end
        end,
    })
end
