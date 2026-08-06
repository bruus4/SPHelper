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

    -- Sort items alphabetically by display text, WITHIN each section: runs
    -- of plain items between isHeader items are sorted independently and
    -- headers keep their position. Menus without headers (a single run)
    -- sort globally, exactly as before.
    local sortedItems = {}
    for _, item in ipairs(items) do
        sortedItems[#sortedItems + 1] = item
    end
    local function SortRun(a, b)
        local ta = tostring(a.text or a.value or "")
        local tb = tostring(b.text or b.value or "")
        if ta == tb then return false end
        return ta < tb
    end
    local runStart = 1
    for i = 1, #sortedItems + 1 do
        local item = sortedItems[i]
        if i > #sortedItems or (item and item.isHeader) then
            if runStart < i then
                local run = {}
                for j = runStart, i - 1 do run[#run + 1] = sortedItems[j] end
                table.sort(run, SortRun)
                for j = 1, #run do sortedItems[runStart + j - 1] = run[j] end
            end
            runStart = i + 1
        end
    end

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

        if item.isHeader then
            -- Section header: dim, non-clickable divider row.
            local bg = btn:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(0.16, 0.13, 0.22, 0.95)
            local htxt = btn:CreateFontString(nil, "OVERLAY")
            htxt:SetFont(FONT, 9, "OUTLINE")
            htxt:SetPoint("LEFT",  btn, "LEFT",  6, 0)
            htxt:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
            htxt:SetJustifyH("LEFT")
            htxt:SetText(tostring(item.text or ""))
            htxt:SetTextColor(1, 0.82, 0.4, 1)
            btn:EnableMouseWheel(true)
            btn:SetScript("OnMouseWheel", function(_, delta) DoScroll(delta) end)
            rowBtns[#rowBtns + 1] = { btn = btn, item = item }
        else
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
        -- Optional 14px spell icon left of the label (used by the ability
        -- pickers); the text shifts right to make room for it.
        local textLeft = 6
        if item.icon then
            local ic = btn:CreateTexture(nil, "ARTWORK")
            ic:SetSize(14, 14)
            ic:SetPoint("LEFT", btn, "LEFT", 6, 0)
            ic:SetTexture(item.icon)
            textLeft = 26
        end
        txt:SetPoint("LEFT",  btn, "LEFT",  textLeft, 0)
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
        end -- /else (non-header row)

        rowBtns[#rowBtns + 1] = { btn = btn, item = item }
    end

    -- ── Filter + layout ────────────────────────────────────────────
    local function RefreshList(filter)
        filter = filter and filter:lower() or ""
        local visY = 0
        for _, row in ipairs(rowBtns) do
            local itemText = tostring(row.item.text or row.item.value or ""):lower()
            local isHdr = row.item.isHeader
            -- Headers show only with an empty filter (sections would be
            -- confusing mid-search); plain rows match the filter as usual.
            if (isHdr and filter == "") or (not isHdr and (filter == "" or itemText:find(filter, 1, true))) then
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

    -- Enter: pick first visible non-header row
    searchEB:SetScript("OnEnterPressed", function()
        for _, row in ipairs(rowBtns) do
            if not row.item.isHeader and row.btn:IsShown() then
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

    -- Show explicitly: focusing the search box does NOT make a hidden
    -- frame visible, so without this the menu would never appear.
    frame:Show()

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
-- Tab 1 – General (merged & fully configurable options)
------------------------------------------------------------------------

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
        -- settingKey references (classification_any_target, classification_from_setting)
        if cond.settingKey and type(cond.settingKey) == "string" and not seen[cond.settingKey] then
            keys[#keys + 1] = cond.settingKey
            seen[cond.settingKey] = true
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
            group   = def.group,          -- ability/group name for visual grouping in General tab
            _fromFile = true,
        }
    end

    -- Helper: add from defs or from legacy uiOptions
    local function AddKey(key)
        if seen[key] or deleted[key] then return end
        seen[key] = true
        local opt
        if defs and defs[key] then
            opt = DefToOpt(key, defs[key])
        elseif spec.uiOptions then
            for _, o in ipairs(spec.uiOptions) do
                if o.key == key then
                    opt = {}
                    for k, v in pairs(o) do opt[k] = v end
                    opt._fromFile = true
                    break
                end
            end
        end
        -- DB overrides (edits made from the General tab in edit mode) are
        -- merged over the file definition so they survive reloads.
        if opt then
            local ov = sdb and sdb.settingOverrides and sdb.settingOverrides[key]
            if ov then
                for k, v in pairs(ov) do
                    if k ~= "key" and k ~= "_fromFile" then opt[k] = v end
                end
                opt._hasOverride = true
            end
            merged[#merged + 1] = opt
        end
    end

    -- Rotation-referenced settings (in encounter order).
    -- Priority: in-memory editor data (reflects unsaved deletions/additions)
    -- → DB-saved rotation.
    -- NOTE: spec.rotation (file default) is intentionally NOT used here so
    -- that deleting all rotation entries produces an empty General tab.
    local effectiveRotation =
        (editorData and editorSpecID == specID and editorData) or
        (sdb and sdb.rotation)
    local rotKeys = CollectRotationSettingKeys(effectiveRotation)
    for _, key in ipairs(rotKeys) do AddKey(key) end

    -- Spec-declared extra General settings (settings read by
    -- engine logic rather than directly referenced in rotation conditions)
    if spec.generalSettings then
        for _, key in ipairs(spec.generalSettings) do AddKey(key) end
    end

    -- All remaining settingDefs not yet surfaced.
    -- This ensures every spec-declared setting is visible in the General tab
    -- regardless of whether the rotation has been saved yet.
    if defs then
        local remainingKeys = {}
        for key in pairs(defs) do
            if not seen[key] then remainingKeys[#remainingKeys + 1] = key end
        end
        table.sort(remainingKeys)
        for _, key in ipairs(remainingKeys) do AddKey(key) end
    end

    -- castBarOptions (rendered in the CastBar & FQ tab; exposed here too)
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

    -- DB custom options
    -- Skip any entry whose key is already defined in settingDefs — those were
    -- erroneously auto-created before settingDefs existed.
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

-- Sentinel picked in option/setting pickers: opens the Add Option dialog
-- instead of storing a value (used by CEFieldEditor).
local NEW_SETTING_SENTINEL = "__sph_new_setting__"

-- Friendly display names for programmatic field values.
local SUBJECT_LABELS = {
    resource_pct                 = "Resource %",
    player_hp_pct                = "Player HP %",
    player_hp                    = "Player HP",
    target_hp_pct                = "Target HP %",
    target_hp                    = "Target HP",
    player_mana_pct              = "Player Mana %",
    player_base_mana_pct         = "Player Base Mana %",
    combo_points                 = "Combo Points",
    target_ttd                   = "Target TTD",
    resource                     = "Resource",
    resource_at_gcd              = "Resource @ Ready",
    next_power_tick_with_gcd     = "Next Power Tick @ Ready",
    threat_pct                   = "Threat %",
    tracked_target_count         = "Tracked Target Count",
    tracked_targets_with_ttd     = "Tracked Targets w/ TTD",
    channel_tick_interval        = "Channel Tick Interval",
    channel_ticks_remaining      = "Channel Ticks Remaining",
    channel_time_to_next_tick    = "Time to Next Channel Tick",
    moving                       = "Moving",
    pet_alive                    = "Pet Alive",
    pet_attacking                = "Pet Attacking",
    swing_mh                     = "Main-hand Swing",
    swing_oh                     = "Off-hand Swing",
    swing_ranged                 = "Ranged Swing",
    feral_mode                   = "Feral Mode",
}
local RESOURCE_LABELS = {
    mana = "Mana", hp = "HP", energy = "Energy", rage = "Rage", focus = "Focus",
}
local CLASS_LABELS = {
    boss = "Boss", elite = "Elite", normal = "Normal", none = "None",
}
local UNIT_LABELS = {
    player = "Player", target = "Target", focus = "Focus", mouseover = "Mouseover",
}

-- Resolve the friendly label of a spec option key (settingDefs / uiOptions /
-- castBarOptions / customOptions via the merged list).  Returns nil when the
-- key is unknown so callers can fall back to the raw key.
local function GetOptionDisplayLabel(optionKey, specID)
    if not optionKey then return nil end
    local spec = specID and A.SpecManager and A.SpecManager:GetSpecByID(specID)
    if not spec then return nil end
    for _, opt in ipairs(GetMergedOptions(spec, specID)) do
        if opt.key == optionKey then
            return opt.label or opt.key
        end
    end
    return nil
end

-- Render a single spec option row (checkbox / slider / dropdown) at offset y
-- inside `container`.  Shared by the General tab and the Rotation editor's
-- Options section.  Returns the new y offset (negative, growing downward).
-- Forward declaration: SUIButtonR is defined further below (with the other
-- rotation-tab layout helpers) but RenderOptionRow and BuildGeneralTab use
-- it.  Lua resolves non-local names at compile time, so without this
-- declaration the references would compile as (nil) globals and the General
-- tab would error on every open.
local SUIButtonR

local function RenderOptionRow(container, opt, y)
    -- Per-option reset to default (G5): drops the DB override so the value
    -- falls back to the option's default. Placed left of the edit/del
    -- cluster; visible in read-only mode too so defaults can be restored
    -- without entering edit mode.
    local rstBtn = SUIButtonR(container, "Reset", 44, 16, function()
        local specID = A._activeSpecID
        local sdb = A.db and A.db.specs and A.db.specs[specID]
        if sdb and sdb[opt.key] ~= nil then
            sdb[opt.key] = nil
        end
        if A.SpecUI and A.SpecUI.RefreshCurrentTab then
            A.SpecUI:RefreshCurrentTab()
        end
    end, 84, y)
    rstBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Reset to default", 1, 1, 1, 1, true)
        GameTooltip:AddLine("Removes your override for this option; the default value applies again.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    rstBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

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
        return y - 26
    elseif opt.type == "slider" then
        local s, lbl = SUISlider(container, opt.label, opt.min or 0, opt.max or 100, opt.step or 1,
            function() return A.SpecVal(opt.key, opt.default) end,
            function(v) A.SetSpecVal(opt.key, v) end,
            16, y)
        if tooltip and lbl then
            lbl:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(opt.label); GameTooltip:AddLine(tooltip, 1, 1, 1, true); GameTooltip:Show() end)
            lbl:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        return y - 38
    elseif opt.type == "dropdown" then
        local dd, lbl = SUIDropdown(container, opt.label, opt.values or {},
            function() return A.SpecVal(opt.key, opt.default) end,
            function(v)
                A.SetSpecVal(opt.key, v)
                -- Preview tick sounds immediately when their dropdown changes.
                if A.PlayTickSound and opt.key and opt.key:match("tickSound$") then
                    pcall(A.PlayTickSound, v)
                end
            end,
            16, y)
        if tooltip and lbl then
            lbl:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(opt.label); GameTooltip:AddLine(tooltip, 1, 1, 1, true); GameTooltip:Show() end)
            lbl:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        return y - 50
    end
    return y
end

-- Forward declaration: OpenAddOptionDialog is defined further below (with the
-- Add Option dialog) but BuildGeneralTab's "+ Add Option" button calls it.
-- Same compile-time resolution rule as SUIButtonR above.
local OpenAddOptionDialog

-- Forward declaration: GetTabIndex is defined further below (with the tab
-- helpers) but the Preview ticker, the CastBar refresh and the Load Cond.
-- tab call it. Without this declaration those calls compile as (nil)
-- globals and crash at runtime ("attempt to call a nil value").
local GetTabIndex

------------------------------------------------------------------------
-- Rotation-reference awareness for General tab options.
------------------------------------------------------------------------

-- Effective rotation entries for a spec: DB override first, else file.
local function GetSpecRotationEntries(spec)
    if not spec or not spec.meta then return {} end
    local db = A.db and A.db.specs and A.db.specs[spec.meta.id]
    return (db and db.rotation) or spec.rotation or {}
end

-- Count rotation conditions that reference `key` via their optionKey /
-- settingKey / safetyKey / value fields, recursing through nested
-- any_of / all_of / not groups.  Used to warn when editing/deleting an
-- option that the rotation depends on.
local function CountRotationOptionRefs(entries, key)
    if not key then return 0 end
    local count = 0
    local function ScanConditions(conds)
        for _, cond in ipairs(conds or {}) do
            if cond.optionKey == key or cond.settingKey == key
                or cond.safetyKey == key or cond.value == key then
                count = count + 1
            end
            if cond.conditions then ScanConditions(cond.conditions) end
            if cond.condition then ScanConditions({ cond.condition }) end
        end
    end
    for _, entry in ipairs(entries or {}) do
        ScanConditions(entry.conditions)
    end
    return count
end

local function BuildGeneralTab(container, spec)
    local y = -8
    local specID = spec.meta.id
    local sdb = A.db and A.db.specs and A.db.specs[specID]
    -- Edit mode (toggled via /sph edit) gates the custom-option controls:
    -- without it the General tab is read-only.
    local editMode = A.db and A.db.specUI and A.db.specUI.editMode

    -- Custom options are created and removed here (file options are fixed).
    -- Visible only in edit mode.
    if editMode then
        SUIButtonR(container, "+ Add Option", 84, 18, function()
            OpenAddOptionDialog(spec)
        end, 116, y)
    end
    y = y - 26

    local merged = GetMergedOptions(spec, specID)

    -- Render all merged options (skip castBar options — they live in tab 4).
    -- Grouped settings are separated visually with a header and divider line.

    -- Re-sort merged options so that all settings sharing the same group are
    -- contiguous, even if rotation encounter order scattered them. Within each
    -- group we preserve original relative order (stable sort). Ungrouped settings
    -- appear at the end in their original order.
    local grouped = {}   -- {group, opts={...}}
    local ungrouped = {}
    local groupOrder = {}  -- first-encounter order of groups
    local seenGroup = {}
    for i, opt in ipairs(merged) do
        if not opt._fromCastBar then
            if opt.group and not seenGroup[opt.group] then
                seenGroup[opt.group] = true
                groupOrder[#groupOrder + 1] = opt.group
                grouped[opt.group] = {}
            end
            if opt.group then
                grouped[opt.group][#grouped[opt.group] + 1] = { idx = i, opt = opt }
            else
                ungrouped[#ungrouped + 1] = { idx = i, opt = opt }
            end
        end
    end

    -- Flatten back into a single list: groups in first-encounter order, then ungrouped.
    local sorted = {}
    for _, g in ipairs(groupOrder) do
        for _, entry in ipairs(grouped[g]) do
            sorted[#sorted + 1] = entry.opt
        end
    end
    for _, entry in ipairs(ungrouped) do
        sorted[#sorted + 1] = entry.opt
    end

    local lastGroup = nil
    for i, opt in ipairs(sorted) do
        -- Emit group separator when the group changes (only for grouped options)
        if opt.group and opt.group ~= lastGroup then
            y = y - 12   -- spacing above the group header

            -- Group header label (top-aligned at y).
            -- NOTE: must anchor TOPLEFT — anchoring to "LEFT" pins to the
            -- container's vertical CENTER, which offsets headers by half the
            -- panel height and misaligns them with the settings below.
            local grpLabel = container:CreateFontString(nil, "OVERLAY")
            grpLabel:SetFont(FONT, 9, "")
            grpLabel:SetPoint("TOPLEFT", container, "TOPLEFT", 16, y)
            grpLabel:SetTextColor(0.85, 0.72, 1, 1)
            grpLabel:SetText(opt.group)

            -- Separator line below the label (also TOPLEFT/TOPRIGHT anchored)
            y = y - 14
            local sepLine = container:CreateTexture(nil, "OVERLAY")
            sepLine:SetPoint("TOPLEFT", container, "TOPLEFT", 16, y)
            sepLine:SetPoint("TOPRIGHT", container, "TOPRIGHT", -16, y)
            sepLine:SetHeight(1)
            sepLine:SetColorTexture(0.45, 0.38, 0.62, 0.7)

            -- Gap between the line and the first setting of the group so the
            -- separator never collides with (or sits directly on) the row below
            y = y - 8

            lastGroup = opt.group
        elseif not opt.group then
            -- Reset group tracking when we hit an ungrouped option
            lastGroup = nil
        end

        local rowY = y
        y = RenderOptionRow(container, opt, y)
        -- Edit/Del buttons for every option, shown only in edit mode.
        -- Custom options are edited/removed in the DB directly; file options
        -- are edited via a per-spec override (the spec file is never mutated)
        -- and "deleted" by hiding them (see the Restore button below).
        if editMode then
            local editKey = opt.key
            SUIButtonR(container, "Edit", 24, 16, function()
                if opt._fromFile then
                    -- Pass the merged option; Save writes a DB override.
                    OpenAddOptionDialog(spec, opt)
                else
                    local co = sdb and sdb.customOptions
                    if co then
                        for _, entry in ipairs(co) do
                            if entry.key == editKey then
                                -- Reopen the Add Option dialog prefilled; Save
                                -- updates this entry in place.
                                OpenAddOptionDialog(spec, entry)
                                break
                            end
                        end
                    end
                end
            end, 56, rowY)
            local delKey = opt.key
            SUIButtonR(container, "Del", 24, 16, function()
                -- Warn when the rotation still references this option.
                local refs = CountRotationOptionRefs(GetSpecRotationEntries(spec), opt.key)
                if refs > 0 then
                    print(string.format("|cffffcc00[SPHelper] Warning: option '%s' is used by %d rotation condition(s).|r", opt.key, refs))
                end
                if opt._fromFile then
                    -- Hide a file option: mark it deleted so GetMergedOptions
                    -- skips it, and drop any override for it.  Create the
                    -- per-spec namespace on demand (it may not exist yet for
                    -- specs that were never customized).
                    if not sdb then
                        if not A.db.specs then A.db.specs = {} end
                        sdb = {}
                        A.db.specs[specID] = sdb
                    end
                    sdb.deletedOptions = sdb.deletedOptions or {}
                    sdb.deletedOptions[delKey] = true
                    if sdb.settingOverrides then sdb.settingOverrides[delKey] = nil end
                else
                    local co = sdb and sdb.customOptions
                    if co then
                        for ci = #co, 1, -1 do
                            if co[ci].key == delKey then table.remove(co, ci) end
                        end
                    end
                end
                if A.SpecUI and A.SpecUI.RefreshCurrentTab then
                    A.SpecUI:RefreshCurrentTab()
                end
            end, 28, rowY)
        end
    end

    -- In edit mode, offer to bring back file options hidden with Del.
    if editMode and sdb and sdb.deletedOptions and next(sdb.deletedOptions) then
        y = y - 12
        SUIButtonR(container, "Restore hidden options", 150, 18, function()
            sdb.deletedOptions = {}
            if A.SpecUI and A.SpecUI.RefreshCurrentTab then
                A.SpecUI:RefreshCurrentTab()
            end
        end, 16, y)
        y = y - 24
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
    { type = "melee_range",                label = "Melee Range (≤6y)",    fields = {} },
    { type = "not_melee_range",            label = "Not Melee Range (>6y)",fields = {} },
    { type = "wand_equipped",              label = "Wand Equipped",        fields = {} },
    { type = "channeling",                 label = "Is Channeling",        fields = {} },
    { type = "cooldown_lt",                label = "Cooldown < Seconds",   fields = { "spellKey", "seconds" } },
    { type = "spell_usable",               label = "Spell Ready",          fields = { "spellKey" } },
    { type = "group_size_gte",             label = "Group Size >=",         fields = { "size" } },
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
    { type = "trinket_ready",             label = "Trinket On-Use Ready",  fields = { "slot" } },
    { type = "classification_any_target",   label = "Class. Any Target (from setting)", fields = { "settingKey" } },
    { type = "classification_from_setting", label = "Class. Current Target (from setting)", fields = { "settingKey" } },
    { type = "not_in_combat",              label = "Not In Combat",         fields = {} },
    { type = "any_of",                     label = "OR Group",             fields = {} },
    { type = "all_of",                     label = "AND Group",            fields = {} },
    { type = "not",                        label = "Not",                  fields = {} },
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

-- Section grouping for the condition-type picker menu (G7). Each group is
-- rendered under a header row; items sort alphabetically within their group.
local COND_GROUPS = {
    { "Flow & Combat",      { "always", "target_valid", "in_combat", "not_in_combat", "precombat", "channeling", "any_of", "all_of", "not" } },
    { "Target & Damage",    { "target_hp_pct_lt", "target_hp_pct_gt", "target_hp_lt", "target_dying_fast", "target_ttd_gte", "target_ttd_lt", "target_classification", "option_gated_classification", "classification_any_target", "classification_from_setting", "spell_can_kill_target", "behind_target", "not_behind_target", "melee_range", "not_melee_range", "wand_equipped" } },
    { "Player & Resources", { "player_hp_pct_lt", "player_hp_pct_gt", "player_mana_pct_lt", "player_mana_pct_gt", "player_base_mana_pct_lt", "player_base_mana_pct_gt", "resource_pct_lt", "resource_pct_gt", "resource_gte", "resource_lt", "resource_required_gte", "resource_at_gcd_lt", "resource_at_gcd_gt", "next_power_tick_with_gcd_lt", "next_power_tick_with_gcd_gt", "combo_points_gte", "combo_points_lt", "state_compare" } },
    { "Buffs & Debuffs",    { "buff_on_player", "buff_stacks_gte", "not_buff_on_player", "buff_property_compare", "debuff_on_target", "debuff_time_left_lt", "not_debuff_on_target", "debuff_property_compare", "dot_missing", "projected_dot_time_left_lt", "dot_time_left_lt", "other_targets_with_debuff_lt" } },
    { "Cooldowns & Items",  { "cooldown_ready", "cooldown_lt", "spell_usable", "spell_property_compare", "not_recently_cast", "unit_cast_compare", "unit_interruptible", "trinket_ready", "item_ready_and_owned", "item_ready_by_key" } },
    { "Spec Options",       { "spec_option_enabled", "spec_option_value", "setting_compare", "content_mode_allow", "content_type" } },
    { "Threat & Group",     { "threat_pct_lt", "threat_pct_ge", "group_size_gte" } },
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
local condEditorFrame = nil
local ceState = {}
local pendingPickerRow = nil  -- row index whose spell picker should auto-open after Refresh
local advExpanded = {}        -- entry table -> advanced row expanded (keyed by table identity)

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
    -- Pseudo-keys (SWD_EXEC, TRINKET1, POTION, ...) are literal rotation keys:
    -- pass them through so picker value matching keeps working.
    local ps = A.SPELLS and A.SPELLS[rawValue]
    if ps and ps.pseudo then
        return rawValue
    end
    local def = A.GetSpellDefinition and A.GetSpellDefinition(rawValue)
    if def and def.name and def.name ~= "" then
        return def.name
    end
    return rawValue
end

-- Display label for a rotation entry key.  Pseudo-keys (SWD_EXEC, TRINKET1,
-- POTION, ...) resolve through their A.SPELLS record to a human-readable
-- label; everything else (catalog keys = spell names) shows as-is.
local function SpellDisplayLabel(key)
    if type(key) ~= "string" then return tostring(key or "") end
    local spell = A.SPELLS and A.SPELLS[key]
    if spell and spell.label and spell.label ~= "" then
        return spell.label
    end
    return key
end

-- Map a user-typed label (or raw key) back to a canonical rotation key.
-- Exact key match wins; otherwise match against spell labels/names.
local function SpellKeyFromLabel(label)
    if type(label) ~= "string" then return nil end
    local trimmed = label:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" or not A.SPELLS then return nil end
    if A.SPELLS[trimmed] then
        local s = A.SPELLS[trimmed]
        if s.key and (s.key == trimmed or (s.label and s.label == trimmed)) then
            return s.key
        end
        return trimmed
    end
    for k, s in pairs(A.SPELLS) do
        if (s.label and s.label == trimmed) or (s.name and s.name == trimmed) then
            return k
        end
    end
    return nil
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

-- Convert a list of raw values to { text = friendly, value = raw } entries
-- so pickers display readable names while the DB stores the raw values.
local function LabeledValues(rawList, labelMap)
    local out = {}
    for _, v in ipairs(rawList) do
        out[#out + 1] = { text = (labelMap and labelMap[v]) or tostring(v), value = v }
    end
    return out
end

-- Setting-key pickers (optionKey / safetyKey / slider-reference fields):
-- show the option's friendly label, store the raw key, and offer a
-- "+ New Setting…" entry that opens the Add Option dialog inline.
-- Returns nil for an empty list so CEFieldEditor falls back to the
-- free-text editbox (raw key / numeric literal entry stays possible).
local function SettingKeyPicker(keys)
    if not keys or #keys == 0 then return nil end
    local specID = A._activeSpecID
    local out = {}
    for _, k in ipairs(keys) do
        out[#out + 1] = { text = GetOptionDisplayLabel(k, specID) or k, value = k }
    end
    table.sort(out, function(a, b) return tostring(a.text) < tostring(b.text) end)
    out[#out + 1] = { text = "+ New Setting…", value = NEW_SETTING_SENTINEL }
    return out
end

local FIELD_DROPDOWNS = {
    spellKey = function()
        local keys = {}
        local classFilter = GetEditorSpellClass()
        if A.SpellData and A.SpellData.GetSpellKeysForEditor then
            for _, spell in ipairs(A.SpellData:GetSpellKeysForEditor(classFilter) or {}) do
                -- Skip pseudo-keys here: condition spellKey fields must hold
                -- real spell names (e.g. "Shadow Word: Death"), never "SWD_EXEC".
                if spell and spell.key and not spell.pseudo then
                    local displayName = spell.resolvedName or spell.name or spell.key
                    keys[#keys + 1] = {
                        key = displayName,
                        text = displayName,
                        value = displayName,
                        class = spell.class,
                        resolvedName = spell.resolvedName,
                        icon = spell.icon,
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
        return LabeledValues({ "mana", "hp", "energy", "rage", "focus" }, RESOURCE_LABELS)
    end,
    subject = function()
        return LabeledValues({
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
            "moving",
            "pet_alive",
            "pet_attacking",
            "swing_mh",
            "swing_oh",
            "swing_ranged",
            "feral_mode",
        }, SUBJECT_LABELS)
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
        return LabeledValues({ "player", "target", "focus", "mouseover" }, UNIT_LABELS)
    end,
    source = function()
        return LabeledValues({ "player", "any" }, { player = "Player", any = "Any" })
    end,
    classification = function()
        return LabeledValues({ "boss", "elite", "normal", "none" }, CLASS_LABELS)
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
        return SettingKeyPicker(keys)
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
        return LabeledValues({ "faster", "slower" }, { faster = "Faster", slower = "Slower" })
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
        if A.db and A.db.specs and specID and A.db.specs[specID] and A.db.specs[specID].customOptions then
            for _, opt in ipairs(A.db.specs[specID].customOptions) do
                if not seen[opt.key] then seen[opt.key] = true; keys[#keys + 1] = opt.key end
            end
        end
        if #keys == 0 then return nil end
        return SettingKeyPicker(keys)
    end,
    pct = function()
        -- Spec option keys that can be used as dynamic numeric references
        return SettingKeyPicker(CollectSliderOptionKeys())
    end,
    count = function() return SettingKeyPicker(CollectSliderOptionKeys()) end,
    minTTD = function() return SettingKeyPicker(CollectSliderOptionKeys()) end,
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
    elseif field == "optionKey" or field == "settingKey" then
        local specID = activeSpec and activeSpec.meta and activeSpec.meta.id
        local lbl = specID and GetOptionDisplayLabel(value, specID)
        if lbl then return lbl end
    elseif field == "subject" then
        local s = SUBJECT_LABELS[tostring(value)]
        if s then return s end
    elseif field == "resource" then
        local r = RESOURCE_LABELS[tostring(value)]
        if r then return r end
    elseif field == "classification" then
        local c = CLASS_LABELS[tostring(value)]
        if c then return c end
    elseif field == "unit" then
        local u = UNIT_LABELS[tostring(value)]
        if u then return u end
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

    -- setting_compare: "optionKey op value"  e.g. "Use Trinket 1 = enable"
    if cond.type == "setting_compare" then
        local opSym = cond.op or "="
        if opSym == "==" then opSym = "=" end
        local specID = activeSpec and activeSpec.meta and activeSpec.meta.id
        local keyLabel = (specID and GetOptionDisplayLabel(cond.optionKey, specID)) or cond.optionKey or "?"
        return tostring(keyLabel) .. " " .. opSym .. " "
               .. FormatPreviewValue("value", cond.value, activeSpec)
    end

    -- state_compare: "subject op value"  e.g. "Player Mana % < 25"
    if cond.type == "state_compare" then
        local opSym = cond.op or "="
        if opSym == "==" then opSym = "=" end
        local subject = tostring(cond.subject or "?")
        return (SUBJECT_LABELS[subject] or subject) .. " " .. opSym .. " "
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

    -- trinket_ready: "Trinket 1 ready" / "Trinket 2 ready"
    if cond.type == "trinket_ready" then
        local slot = tonumber(cond.slot) or 13
        return "Trinket " .. (slot == 13 and "1" or "2") .. " ready"
    end

    -- classification_any_target / classification_from_setting: "Class. [settingKey] on any target"
    if cond.type == "classification_any_target" then
        local specID = activeSpec and activeSpec.meta and activeSpec.meta.id
        local keyLabel = (specID and GetOptionDisplayLabel(cond.settingKey, specID)) or cond.settingKey or "?"
        return "Class. " .. tostring(keyLabel) .. " on any target"
    end
    if cond.type == "classification_from_setting" then
        local specID = activeSpec and activeSpec.meta and activeSpec.meta.id
        local keyLabel = (specID and GetOptionDisplayLabel(cond.settingKey, specID)) or cond.settingKey or "?"
        return "Class. " .. tostring(keyLabel) .. " on current target"
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
        "debuff", "buff", "itemKey", "itemId", "dbKey", "classification", "settingKey",
        "contentType", "direction", "window", "size", "amount", "points", "count", "pctPerSec",
        "minTTD", "slot",
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

--- Persist the rotation editor buffer to the DB. Used by the Save button and
--- by the auto-save guards (window close, spec switch) so unsaved edits are
--- never silently discarded. Returns true on success.
local function SaveRotationEditor()
    if not editorData or not editorSpecID then return false end
    local spec = A.SpecManager and A.SpecManager.GetSpecByID and A.SpecManager:GetSpecByID(editorSpecID)
    if not spec then return false end
    -- Validate the editor buffer before persisting: malformed conditions,
    -- empty keys and bad repeatLimits should be caught here, not silently saved.
    if A.SpecValidator and A.SpecValidator.ValidateRotation then
        local ok, valErr = A.SpecValidator:ValidateRotation(editorData)
        if not ok then
            print("|cffff4444SPHelper|r: Rotation NOT saved: " .. tostring(valErr))
            return false, valErr
        end
    end
    if not A.db.specs then A.db.specs = {} end
    if not A.db.specs[editorSpecID] then A.db.specs[editorSpecID] = {} end
    A.db.specs[editorSpecID].rotation = DeepCopy(editorData)
    -- RotationEngine reads DB rotation on every Evaluate() call, so no
    -- deactivate/reactivate needed - the next tick picks up the new data.
    editorDirty = false
    if editorRefreshFn then editorRefreshFn() end

    -- Auto-discover spec_option references and create missing options
    local referencedKeys = {}
    for _, entry in ipairs(editorData) do
        for _, cond in ipairs(entry.conditions or {}) do
            if (cond.type == "spec_option_enabled" or cond.type == "spec_option_value") and cond.optionKey then
                referencedKeys[cond.optionKey] = true
            end
        end
    end
    local existingKeys = {}
    if spec.settingDefs then
        for key in pairs(spec.settingDefs) do existingKeys[key] = true end
    end
    for _, opt in ipairs(spec.uiOptions or {}) do existingKeys[opt.key] = true end
    local custOpts = A.db.specs[editorSpecID] and A.db.specs[editorSpecID].customOptions or {}
    for _, opt in ipairs(custOpts) do existingKeys[opt.key] = true end
    local missing = {}
    for k in pairs(referencedKeys) do
        if not existingKeys[k] then missing[#missing + 1] = k end
    end
    if #missing > 0 then
        if not A.db.specs[editorSpecID].customOptions then
            A.db.specs[editorSpecID].customOptions = {}
        end
        local co = A.db.specs[editorSpecID].customOptions
        for _, k in ipairs(missing) do
            co[#co + 1] = { key = k, type = "checkbox", label = k, default = true }
        end
        print("|cff8882d5SPHelper|r: Auto-created config options: " .. table.concat(missing, ", "))
    end

    -- Warn (but don't block) about keys that resolve to no known spell or
    -- pseudo-key — typo'd spell names save silently and never cast.
    local unresolved = {}
    for _, entry in ipairs(editorData) do
        if entry.key and not A.SPELLS[entry.key] then
            unresolved[#unresolved + 1] = entry.key
        end
    end
    if #unresolved > 0 then
        print("|cffffcc00SPHelper|r: Warning - entries with unknown spell keys (they will never cast): " .. table.concat(unresolved, ", "))
    end

    print("|cff8882d5SPHelper|r: Rotation saved.")
    return true
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
                if value == NEW_SETTING_SENTINEL then
                    -- "+ New Setting…" → open the Add Option dialog inline;
                    -- after saving, RebuildCondEditor refreshes this picker.
                    OpenAddOptionDialog(ceState.spec)
                    return
                end
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
        -- Grouped menu: section headers + alphabetically sorted items per
        -- group; anything not covered by a group lands under "Other".
        local menuItems = {}
        local covered = {}
        for _, group in ipairs(COND_GROUPS) do
            local gName, gTypes = group[1], group[2]
            menuItems[#menuItems + 1] = { isHeader = true, text = gName }
            for _, ct in ipairs(COND_TYPES) do
                if gTypes[ct.type] then
                    covered[ct.type] = true
                    menuItems[#menuItems + 1] = { text = ct.label, value = ct.type }
                end
            end
        end
        local hasOther = false
        for _, ct in ipairs(COND_TYPES) do
            if not covered[ct.type] then
                if not hasOther then
                    menuItems[#menuItems + 1] = { isHeader = true, text = "Other" }
                    hasOther = true
                end
                menuItems[#menuItems + 1] = { text = ct.label, value = ct.type }
            end
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

            -- Move Up / Move Down (always present so columns stay fixed;
            -- disabled at the edges instead of being hidden)
            local upSub = SUIButton(c, "^", 16, 14, function()
                editCond.conditions[csi], editCond.conditions[csi - 1] =
                    editCond.conditions[csi - 1], editCond.conditions[csi]
                RebuildCondEditor()
            end, 350, y)
            upSub:SetEnabled(si > 1)
            local dnSub = SUIButton(c, "v", 16, 14, function()
                editCond.conditions[csi], editCond.conditions[csi + 1] =
                    editCond.conditions[csi + 1], editCond.conditions[csi]
                RebuildCondEditor()
            end, 370, y)
            dnSub:SetEnabled(si < #editCond.conditions)

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

-----------------------------------------------------------------------
-- Rotation tab layout helpers
-----------------------------------------------------------------------

-- Shared edit box: dark backdrop, no autofocus, commit on Enter, ESC clears
-- focus.  onCommit receives the trimmed text (or nil when empty).
local function SUIMakeEditBox(parent, w, x, y, text, onCommit)
    local eb = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    eb:SetSize(w, 18)
    eb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    eb:SetFont(FONT, 9, "")
    eb:SetAutoFocus(false)
    eb:SetTextColor(1, 1, 1, 1)
    A.CreateBackdrop(eb, 0.1, 0.1, 0.1, 0.8, 0.3, 0.3, 0.3, 0.8)
    eb:SetTextInsets(4, 4, 0, 0)
    eb:SetText(tostring(text or ""))
    eb:SetScript("OnEnterPressed", function(self)
        local val = strtrim(self:GetText() or "")
        if onCommit then onCommit(val ~= "" and val or nil) end
        self:ClearFocus()
    end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return eb
end

-- Truncate `text` to fit maxWidth at font 9, appending an ellipsis.
local _truncProbe = nil
local _truncProbeParent = nil
local function TruncateToWidth(parent, text, maxWidth)
    if not _truncProbe or _truncProbeParent ~= parent then
        _truncProbe = parent:CreateFontString(nil, "OVERLAY")
        _truncProbe:SetFont(FONT, 9)
        _truncProbe:Hide()
        _truncProbeParent = parent
    end
    _truncProbe:SetText(text or "")
    if (_truncProbe:GetStringWidth() or 0) <= maxWidth then return text or "" end
    local t = text or ""
    local ell = "\226\128\166"  -- horizontal ellipsis (...)
    while #t > 1 do
        t = t:sub(1, -2)
        _truncProbe:SetText(t .. ell)
        if (_truncProbe:GetStringWidth() or 0) <= maxWidth then
            return t .. ell
        end
    end
    return ell
end

-- Button anchored to the parent's right edge (fixed action columns).
-- rightOff is the distance from the parent's right edge.
SUIButtonR = function(parent, text, w, h, onClick, rightOff, y)
    local btn = SUIButton(parent, text, w, h, onClick, 0, y)
    btn:ClearAllPoints()
    btn:SetPoint("TOPLEFT", parent, "TOPRIGHT", -rightOff - (w or 80), y)
    return btn
end

-----------------------------------------------------------------------
-- Add Option dialog (Rotation editor > Options section)
-----------------------------------------------------------------------
local addOptFrame = nil

-- Create a new custom spec option and persist it to the DB so it shows up
-- in the General tab and can be referenced by spec_option_enabled /
-- spec_option_value conditions (the rotation Save handler auto-creates
-- missing referenced options; this dialog creates them up front).
OpenAddOptionDialog = function(spec, existing)
    if not addOptFrame then
        addOptFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        addOptFrame:SetSize(380, 300)
        addOptFrame:SetPoint("CENTER")
        addOptFrame:SetFrameStrata("TOOLTIP")
        addOptFrame:SetToplevel(true)
        addOptFrame:SetClampedToScreen(true)
        A.CreateBackdrop(addOptFrame, 0.10, 0.10, 0.16, 0.98, 0.3, 0.25, 0.4, 1)
        addOptFrame:SetScript("OnHide", function() CloseActiveScrollMenu() end)
        local content = CreateFrame("Frame", nil, addOptFrame)
        content:SetAllPoints()
        addOptFrame._content = content
    end
    local f = addOptFrame
    local content = f._content
    -- `existing` (a DB custom option) prefills the form for editing; when
    -- present, Save updates that entry in place instead of creating a new one.
    local optDef = {
        type    = existing and existing.type or "checkbox",
        key     = existing and existing.key,
        label   = existing and existing.label,
        default = existing and existing.default,
        min     = existing and existing.min,
        max     = existing and existing.max,
        step    = existing and existing.step,
        values  = existing and existing.values,
    }

    -- Rebuilds the whole form from `optDef`.  Runs on open and whenever the
    -- Type changes, so only the fields that apply to the current type are
    -- shown (no slider range for a checkbox, no values for a slider).  All
    -- inputs write into `optDef` live, so nothing typed is lost on rebuild.
    local function BuildForm()
        local kids = { content:GetChildren() }
        for _, c in ipairs(kids) do c:Hide(); c:SetParent(nil) end
        local regions = { content:GetRegions() }
        for _, r in ipairs(regions) do if r.Hide then r:Hide() end end

        local y = -30
        local t = content:CreateFontString(nil, "OVERLAY")
        t:SetFont(FONT, 11, "OUTLINE"); t:SetPoint("TOP", content, "TOP", 0, -8)
        t:SetText(existing and "|cff8882d5Edit Option|r" or "|cff8882d5Add Option|r")
        local closeBtn = CreateFrame("Button", nil, content)
        closeBtn:SetSize(20, 20); closeBtn:SetPoint("TOPRIGHT", content, "TOPRIGHT", -6, -6)
        local xl = closeBtn:CreateFontString(nil, "OVERLAY")
        xl:SetFont(FONT, 12, "OUTLINE"); xl:SetPoint("CENTER"); xl:SetText("X")
        closeBtn:SetScript("OnClick", function() f:Hide() end)

        local function RowLabel(text, tooltip)
        local fs = content:CreateFontString(nil, "OVERLAY")
        fs:SetFont(FONT, 9)
        fs:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
        fs:SetTextColor(0.8, 0.8, 0.8, 1)
        fs:SetText(text)
        if tooltip then
            fs:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(text, 1, 1, 1, 1, true)
                GameTooltip:AddLine(tooltip, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            fs:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        return fs
    end

    -- Key
    RowLabel("Key (referenced by conditions):", "This setting appears in the General tab. Reference it from rotation entries with the 'Spec Option Enabled' / 'Spec Option = Value' conditions - pick it from the Option list in the condition editor.")
    local rotationEntries = GetSpecRotationEntries(spec)
    local usageFs = content:CreateFontString(nil, "OVERLAY")
    usageFs:SetFont(FONT, 9, "")
    usageFs:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y - 34)
    -- Rotation-reference awareness: shows whether any rotation condition
    -- (including nested groups) uses this option key.  Rechecked when the
    -- key is committed in the editbox.
    local function UpdateUsage()
        local refs = CountRotationOptionRefs(rotationEntries, optDef.key)
        if refs > 0 then
            usageFs:SetText(string.format("|cff88ff88Referenced by %d rotation condition(s).|r", refs))
        else
            usageFs:SetText("|cff888888Not referenced by the rotation.|r")
        end
    end
    local keyEB = SUIMakeEditBox(content, 240, 16, y - 16, optDef.key or "", function(v)
        if v then optDef.key = v end
        UpdateUsage()
    end)
    UpdateUsage()
    -- File options keep their key: overrides only apply to keys that exist in
    -- the spec file, so renaming a file option would orphan the override.
    if existing and existing._fromFile then
        keyEB:SetEnabled(false)
    end
    y = y - 42
    y = y - 18

    -- Type.  Uses the Blizzard UIDropDownMenu (the same mechanism as the
    -- tick-sound dropdown, confirmed working in-game) because the custom
    -- scroll-menu picker's rows were unresponsive in the live client.  The
    -- template's own button opens the list on click.
    RowLabel("Type:", "checkbox / slider / dropdown.")
    suiDropdownCounter = suiDropdownCounter + 1
    local typeDD = CreateFrame("Frame", "SPHSpecUIDDType" .. suiDropdownCounter, content, "UIDropDownMenuTemplate")
    typeDD:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y - 16)
    UIDropDownMenu_SetWidth(typeDD, 110)
    UIDropDownMenu_SetText(typeDD, optDef.type or "checkbox")
    UIDropDownMenu_Initialize(typeDD, function(self, level)
        for _, tv in ipairs({ "checkbox", "slider", "dropdown" }) do
            local info = UIDropDownMenu_CreateInfo()
            info.text    = tv
            info.value   = tv
            info.checked = (tv == optDef.type)
            info.func    = function(self2)
                optDef.type = self2.value
                UIDropDownMenu_SetText(typeDD, tostring(optDef.type))
                -- Rebuild so only the fields for the new type are shown.
                BuildForm()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    y = y - 48

    -- Label
    RowLabel("Label (shown in tabs):")
    local labelEB = SUIMakeEditBox(content, 240, 16, y - 16, optDef.label or "", function(v) if v then optDef.label = v end end)
    y = y - 42

    -- Default
    RowLabel("Default:", "Checkbox: true/false. Slider: number. Dropdown: one of the values.")
    local defaultEB = SUIMakeEditBox(content, 240, 16, y - 16, tostring(optDef.default or ""), function(v) if v then optDef.default = v end end)
    y = y - 42

    -- Type-specific fields: values for dropdowns, slider range for sliders,
    -- nothing extra for checkboxes.
    if optDef.type == "dropdown" then
        RowLabel("Values (comma-separated):")
        local valuesEB = SUIMakeEditBox(content, 240, 16, y - 16, optDef.values and table.concat(optDef.values, ",") or "", function(v) if v then optDef.valuesText = v end end)
        y = y - 42
    elseif optDef.type == "slider" then
        RowLabel("Slider range - Min / Max / Step:")
        local minEB = SUIMakeEditBox(content, 70, 16, y - 16, tostring(optDef.min or 0), function(v) if v then optDef.min = tonumber(v) end end)
        local maxEB = SUIMakeEditBox(content, 70, 92, y - 16, tostring(optDef.max or 100), function(v) if v then optDef.max = tonumber(v) end end)
        local stepEB = SUIMakeEditBox(content, 70, 168, y - 16, tostring(optDef.step or 1), function(v) if v then optDef.step = tonumber(v) end end)
        y = y - 42
    end

    -- Save / Cancel
    local saveFn = function()
        local key = optDef.key or (keyEB and strtrim(keyEB:GetText() or ""))
        if not key or key == "" then
            print("|cffff4444[SPHelper] Option key is required.|r")
            return
        end
        if optDef.type == "dropdown" then
            local values = {}
            -- If the user never touched the values box, keep the prefilled
            -- values from edit mode (valuesText stays nil in that case).
            if optDef.valuesText then
                for part in (tostring(optDef.valuesText or ""):gsub("%s+", "")):gmatch("[^,]+") do
                    values[#values + 1] = part
                end
            else
                for _, v in ipairs(optDef.values or {}) do values[#values + 1] = v end
            end
            if #values == 0 then
                print("|cffff4444[SPHelper] Dropdown options need at least one value.|r")
                return
            end
            optDef.values = values
        end
        optDef.valuesText = nil
        if optDef.type == "checkbox" then
            optDef.default = (optDef.default == true or optDef.default == "true")
        elseif optDef.type == "slider" then
            optDef.default = tonumber(optDef.default) or 0
        end
        local sdb = A.db and A.db.specs
        if not sdb then
            print("|cffff4444[SPHelper] No spec DB available.|r")
            return
        end
        if not sdb[editorSpecID] then sdb[editorSpecID] = {} end
        if not sdb[editorSpecID].customOptions then sdb[editorSpecID].customOptions = {} end
        local co = sdb[editorSpecID].customOptions

        local newOpt = {
            key     = key,
            type    = optDef.type,
            label   = optDef.label or key,
            default = optDef.default,
            min     = optDef.min,
            max     = optDef.max,
            step    = optDef.step,
            values  = optDef.values,
        }
        if existing then
            if existing._fromFile then
                -- File option edit: persist a per-spec override that
                -- GetMergedOptions merges over the file definition.  The
                -- spec file itself is never modified.  A key change just
                -- moves the override (and must not collide with another
                -- file key).
                local defs = spec.settingDefs
                if key ~= existing.key and defs and defs[key] then
                    print("|cffff4444[SPHelper] Option '" .. key .. "' already exists in the spec file.|r")
                    return
                end
                local sSpec = sdb[editorSpecID]
                sSpec.settingOverrides = sSpec.settingOverrides or {}
                if key ~= existing.key then
                    sSpec.settingOverrides[existing.key] = nil
                end
                sSpec.settingOverrides[key] = {
                    type    = optDef.type,
                    label   = optDef.label or key,
                    default = optDef.default,
                    min     = optDef.min,
                    max     = optDef.max,
                    step    = optDef.step,
                    values  = optDef.values,
                }
            else
                -- Edit mode: replace the existing entry's fields in place.  If the
                -- key changed, first make sure the new key isn't taken by another
                -- option (the entry being edited itself is exempt).
                for _, other in ipairs(co) do
                    if other ~= existing and other.key == key then
                        print("|cffff4444[SPHelper] Option '" .. key .. "' already exists.|r")
                        return
                    end
                end
                for k, v in pairs(newOpt) do existing[k] = v end
            end
        else
            -- Add mode: reject duplicate keys.
            for _, other in ipairs(co) do
                if other.key == key then
                    print("|cffff4444[SPHelper] Option '" .. key .. "' already exists.|r")
                    return
                end
            end
            co[#co + 1] = newOpt
        end
        if editorRefreshFn then editorRefreshFn() end
        -- If the dialog was opened from the condition editor's option picker,
        -- rebuild the editor so the new setting shows up in the picker.
        if condEditorFrame and condEditorFrame:IsShown() and RebuildCondEditor then
            RebuildCondEditor()
        end
        -- Opened from the General tab: rebuild it so the new/edited option
        -- appears (editorRefreshFn is only set while the Rotation tab is up).
        if not editorRefreshFn and A.SpecUI and A.SpecUI.RefreshCurrentTab then
            A.SpecUI:RefreshCurrentTab()
        end
        f:Hide()
    end
    local sv = SUIButton(content, "Save", 80, 22, saveFn, 0, 0)
    sv:ClearAllPoints(); sv:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 16, 12)
    local cn = SUIButton(content, "Cancel", 80, 22, function() f:Hide() end, 0, 0)
    cn:ClearAllPoints(); cn:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 106, 12)
    end

    BuildForm()
    -- Blizzard dropdowns open on the shared DropDownList1..10 frames, which
    -- default to DIALOG strata and render BEHIND this TOOLTIP-strata dialog
    -- (the Type list was clickable but invisible for that reason).  Raise
    -- them so any menu opened from this dialog draws above it; the lists are
    -- hidden again whenever the menu closes, so this is safe to leave set.
    for i = 1, 10 do
        local dl = _G["DropDownList" .. i]
        if dl then
            dl:SetFrameStrata("TOOLTIP")
            dl:SetToplevel(true)
        end
    end
    f:Show()
end

-----------------------------------------------------------------------
-- Tab 2 - Rotation
-----------------------------------------------------------------------
local function BuildRotationTab(container, spec)
    -- Clear children
    local kids = { container:GetChildren() }
    for _, c in ipairs(kids) do c:Hide(); c:SetParent(nil) end
    local regions = { container:GetRegions() }
    for _, r in ipairs(regions) do if r.Hide then r:Hide() end end

    if not editorData then
        InitEditorData(spec)
    end

    -- Column grid (fixed positions; right cluster adapts to window width).
    -- Main row:      [#] [^][v] [icon] [Ability......] [...] [Prio]   [Dup][Del]
    -- Condition row:                     AND  <desc..flex..>          [Edit][x]
    local COL_IDX   = 12    -- index number
    local COL_UP    = 36    -- move-up button (16)
    local COL_DN    = 54    -- move-down button (16)
    local COL_ICON  = 72    -- ability icon (16)
    local COL_KEY   = 92    -- ability editbox (130)
    local COL_PICK  = 226   -- spell picker (24)
    local COL_PRIO  = 254   -- split-bucket priority editbox (40)
    local COL_COND  = 108   -- condition joiner/description start
    local CLUSTER_W = 56    -- right action cluster width (Dup/Edit + Del/x)

    local W = container:GetWidth() or (FRAME_W - 60)
    local y = -8

    local function Refresh()
        if editorRefreshFn then editorRefreshFn() end
    end

    ---------------------------------------------------------------
    -- Row 1: status (left) + action buttons (right)
    ---------------------------------------------------------------
    local status = container:CreateFontString(nil, "OVERLAY")
    status:SetFont(FONT, 10)
    status:SetPoint("TOPLEFT", container, "TOPLEFT", 12, y)
    status:SetPoint("RIGHT", container, "RIGHT", -356, 0)
    status:SetTextColor(0.7, 0.7, 0.7, 1)
    local statusText = string.format("%d entries", #editorData)
    if editorDirty then
        statusText = "|cffffcc00" .. statusText .. " - unsaved changes|r"
    end
    status:SetText(TruncateToWidth(container, statusText, W - 368))

    local btnY = y - 1
    local saveBtn = SUIButtonR(container, "Save", 60, 20, function()
        local ok, valErr = SaveRotationEditor()
        if not ok and valErr then
            status:SetText(TruncateToWidth(container, "|cffff4444Not saved: " .. tostring(valErr) .. "|r", W - 368))
        end
    end, 12, btnY)
    saveBtn:SetEnabled(editorDirty)
    saveBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Save rotation", 1, 1, 1, 1, true)
        GameTooltip:AddLine("Writes the edited rotation to this spec's saved settings.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    saveBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    SUIButtonR(container, "Cancel", 60, 20, function()
        InitEditorData(spec)
        Refresh()
    end, 80, btnY)

    SUIButtonR(container, "Reset Default", 100, 20, function()
        -- Only clear the DB override; RotationEngine will revert to file defaults.
        if A.db.specs and A.db.specs[editorSpecID] then
            A.db.specs[editorSpecID].rotation = nil
        end
        InitEditorData(spec)
        Refresh()
        print("|cff8882d5SPHelper|r: Rotation reset to spec defaults.")
    end, 148, btnY)

    SUIButtonR(container, "+ Add Entry", 90, 20, function()
        local newEntry = {
            key = "NEW",
            conditions = {{ type = "always" }},
        }
        editorData[#editorData + 1] = newEntry
        editorDirty = true
        pendingPickerRow = #editorData
        Refresh()
    end, 256, btnY)

    -- Validate the editor buffer in place (structure + unknown spell keys).
    SUIButtonR(container, "Validate", 60, 20, function()
        if not editorData then return end
        if A.SpecValidator and A.SpecValidator.ValidateRotation then
            local ok, valErr = A.SpecValidator:ValidateRotation(editorData)
            if not ok then
                status:SetText(TruncateToWidth(container, "|cffff4444Invalid: " .. tostring(valErr) .. "|r", W - 368))
            else
                local unresolved = {}
                for _, entry in ipairs(editorData) do
                    if entry.key and not A.SPELLS[entry.key] then
                        unresolved[#unresolved + 1] = entry.key
                    end
                end
                if #unresolved > 0 then
                    status:SetText(TruncateToWidth(container,
                        "|cffffcc00Valid structure, unknown keys: " .. table.concat(unresolved, ", ") .. "|r", W - 368))
                else
                    status:SetText(TruncateToWidth(container,
                        "|cff00ff00Valid rotation: " .. #editorData .. " entries|r", W - 368))
                end
            end
        else
            status:SetText(TruncateToWidth(container, "|cffffcc00Validator not loaded|r", W - 368))
        end
    end, 356, btnY)
    y = y - 26

    ---------------------------------------------------------------
    -- Row 2: column headers
    ---------------------------------------------------------------
    local function ColHeader(x, text, tooltip)
        local fs = container:CreateFontString(nil, "OVERLAY")
        fs:SetFont(FONT, 8)
        fs:SetPoint("TOPLEFT", container, "TOPLEFT", x, y)
        fs:SetTextColor(0.55, 0.55, 0.55, 1)
        fs:SetText(text)
        if tooltip then
            fs:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(tooltip, 1, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            fs:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        return fs
    end
    ColHeader(COL_IDX, "#")
    ColHeader(COL_KEY, "Ability")
    ColHeader(COL_PRIO, "Prio", "Split bucket priority (optional). If the two top recommendations share the same priority number, the cast bar splits them in list order.")
    ColHeader(COL_COND, "Conditions")
    local actHdr = ColHeader(0, "Actions")
    actHdr:ClearAllPoints()
    actHdr:SetPoint("TOPRIGHT", container, "TOPRIGHT", -30, y)
    y = y - 16

    ---------------------------------------------------------------
    -- Empty state
    ---------------------------------------------------------------
    if #editorData == 0 then
        pendingPickerRow = nil
        local empty = container:CreateFontString(nil, "OVERLAY")
        empty:SetFont(FONT, 9)
        empty:SetPoint("TOPLEFT", container, "TOPLEFT", 12, y)
        empty:SetTextColor(0.6, 0.6, 0.6, 1)
        empty:SetText("No rotation entries yet. Use '+ Add Entry' to add your first ability.")
        y = y - 20
    end

    ---------------------------------------------------------------
    -- Entry rows
    ---------------------------------------------------------------
    for i, entry in ipairs(editorData) do
        local i2 = i  -- capture loop index for closures

        -- Main row: index | move up/down | ability | picker | priority | dup/del
        local idxFS = container:CreateFontString(nil, "OVERLAY")
        idxFS:SetFont(FONT, 9, "OUTLINE")
        idxFS:SetPoint("TOPLEFT", container, "TOPLEFT", COL_IDX, y + 2)
        idxFS:SetTextColor(1, 0.85, 0.4, 1)
        idxFS:SetText(tostring(i))

        local upBtn = SUIButton(container, "^", 16, 18, function()
            editorData[i2], editorData[i2 - 1] = editorData[i2 - 1], editorData[i2]
            editorDirty = true
            Refresh()
        end, COL_UP, y)
        upBtn:SetEnabled(i2 > 1)
        upBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Move entry up", 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        upBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        local dnBtn = SUIButton(container, "v", 16, 18, function()
            editorData[i2], editorData[i2 + 1] = editorData[i2 + 1], editorData[i2]
            editorDirty = true
            Refresh()
        end, COL_DN, y)
        dnBtn:SetEnabled(i2 < #editorData)
        dnBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Move entry down", 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        dnBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        -- Ability icon (small; question mark for pseudo-keys like IF/NEW)
        local iconDef = A.SPELLS and A.SPELLS[entry.key]
        local iconPath = iconDef and (iconDef.icon
            or (A.GetSpellIconCached and A.GetSpellIconCached(iconDef.id or iconDef.baseId)))
        if not iconPath then
            iconPath = "Interface\\Icons\\INV_Misc_QuestionMark"
        end
        local iconTex = container:CreateTexture(nil, "OVERLAY")
        iconTex:SetSize(16, 16)
        iconTex:SetPoint("TOPLEFT", container, "TOPLEFT", COL_ICON, y + 1)
        iconTex:SetTexture(iconPath)

        -- Ability key editbox (shows the resolved spell label; empty edits are
        -- rejected; known labels/keys resolve to their canonical key, unknown
        -- text is accepted as a raw key so custom pseudo-keys stay possible)
        local keyEB
        keyEB = SUIMakeEditBox(container, 130, COL_KEY, y, SpellDisplayLabel(entry.key), function(val)
            local resolved = SpellKeyFromLabel(val)
            if not resolved then
                local trimmed = tostring(val or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if trimmed == "" then
                    keyEB:SetText(SpellDisplayLabel(entry.key))
                    return
                end
                if trimmed ~= entry.key then
                    entry.key = trimmed
                    editorDirty = true
                    Refresh()
                else
                    keyEB:SetText(SpellDisplayLabel(entry.key))
                end
                return
            end
            if resolved ~= entry.key then
                entry.key = resolved
                editorDirty = true
                Refresh()
            else
                keyEB:SetText(SpellDisplayLabel(entry.key))
            end
        end)
        -- Spell tooltip on key field
        keyEB:SetScript("OnEnter", function(self)
            if entry.key == "NEW" then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("NEW - no ability selected yet", 1, 0.4, 0.4, 1, true)
                GameTooltip:AddLine("Pick an ability with the '...' button, or type a key manually.", 1, 1, 1, true)
                GameTooltip:Show()
                return
            end
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
        -- Placeholder entries get a red key so an un-assigned ability stands out.
        if entry.key == "NEW" then
            keyEB:SetTextColor(1, 0.4, 0.4)
        end

        -- Spell picker button (shows dropdown of known spell keys).
        -- NOTE: split declaration/assignment - a closure passed as an
        -- argument to the SAME statement that assigns its own local sees
        -- nil in Lua 5.1 (upvalue cell), so the one-liner would crash
        -- OpenScrollableListMenu with 'anchor (a nil value)'.
        local spellPickBtn
        spellPickBtn = SUIButton(container, "...", 24, 18, function(self)
            local menuItems = {}
            -- Never let a data-layer error blank the menu: fall back to an
            -- empty list (still opens, search box visible) instead of erroring.
            local spellEntries = {}
            if A.SpellData and A.SpellData.GetSpellKeysForEditor then
                local okSE, se = pcall(A.SpellData.GetSpellKeysForEditor, A.SpellData,
                    (spec.meta and spec.meta.class) or nil)
                if okSE and type(se) == "table" then
                    spellEntries = se
                end
            end
            for _, spellEntry in ipairs(spellEntries) do
                local displayText = spellEntry.label
                        or spellEntry.resolvedName
                        or spellEntry.name
                        or spellEntry.key
                local spellValue = spellEntry.value
                        or spellEntry.resolvedName
                        or spellEntry.name
                        or spellEntry.key
                local item = {
                    text = displayText,
                    value = spellValue,
                    icon = spellEntry.icon,
                }
                if A.SpellData then
                    local okTip, tip = pcall(A.SpellData.GetSpellTooltipText, A.SpellData,
                        spellEntry.id or spellEntry.baseId)
                    if okTip and tip then
                        item.tooltipTitle = displayText
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
                keyEB:SetText(SpellDisplayLabel(entry.key))
                editorDirty = true
                Refresh()
            end, selectedSpellValue)
        end, COL_PICK, y)
        spellPickBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Pick ability", 1, 1, 1, 1, true)
            GameTooltip:AddLine("Choose an ability from the list of known spells.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        spellPickBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        -- Freshly added entries auto-open the spell picker so the user can
        -- replace the placeholder "NEW" key right away (deferred until the
        -- current rebuild is fully done; immediate fallback keeps test mocks
        -- working where C_Timer is absent).
        if pendingPickerRow == i then
            pendingPickerRow = nil
            local btn = spellPickBtn
            if C_Timer and C_Timer.After then
                C_Timer.After(0.05, function() btn:Click() end)
            else
                btn:Click()
            end
        end

        -- Split bucket priority (integer only)
        local prEB
        prEB = SUIMakeEditBox(container, 40, COL_PRIO, y,
            (entry.explicitPriority ~= nil) and tostring(entry.explicitPriority) or "", function(val)
            if not val then
                entry.explicitPriority = nil
                prEB:SetText("")
            else
                local num = tonumber(val)
                if num and num == math.floor(num) then
                    entry.explicitPriority = num
                    prEB:SetText(tostring(num))
                else
                    prEB:SetText((entry.explicitPriority ~= nil) and tostring(entry.explicitPriority) or "")
                    return
                end
            end
            editorDirty = true
            Refresh()
        end)
        prEB:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Split bucket priority", 1, 1, 1, 1, true)
            GameTooltip:AddLine("Optional number. If two ready abilities share the same priority, the cast bar splits them in list order.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        prEB:SetScript("OnLeave", function() GameTooltip:Hide() end)

        -- Advanced toggle (right cluster; expands an extra settings row).
        -- Hidden for IF pseudo-keys, which have no advanced options.
        if entry.key ~= "IF" then
            local advBtn = SUIButtonR(container, "Adv", 24, 18, function()
                if advExpanded[entry] then
                    advExpanded[entry] = nil
                else
                    advExpanded[entry] = true
                end
                Refresh()
            end, CLUSTER_W + 28, y)
            advBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Advanced options", 1, 1, 1, 1, true)
                GameTooltip:AddLine("Filler cast, repeat limit and instant-cast settings.", 1, 1, 1, true)
                GameTooltip:Show()
            end)
            advBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end

        -- Duplicate / remove (right cluster, same columns as Edit/x below)
        SUIButtonR(container, "Dup", 24, 18, function()
            local copy = DeepCopy(entry)
            table.insert(editorData, i2 + 1, copy)
            editorDirty = true
            Refresh()
        end, CLUSTER_W, y)

        SUIButtonR(container, "Del", 24, 18, function()
            table.remove(editorData, i2)
            editorDirty = true
            Refresh()
        end, 28, y)
        y = y - 24

        -- Advanced settings row (filler / repeat limit / instant cast)
        if advExpanded[entry] and entry.key ~= "IF" then
            local advLbl = container:CreateFontString(nil, "OVERLAY")
            advLbl:SetFont(FONT, 8)
            advLbl:SetPoint("TOPLEFT", container, "TOPLEFT", 14, y + 3)
            advLbl:SetTextColor(0.7, 0.7, 0.7, 1)
            advLbl:SetText("Advanced:")

            local fillCB, fillLbl = SUICheckbox(container, "Filler", function()
                return entry.isFiller or false
            end, function(v)
                entry.isFiller = v
                editorDirty = true
            end, 92, y)
            fillCB:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Filler cast", 1, 1, 1, 1, true)
                GameTooltip:AddLine("Casts this ability whenever no higher-priority action is ready.", 1, 1, 1, true)
                GameTooltip:Show()
            end)
            fillCB:SetScript("OnLeave", function() GameTooltip:Hide() end)

            local repLbl = container:CreateFontString(nil, "OVERLAY")
            repLbl:SetFont(FONT, 9)
            repLbl:SetPoint("TOPLEFT", container, "TOPLEFT", 200, y + 3)
            repLbl:SetTextColor(1, 1, 1, 1)
            repLbl:SetText("Repeat:")
            local repEB
            repEB = SUIMakeEditBox(container, 30, 248, y,
                (entry.repeatLimit ~= nil) and tostring(entry.repeatLimit) or "", function(val)
                if not val then
                    entry.repeatLimit = nil
                    repEB:SetText("")
                else
                    local num = tonumber(val)
                    if num and num == math.floor(num) and num >= 1 then
                        entry.repeatLimit = num
                        repEB:SetText(tostring(num))
                    else
                        repEB:SetText((entry.repeatLimit ~= nil) and tostring(entry.repeatLimit) or "")
                        return
                    end
                end
                editorDirty = true
            end)
            repEB:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Repeat limit", 1, 1, 1, 1, true)
                GameTooltip:AddLine("Maximum consecutive casts before the rotation moves on (optional).", 1, 1, 1, true)
                GameTooltip:Show()
            end)
            repEB:SetScript("OnLeave", function() GameTooltip:Hide() end)

            local instCB, instLbl = SUICheckbox(container, "Instant", function()
                return entry.isInstant or false
            end, function(v)
                entry.isInstant = v
                editorDirty = true
            end, 300, y)
            instCB:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Instant cast", 1, 1, 1, 1, true)
                GameTooltip:AddLine("Treat this ability as instant for the cast-time clip simulation.", 1, 1, 1, true)
                GameTooltip:Show()
            end)
            instCB:SetScript("OnLeave", function() GameTooltip:Hide() end)

            y = y - 24
        end

        -- Insert-before row (optional - for entries that insert before another key)
        if entry.insertBefore or entry.key == "IF" or entry.key == "NEW" then
            local ibLbl = container:CreateFontString(nil, "OVERLAY")
            ibLbl:SetFont(FONT, 8)
            ibLbl:SetPoint("TOPLEFT", container, "TOPLEFT", COL_KEY, y + 3)
            ibLbl:SetTextColor(0.6, 0.6, 0.6, 1)
            ibLbl:SetText("Insert before:")
            SUIMakeEditBox(container, 110, COL_KEY + 76, y, entry.insertBefore or "", function(val)
                entry.insertBefore = val
                editorDirty = true
            end)
            -- 18px editbox -> 20px pitch so the next row cannot touch it
            y = y - 20
        end

        -- Condition rows (one compact line per condition; AND inline)
        if entry.conditions then
            for ci, cond in ipairs(entry.conditions) do
                local ci2 = ci  -- capture loop index for closures
                local desc = DescribeCondition(cond, spec)

                if ci2 > 1 then
                    local andLbl = container:CreateFontString(nil, "OVERLAY")
                    andLbl:SetFont(FONT, 8, "OUTLINE")
                    andLbl:SetPoint("TOPRIGHT", container, "TOPLEFT", COL_COND - 2, y + 2)
                    andLbl:SetTextColor(0.4, 0.7, 1, 1)
                    andLbl:SetText("AND")
                end

                local descFS = container:CreateFontString(nil, "OVERLAY")
                descFS:SetFont(FONT, 9)
                descFS:SetPoint("TOPLEFT", container, "TOPLEFT", COL_COND, y)
                descFS:SetTextColor(0.85, 0.85, 0.85, 1)
                descFS:SetText(TruncateToWidth(container, desc, W - 84 - COL_COND))
                descFS:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText(desc, 1, 1, 1, 1, true)
                    GameTooltip:Show()
                end)
                descFS:SetScript("OnLeave", function() GameTooltip:Hide() end)

                SUIButtonR(container, "Edit", 24, 16, function()
                    OpenConditionEditor(i2, ci2, spec)
                end, CLUSTER_W, y)

                local rem = CreateFrame("Button", nil, container, "BackdropTemplate")
                rem:SetSize(16, 16)
                rem:SetPoint("TOPLEFT", container, "TOPRIGHT", -28 - 16, y)
                A.CreateBackdrop(rem, 0.4, 0.1, 0.1, 0.9, 0.5, 0.2, 0.2, 1)
                local rl = rem:CreateFontString(nil, "OVERLAY")
                rl:SetFont(FONT, 9, "OUTLINE")
                rl:SetPoint("CENTER")
                rl:SetText("x")
                rem:SetScript("OnClick", function()
                    table.remove(editorData[i2].conditions, ci2)
                    editorDirty = true
                    Refresh()
                end)
                y = y - 18
            end

            -- Add condition
            SUIButton(container, "+ Condition", 88, 16, function()
                entry.conditions[#entry.conditions + 1] = { type = "always" }
                editorDirty = true
                Refresh()
            end, COL_COND, y)
            y = y - 16
        end

        -- Separator (full content width)
        local sep = container:CreateTexture(nil, "ARTWORK")
        sep:SetColorTexture(0.25, 0.25, 0.25, 0.5)
        sep:SetHeight(1)
        sep:SetPoint("TOPLEFT", container, "TOPLEFT", 12, y)
        sep:SetPoint("RIGHT", container, "RIGHT", -12, 0)
        y = y - 8
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

    local sourceLbl = container:CreateFontString(nil, "OVERLAY")
    sourceLbl:SetFont(FONT, 8)
    sourceLbl:SetPoint("TOPLEFT", container, "TOPLEFT", 12, -20)
    sourceLbl:SetTextColor(0.7, 0.7, 0.7, 1)
    sourceLbl:SetText("")

    local output = container:CreateFontString(nil, "OVERLAY")
    output:SetFont(FONT, 9)
    output:SetPoint("TOPLEFT", container, "TOPLEFT", 12, -36)
    output:SetTextColor(0.85, 0.85, 0.85, 1)
    output:SetWidth(560)
    output:SetJustifyH("LEFT")
    output:SetText("Waiting for data...")

    local function UpdatePreview()
        if not A.RotationEngine then
            output:SetText("RotationEngine not loaded.")
            sourceLbl:SetText("")
            return
        end
        local RE = A.RotationEngine
        local activeSpec = A.SpecManager and A.SpecManager:GetSpecByID(A._activeSpecID or "")
        if not activeSpec then
            output:SetText("No active spec.")
            sourceLbl:SetText("")
            return
        end

        -- G1: with unsaved edits in the rotation editor for the active spec,
        -- preview the EDITOR BUFFER instead of the saved rotation, and label
        -- which data source is being evaluated so it is never ambiguous.
        local previewBuffer = editorSpecID == (activeSpec.meta and activeSpec.meta.id)
            and editorData ~= nil
            and editorDirty
            and A.db ~= nil and A.db.specs ~= nil
        local specName = activeSpec.meta.specName or activeSpec.meta.id
        if previewBuffer then
            sourceLbl:SetText("Previewing UNSAVED rotation of " .. specName .. " (editor buffer)")
            sourceLbl:SetTextColor(1, 0.7, 0.2, 1)
        else
            sourceLbl:SetText("Previewing saved rotation of active spec: " .. specName)
            sourceLbl:SetTextColor(0.7, 0.7, 0.7, 1)
        end

        -- The evaluator reads the spec's rotation from A.db.specs[<id>].rotation
        -- (falling back to spec.rotation). Temporarily point that at the editor
        -- buffer for the duration of the evaluation, then restore - the buffer
        -- is only ever swapped in, never saved.
        local db = A.db.specs[activeSpec.meta.id]
        local hadDb = (db ~= nil)
        local prevRot = db and db.rotation
        if previewBuffer then
            if not hadDb then
                db = {}
                A.db.specs[activeSpec.meta.id] = db
            end
            db.rotation = DeepCopy(editorData)
        end
        local ok, debugData = pcall(function() return RE:DebugEvaluate(activeSpec) end)
        if previewBuffer then
            if hadDb then
                db.rotation = prevRot
            else
                A.db.specs[activeSpec.meta.id] = nil
            end
        end
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
                    -- Use fuzzy matching for rank differences
                    local _, _, _, _, _, expireTime = A.FindDebuffByName("target", debuffName)
                    if expireTime then
                        rem = math.max(expireTime - ctx.now, 0)
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
                queueBits[#queueBits + 1] = string.format("%s(%.1f)", SpellDisplayLabel(rec.key), rec.eta or 0)
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
            local previewIdx = GetTabIndex("Preview")
            if A.SpecUI and A.SpecUI.frame and A.SpecUI.frame:IsShown()
               and previewIdx and A.SpecUI._activeTab == previewIdx then
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
            local ci = GetTabIndex("CastBar")
            if ci then A.SpecUI:SwitchTab(ci, spec, true) end
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
            -- Note: Fake Queue is global-only (castBarOptions.channelFakeQueue),
            -- so there is deliberately no per-spell FQ toggle here.
            local toggles = {
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
                        if opt.key == "clipMarginMs"    then CH._config.clipMarginMs    = v end
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
                function(v)
                    A.SetSpecVal(opt.key, v)
                    -- Preview tick sounds immediately when their dropdown changes.
                    if A.PlayTickSound and opt.key and opt.key:match("tickSound$") then
                        pcall(A.PlayTickSound, v)
                    end
                end,
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

        -- Apply options to DB (validated: only well-formed custom options,
        -- string keys for the deletedOptions map, and values for known
        -- option keys so hand-edited payloads can't pollute the DB).
        if options then
            local sdb = A.db.specs and A.db.specs[specID]
            if sdb then
                if options.customOptions then
                    local valid = {}
                    for _, opt in ipairs(options.customOptions) do
                        if type(opt) == "table" and type(opt.key) == "string" and opt.key ~= "" then
                            valid[#valid + 1] = opt
                        end
                    end
                    sdb.customOptions = valid
                end
                if options.deletedOptions then
                    local valid = {}
                    for k in pairs(options.deletedOptions) do
                        if type(k) == "string" then valid[k] = true end
                    end
                    sdb.deletedOptions = valid
                end
                if options.values then
                    -- Only write values whose key exists in the merged option set
                    local known = {}
                    local merged = GetMergedOptions(spec, specID)
                    for _, opt in ipairs(merged) do known[opt.key] = true end
                    for _, opt in ipairs(sdb.customOptions or {}) do known[opt.key] = true end
                    for k, v in pairs(options.values) do
                        if known[k] then
                            sdb[k] = v
                        end
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
        -- TBC Anniversary: id, name, description, icon, pointsSpent = GetTalentTabInfo(index)
        if GetTalentTabInfo then rawName = select(2, GetTalentTabInfo(t)) end
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
            -- May be a number from spec file or DB, or a string like "3: Destruction" from dropdown.
            local chosenIndex = nil
            if type(chosen) == "number" then
                chosenIndex = chosen
            else
                -- Labels are formatted as "N: Name" — extract the leading number first.
                chosenIndex = tonumber(chosen:match("^%s*(%d+)"))
                -- Fallback: bare numeric string
                if not chosenIndex then chosenIndex = tonumber(chosen) end
            end
            -- Fallback: match by tree name (strip leading "N: " prefix for comparison)
            if not chosenIndex then
                local numTabs = GetNumTalentTabs and GetNumTalentTabs() or 3
                local chosenName = (chosen:match("^%s*%d+%s*:%s*(.+)$") or chosen):lower()
                for t = 1, numTabs do
                    -- TBC Anniversary: id, name, description, icon, pointsSpent = GetTalentTabInfo(index)
                    local name = select(2, GetTalentTabInfo(t)) or tostring(t)
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
        if ml and ml >= 1 then newLC.minLevel = ml end

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
        -- Rebuild the tab so the talent-tree dropdown reflects the saved value
        local loadTabIdx = GetTabIndex("LoadConditions")
        if SUI.frame and SUI.frame:IsShown() and loadTabIdx and SUI._activeTab == loadTabIdx then
            SUI:SwitchTab(loadTabIdx, spec)
        end
    end, 16, y)

    SUIButton(container, "Reset to File Defaults", 140, 22, function()
        if A.db.specs and A.db.specs[specID] then
            A.db.specs[specID].loadConditionsOverride = nil
        end
        -- Restore from file-defined loadConditions (need to look at _available)
        local origSpec = A.SpecManager and A.SpecManager:GetSpecByID(specID)
        if origSpec and origSpec._fileLoadConditions then
            -- Copy so later in-place edits can't corrupt the file snapshot
            origSpec.loadConditions = DeepCopy(origSpec._fileLoadConditions)
        end
        if A.SpecManager then A.SpecManager:ReEvaluate() end
        statusLbl:SetText("|cff00ff00Reset to file defaults.|r")
        local loadTabIdx = GetTabIndex("LoadConditions")
        if SUI.frame and SUI.frame:IsShown() and loadTabIdx and SUI._activeTab == loadTabIdx then
            SUI:SwitchTab(loadTabIdx, spec)
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

    -- Enable / Disable (persistent opt-in for built-in specs; the reference
    -- Shadow Priest spec and user-created specs are controlled by conditions).
    local isBuiltin = spec.meta and spec.meta.author == "SPHelper"
    local isReference = spec.meta and spec.meta.id == "shadow_priest"
    if not isReference and isBuiltin then
        local enabledNow = A.SpecManager and A.SpecManager:IsSpecEnabled(specID)
        if isActive or enabledNow then
            SUIButton(container, "Disable Spec", 100, 20, function()
                if A.SpecManager then
                    A.SpecManager:SetSpecEnabled(specID, false)
                end
                print("|cff8882d5SPHelper|r: Disabled " .. (spec.meta.specName or specID) .. ".")
                local loadTabIdx = GetTabIndex("LoadConditions")
                if SUI.frame and SUI.frame:IsShown() and loadTabIdx and SUI._activeTab == loadTabIdx then
                    SUI:SwitchTab(loadTabIdx, spec)
                end
            end, 16, y)
            y = y - 26
        else
            SUIButton(container, "Enable Spec", 100, 20, function()
                if A.SpecManager then
                    local ok = A.SpecManager:SetSpecEnabled(specID, true)
                    if ok then
                        print("|cff8882d5SPHelper|r: Enabled " .. (spec.meta.specName or specID) .. ".")
                    else
                        print("|cffff4444SPHelper|r: " .. (spec.meta.specName or specID) .. " enabled, but its load conditions do not match this character yet.")
                    end
                end
                local loadTabIdx = GetTabIndex("LoadConditions")
                if SUI.frame and SUI.frame:IsShown() and loadTabIdx and SUI._activeTab == loadTabIdx then
                    SUI:SwitchTab(loadTabIdx, spec)
                end
            end, 16, y)
            y = y - 26
        end
    elseif not isActive then
        SUIButton(container, "Force Activate", 100, 20, function()
            if A.SpecManager then
                A.SpecManager:ActivateSpec(specID)
            end
            print("|cff8882d5SPHelper|r: Force-activated " .. (spec.meta.specName or specID))
            local loadTabIdx = GetTabIndex("LoadConditions")
            if SUI.frame and SUI.frame:IsShown() and loadTabIdx and SUI._activeTab == loadTabIdx then
                SUI:SwitchTab(loadTabIdx, spec)
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

-- Default castBarOptions for created specs (G4): seeded from the built-in
-- Shadow Priest spec when registered, so the CastBar & FQ tab's global
-- section is never empty for a new spec. Falls back to a minimal hardcoded
-- seed if the built-in spec is not available.
local function DefaultCastBarOptions()
    if A.SpecManager and A.SpecManager.GetSpecByID then
        local spriest = A.SpecManager:GetSpecByID("shadow_priest")
        if spriest and type(spriest.castBarOptions) == "table" and #spriest.castBarOptions > 0 then
            return DeepCopy(spriest.castBarOptions)
        end
    end
    return {
        { key = "channelFakeQueue",     type = "checkbox", label = "Enable Fake Queue (clip assist)", default = true },
        { key = "channelClipCues",      type = "checkbox", label = "Show clip zone on cast bar", default = true },
        { key = "tickSound",            type = "dropdown", label = "Tick sound",           default = "click",
          values = {"none","click","impact","pop","blip","coin","tick","chink","ping","note","popup","slash","bite","clank","chop","fizzle","bell","alert"} },
        { key = "tickFlash",            type = "dropdown", label = "Tick flash effect",    default = "green",
          values = {"none","green","purple","shadow","white","red","green_top","purple_top","shadow_top","white_top","red_top","green_sides","purple_sides","shadow_sides","white_sides","red_sides"} },
        { key = "tickFeedbackOffsetMs", type = "slider",   label = "Tick feedback offset (ms)", default = 0, min = 0, max = 300, step = 10 },
    }
end


local newSpecFrame = nil

local function OpenNewSpecDialog()
    if newSpecFrame and newSpecFrame:IsShown() then
        newSpecFrame:Show()
        return
    end
    if not newSpecFrame then
        local f = CreateFrame("Frame", "SPHNewSpecDialog", UIParent, "BackdropTemplate")
        f:SetSize(320, 240)
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

        -- ── Enable an existing built-in spec (opt-in) ────────────────
        -- Built-in specs other than the reference Shadow Priest spec are
        -- disabled until the player opts in here (or via the Load Cond.
        -- tab once a spec is active).
        local _, playerClassDD = UnitClass("player")
        local builtinSpecs = {}
        if A.SpecManager then
            for sid, s in pairs(A.SpecManager:GetRegisteredSpecs()) do
                if s.meta and s.meta.class == playerClassDD and s.meta.author == "SPHelper"
                   and sid ~= "shadow_priest" then
                    local specDB = A.db and A.db.specs and A.db.specs[sid]
                    local enabledNow = specDB ~= nil and specDB.enabled == true
                    if not enabledNow and not (A.SpecManager:IsSpecActive(sid)) then
                        builtinSpecs[#builtinSpecs + 1] = { id = sid, name = s.meta.specName or sid }
                    end
                end
            end
        end
        if #builtinSpecs > 0 then
            table.sort(builtinSpecs, function(a, b) return a.name < b.name end)
            local sep = f:CreateFontString(nil, "OVERLAY")
            sep:SetFont(FONT, 9, "OUTLINE")
            sep:SetPoint("TOPLEFT", f, "TOPLEFT", 16, ly)
            sep:SetText("|cff8882d5— or enable a built-in spec —|r")
            ly = ly - 20

            suiDropdownCounter = suiDropdownCounter + 1
            local builtinDD = CreateFrame("Frame", "SPHEnableSpecDD" .. suiDropdownCounter, f, "UIDropDownMenuTemplate")
            builtinDD:SetPoint("TOPLEFT", f, "TOPLEFT", 16, ly)
            UIDropDownMenu_SetWidth(builtinDD, 200)
            UIDropDownMenu_SetText(builtinDD, "Select spec…")
            UIDropDownMenu_Initialize(builtinDD, function(self2, level)
                for _, bs in ipairs(builtinSpecs) do
                    local info = UIDropDownMenu_CreateInfo()
                    info.text = bs.name
                    info.value = bs.id
                    info.func = function(self3)
                        UIDropDownMenu_SetText(builtinDD, bs.name)
                        builtinDD._selected = bs.id
                    end
                    UIDropDownMenu_AddButton(info, level)
                end
            end)
            ly = ly - 28

            SUIButton(f, "Enable Spec", 80, 22, function()
                local sid = builtinDD._selected
                if not sid then
                    statusLbl:SetText("|cffff4444Pick a spec first.|r")
                    return
                end
                if A.SpecManager then
                    local ok = A.SpecManager:SetSpecEnabled(sid, true)
                    if ok then
                        f:Hide()
                        print("|cff8882d5SPHelper|r: Enabled " .. (A.SpecManager:GetSpecByID(sid).meta.specName or sid) .. ".")
                        if A.SpecUI then A.SpecUI:Open(sid) end
                    else
                        statusLbl:SetText("|cffff4444Enabled, but load conditions don't match this character yet.|r")
                    end
                end
            end, 196, ly)
        end

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
                castBarOptions  = DefaultCastBarOptions(),
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

        -- Size the dialog to its content (the built-in spec section is optional)
        f:SetHeight(math.abs(ly) + 30)
    end
    newSpecFrame:Show()
end

-- Expose the new-spec dialog so external callers can open it directly
-- This allows other UI (e.g., the main options panel) to always open
-- the Create New Spec modal regardless of active spec state.
A.SpecUI.OpenNewSpecDialog = OpenNewSpecDialog

----------------------------------------------------------------------
-- Tab registry — defines which tabs exist and which require edit mode
----------------------------------------------------------------------
local ALL_TABS = {
    { name = "General",        build = "General",        requiresEdit = false },
    { name = "Rotation",       build = "Rotation",       requiresEdit = true  },
    { name = "Preview",        build = "Preview",        requiresEdit = true  },
    { name = "CastBar & FQ",   build = "CastBar",        requiresEdit = false },
    { name = "Load Cond.",     build = "LoadConditions", requiresEdit = false },
    { name = "Import/Export",  build = "ImportExport",   requiresEdit = true  },
}

--- Return the list of tabs that should be visible given the current edit mode.
local function GetVisibleTabs()
    local editMode = A.db and A.db.specUI and A.db.specUI.editMode
    local visible = {}
    for _, tab in ipairs(ALL_TABS) do
        if editMode or not tab.requiresEdit then
            visible[#visible + 1] = tab
        end
    end
    return visible
end

--- Return the visual index of a tab by its build key, or nil if not visible.
-- (Assignment, not `local function`, so it binds to the forward declaration
-- above - see the compile-time resolution rule documented there.)
GetTabIndex = function(buildKey)
    local visible = GetVisibleTabs()
    for i, tab in ipairs(visible) do
        if tab.build == buildKey then return i end
    end
    return nil
end

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
            -- Auto-save pending rotation edits before switching specs
            if editorDirty and editorData then
                SaveRotationEditor()
            end
            editorData = nil  -- reset editor only when switching to a different spec
        end
        -- Rebuild tabs in case edit mode was toggled while the frame was closed
        if self._tabs then
            for _, btn in ipairs(self._tabs) do
                btn:Hide()
                btn:SetParent(nil)
            end
        end
        local visibleTabs = GetVisibleTabs()
        local tabCount = #visibleTabs
        local tabWidth = math.floor((FRAME_W - 8 - (tabCount - 1) * 4) / tabCount)
        local tabSpacing = tabWidth + 4
        local tabs = {}
        for i, tab in ipairs(visibleTabs) do
            tabs[i] = CreateTabButton(self.frame, tab.name, i, function(idx)
                self:SwitchTab(idx)
            end, tabWidth, tabSpacing)
        end
        self._tabs = tabs
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

    -- Edit-mode toggle button (mirrors /sph edit) — makes the Rotation /
    -- Preview / Import-Export tabs discoverable from inside the window.
    local editBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    editBtn:SetSize(52, 18)
    editBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -32, -4)
    A.CreateBackdrop(editBtn, 0.1, 0.1, 0.1, 0.8, 0.3, 0.3, 0.3, 0.8)
    local editLbl = editBtn:CreateFontString(nil, "OVERLAY")
    editLbl:SetFont(FONT, 9, "OUTLINE")
    editLbl:SetPoint("CENTER")
    local function UpdateEditLabel()
        local on = A.db and A.db.specUI and A.db.specUI.editMode
        editLbl:SetText(on and "Edit: ON" or "Edit: OFF")
    end
    UpdateEditLabel()
    editBtn:SetScript("OnClick", function()
        if not A.db.specUI then A.db.specUI = {} end
        A.db.specUI.editMode = not A.db.specUI.editMode
        UpdateEditLabel()
        if A.SpecUI then A.SpecUI:RebuildTabs() end
    end)
    self._editBtn = editBtn
    self._updateEditBtn = UpdateEditLabel

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
                        -- Auto-save pending rotation edits before switching specs
                        if editorDirty and editorData then
                            SaveRotationEditor()
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
        -- Auto-save pending rotation edits so closing never loses work
        if editorDirty and editorData then
            SaveRotationEditor()
        end
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

    -- Tabs (filtered by edit mode)
    local visibleTabs = GetVisibleTabs()
    local tabCount = #visibleTabs
    local tabWidth = math.floor((FRAME_W - 8 - (tabCount - 1) * 4) / tabCount)
    local tabSpacing = tabWidth + 4
    local tabs = {}
    for i, tab in ipairs(visibleTabs) do
        tabs[i] = CreateTabButton(f, tab.name, i, function(idx)
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

    local visibleTabs = GetVisibleTabs()
    local tabConfig = visibleTabs[idx]
    if not tabConfig then return end
    local buildKey = tabConfig.build

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
    if buildKey ~= "Rotation" then editorRefreshFn = nil end

    if buildKey == "General" then
        BuildGeneralTab(content, spec)
    elseif buildKey == "Rotation" then
        editorRefreshFn = function()
            BuildRotationTab(content, spec)
        end
        BuildRotationTab(content, spec)
    elseif buildKey == "Preview" then
        BuildPreviewTab(content, spec)
    elseif buildKey == "CastBar" then
        BuildCastBarTab(content, spec)
    elseif buildKey == "LoadConditions" then
        BuildLoadConditionsTab(content, spec)
    elseif buildKey == "ImportExport" then
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

--- Rebuild the tab bar from the current edit mode (called after toggling edit mode).
function SUI:RebuildTabs()
    if not self.frame then return end
    -- Keep the current tab (matched by build key) across the rebuild so
    -- toggling edit mode doesn't throw the user back to the first tab.
    local oldVisible = GetVisibleTabs()
    local prevBuild = self._activeTab and oldVisible[self._activeTab] and oldVisible[self._activeTab].build
    if self._tabs then
        for _, btn in ipairs(self._tabs) do
            btn:Hide()
            btn:SetParent(nil)
        end
    end
    local visibleTabs = GetVisibleTabs()
    local tabCount = #visibleTabs
    if tabCount == 0 then self._tabs = {}; return end
    local tabWidth = math.floor((FRAME_W - 8 - (tabCount - 1) * 4) / tabCount)
    local tabSpacing = tabWidth + 4
    local tabs = {}
    for i, tab in ipairs(visibleTabs) do
        tabs[i] = CreateTabButton(self.frame, tab.name, i, function(idx)
            self:SwitchTab(idx)
        end, tabWidth, tabSpacing)
    end
    self._tabs = tabs
    -- Refresh the header edit-mode toggle label (may have changed via /sph edit)
    if self._updateEditBtn then self._updateEditBtn() end
    -- Switch to the same tab by build key, or the first tab if it no longer exists
    local newIdx = 1
    if prevBuild then
        for i, tab in ipairs(visibleTabs) do
            if tab.build == prevBuild then newIdx = i; break end
        end
    end
    self:SwitchTab(newIdx)
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

------------------------------------------------------------------------
-- Rotation-editor state accessor (used by tests/harnesses and internal
-- preview code that needs to read the current editor buffer + dirty flag
-- without reaching into the chunk locals).
------------------------------------------------------------------------
function get()
    return {
        dirty = function() return editorDirty end,
        data  = function() return editorData end,
    }
end

-- Test hook: force the editor dirty flag (same effect as any mutation).
function setEditorDirty(v)
    editorDirty = v and true or false
end