import AppKit
import CoreAudio
import Foundation

/// Owns the whole audio pipeline and everything that can disturb it: the
/// default output device changing, a sample rate change, Bluetooth dropping,
/// sleep and wake, and the audio-capture permission being absent.
///
/// Every build and teardown runs on one serial queue. Listeners never touch the
/// pipeline directly, they only ask for a rebuild, so two events arriving
/// together cannot interleave two rebuilds.
final class AudioSession: @unchecked Sendable {

    enum State: Equatable {
        case stopped
        case running
        /// Started cleanly but no IO callbacks arrived — the audio-capture
        /// grant is missing. Core Audio reports no error for this.
        case needsPermission
        case recovering(attempt: Int)
        case failed(String)
    }

    struct Status {
        var state: State = .stopped
        var deviceName = "—"
        var deviceUID = ""
        var sampleRate: Double = 0
        var channels = 0
        var bufferFrames: UInt32 = 0
        var enabled = true
        var userPreampDB: Double = 0
        var effectivePreampDB: Double = 0
        var requiredHeadroomDB: Double = 0
        var autoHeadroom = true
        var limiterEnabled = true
        var peakInDB: Double = -.infinity
        var peakOutDB: Double = -.infinity
        var limiterReductionDB: Double = 0
        var lastError: String?
        var callbacksPerTick: UInt64 = 0
        var deviceActive = false
    }

    /// Give up after this many consecutive failures rather than spinning.
    private static let maxRecoveryAttempts = 5

    private let queue = DispatchQueue(label: "com.maceq.audio")
    private let dsp = DSPCore()

    private var tap: ProcessTap?
    private var aggregate: TapAggregateDevice?
    private var procID: AudioDeviceIOProcID?
    private var device: OutputDevice?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private var watchdog: DispatchSourceTimer?
    private var sawCallbacks = false
    private var silentTicks = 0
    private var recoveryAttempt = 0
    private var suspended = false
    private var started = false

    private var settings = EQSettings.flat
    private var enabled = true
    private var limiterEnabled = true
    /// nil means "follow the system default output".
    private var preferredDeviceUID: String?

    private var status = Status()
    private let statusLock = NSLock()

    /// Called on the main queue whenever anything in `Status` changes.
    var onStatusChange: ((Status) -> Void)?

    var currentStatus: Status {
        statusLock.lock(); defer { statusLock.unlock() }
        return status
    }

    // MARK: - Public control

    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            installSystemListeners()
            installSleepWakeObservers()
            build(reason: "start")
            startWatchdog()
        }
    }

    func stop() {
        queue.sync { [self] in
            started = false
            stopWatchdog()
            teardown()
            update { $0.state = .stopped }
        }
    }

    func apply(settings newSettings: EQSettings) {
        queue.async { [self] in
            settings = newSettings
            pushParameters()
        }
    }

    func setEnabled(_ value: Bool) {
        queue.async { [self] in
            enabled = value
            dsp.setEnabled(value)
            update { $0.enabled = value }
        }
    }

    func setLimiterEnabled(_ value: Bool) {
        queue.async { [self] in
            limiterEnabled = value
            dsp.setLimiterEnabled(value)
            update { $0.limiterEnabled = value }
        }
    }

    /// `nil` follows the system default output device.
    func setPreferredDevice(uid: String?) {
        queue.async { [self] in
            guard preferredDeviceUID != uid else { return }
            preferredDeviceUID = uid
            rebuild(reason: "output device preference changed")
        }
    }

    /// Manual retry from the failure UI.
    func retry() {
        queue.async { [self] in
            recoveryAttempt = 0
            rebuild(reason: "user retry")
        }
    }

    // MARK: - Pipeline

    private func build(reason: String) {
        teardown()
        do {
            let resolved = try preferredDeviceUID.map { try OutputDevice.named(uid: $0) }
                ?? OutputDevice.currentDefault()
            device = resolved

            let newTap = try ProcessTap(excludingSelfOn: resolved)
            tap = newTap
            let newAggregate = try TapAggregateDevice(tap: newTap, output: resolved)
            aggregate = newAggregate

            let bufferFrames: UInt32 = (try? CA.value(newAggregate.id,
                                                      kAudioDevicePropertyBufferFrameSize,
                                                      default: UInt32(512))) ?? 512
            let format = newTap.format
            dsp.prepare(sampleRate: format.mSampleRate,
                        channels: Int(format.mChannelsPerFrame),
                        blockFrames: Int(bufferFrames))
            dsp.setEnabled(enabled)
            dsp.setLimiterEnabled(limiterEnabled)
            pushParameters()

            let context = dsp.renderContext()
            var newProcID: AudioDeviceIOProcID?
            var osStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, newAggregate.id, nil) {
                _, inputData, _, outputData, _ in
                DSPCore.render(input: inputData, output: outputData, context: context)
            }
            guard osStatus == noErr, let newProcID else {
                throw CA.Error(status: osStatus, what: "AudioDeviceCreateIOProcIDWithBlock")
            }
            procID = newProcID

            osStatus = AudioDeviceStart(newAggregate.id, newProcID)
            guard osStatus == noErr else {
                throw CA.Error(status: osStatus, what: "AudioDeviceStart")
            }

            for line in newAggregate.diagnose() { Log.info("  agg: \(line)") }
            installDeviceListeners(for: resolved)
            sawCallbacks = false
            silentTicks = 0
            recoveryAttempt = 0

            update {
                $0.state = .running
                $0.deviceName = resolved.name
                $0.deviceUID = resolved.uid
                $0.sampleRate = format.mSampleRate
                $0.channels = Int(format.mChannelsPerFrame)
                $0.bufferFrames = bufferFrames
                $0.lastError = nil
            }
            Log.info("pipeline built (\(reason)): \(resolved.name), "
                + "\(Int(format.mSampleRate)) Hz, \(format.mChannelsPerFrame) ch, "
                + "\(bufferFrames) frames")
        } catch {
            let message = "\(error)"
            Log.info("pipeline build failed (\(reason)): \(message)")
            teardown()
            scheduleRecovery(error: message)
        }
    }

    private func teardown() {
        removeDeviceListeners()
        if let aggregate, let procID {
            AudioDeviceStop(aggregate.id, procID)
            AudioDeviceDestroyIOProcID(aggregate.id, procID)
        }
        procID = nil
        aggregate?.destroy()
        aggregate = nil
        tap?.destroy()
        tap = nil
        device = nil
    }

    private func rebuild(reason: String) {
        guard started, !suspended else { return }
        build(reason: reason)
    }

    private func scheduleRecovery(error: String) {
        guard started, !suspended else {
            update { $0.state = .failed(error); $0.lastError = error }
            return
        }
        recoveryAttempt += 1
        guard recoveryAttempt <= AudioSession.maxRecoveryAttempts else {
            Log.info("giving up after \(AudioSession.maxRecoveryAttempts) attempts")
            update { $0.state = .failed(error); $0.lastError = error }
            return
        }
        // Exponential backoff: a device that just vanished is rarely back in
        // 100 ms, and hammering Core Audio makes recovery slower, not faster.
        let delay = min(pow(2.0, Double(recoveryAttempt - 1)) * 0.5, 8)
        update { $0.state = .recovering(attempt: recoveryAttempt); $0.lastError = error }
        Log.info("recovery attempt \(recoveryAttempt) in \(delay)s")
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard started, !suspended else { return }
            build(reason: "recovery \(recoveryAttempt)")
        }
    }

    /// Auto Headroom lives here because it needs the live sample rate.
    private func pushParameters() {
        let required = Headroom.requiredDB(bandGainsDB: settings.bandGainsDB,
                                           sampleRate: dsp.sampleRate)
        let effective = Headroom.effectivePreampDB(userPreampDB: settings.preampDB,
                                                   requiredDB: required,
                                                   autoHeadroom: settings.autoHeadroom)
        dsp.setBandGains(settings.bandGainsDB)
        dsp.setEffectivePreampDB(effective)
        update {
            $0.userPreampDB = settings.preampDB
            $0.requiredHeadroomDB = required
            $0.effectivePreampDB = effective
            $0.autoHeadroom = settings.autoHeadroom
        }
    }

    // MARK: - Listeners

    private func addListener(_ objectID: AudioObjectID,
                             _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                             reason: String) {
        var address = CA.address(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.queue.async { self?.rebuild(reason: reason) }
        }
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
        if status == noErr {
            listeners.append((objectID, address, block))
        } else {
            Log.info("warn: listener \(CA.fourCC(selector)) failed: \(CA.describe(status))")
        }
    }

    private func installSystemListeners() {
        // Only relevant while following the system default.
        var address = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            queue.async {
                guard self.preferredDeviceUID == nil else { return }
                self.rebuild(reason: "default output device changed")
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                        &address, queue, block)
        if status == noErr {
            listeners.append((AudioObjectID(kAudioObjectSystemObject), address, block))
        }
    }

    private func installDeviceListeners(for device: OutputDevice) {
        addListener(device.id, kAudioDevicePropertyNominalSampleRate,
                    reason: "sample rate changed")
        addListener(device.id, kAudioDevicePropertyStreamFormat,
                    scope: kAudioDevicePropertyScopeOutput,
                    reason: "stream format changed")
        addListener(device.id, kAudioDevicePropertyDeviceIsAlive,
                    reason: "output device disappeared")
    }

    private func removeDeviceListeners() {
        // The system-object listener is installed once and outlives rebuilds.
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var kept: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        for entry in listeners {
            if entry.0 == systemObject {
                kept.append(entry)
                continue
            }
            var address = entry.1
            AudioObjectRemovePropertyListenerBlock(entry.0, &address, queue, entry.2)
        }
        listeners = kept
    }

    private func installSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification,
                           object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            queue.async { [self] in
                guard started else { return }
                Log.info("system sleeping — suspending audio")
                suspended = true
                teardown()
                update { $0.state = .stopped }
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification,
                           object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            queue.async { [self] in
                guard started else { return }
                Log.info("system woke — rebuilding audio")
                suspended = false
                recoveryAttempt = 0
                // Devices come back a beat after wake; a cold retry here just
                // burns the first recovery attempt.
                queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.rebuild(reason: "wake from sleep")
                }
            }
        }
    }

    // MARK: - Watchdog

    /// The IO callback is the only liveness signal that distinguishes "running
    /// and silent" from "started but never actually running".
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    /// Core Audio stops cycling the aggregate when nothing is playing, so a
    /// callback count of zero on its own means nothing. The verdict only makes
    /// sense while the physical device is actually running for somebody:
    /// audio is being produced and we are not seeing it.
    private func tick() {
        let meters = dsp.drainMeters()
        let deviceActive: Bool = device.flatMap {
            (try? CA.value($0.id, kAudioDevicePropertyDeviceIsRunningSomewhere,
                           default: UInt32(0))).map { $0 != 0 }
        } ?? false

        update {
            $0.callbacksPerTick = meters.callbacks
            $0.deviceActive = deviceActive
            $0.peakInDB = meters.peakIn > 0 ? 20 * log10(Double(meters.peakIn)) : -.infinity
            $0.peakOutDB = meters.peakOut > 0 ? 20 * log10(Double(meters.peakOut)) : -.infinity
            $0.limiterReductionDB = meters.limitDB
        }

        if meters.callbacks > 0 {
            let recovered = !sawCallbacks
            sawCallbacks = true
            silentTicks = 0
            recoveryAttempt = 0
            if currentStatus.state != .running {
                if recovered { Log.info("audio flowing") }
                update { $0.state = .running; $0.lastError = nil }
            }
            return
        }

        guard started, !suspended, procID != nil, deviceActive else {
            silentTicks = 0
            return
        }

        silentTicks += 1
        guard silentTicks >= 2 else { return }
        silentTicks = 0

        if sawCallbacks {
            Log.info("IO callbacks stopped while the device is active — rebuilding")
            scheduleRecovery(error: "Audio stopped unexpectedly")
        } else if currentStatus.state != .needsPermission {
            // Something is playing, the device is running, and Core Audio
            // returned noErr for every call — the audio-capture grant is the
            // only thing left that can be missing.
            Log.info("device active but no IO callbacks — audio capture permission missing")
            update { $0.state = .needsPermission }
        }
    }

    // MARK: - Status

    private func update(_ mutate: (inout Status) -> Void) {
        statusLock.lock()
        mutate(&status)
        let snapshot = status
        statusLock.unlock()
        if let onStatusChange {
            DispatchQueue.main.async { onStatusChange(snapshot) }
        }
    }
}
