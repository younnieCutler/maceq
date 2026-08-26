import CoreAudio
import Foundation
import os

/// Owns the tap, the aggregate device and the single IOProc that does
/// input -> EQ -> output on one clock.
///
/// Gate A runs one peaking band; the cascade lands in Gate B.
final class EQEngine: @unchecked Sendable {

    /// Everything the IO thread touches. Plain-old-data behind a raw pointer so
    /// the IO block captures a trivial value and never triggers ARC.
    private struct Shared {
        var lock = os_unfair_lock()
        // Written by the control thread under `lock`.
        var coefficients = BiquadCoefficients.identity
        var bypass = false
        // Owned by the IO thread; refreshed from the fields above when the
        // trylock succeeds.
        var ioCoefficients = BiquadCoefficients.identity
        var ioBypass = false
        // Diagnostics: peak magnitude since the last read. Torn reads are
        // harmless here.
        var peak: Float = 0
        var outPeak: Float = 0
        var frames: UInt64 = 0
        var callbacks: UInt64 = 0
        var lastInBuffers: UInt32 = 0
        var lastOutBuffers: UInt32 = 0
        var lastInBytes: UInt32 = 0
        var lastOutBytes: UInt32 = 0
    }

    let tap: ProcessTap?
    let aggregate: TapAggregateDevice
    let output: OutputDevice

    private let shared: UnsafeMutablePointer<Shared>
    private let states: UnsafeMutablePointer<BiquadState>
    private let channelCount: Int
    private var procID: AudioDeviceIOProcID?
    private var running = false

    private let sampleRate: Double
    private(set) var gainDB: Double = 0
    private(set) var bypassed = false
    let frequency: Double
    let q: Double

    init(output: OutputDevice, frequency: Double = 1_000, q: Double = 1.0) throws {
        self.output = output
        self.frequency = frequency
        self.q = q

        // MACEQ_NOTAP isolates the aggregate from the tap while debugging.
        let useTap = ProcessInfo.processInfo.environment["MACEQ_NOTAP"] == nil
        tap = useTap ? try ProcessTap(excludingSelfOn: output) : nil
        if let tap {
            Log.info("tap created: uid \(tap.uid), format \(tap.format.summary)")
        } else {
            Log.info("tap SKIPPED (MACEQ_NOTAP)")
        }
        let renderFormat = tap?.format ?? output.format

        sampleRate = renderFormat.mSampleRate
        aggregate = try TapAggregateDevice(tap: tap, output: output)
        Log.info("aggregate created: id \(aggregate.id), uid \(aggregate.uid)")
        Log.info("  aggregate input : \(aggregate.inputFormat.summary)")
        Log.info("  aggregate output: \(aggregate.outputFormat.summary)")

        channelCount = max(Int(renderFormat.mChannelsPerFrame),
                           Int(aggregate.outputFormat.mChannelsPerFrame))
        states = .allocate(capacity: max(channelCount, 1))
        states.initialize(repeating: BiquadState(), count: max(channelCount, 1))
        shared = .allocate(capacity: 1)
        shared.initialize(to: Shared())
    }

    deinit {
        states.deinitialize(count: max(channelCount, 1))
        states.deallocate()
        shared.deinitialize(count: 1)
        shared.deallocate()
    }

    // MARK: - Control (main thread)

    func setGain(_ db: Double) {
        gainDB = min(max(db, -12), 12)
        let coefficients = BiquadCoefficients(peakingAt: frequency,
                                              sampleRate: sampleRate,
                                              q: q,
                                              gainDB: gainDB)
        // ponytail: coefficients swap in abruptly, which can click on large
        //           steps. Gate B adds the gain ramp required by PRD §19.
        os_unfair_lock_lock(&shared.pointee.lock)
        shared.pointee.coefficients = coefficients
        os_unfair_lock_unlock(&shared.pointee.lock)
    }

    func setBypass(_ bypass: Bool) {
        bypassed = bypass
        os_unfair_lock_lock(&shared.pointee.lock)
        shared.pointee.bypass = bypass
        os_unfair_lock_unlock(&shared.pointee.lock)
    }

    /// Peak magnitude and frame count observed since the previous call.
    func drainMeters() -> (peak: Float, outPeak: Float, frames: UInt64, callbacks: UInt64, shape: String) {
        let peak = shared.pointee.peak
        let outPeak = shared.pointee.outPeak
        let frames = shared.pointee.frames
        let callbacks = shared.pointee.callbacks
        let shape = "in \(shared.pointee.lastInBuffers)buf/\(shared.pointee.lastInBytes)B"
            + " out \(shared.pointee.lastOutBuffers)buf/\(shared.pointee.lastOutBytes)B"
        shared.pointee.peak = 0
        shared.pointee.outPeak = 0
        shared.pointee.frames = 0
        shared.pointee.callbacks = 0
        return (peak, outPeak, frames, callbacks, shape)
    }

    // MARK: - Lifecycle

    func start() throws {
        let shared = self.shared
        let states = self.states
        let channelCount = self.channelCount

        var newProcID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregate.id, nil) {
            _, inputData, _, outputData, _ in
            EQEngine.render(input: inputData,
                            output: outputData,
                            shared: shared,
                            states: states,
                            channelCount: channelCount)
        }
        guard status == noErr, let newProcID else {
            throw CA.Error(status: status, what: "AudioDeviceCreateIOProcIDWithBlock")
        }
        procID = newProcID

        status = AudioDeviceStart(aggregate.id, newProcID)
        guard status == noErr else {
            throw CA.Error(status: status, what: "AudioDeviceStart")
        }
        running = true
        for line in aggregate.diagnose() { Log.info("  agg: \(line)") }
        Log.info("engine running (\(channelCount) ch @ \(Int(sampleRate)) Hz)")
    }

    /// Best-effort teardown: a failure in one step must not skip the next, or
    /// the user is left with a muted Mac.
    func stop() {
        if let procID {
            if running { AudioDeviceStop(aggregate.id, procID) }
            AudioDeviceDestroyIOProcID(aggregate.id, procID)
            self.procID = nil
        }
        running = false
        aggregate.destroy()
        tap?.destroy()
        Log.info("engine stopped, resources released")
    }

    // MARK: - Audio IO thread

    /// Real-time context. No allocation, no locks that can block, no logging,
    /// no Swift runtime calls beyond arithmetic.
    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               shared: UnsafeMutablePointer<Shared>,
                               states: UnsafeMutablePointer<BiquadState>,
                               channelCount: Int) {
        // ponytail: trylock, not lock. Missing one update costs a few ms of
        //           staleness; blocking the IO thread costs a dropout.
        if os_unfair_lock_trylock(&shared.pointee.lock) {
            shared.pointee.ioCoefficients = shared.pointee.coefficients
            shared.pointee.ioBypass = shared.pointee.bypass
            os_unfair_lock_unlock(&shared.pointee.lock)
        }
        let coefficients = shared.pointee.ioCoefficients
        let bypass = shared.pointee.ioBypass
        shared.pointee.callbacks &+= 1
        shared.pointee.lastInBuffers = input.pointee.mNumberBuffers
        shared.pointee.lastOutBuffers = output.pointee.mNumberBuffers
        shared.pointee.lastInBytes = input.pointee.mBuffers.mDataByteSize
        shared.pointee.lastOutBytes = output.pointee.mBuffers.mDataByteSize

        let inList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        guard inList.count > 0, outList.count > 0 else { return }

        var peak: Float = 0
        var outPeak: Float = 0
        var renderedFrames = 0

        // Both lists are laid out the same way (one interleaved buffer, or one
        // buffer per channel), so walking them in lockstep covers both.
        let pairs = min(inList.count, outList.count)
        for index in 0..<pairs {
            let inBuffer = inList[index]
            let outBuffer = outList[index]
            guard let inData = inBuffer.mData, let outData = outBuffer.mData else { continue }

            let inChannels = Int(inBuffer.mNumberChannels)
            let outChannels = Int(outBuffer.mNumberChannels)
            guard inChannels > 0, outChannels > 0 else { continue }

            let inFrames = Int(inBuffer.mDataByteSize) / (MemoryLayout<Float>.size * inChannels)
            let outFrames = Int(outBuffer.mDataByteSize) / (MemoryLayout<Float>.size * outChannels)
            let frames = min(inFrames, outFrames)
            guard frames > 0 else { continue }

            let source = inData.assumingMemoryBound(to: Float.self)
            let destination = outData.assumingMemoryBound(to: Float.self)
            let copyChannels = min(inChannels, outChannels)
            let stateBase = index * outChannels

            for frame in 0..<frames {
                for channel in 0..<copyChannels {
                    let x = source[frame * inChannels + channel]
                    let magnitude = abs(x)
                    if magnitude > peak { peak = magnitude }

                    var y = x
                    if !bypass {
                        let stateIndex = stateBase + channel
                        if stateIndex < channelCount {
                            y = Float(states[stateIndex].process(Double(x), coefficients))
                        }
                    }
                    destination[frame * outChannels + channel] = y
                    let outMagnitude = abs(y)
                    if outMagnitude > outPeak { outPeak = outMagnitude }
                }
                // Output channels the tap does not feed must be silent rather
                // than left holding whatever the device buffer had.
                for channel in copyChannels..<outChannels {
                    destination[frame * outChannels + channel] = 0
                }
            }
            renderedFrames = max(renderedFrames, frames)
        }

        if peak > shared.pointee.peak { shared.pointee.peak = peak }
        if outPeak > shared.pointee.outPeak { shared.pointee.outPeak = outPeak }
        shared.pointee.frames &+= UInt64(renderedFrames)
    }
}
