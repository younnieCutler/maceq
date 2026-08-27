# Preset UI Refinement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make preset ownership, active sound, manual modifications, headroom context, and equalizer preferences immediately understandable in both Home and Settings.

**Architecture:** Keep `AppState` and `EQSettings` as the sole sound-state owners. Home and Settings only render `AppState`; neither receives a separate gain model. Built-ins and user presets are rendered as separate UI groups, while persisted user presets remain untouched.

**Tech Stack:** Swift 6, SwiftUI, XCTest, existing localization helper `L`.

---

### Task 1: Add behavior coverage for preset selection and safe user-preset handling

**Files:**
- Modify: `Tests/MacEQTests/PresetStoreTests.swift`
- Modify: `Tests/MacEQTests/SettingsStoreTests.swift`

- [x] **Step 1: Write failing tests**

```swift
func testAUserPresetNamedZeroIsStillKept() {
    var store = PresetStore(userPresets: [])
    let preset = store.create(name: "0", settings: .flat)
    XCTAssertEqual(store.userPresets, [preset])
}
```

- [x] **Step 2: Run the focused test**

Run: `swift test --filter PresetStoreTests/testAUserPresetNamedZeroIsStillKept`

Expected: PASS, proving UI grouping must not migrate or delete user data.

- [x] **Step 3: Preserve the existing single source of truth**

Keep preset groups derived from `EQPreset.builtIns` and `state.presets.userPresets`; do not add a second preset-state array.

- [x] **Step 4: Run the preset and settings test groups**

Run: `swift test --filter PresetStoreTests && swift test --filter SettingsStoreTests`

Expected: PASS.

### Task 2: Refine the Home sound and headroom hierarchy

**Files:**
- Modify: `Sources/MacEQ/UI/HomeView.swift`
- Modify: `Sources/MacEQ/Resources/ko.lproj/Localizable.strings`
- Modify: `Sources/MacEQ/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/MacEQ/Resources/ja.lproj/Localizable.strings`

- [x] **Step 1: Replace the single mixed preset grid**

Render built-ins first, then a labeled user-preset section only when `state.presets.userPresets` is non-empty. Give user presets a person SF Symbol and visible rename/delete actions; never delete a user preset automatically.

- [x] **Step 2: Strengthen active and modified state**

Use an accent fill, checkmark, and selected accessibility trait for the active chip. Display the active preset and a `Modified` state in the sound header. Show save/update actions only after the curve differs from the selected preset.

- [x] **Step 3: Add the concise headroom explanation**

Below the curve, render the measured cascade peak, the fixed `Headroom.safetyMarginDB`, and resulting automatic preamp from `state.status`. Do not recalculate DSP response in SwiftUI.

- [x] **Step 4: Keep spacing and appearance semantic**

Use native materials, semantic foreground styles, SF Symbols, 8-point spacing, and at least 44-point controls. Avoid hard-coded light/dark colors.

### Task 3: Surface the same sound state in Settings

**Files:**
- Modify: `Sources/MacEQ/UI/SettingsView.swift`
- Modify: `Sources/MacEQ/Resources/ko.lproj/Localizable.strings`
- Modify: `Sources/MacEQ/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/MacEQ/Resources/ja.lproj/Localizable.strings`

- [x] **Step 1: Add a current-sound summary to Equalizer settings**

Add a section showing the selected preset name, whether the curve is modified, and the effective preamp when Auto Headroom is enabled.

- [x] **Step 2: Group preset choices without changing persistence**

Use `Picker` sections for built-in and user presets, both routing selection to `state.select(preset:)`.

- [x] **Step 3: Keep destructive preset reset explicit**

Retain the existing reset action and confirm its destructive behavior through the existing localized copy.

### Task 4: Verify, package, and inspect the delivered app

**Files:**
- Verify: `Sources/MacEQ/UI/HomeView.swift`
- Verify: `Sources/MacEQ/UI/SettingsView.swift`

- [x] **Step 1: Run complete validation**

Run: `swift test && make build && swift build -c release && git diff --check`

Expected: all tests pass, both builds succeed, and diff check is empty.

- [x] **Step 2: Refresh the runnable bundle**

Run: `make bundle`

Expected: `MacEQ.app` contains the current executable so runtime labels do not lag source.

- [x] **Step 3: Review the final diff**

Confirm: no duplicate gain state, no automatic deletion of user presets, selected state is distinct, headroom is sourced from DSP status, settings expose current sound state, and localization is complete.

- [ ] **Step 4: Commit and push**

Run: `git add <changed files> && git commit -m "feat: refine preset controls and settings" && git push`
