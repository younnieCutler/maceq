import CoreAudio
import Foundation
import os

/// The real-time signal path: preamp -> 20-band cascade -> safety limiter,
/// crossfaded against the dry signal so enabling and disabling the EQ never
/// clicks.
///
/// All state the IO thread touches lives in manually allocated plain-old-data
/// so the render block captures nothing that needs ARC. Control-side setters
/// take a lock; the IO thread only ever tries it.
final class DSPCore: @unchecked Sendable {

    static let maxChannels = 8

    fileprivate struct Shared {
        var lock = os_unfair_lock()

        // Written by the control thread under `lock`.
        var generation: UInt64 = 0
        var preampDB: Double = 0
        var enabled = true
        var limiterEnabled = true

        // IO-thread only.
        var appliedGeneration: UInt64 = .max
        var preampGain: Double = 1
        var preampTarget: Double = 1
        var wet: Double = 1
        var wetTarget: Double = 1
        var limiter = SafetyLimiter()
        var ioLimiterEnabled = true
        var bandSmoothing: Double = 0
        var gainSmoothing: Double = 0

        // Metering, drained by the control thread. Torn reads are harmless.
        var peakIn: Float = 0
        var peakOut: Float = 0
        var frames: UInt64 = 0
        var callbacks: UInt64 = 0
        var limitDB: Double = 0
    }

    struct Meters {
        var peakIn: Float = 0
        var peakOut: Float = 0
        var frames: UInt64 = 0
        var callbacks: UInt64 = 0
        var limitDB: Double = 0
    }

    private let shared: UnsafeMutablePointer<Shared>
    private let targetGainDB: UnsafeMutablePointer<Double>   // control -> IO
    private let currentGainDB: UnsafeMutablePointer<Double>  // IO-owned, smoothed
    private let pendingGainDB: UnsafeMutablePointer<Double>  // IO-owned snapshot
    private let coefficients: UnsafeMutablePointer<BiquadCoefficients>
    private let states: UnsafeMutablePointer<BiquadState>
    private let scratch: UnsafeMutablePointer<Double>

    private(set) var sampleRate: Double = 48_000
    private(set) var channels: Int = 2

    init() {
        shared = .allocate(capacity: 1)
        shared.initialize(to: Shared())
        targetGainDB = .allocate(capacity: EQBands.count)
        targetGainDB.initialize(repeating: 0, count: EQBands.count)
        currentGainDB = .allocate(capacity: EQBands.count)
        currentGainDB.initialize(repeating: 0, count: EQBands.count)
        pendingGainDB = .allocate(capacity: EQBands.count)
        pendingGainDB.initialize(repeating: 0, count: EQBands.count)
        coefficients = .allocate(capacity: EQBands.count)
        coefficients.initialize(repeating: .identity, count: EQBands.count)
        states = .allocate(capacity: EQBands.count * DSPCore.maxChannels)
        states.initialize(repeating: BiquadState(),
                          count: EQBands.count * DSPCore.maxChannels)
        scratch = .allocate(capacity: DSPCore.maxChannels)
        scratch.initialize(repeating: 0, count: DSPCore.maxChannels)
    }

    deinit {
        shared.deinitialize(count: 1); shared.deallocate()
        targetGainDB.deinitialize(count: EQBands.count); targetGainDB.deallocate()
        currentGainDB.deinitialize(count: EQBands.count); currentGainDB.deallocate()
        pendingGainDB.deinitialize(count: EQBands.count); pendingGainDB.deallocate()
        coefficients.deinitialize(count: EQBands.count); coefficients.deallocate()
        states.deinitialize(count: EQBands.count * DSPCore.maxChannels); states.deallocate()
        scratch.deinitialize(count: DSPCore.maxChannels); scratch.deallocate()
    }

    // MARK: - Configuration (control thread)

    /// Called whenever the pipeline is (re)built for a device or sample rate.
    func prepare(sampleRate: Double, channels: Int, blockFrames: Int) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        self.channels = min(max(channels, 1), DSPCore.maxChannels)

        os_unfair_lock_lock(&shared.pointee.lock)
        // Band gains settle over ~25 ms, recomputed once per block.
        let blockDuration = Double(max(blockFrames, 1)) / self.sampleRate
        shared.pointee.bandSmoothing = 1 - exp(-blockDuration / 0.025)
        // Preamp and the wet/dry crossfade move per sample over ~20 ms.
        shared.pointee.gainSmoothing = 1 - exp(-1 / (0.020 * self.sampleRate))
        shared.pointee.limiter.prepare(sampleRate: self.sampleRate)
        shared.pointee.generation &+= 1
        os_unfair_lock_unlock(&shared.pointee.lock)

        for index in 0..<(EQBands.count * DSPCore.maxChannels) {
            states[index].reset()
        }
        // A rebuild is a discontinuity anyway; start from the target rather
        // than sliding up from wherever the previous device left off.
        for index in 0..<EQBands.count {
            currentGainDB[index] = targetGainDB[index]
            coefficients[index] = BiquadCoefficients(peakingAt: EQBands.frequencies[index],
                                                     sampleRate: self.sampleRate,
                                                     q: EQBands.q,
                                                     gainDB: currentGainDB[index])
        }
        shared.pointee.appliedGeneration = shared.pointee.generation
        shared.pointee.preampGain = pow(10, shared.pointee.preampDB / 20)
        shared.pointee.preampTarget = shared.pointee.preampGain
        shared.pointee.wet = shared.pointee.enabled ? 1 : 0
        shared.pointee.wetTarget = shared.pointee.wet
    }

    func setBandGains(_ gains: [Double]) {
        os_unfair_lock_lock(&shared.pointee.lock)
        for index in 0..<EQBands.count {
            targetGainDB[index] = index < gains.count ? EQBands.clamp(gains[index]) : 0
        }
        shared.pointee.generation &+= 1
        os_unfair_lock_unlock(&shared.pointee.lock)
    }

    func setEffectivePreampDB(_ db: Double) {
        os_unfair_lock_lock(&shared.pointee.lock)
        shared.pointee.preampDB = db
        shared.pointee.generation &+= 1
        os_unfair_lock_unlock(&shared.pointee.lock)
    }

    /// `false` crossfades to a transparent passthrough. It does not stop the
    /// engine — audio keeps flowing through MacEQ either way.
    func setEnabled(_ enabled: Bool) {
        os_unfair_lock_lock(&shared.pointee.lock)
        shared.pointee.enabled = enabled
        shared.pointee.generation &+= 1
        os_unfair_lock_unlock(&shared.pointee.lock)
    }

    func setLimiterEnabled(_ enabled: Bool) {
        os_unfair_lock_lock(&shared.pointee.lock)
        shared.pointee.limiterEnabled = enabled
        shared.pointee.generation &+= 1
        os_unfair_lock_unlock(&shared.pointee.lock)
    }

    func drainMeters() -> Meters {
        var meters = Meters()
        meters.peakIn = shared.pointee.peakIn
        meters.peakOut = shared.pointee.peakOut
        meters.frames = shared.pointee.frames
        meters.callbacks = shared.pointee.callbacks
        meters.limitDB = shared.pointee.limitDB
        shared.pointee.peakIn = 0
        shared.pointee.peakOut = 0
        shared.pointee.frames = 0
        shared.pointee.callbacks = 0
        shared.pointee.limitDB = 0
        return meters
    }

    // MARK: - Render context handed to the IO block

    /// Trivial value, so the render block captures no managed references.
    struct RenderContext {
        fileprivate let shared: UnsafeMutablePointer<Shared>
        let targetGainDB: UnsafeMutablePointer<Double>
        let currentGainDB: UnsafeMutablePointer<Double>
        let pendingGainDB: UnsafeMutablePointer<Double>
        let coefficients: UnsafeMutablePointer<BiquadCoefficients>
        let states: UnsafeMutablePointer<BiquadState>
        let scratch: UnsafeMutablePointer<Double>
        let sampleRate: Double
        let channels: Int
    }

    func renderContext() -> RenderContext {
        RenderContext(shared: shared,
                      targetGainDB: targetGainDB,
                      currentGainDB: currentGainDB,
                      pendingGainDB: pendingGainDB,
                      coefficients: coefficients,
                      states: states,
                      scratch: scratch,
                      sampleRate: sampleRate,
                      channels: channels)
    }

    // MARK: - Audio IO thread

    /// No allocation, no blocking locks, no logging, no ARC.
    static func render(input: UnsafePointer<AudioBufferList>,
                       output: UnsafeMutablePointer<AudioBufferList>,
                       context: RenderContext) {
        let shared = context.shared
        shared.pointee.callbacks &+= 1

        // ponytail: trylock. A missed update is one block of staleness;
        //           blocking here is a dropout.
        if os_unfair_lock_trylock(&shared.pointee.lock) {
            if shared.pointee.generation != shared.pointee.appliedGeneration {
                for index in 0..<EQBands.count {
                    context.pendingGainDB[index] = context.targetGainDB[index]
                }
                shared.pointee.preampTarget = pow(10, shared.pointee.preampDB / 20)
                shared.pointee.wetTarget = shared.pointee.enabled ? 1 : 0
                shared.pointee.ioLimiterEnabled = shared.pointee.limiterEnabled
                shared.pointee.appliedGeneration = shared.pointee.generation
            }
            os_unfair_lock_unlock(&shared.pointee.lock)
        }

        // Slide band gains toward their targets once per block and rebuild only
        // the sections that actually moved. Ramping the gain rather than
        // swapping coefficients outright is what keeps preset changes silent.
        let bandSmoothing = shared.pointee.bandSmoothing
        for index in 0..<EQBands.count {
            let target = context.pendingGainDB[index]
            let current = context.currentGainDB[index]
            let delta = target - current
            guard abs(delta) > 1e-4 else {
                if current != target { context.currentGainDB[index] = target }
                continue
            }
            let next = current + delta * bandSmoothing
            context.currentGainDB[index] = next
            context.coefficients[index] = BiquadCoefficients(
                peakingAt: EQBands.frequencies[index],
                sampleRate: context.sampleRate,
                q: EQBands.q,
                gainDB: next)
        }

        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        guard inList.count > 0, outList.count > 0 else { return }

        let gainSmoothing = shared.pointee.gainSmoothing
        let limiterEnabled = shared.pointee.ioLimiterEnabled
        var preampGain = shared.pointee.preampGain
        let preampTarget = shared.pointee.preampTarget
        var wet = shared.pointee.wet
        let wetTarget = shared.pointee.wetTarget
        var limiter = shared.pointee.limiter

        var peakIn: Float = 0
        var peakOut: Float = 0
        var renderedFrames = 0

        for bufferIndex in 0..<min(inList.count, outList.count) {
            let inBuffer = inList[bufferIndex]
            let outBuffer = outList[bufferIndex]
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
            let activeChannels = min(min(inChannels, outChannels), context.channels)
            let stateBase = bufferIndex * outChannels

            for frame in 0..<frames {
                preampGain += (preampTarget - preampGain) * gainSmoothing
                wet += (wetTarget - wet) * gainSmoothing
                let dryMix = 1 - wet

                // Two passes over the frame: filter every channel first, so
                // the limiter sees the true post-EQ peak across the frame
                // before any channel is written out. Otherwise a limiter
                // reacting per channel would shift the stereo image.
                var framePeak = 0.0
                for channel in 0..<activeChannels {
                    let dry = Double(source[frame * inChannels + channel])
                    let magnitudeIn = Float(abs(dry))
                    if magnitudeIn > peakIn { peakIn = magnitudeIn }

                    var value = dry * preampGain
                    let channelBase = (stateBase + channel) * EQBands.count
                    for band in 0..<EQBands.count {
                        value = context.states[channelBase + band]
                            .process(value, context.coefficients[band])
                    }
                    let mixed = dry * dryMix + value * wet
                    context.scratch[channel] = mixed
                    let magnitude = abs(mixed)
                    if magnitude > framePeak { framePeak = magnitude }
                }

                let limitGain = limiterEnabled ? limiter.gain(forPeak: framePeak) : 1
                for channel in 0..<activeChannels {
                    // The limiter has no lookahead, so a transient can slip
                    // past it before the gain catches up. Clamping guarantees
                    // nothing ever leaves here above full scale, whatever the
                    // limiter does or whether it is switched on at all.
                    let limited = min(max(context.scratch[channel] * limitGain, -1), 1)
                    let value = Float(limited)
                    destination[frame * outChannels + channel] = value
                    let magnitude = abs(value)
                    if magnitude > peakOut { peakOut = magnitude }
                }

                for channel in activeChannels..<outChannels {
                    destination[frame * outChannels + channel] = 0
                }
            }
            renderedFrames = max(renderedFrames, frames)
        }

        let reduction = limiter.drainReduction()
        shared.pointee.preampGain = preampGain
        shared.pointee.wet = wet
        shared.pointee.limiter = limiter
        if peakIn > shared.pointee.peakIn { shared.pointee.peakIn = peakIn }
        if peakOut > shared.pointee.peakOut { shared.pointee.peakOut = peakOut }
        if reduction > shared.pointee.limitDB { shared.pointee.limitDB = reduction }
        shared.pointee.frames &+= UInt64(renderedFrames)
    }
}
