import CoreAudio
import Darwin
import Foundation

// Gate A harness. Controlled by signals rather than stdin so the app can be
// launched with `open`, which keeps TCC's audio-capture grant attached to
// MacEQ instead of to the terminal that started it.
//
//   kill -USR1  gain +1 dB      kill -USR2  gain -1 dB
//   kill -HUP   bypass toggle   kill -TERM  quit
//
// MACEQ_LIST=1        list output devices and exit
// MACEQ_OUTPUT_UID=…  render to a specific device instead of the system default

Log.info("MacEQ 0.1.0 (Gate A) starting, pid \(getpid())")

#if DEBUG
BiquadSelfCheck.run()
#endif

if ProcessInfo.processInfo.environment["MACEQ_LIST"] != nil {
    for device in OutputDevice.allOutputs() {
        Log.info("  \(device.summary)")
    }
    exit(0)
}

if ProcessInfo.processInfo.environment["MACEQ_DIRECT"] != nil {
    let device = (try? OutputDevice.currentDefault())
    if let device { DirectProbe.run(on: device) }
    exit(0)
}

// A previous run that died hard can leave a tap or aggregate behind.
ProcessTap.destroyOrphans()
TapAggregateDevice.destroyOrphans()

nonisolated(unsafe) let engine: EQEngine
do {
    let requestedUID = ProcessInfo.processInfo.environment["MACEQ_OUTPUT_UID"]
    let output = try requestedUID.map { try OutputDevice.named(uid: $0) }
        ?? OutputDevice.currentDefault()
    Log.info("output device: \(output.summary)")

    engine = try EQEngine(output: output)
    try engine.start()
} catch {
    Log.info("FATAL: \(error)")
    exit(1)
}

// Handlers run on the main queue, which `dispatchMain()` keeps serviced.
// Top-level code is @MainActor in Swift 6, so any other queue trips the
// isolation assertion.
let controlQueue = DispatchQueue.main

func shutdown() -> Never {
    engine.stop()
    Log.info("bye")
    exit(0)
}

nonisolated(unsafe) var sources: [DispatchSourceSignal] = []
func install(_ number: Int32, _ handler: @escaping () -> Void) {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: controlQueue)
    source.setEventHandler(handler: handler)
    source.resume()
    sources.append(source)
}

install(SIGUSR1) {
    engine.setGain(engine.gainDB + 1)
    Log.info("gain \(String(format: "%+.1f", engine.gainDB)) dB @ \(Int(engine.frequency)) Hz")
}
install(SIGUSR2) {
    engine.setGain(engine.gainDB - 1)
    Log.info("gain \(String(format: "%+.1f", engine.gainDB)) dB @ \(Int(engine.frequency)) Hz")
}
install(SIGHUP) {
    engine.setBypass(!engine.bypassed)
    Log.info("bypass \(engine.bypassed ? "ON (passthrough)" : "OFF (EQ active)")")
}
install(SIGINT) { shutdown() }
install(SIGTERM) { shutdown() }

// Heartbeat so a silent pipeline is distinguishable from a stalled one.
let heartbeat = DispatchSource.makeTimerSource(queue: controlQueue)
heartbeat.schedule(deadline: .now() + 2, repeating: 2)
heartbeat.setEventHandler {
    let meters = engine.drainMeters()
    func dBFS(_ value: Float) -> String {
        value > 0 ? String(format: "%.1f dBFS", 20 * log10(Double(value))) : "silent"
    }
    let level = "in \(dBFS(meters.peak)) / out \(dBFS(meters.outPeak))"
    Log.info("io: \(meters.callbacks) cb, \(meters.frames) frames, \(meters.shape), \(level), "
        + "gain \(String(format: "%+.1f", engine.gainDB)) dB, "
        + "bypass \(engine.bypassed ? "on" : "off")")
}
heartbeat.resume()

Log.info("ready — kill -USR1/-USR2 to change gain, -HUP to bypass, -TERM to quit")
dispatchMain()
