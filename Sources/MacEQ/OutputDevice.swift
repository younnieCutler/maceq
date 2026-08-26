import CoreAudio
import Foundation

/// The physical output device MacEQ renders to. Also the device whose stream
/// gets tapped, so the tap format and the render format match by construction.
struct OutputDevice {
    let id: AudioObjectID
    let uid: String
    let name: String
    let format: AudioStreamBasicDescription
    let sampleRate: Double

    static func currentDefault() throws -> OutputDevice {
        let id: AudioObjectID = try CA.value(AudioObjectID(kAudioObjectSystemObject),
                                             kAudioHardwarePropertyDefaultOutputDevice,
                                             default: AudioObjectID(kAudioObjectUnknown))
        guard id != kAudioObjectUnknown else {
            throw CA.Error(status: kAudioHardwareBadDeviceError, what: "default output device")
        }
        return try OutputDevice(id: id)
    }

    init(id: AudioObjectID) throws {
        self.id = id
        uid = try CA.string(id, kAudioDevicePropertyDeviceUID)
        name = try CA.string(id, kAudioObjectPropertyName)
        format = try CA.value(id, kAudioDevicePropertyStreamFormat,
                              scope: kAudioDevicePropertyScopeOutput,
                              default: AudioStreamBasicDescription())
        sampleRate = try CA.value(id, kAudioDevicePropertyNominalSampleRate,
                                  default: Double(0))
    }

    var summary: String {
        "\(name) [\(uid)] — \(format.summary), nominal \(Int(sampleRate)) Hz"
    }
}

extension OutputDevice {
    /// Every device that has at least one output channel.
    static func allOutputs() -> [OutputDevice] {
        let ids = (try? CA.array(AudioObjectID(kAudioObjectSystemObject),
                                 kAudioHardwarePropertyDevices,
                                 of: AudioObjectID.self)) ?? []
        return ids.compactMap { id in
            guard let device = try? OutputDevice(id: id),
                  device.format.mChannelsPerFrame > 0 else { return nil }
            return device
        }
    }

    static func named(uid: String) throws -> OutputDevice {
        guard let match = allOutputs().first(where: { $0.uid == uid }) else {
            throw CA.Error(status: kAudioHardwareBadDeviceError, what: "output device \(uid)")
        }
        return match
    }
}
