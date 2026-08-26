# MacEQ

System-wide equalizer for macOS, built on Core Audio process taps (macOS 14.2+).
No kernel extension, no virtual audio driver.

**Status: Gate A (audio proof of concept).** One peaking band, no UI.

## How it works

```
private aggregate device
├─ subdevices: [current physical output]   ← output stream, clock master
└─ taps:       [MacEQ tap]                 ← input stream
        │
        └─ one AudioDeviceIOProc
           input(tap) → biquad → output(physical device)
```

The tap is scoped to the output device's stream and **excludes MacEQ's own
process**, so MacEQ's rendered audio is neither captured nor muted. Other apps'
audio is muted on the hardware path (`CATapMutedWhenTapped`) and re-rendered
through the EQ. One aggregate device means one clock: no ring buffer, no drift.

## Build and run

```sh
make bundle          # debug build + MacEQ.app + codesign
CONFIG=release make bundle
open MacEQ.app       # launch via `open` so TCC attributes the grant to MacEQ
make log             # tail /tmp/maceq.log
```

`open`, not `./MacEQ.app/Contents/MacOS/maceq`: launching the binary from a
shell makes the terminal the responsible process and the audio-capture grant
lands on the terminal instead.

### Controls

Signals, not stdin, so the app can run detached from a terminal:

```sh
make up       # +1 dB      make bypass   # toggle passthrough
make down     # -1 dB      make stop     # quit and release resources
```

Dispatch coalesces signals, so rapid repeats collapse into one step. Space them
out (~1 s) when stepping the gain.

### Environment switches

| Variable | Effect |
|---|---|
| `MACEQ_LIST=1` | list output devices and exit |
| `MACEQ_OUTPUT_UID=…` | render to a specific device instead of the system default |
| `MACEQ_NOTAP=1` | build the aggregate without the tap (isolates tap problems) |
| `MACEQ_DIRECT=1` | install an IOProc straight on the physical device (isolates IOProc problems) |

## Permission

The tap needs the **AudioCapture** TCC grant. `AudioHardwareCreateProcessTap`
and `AudioDeviceStart` both return `noErr` when it is missing — the only symptom
is that the IOProc never fires. To re-trigger the prompt:

```sh
tccutil reset AudioCapture com.maceq.app
```

`CFBundleIdentifier` must stay `com.maceq.app` and the signing identity must stay
stable, or the grant is dropped on the next build.
