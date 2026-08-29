import CoreAudio
import Foundation
import libkern
import os

enum SpectrumMath {
    static func magnitudeDB(q1: Double, q2: Double,
                            coefficient: Double, windowSize: Int) -> Double {
        guard windowSize > 0 else { return -80 }
        let power = max(q1 * q1 + q2 * q2 - coefficient * q1 * q2, 0)
        let amplitude = max(power.squareRoot() / Double(windowSize) * 2, 1e-5)
        return min(max(20 * log10(amplitude), -80), 0)
    }
}

/// The real-time signal path: preamp -> 20-band cascade -> safety limiter,
/// crossfaded against the dry signal so enabling and disabling the EQ never
/// clicks.
///
/// All state the IO thread touches lives in manually allocated plain-old-data
/// so the render block captures nothing that needs ARC. Control-side setters
/// take a lock; the IO thread only ever tries it.
final class DSPCore: @unchecked Sendable {

    static let maxChannels = 8
    static let spectrumBinCount = EQBands.count
    static let spectrumBufferCount = 3
    private static let spectrumWindowSize = 1_024

    fileprivate struct Shared {
        var lock = os_unfair_lock()

        // Written by the control thread under `lock`.
        var generation: UInt64 = 0
        var preampDB: Double = 0
        var enabled = true
        var limiterEnabled = true
        var spectrumEnabled = true

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
        var peakOutLeft: Float = 0
        var peakOutRight: Float = 0
        var frames: UInt64 = 0
        var callbacks: UInt64 = 0
        var limitDB: Double = 0
        // IO-thread only. The control thread reads the completed smoothed bins.
        var spectrumSampleCount = 0
        var ioSpectrumEnabled = true
        var spectrumWasEnabled = true
        var spectrumPublishedIndex: Int32 = 0
        var spectrumReadIndex: Int32 = -1
    }

    struct Meters {
        var peakIn: Float = 0
        var peakOut: Float = 0
        var peakOutLeft: Float = 0
        var peakOutRight: Float = 0
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
    private let spectrumBuffers: UnsafeMutablePointer<Float>
    private let spectrumQ1: UnsafeMutablePointer<Double>
    private let spectrumQ2: UnsafeMutablePointer<Double>
    private let spectrumCoefficients: UnsafeMutablePointer<Double>

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
        spectrumBuffers = .allocate(capacity: DSPCore.spectrumBinCount * DSPCore.spectrumBufferCount)
        spectrumBuffers.initialize(repeating: -80,
                                    count: DSPCore.spectrumBinCount * DSPCore.spectrumBufferCount)
        spectrumQ1 = .allocate(capacity: DSPCore.spectrumBinCount)
        spectrumQ1.initialize(repeating: 0, count: DSPCore.spectrumBinCount)
        spectrumQ2 = .allocate(capacity: DSPCore.spectrumBinCount)
        spectrumQ2.initialize(repeating: 0, count: DSPCore.spectrumBinCount)
        spectrumCoefficients = .allocate(capacity: DSPCore.spectrumBinCount)
        spectrumCoefficients.initialize(repeating: 0, count: DSPCore.spectrumBinCount)
    }

    deinit {
        shared.deinitialize(count: 1); shared.deallocate()
        targetGainDB.deinitialize(count: EQBands.count); targetGainDB.deallocate()
        currentGainDB.deinitialize(count: EQBands.count); currentGainDB.deallocate()
        pendingGainDB.deinitialize(count: EQBands.count); pendingGainDB.deallocate()
        coefficients.deinitialize(count: EQBands.count); coefficients.deallocate()
        states.deinitialize(count: EQBands.count * DSPCore.maxChannels); states.deallocate()
        scratch.deinitialize(count: DSPCore.maxChannels); scratch.deallocate()
        spectrumBuffers.deinitialize(count: DSPCore.spectrumBinCount * DSPCore.spectrumBufferCount); spectrumBuffers.deallocate()
        spectrumQ1.deinitialize(count: DSPCore.spectrumBinCount); spectrumQ1.deallocate()
        spectrumQ2.deinitialize(count: DSPCore.spectrumBinCount); spectrumQ2.deallocate()
        spectrumCoefficients.deinitialize(count: DSPCore.spectrumBinCount); spectrumCoefficients.deallocate()
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
        shared.pointee.spectrumSampleCount = 0
        shared.pointee.ioSpectrumEnabled = shared.pointee.spectrumEnabled
        shared.pointee.spectrumWasEnabled = shared.pointee.spectrumEnabled
        shared.pointee.spectrumPublishedIndex = 0
        shared.pointee.spectrumReadIndex = -1
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
            let frequency = min(EQBands.frequencies[index], self.sampleRate * 0.45)
            spectrumCoefficients[index] = 2 * cos(2 * Double.pi * frequency / self.sampleRate)
            spectrumQ1[index] = 0
            spectrumQ2[index] = 0
            for buffer in 0..<DSPCore.spectrumBufferCount {
                spectrumBuffers[buffer * DSPCore.spectrumBinCount + index] = -80
            }
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

    func setSpectrumEnabled(_ enabled: Bool) {
        os_unfair_lock_lock(&shared.pointee.lock)
        shared.pointee.spectrumEnabled = enabled
        shared.pointee.generation &+= 1
        os_unfair_lock_unlock(&shared.pointee.lock)
    }

    func drainMeters() -> Meters {
        var meters = Meters()
        meters.peakIn = shared.pointee.peakIn
        meters.peakOut = shared.pointee.peakOut
        meters.peakOutLeft = shared.pointee.peakOutLeft
        meters.peakOutRight = shared.pointee.peakOutRight
        meters.frames = shared.pointee.frames
        meters.callbacks = shared.pointee.callbacks
        meters.limitDB = shared.pointee.limitDB
        shared.pointee.peakIn = 0
        shared.pointee.peakOut = 0
        shared.pointee.peakOutLeft = 0
        shared.pointee.peakOutRight = 0
        shared.pointee.frames = 0
        shared.pointee.callbacks = 0
        shared.pointee.limitDB = 0
        return meters
    }

    /// Copies the smoothed spectrum on the control side; the render thread
    /// never allocates or takes a lock for metering. A reader claims the
    /// published buffer while copying, and the writer always uses another one.
    // ponytail: OSAtomic is deprecated but available on the macOS 14 target;
    //           replace it with a C11 atomic shim when the minimum rises.
    func readSpectrumDB() -> [Float] {
        for _ in 0..<DSPCore.spectrumBufferCount {
            let published = Int(OSAtomicAdd32Barrier(0, &shared.pointee.spectrumPublishedIndex))
            guard OSAtomicCompareAndSwap32Barrier(-1,
                                                  Int32(published),
                                                  &shared.pointee.spectrumReadIndex) else { continue }
            let stillPublished = Int(OSAtomicAdd32Barrier(0, &shared.pointee.spectrumPublishedIndex))
            guard stillPublished == published else {
                _ = OSAtomicCompareAndSwap32Barrier(Int32(published),
                                                    -1,
                                                    &shared.pointee.spectrumReadIndex)
                continue
            }
            let start = spectrumBuffers.advanced(by: published * DSPCore.spectrumBinCount)
            let result = Array(UnsafeBufferPointer(start: start, count: DSPCore.spectrumBinCount))
            _ = OSAtomicCompareAndSwap32Barrier(Int32(published),
                                                -1,
                                                &shared.pointee.spectrumReadIndex)
            return result
        }

        let published = Int(OSAtomicAdd32Barrier(0, &shared.pointee.spectrumPublishedIndex))
        let start = spectrumBuffers.advanced(by: published * DSPCore.spectrumBinCount)
        return Array(UnsafeBufferPointer(start: start, count: DSPCore.spectrumBinCount))
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
        let spectrumBuffers: UnsafeMutablePointer<Float>
        let spectrumQ1: UnsafeMutablePointer<Double>
        let spectrumQ2: UnsafeMutablePointer<Double>
        let spectrumCoefficients: UnsafeMutablePointer<Double>
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
                      spectrumBuffers: spectrumBuffers,
                      spectrumQ1: spectrumQ1,
                      spectrumQ2: spectrumQ2,
                      spectrumCoefficients: spectrumCoefficients,
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
                shared.pointee.ioSpectrumEnabled = shared.pointee.spectrumEnabled
                shared.pointee.appliedGeneration = shared.pointee.generation
            }
            os_unfair_lock_unlock(&shared.pointee.lock)
        }

        if shared.pointee.ioSpectrumEnabled != shared.pointee.spectrumWasEnabled {
            shared.pointee.spectrumSampleCount = 0
            for bin in 0..<DSPCore.spectrumBinCount {
                context.spectrumQ1[bin] = 0
                context.spectrumQ2[bin] = 0
                if !shared.pointee.ioSpectrumEnabled {
                    for buffer in 0..<DSPCore.spectrumBufferCount {
                        context.spectrumBuffers[buffer * DSPCore.spectrumBinCount + bin] = -80
                    }
                }
            }
            shared.pointee.spectrumWasEnabled = shared.pointee.ioSpectrumEnabled
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

                    if shared.pointee.ioSpectrumEnabled && bufferIndex == 0 && channel == 0 {
                        for bin in 0..<DSPCore.spectrumBinCount {
                            let q0 = context.spectrumCoefficients[bin] * context.spectrumQ1[bin]
                                - context.spectrumQ2[bin] + dry
                            context.spectrumQ2[bin] = context.spectrumQ1[bin]
                            context.spectrumQ1[bin] = q0
                        }
                        shared.pointee.spectrumSampleCount += 1
                        if shared.pointee.spectrumSampleCount == DSPCore.spectrumWindowSize {
                            let publishedIndex = Int(OSAtomicAdd32Barrier(0, &shared.pointee.spectrumPublishedIndex))
                            let readerIndex = Int(OSAtomicAdd32Barrier(0, &shared.pointee.spectrumReadIndex))
                            var writeIndex: Int?
                            for offset in 1..<DSPCore.spectrumBufferCount {
                                let candidate = (publishedIndex + offset) % DSPCore.spectrumBufferCount
                                if candidate != readerIndex {
                                    writeIndex = candidate
                                    break
                                }
                            }
                            if let writeIndex {
                                let previousBuffer = context.spectrumBuffers
                                    .advanced(by: publishedIndex * DSPCore.spectrumBinCount)
                                let writeBuffer = context.spectrumBuffers
                                    .advanced(by: writeIndex * DSPCore.spectrumBinCount)
                                for bin in 0..<DSPCore.spectrumBinCount {
                                    let q1 = context.spectrumQ1[bin]
                                    let q2 = context.spectrumQ2[bin]
                                    let db = SpectrumMath.magnitudeDB(
                                        q1: q1,
                                        q2: q2,
                                        coefficient: context.spectrumCoefficients[bin],
                                        windowSize: DSPCore.spectrumWindowSize)
                                    let previous = Double(previousBuffer[bin])
                                    writeBuffer[bin] = Float(previous + (db - previous) * 0.35)
                                    context.spectrumQ1[bin] = 0
                                    context.spectrumQ2[bin] = 0
                                }
                                _ = OSAtomicCompareAndSwap32Barrier(Int32(publishedIndex),
                                                                   Int32(writeIndex),
                                                                   &shared.pointee.spectrumPublishedIndex)
                            } else {
                                for bin in 0..<DSPCore.spectrumBinCount {
                                    context.spectrumQ1[bin] = 0
                                    context.spectrumQ2[bin] = 0
                                }
                            }
                            shared.pointee.spectrumSampleCount = 0
                        }
                    }

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
                    if channel == 0, magnitude > shared.pointee.peakOutLeft {
                        shared.pointee.peakOutLeft = magnitude
                    } else if channel == 1, magnitude > shared.pointee.peakOutRight {
                        shared.pointee.peakOutRight = magnitude
                    }
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
