# MacEQ

System-wide equalizer for macOS, built on Core Audio process taps (macOS
14.2+). No kernel extension, no virtual audio driver.

```
System Audio → Core Audio Tap → 20-band EQ → Safety Limiter → Physical Output
```

## Status

MVP. Gates A–D from `plan/gate-a.md` are complete: audio pipeline, 20-band
engine with Auto Headroom and a safety limiter, device hot-swap and recovery,
a SwiftUI Home/Curve Editor/Presets/Settings/Menu Bar UI, and 30 automated
tests. Gate E (this document) covers packaging and distribution.

## How it works

```
private aggregate device
├─ subdevices: [current physical output]   ← output stream, clock master
└─ taps:       [MacEQ tap]                 ← input stream
        │
        └─ one AudioDeviceIOProc
           input(tap) → preamp → 20×biquad → limiter → output(physical device)
```

The tap is scoped to the output device's stream and **excludes MacEQ's own
process**, so MacEQ's rendered audio is neither captured nor muted. Other
apps' audio is muted on the hardware path (`CATapMutedWhenTapped`) and
re-rendered through the EQ. One aggregate device means one clock: no ring
buffer, no drift, no resampling. Full detail and measurements in
`plan/gate-a.md`.

## Build and run

```sh
swift test            # 30 tests, DSP + persistence + presets
make bundle            # debug build → MacEQ.app, ad-hoc signed
CONFIG=release make bundle
open MacEQ.app          # launch via `open`, not the raw binary (see Permission)
```

## Package a release

```sh
./scripts/dmg.sh                # MacEQ-<version>.dmg from a release build
./scripts/dmg.sh 0.2.0           # override the version in the file name
```

## Download and install

1. [Download MacEQ.dmg](https://github.com/younnieCutler/maceq/releases/latest/download/MacEQ.dmg).
2. Open it, then double-click **Install MacEQ.command**. It installs MacEQ in
   `~/Applications`, adds **MacEQ.app** to the Desktop, and launches it.

The installer never overwrites a non-shortcut Desktop item. To publish a new
download, push a version tag such as `v0.1.0`; GitHub Actions builds the DMG
and attaches it to that release.

## Permission

The tap needs the **AudioCapture** TCC grant. Core Audio returns `noErr` for
everything even when it is missing — the only symptom is that audio never
flows. MacEQ's watchdog (`AudioSession`) detects this once the output device
is actually active and surfaces it in the UI; to re-trigger the system prompt
manually:

```sh
tccutil reset AudioCapture com.maceq.app
```

`CFBundleIdentifier` must stay `com.maceq.app` and the signing identity must
stay stable, or the grant is dropped on the next build. Always launch via
`open MacEQ.app`, not the binary directly — running the binary from a shell
makes the terminal the responsible process and the grant lands there instead.

## Distribution

No Developer ID certificate — MacEQ ships ad-hoc signed for local /
GitHub-Releases distribution, not the Mac App Store. `UpdateManager` polls the
GitHub Releases API for a newer tag rather than using Sparkle: without
notarization an auto-installed update would be blocked by Gatekeeper anyway.

First launch of a downloaded, ad-hoc-signed app may need one manual step:
right-click `MacEQ.app` → **Open** → confirm, since it isn't notarized.

## Project layout

```
Sources/MacEQ/
├── Audio/        tap, aggregate device, session lifecycle & recovery
├── DSP/          biquad cascade, headroom, safety limiter (realtime-safe)
├── Persistence/  JSON settings store, migration
├── Presets/      preset model + CRUD store
├── System/       login item, permission, update manager
├── Support/      Core Audio property helpers, logging
└── UI/           SwiftUI app shell, Home, Curve Editor, Settings, Menu Bar
Tests/MacEQTests/ XCTest — DSP correctness, presets, settings, migration
plan/gate-a.md    running implementation log, gate by gate
```
