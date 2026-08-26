import CoreAudio
import Foundation

/// A private aggregate device that pairs the tap (input) with the physical
/// output device (output) so a single IOProc reads and writes on one clock —
/// no ring buffer, no drift compensation between two devices, minimum latency.
///
/// `private = true` also means Core Audio tears the device down when this
/// process dies, which covers most of the crash-safety requirement for free.
final class TapAggregateDevice {
    static let uidPrefix = "com.maceq.aggregate."

    let id: AudioObjectID
    let uid: String

    init(tap: ProcessTap?, output: OutputDevice) throws {
        uid = TapAggregateDevice.uidPrefix + UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacEQ Engine",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: output.uid]
            ],
            kAudioAggregateDeviceTapListKey: tap.map {
                [[kAudioSubTapUIDKey: $0.uid,
                  kAudioSubTapDriftCompensationKey: true]]
            } ?? [],
        ]

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw CA.Error(status: status, what: "AudioHardwareCreateAggregateDevice")
        }
        id = deviceID
    }

    var inputFormat: AudioStreamBasicDescription {
        (try? CA.value(id, kAudioDevicePropertyStreamFormat,
                       scope: kAudioDevicePropertyScopeInput,
                       default: AudioStreamBasicDescription())) ?? AudioStreamBasicDescription()
    }

    var outputFormat: AudioStreamBasicDescription {
        (try? CA.value(id, kAudioDevicePropertyStreamFormat,
                       scope: kAudioDevicePropertyScopeOutput,
                       default: AudioStreamBasicDescription())) ?? AudioStreamBasicDescription()
    }

    /// Dumps what Core Audio actually built, which is rarely what the
    /// description asked for when something is wrong.
    func diagnose() -> [String] {
        var lines: [String] = []
        let running: UInt32 = (try? CA.value(id, kAudioDevicePropertyDeviceIsRunning,
                                             default: UInt32(0))) ?? 0
        let alive: UInt32 = (try? CA.value(id, kAudioDevicePropertyDeviceIsAlive,
                                           default: UInt32(0))) ?? 0
        let bufferFrames: UInt32 = (try? CA.value(id, kAudioDevicePropertyBufferFrameSize,
                                                  default: UInt32(0))) ?? 0
        lines.append("alive \(alive), running \(running), buffer \(bufferFrames) frames")

        for (label, scope) in [("input", kAudioDevicePropertyScopeInput),
                               ("output", kAudioDevicePropertyScopeOutput)] {
            let streams = (try? CA.array(id, kAudioDevicePropertyStreams,
                                         scope: scope, of: AudioObjectID.self)) ?? []
            lines.append("\(label) streams: \(streams.count) \(streams)")
        }

        let active = (try? CA.array(id, kAudioAggregateDevicePropertyActiveSubDeviceList,
                                    of: AudioObjectID.self)) ?? []
        lines.append("active sub-devices: \(active)")
        let subTaps = (try? CA.array(id, kAudioAggregateDevicePropertySubTapList,
                                     of: AudioObjectID.self)) ?? []
        lines.append("sub-taps: \(subTaps)")
        if let full: CFDictionary = try? CA.value(id, kAudioAggregateDevicePropertyFullSubDeviceList,
                                                  default: [:] as CFDictionary) {
            lines.append("composition: \(full)")
        }
        return lines
    }

    func destroy() {
        let status = AudioHardwareDestroyAggregateDevice(id)
        if status != noErr {
            Log.info("warn: destroy aggregate \(id): \(CA.describe(status))")
        }
    }

    /// Removes aggregates left behind by a previous MacEQ process.
    static func destroyOrphans() {
        guard let devices = try? CA.array(AudioObjectID(kAudioObjectSystemObject),
                                          kAudioHardwarePropertyDevices,
                                          of: AudioObjectID.self) else { return }
        var removed = 0
        for device in devices {
            guard let deviceUID = try? CA.string(device, kAudioDevicePropertyDeviceUID),
                  deviceUID.hasPrefix(uidPrefix) else { continue }
            if AudioHardwareDestroyAggregateDevice(device) == noErr { removed += 1 }
        }
        if removed > 0 { Log.info("cleaned up \(removed) orphaned aggregate device(s)") }
    }
}
