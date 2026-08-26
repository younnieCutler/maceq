import Darwin
import Foundation

// Gate B verification harness. Replaced by the SwiftUI app in Gate C.
//
//   kill -USR1  next built-in preset      kill -HUP   toggle EQ on/off
//   kill -USR2  toggle Auto Headroom      kill -TERM  quit

Log.info("MacEQ 0.2.0 (Gate B) starting, pid \(getpid())")

#if DEBUG
BiquadSelfCheck.run()
HeadroomSelfCheck.run()
#endif

if ProcessInfo.processInfo.environment["MACEQ_LIST"] != nil {
    for device in OutputDevice.allOutputs() { Log.info("  \(device.summary)") }
    exit(0)
}

ProcessTap.destroyOrphans()
TapAggregateDevice.destroyOrphans()

nonisolated(unsafe) let session = AudioSession()
nonisolated(unsafe) var presetIndex = 0
nonisolated(unsafe) var enabled = true

func applyCurrentPreset() {
    let preset = EQPreset.builtIns[presetIndex]
    session.apply(settings: preset.settings)
    Log.info("preset: \(preset.name)")
}

session.setPreferredDevice(uid: ProcessInfo.processInfo.environment["MACEQ_OUTPUT_UID"])
session.start()
applyCurrentPreset()

nonisolated(unsafe) var sources: [DispatchSourceSignal] = []
func install(_ number: Int32, _ handler: @escaping () -> Void) {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler(handler: handler)
    source.resume()
    sources.append(source)
}

install(SIGUSR1) {
    presetIndex = (presetIndex + 1) % EQPreset.builtIns.count
    applyCurrentPreset()
}
install(SIGUSR2) {
    var settings = EQPreset.builtIns[presetIndex].settings
    settings.autoHeadroom.toggle()
    session.apply(settings: settings)
    Log.info("auto headroom \(settings.autoHeadroom ? "ON" : "OFF")")
}
install(SIGHUP) {
    enabled.toggle()
    session.setEnabled(enabled)
    Log.info("EQ \(enabled ? "ON" : "OFF (passthrough)")")
}
func shutdown() -> Never {
    session.stop()
    Log.info("bye")
    exit(0)
}
install(SIGINT) { shutdown() }
install(SIGTERM) { shutdown() }

let heartbeat = DispatchSource.makeTimerSource(queue: .main)
heartbeat.schedule(deadline: .now() + 2, repeating: 2)
heartbeat.setEventHandler {
    let status = session.currentStatus
    func level(_ value: Double) -> String {
        value.isFinite ? String(format: "%.1f", value) : "—"
    }
    Log.info("[\(status.state)] cb=\(status.callbacksPerTick) active=\(status.deviceActive) \(status.deviceName) \(Int(status.sampleRate))Hz/\(status.channels)ch "
        + "in \(level(status.peakInDB)) out \(level(status.peakOutDB)) dBFS, "
        + "preamp \(String(format: "%+.1f", status.effectivePreampDB)) dB "
        + "(headroom \(String(format: "%.1f", status.requiredHeadroomDB))), "
        + "limit \(String(format: "%.1f", status.limiterReductionDB)) dB")
}
heartbeat.resume()

Log.info("ready")
dispatchMain()
