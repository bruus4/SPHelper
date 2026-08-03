# SPHelper â€” Developer Guide (WoW 2.5.5 / TBC Anniversary)

Purpose: a standalone developer reference for building WoW TBC-era addons (Lua 2.5.5). This document lists platform restrictions, useful API calls with usage notes, event and saved-variable patterns, and a recommended default visual style for controls (buttons, dropdowns, fonts, backdrops). It also includes examples for building tabbed configuration UIs.
## Common libraries / frameworks

- Ace3 (optional): `AceConfig-3.0`, `AceConfigDialog-3.0`, `AceDB-3.0` and `LibStub` are widely used. They provide:
  - Rapid options table creation and automatic Blizzard options integration.
## Building configuration UIs: recommended approaches and tabs

Two practical approaches for tabbed options UI:

1) AceConfig-based (preferred when available):

  - Benefits: automatic Blizzard options integration, profiles via AceDB, tab rendering with `childGroups = 'tab'`, and less UI plumbing.
2) Custom frame-based tabs (if Ace is not available):

  - Create a main container frame and one child content frame per tab. Add tab buttons that show/hide the corresponding content frame.
Example (simplified):

```lua
local main = CreateFrame('Frame', 'SPHelperOptions', UIParent, 'BackdropTemplate')
Tabs UX tips:
- Prefer AceConfig's `childGroups='tab'` when available.
- For custom frames, create one content frame per tab and show/hide them with tab buttons.
- Use consistent spacing, margins and control templates for a professional look (see recommended default style below).
## Recommended default visual style (buttons, dropdowns, fonts, backdrops)

This section prescribes a default, consistent visual style for controls used across the addon. Use these templates and values to get a professional, familiar WoW look.
- Button:
  - Template: `UIPanelButtonTemplate`.
  - Size: typically `120 x 22` for primary buttons, `100 x 22` for secondary.
- Dropdown:
  - Use built-in UIDropDownMenu API with the `UIDropDownMenuTemplate` or a lightweight dropdown helper.
  - Suggested width: `160-200` depending on label lengths.
- Fonts and text:
  - Headings: `GameFontNormal` or `GameFontHighlight`.
  - Body text and labels: `GameFontNormalSmall` or `ChatFontNormal` for multi-line fields.
- Backdrop (panel background):
  - Use `BackdropTemplate` and the Blizzard dialog textures for a native look.
  - Example backdrop config:
- Scroll areas:
  - Use `UIPanelScrollFrameTemplate` for scrollable content lists and set a child `EditBox` or content frame.

Layout conventions:
---

## Secure actions and protected templates

Interaction with secure actions (casting, targeting) requires secure templates (`SecureActionButtonTemplate`) and careful consideration of what can be performed in combat. Configuration UIs should avoid trying to perform protected actions directly.
## Implementation notes and next steps

- Add `Core.lua` early in TOC with the `SpecManager` and `SpecValidator` bootstraps so spec files can register themselves on load.
- Implement `SpecUI` that prefers AceConfig when available and falls back to the custom frame/tab system described above.
- Provide an in-game Rotation Editor tab with `Editor`, `Preview`, and `Import/Export` sub-views. Save edited specs to `A.db.specs[specID]` and support `Reset to Default` to remove overrides.

---

End of developer guide.
# SPHelper â€” Developer Guide (WoW 2.5.5 / TBC Anniversary)

Purpose: practical reference for developing addons and spec-driven features for the TBC Anniversary (WoW 2.5.5) client. Contains platform restrictions, commonly used API calls with usage notes, UI patterns (with emphasis on settings GUIs and tabs), and examples discovered in the local AddOns folder.

Note: this guide mixes authoritative API usage with pragmatic patterns observed in installed addons (examples under `C:/Spil/World of Warcraft/_anniversary_/Interface/AddOns`).

---

## High-level constraints and rules

- Addon files must be listed in the addon's `.toc` to be loaded by the client. You cannot dynamically scan and load arbitrary filesystem files at runtime.
- Addons cannot write files to the installation directory from in-game Lua. Persist runtime settings using SavedVariables only.
- No C libraries or OS access. All code must be pure Lua and use the WoW API.
- Avoid long-running/blocking work on the main thread (no sleeps or heavy loops). Use event-driven callbacks and throttled `OnUpdate` for periodic tasks.
- Use secure templates for protected actions (e.g., `SecureActionButtonTemplate`) when performing protected operations (casting, targeting); config UIs do not need protected templates.
- Be conservative with global variables; prefer module-local tables.

---

## TOC and file loading

- The `.toc` decides load order. If you want your core API (`SpecManager`) available to spec files at load time, list `Core.lua` before spec files in the TOC.
- Two common patterns for spec files:
  - Each spec file is added to the TOC and executes `SpecManager:RegisterSpec(specTable)` during load.
  - A single `specs_loader.lua` is listed in TOC and `require`s known spec files.

Limitations: you cannot add or remove TOC entries at runtime â€” updates that add new spec files require filesystem changes and a UI reload.

---

## SavedVariables and per-spec persistence

- Declare SavedVariables in the TOC (e.g., `## SavedVariables: SPHelperDB`).
- Store per-spec overrides under a namespaced table, e.g. `A.db.specs[specID] = { rotation = {...}, ui = {...} }`.
- To reset to the file-based default, remove the per-spec table (`A.db.specs[specID] = nil`) and reapply the file spec via `SpecManager`.

---

## Events & Throttling

- Rely on events (e.g., `PLAYER_LOGIN`, `PLAYER_TALENT_UPDATE`, `UNIT_AURA`, `SPELL_UPDATE_COOLDOWN`, `UNIT_SPELLCAST_SUCCEEDED`) to react to state changes.
- Use a short throttled `OnUpdate` (e.g., 0.1s accumulator) only for periodic UI updates (countdowns, cast timers). Keep handlers error-wrapped to avoid killing the ticker.

---

## Useful WoW API functions (TBC-era) and how we use them

The following is a non-exhaustive list tailored to rotation helpers and options UIs.

- UnitExists(unit): returns true if unit exists. Use to validate `target`.
- UnitIsDead(unit) / UnitCanAttack(unit, other): target validity checks.
- UnitCastingInfo("unit"): returns current cast name and end time (nil if not casting). Used to compute `castRemaining`.
- UnitChannelInfo("unit"): returns channel name and end time.
- UnitBuff(unit, index|name) / UnitDebuff(unit, index|name): inspect buffs/debuffs on player/target to track dot durations.
- GetSpellInfo(spellId): returns spelling name (useful for name-based debuff lookups).
- GetSpellCooldown(spellId): returns start, duration, enable flag (cooldown queries). Some addons use helper wrappers to compute effective remaining CD.
- GetTime(): current time in seconds (high resolution) used for projecting expiries.
- GetItemCount(itemId): inventory count checks for consumables.
- GetItemCooldown(itemId): start, duration for item cooldowns.
- IsSpellInRange(spellName, "target"): returns 1/0 if the spell is in range; use `pcall` to avoid runtime errors if the spell name isn't valid.
- UnitHealth(unit) / UnitHealthMax(unit): for HP-based decisions (e.g., SW:D safety vs player HP).
- UnitPower(unit, powerType) / UnitPowerMax(unit, powerType): mana/energy checks (use 0 for mana).
- GetNumTalentTabs / GetTalentTabInfo / PLAYER_TALENT_UPDATE: detect talent specialization (TBC classic style). Use to implement `loadConditions` based on spec.
- UnitThreatSituation(unit, other) and UnitDetailedThreatSituation(unit, other): threat percentage/status (availability can vary; provide fallbacks). Use to compute proximity to pulling aggro.
- GetNetStats(): can be used to estimate latency; use carefully (behavior differs between versions). Many addons obtain latency via `select(4, GetNetStats())` or via built-in latency utilities.

Notes:
- Always guard API calls that may error (e.g., `IsSpellInRange`) with `pcall` when using dynamic names.
- For debuff expiration times many addons scan `UnitDebuff` return values to extract expiration timestamps where available.

---

## Common libraries / frameworks observed (local AddOns)

- Ace3 family (when present): `AceConfig-3.0` / `AceConfigDialog-3.0`, `AceDB-3.0`, `LibStub` â€” excellent for building options UIs quickly with tabs and profiles.
  - Example: `OmniCC_Config/options.lua` uses `AceConfig-3.0` and sets `childGroups = "tab"` to create tabbed sections (see file: `OmniCC_Config/options.lua`).
- LibSharedMedia-3.0: media registration and selection (fonts, textures, sounds). DBM demonstrates registering media with LSM (`DBM-GUI.lua`).
- Custom internal UI frameworks: large addons (DBM, ConsolePort) implement custom option frameworks (panels, subcategories, left/right lists and tabbed views). See `DBM-GUI.lua` and `ConsolePort_Config/View/Settings/Panel.lua` for examples.

---

## Building configuration UIs: options patterns and tabs

You have two pragmatic approaches to a settings UI with tabs:

1) Use AceConfig / AceConfigDialog (recommended if libraries are bundled or available):

  - Advantages: fast, supports profiles, tabs, nested groups, search, and integrates with Blizzard Interface Options via `AddToBlizOptions`.
  - Minimal example (tabs):

```lua
local options = {
  type = 'group',
  childGroups = 'tab', -- creates tabs for top-level args
  args = {
    general = { type = 'group', name = 'General', args = { ... } },
    advanced = { type = 'group', name = 'Advanced', args = { ... } },
  }
}

LibStub('AceConfig-3.0'):RegisterOptionsTable('MyAddon', options)
LibStub('AceConfigDialog-3.0'):AddToBlizOptions('MyAddon', 'MyAddon')
```

  - Example in repo: see `OmniCC_Config/options.lua` which uses `childGroups = "tab"`.

2) Implement custom tabbed panels using frames (used by DBM and other large addons):

  - Create a parent options frame (UIPanel or custom):

```lua
local frame = CreateFrame('Frame', 'MyAddonOptions', UIParent, 'BackdropTemplate')
frame:SetSize(600, 400)
frame:SetPoint('CENTER')

local tab1 = CreateFrame('Button', nil, frame, 'UIPanelButtonTemplate')
tab1:SetText('General')
tab1:SetPoint('TOPLEFT', 10, -10)

local page1 = CreateFrame('Frame', nil, frame)
page1:SetAllPoints(frame)

tab1:SetScript('OnClick', function()
  page1:Show(); page2:Hide()
end)
```

  - DBM implements a rich set of helper functions to create areas, dropdowns, buttons, and a left/right nav with subcategories (`DBM-GUI.lua`). That is a good reference if you need advanced behaviors (import/export, profiles, per-mod tabs).

Tabs UX tips:
- Use `childGroups='tab'` with AceConfig when available â€” it's simpler and integrates with Blizzard's panel system.
- For custom frames, create one content frame per tab and show/hide them when the tab button is clicked.
- Keep controls appropriately anchored and use templates like `UIPanelButtonTemplate`, `UIPanelScrollFrameTemplate`, and `BackdropTemplate` for consistent look.

---

## Secure actions and protected templates

- Interaction with secure actions (casting, targeting) requires secure templates (`SecureActionButtonTemplate`) and careful consideration of what can be performed in combat. Configuration UIs should avoid trying to perform protected actions directly.

---

## Examples discovered in local AddOns (use as references)

- OmniCC_Config/options.lua â€” AceConfig usage, tabs via `childGroups = 'tab'`.
  - Path: `OmniCC_Config/options.lua`
- DBM-GUI.lua â€” large custom options framework with modular panels, import/export, and per-mod tabs. Look for `CreateArea`, `CreateDropdown`, `CreateButton` helpers inside to learn advanced patterns.
  - Path: `DBM-GUI/DBM-GUI.lua`
- ConsolePort_Config â€” XML + custom view system; look at `View/Settings/Panel.lua` for a left-category / right-settings layout and event-driven rendering.
  - Path: `ConsolePort_Config/View/Settings/Panel.lua`

Study these files to see production-quality patterns for:
- Building a settings UI with tabs/subsections.
- Reusing templates and helper functions for consistent layout.
- Implementing import/export and profile selection.

---

## Recommended approach for SPHelper

1. Keep spec files as Lua tables (data-only) and require/register them at load time via `SpecManager:RegisterSpec` (make `Core.lua` first in TOC).
2. Implement a small `SpecManager` and a `SpecUI` that uses AceConfig if available; otherwise provide a simple in-addon options panel.
3. Provide the rotation editor UI as a tab under the addon's options: either an AceConfig top-level group with `childGroups='tab'` or a custom frame with one tab labeled `Rotation` and sub-tabs for `Editor`, `Preview`, `Import/Export`.
4. Persist editable overrides under `A.db.specs[specID]`. Expose `Reset to Default` to clear the override.

---

## Quick reference: useful widgets and templates

- `CreateFrame('Frame', name, parent, 'BackdropTemplate')` â€” backdrop + border support.
- `CreateFrame('Button', name, parent, 'UIPanelButtonTemplate')` â€” standard button.
- `CreateFrame('EditBox', name, parent)` â€” text input.
- `CreateFrame('ScrollFrame', name, parent, 'UIPanelScrollFrameTemplate')` â€” scrollable area.
- `StaticPopup_Show('MY_DIALOG')` â€” standardized popups for confirmation.

---

## Next steps / TODO for implementers

1. Add `Core.lua` early in TOC with `SpecManager` and `SpecValidator` bootstraps.
2. Create `SpecUI` that prefers AceConfig but falls back to a custom tabbed frame if Ace libraries are absent.
3. Convert current `RotationSpec.lua` into a `specs/Shadow_Priest.lua` under the described schema and register it.

---

If you want, I can now implement the `SpecManager` bootstrap and an example spec registration file so you can test registration and activation. I can also implement a minimal AceConfig-backed `SpecUI` that creates tabs for `Editor`, `Preview`, and `Import/Export`.



---

# SPHelper Modular Architecture (Class-Agnostic Rotation Pipeline)

The addon strictly separates **spec data** (per-class rules) from **engine logic** (generic). Adding a new class/spec MUST require changes to a single file under `specs/` only — no engine edits.

## Module Contract

```
specs/<Class>_<Spec>.lua  — declares rotation, conditions, options, postCast
        |
        v  registered via A.SpecManager:RegisterSpec(spec)
        v
SpecManager.lua           — picks ONE spec per class via load conditions
        |
        v
RotationEngine.lua        — generic evaluator. Reads spec rotation +
        |                   ctx + spell catalog. Emits result list +
        |                   A.DotRefreshHints.
        v
SpellDatabase.lua         — static catalog (castType, castTime, hasteType,
        |                   duration, ticks, tickInterval, travel time)
        |                   plus runtime spellbook resolution into A.SPELLS
        v
WoW API helpers (Core.lua) — A.GetSpellCDReal, A.FindPlayerDebuff,
                            A.GetTargetTimeToDie, A.GetHaste, ...
```

Consumers of the engine output:
- **Rotation.lua** — renders the queue (primary + 3 follow-ups). UI only; never recomputes priority.
- **ChannelHelper.lua** — consumes `A.DotRefreshHints` to drive `SPH_FQ()` busy-wait macros. Class-agnostic; one function dispatches on hint payload.
- **CastBar.lua** — renders cast/channel + tick markers + clip overlay. Reads catalog data only.

## Hard Rules (enforce when reviewing PRs)

1. **No spell-name special cases in RotationEngine, Rotation, CastBar, or ChannelHelper.** All spell-specific data must come from `A.GetSpellDefinition(key)` (catalog) or live API helpers. The two legacy short-circuits in `BuildContext` for `vtRem`/`swpRem` are tolerated only because they cache the player's known dot stack; generic dot lookup uses `A.FindPlayerDebuff(unit, name)` via the spell catalog name.
2. **Specs declare conditions, not arithmetic.** Use `projected_dot_time_left_lt`, `cooldown_ready`, `state_compare`, `resource_pct_lt`, etc. Never embed `seconds = 1.5` for a refresh window — let the engine derive it from haste-aware catalog data.
3. **`postCast` describes resource state changes.** A spec entry that modifies a resource (powershift refunding energy, Shadow Word: Death dealing self-damage) MUST declare `postCast = { resource = "energy", set = N | "opt_key", delta = N }`. The engine projects context for blocked candidates against the post-cast world. No spell-specific code in the engine.
4. **No cross-spec bleed.** `A.SPELLS`, `A.DotRefreshHints`, and channel definitions are rebuilt on `SpecManager:ActivateSpec()`. ChannelHelper's `LoadChannelSpells(spec)` resets known channel definitions before rebuilding.
5. **ETA contract.** All ETAs returned by the engine are seconds-from-NOW. `cooldownEnd = now + eta` is a stable absolute timestamp. UI counts down via `LiveRemaining(ent) = ent.cooldownEnd - GetTime()`. Never subtract `castRemaining` from a displayed ETA.

## Rotation Advisor — Two-Stage Pipeline

The engine separates **candidate scoring** from **queue rendering** so the same code serves every class:

### Stage 1 — `_EvaluateEntry(entry, index, ctx, spec, ...)`
Reads ONLY:
- `entry.conditions` (declarative dispatch via `RE._condEval[type]`)
- `entry.postCast` (resource projection metadata)
- `ctx` (already-built context: cooldowns, dots, resources, haste, gcd, lat, SAFETY)
- `A.SPELLS[entry.key]` (resolved spell record)

Returns a candidate `{ key, index, eta, clip, entry, priorityBucket }` or nil.

### Stage 2 — `_BuildResultFromCandidates(ctx, rotation, hasTarget, candidates, spec)`
Generic placement logic:
1. Split candidates into `readyCands` (eta ˜ 0) and `blockedCands` (eta > 0).
2. **Refresh-pending synthesis** (class-agnostic): for every rotation entry with a `projected_dot_time_left_lt` condition not already a candidate, compute `deadline = dotRem - (castEff + travel + SAFETY)`. If `deadline <= horizon` (= sum of ready chain time + 1.5s), add it to `blockedCands` with `eta = deadline`. The user sees it tick down in the queue.
3. **Queue-aware promotion**: walk `readyCands` accumulating `ChainStepTime = max(castEff_haste, gcd_haste)`. For each refresh entry (in either bucket) compute `accAhead = sum of ChainStepTime of ready items at lower rotation index`. If `deadline < accAhead`, that entry MUST be cast now or the dot drops — promote the most urgent one to position 1.
4. Sort blocked by `readyIn` so closer events bubble up.
5. Emit result list with `cooldownEnd` timestamps for stable UI countdown.

This means a spec only needs to declare:
```lua
{ key = "VT", conditions = {
    { type = "projected_dot_time_left_lt", spellKey = "VT" },
    { type = "state_compare", subject = "target_ttd", op = ">=", value = "vtMinTTD" },
}}
```
…and the engine handles haste, travel time, multi-spell chain timing, and queue-position-aware promotion uniformly. Same for Rake/Rip on a Druid, Corruption on a Warlock, etc.

## Why ChannelHelper / CastBar are NOT inside the rotation advisor

The user asked whether the rotation advisor should also drive freezing the game (FQ) and the cast bar. The deliberate answer is **no — they consume engine output, they don't share state.**

- The rotation advisor publishes intent: `result[]` (display) and `A.DotRefreshHints[name] = { fireAt, expiresAt, spellKey, castEff, travel }` (clip targets).
- ChannelHelper subscribes via macro `/run SPH_FQ("Spell")` and busy-waits up to `FAKE_QUEUE_SCRIPT_SAFE_MS` (150ms — hard cap, the WoW Anniversary client breaks action buttons past ~189ms of `/run` time).
- CastBar reads catalog tick data and `result` to draw markers/clip overlays.

This keeps each module responsible for exactly one concern and means a new spec gets FQ + clip cues + queue rendering for free, just by declaring its rotation.

## Where to Add a New Spec

1. Create `specs/<Class>_<Spec>.lua`.
2. Define `spec.meta`, `spec.loadConditions`, `spec.uiOptions`, `spec.castBarOptions`, `spec.rotation` (entries with `key` + `conditions`).
3. Catalog any new spell IDs/icons in `SpellDatabase.lua` with correct `castType` and timing data.
4. Call `A.SpecManager:RegisterSpec(spec)` at file end.
5. Add the file to `SPHelper.toc`.

That is the entire surface area. No engine, UI, or helper edits should be required.
