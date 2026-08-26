import CoreAudio
import Foundation

/// A Core Audio process tap scoped to one output device stream, excluding
/// MacEQ itself.
///
/// Excluding our own process is what keeps this from becoming a feedback loop:
/// audio MacEQ renders is neither captured nor muted, so only the other apps'
/// audio is pulled out of the original path and pushed back through the EQ.
///
/// `CATapDescription`'s array-taking initialisers are NS_REFINED_FOR_SWIFT and
/// no Swift overlay ships for them, so the `__`-prefixed selector is the real
/// entry point.
final class ProcessTap {
    let id: AudioObjectID
    let uid: String
    let format: AudioStreamBasicDescription

    init(excludingSelfOn device: OutputDevice, stream: Int = 0) throws {
        let selfProcess = try ProcessTap.selfProcessObjectID()

        let description = CATapDescription(__excludingProcesses: [NSNumber(value: selfProcess)],
                                           andDeviceUID: device.uid,
                                           withStream: stream)
        description.name = "MacEQ Tap"
        description.uuid = UUID()
        description.isPrivate = true
        // Pull the tapped apps off the hardware path while we are reading;
        // otherwise the original audio plays alongside our processed copy.
        description.muteBehavior = .mutedWhenTapped

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw CA.Error(status: status, what: "AudioHardwareCreateProcessTap")
        }
        id = tapID
        uid = try CA.string(tapID, kAudioTapPropertyUID)
        format = try CA.value(tapID, kAudioTapPropertyFormat,
                              default: AudioStreamBasicDescription())
    }

    func destroy() {
        let status = AudioHardwareDestroyProcessTap(id)
        if status != noErr {
            Log.info("warn: destroy tap \(id): \(CA.describe(status))")
        }
    }

    /// PID -> AudioObjectID of the process object, needed by CATapDescription.
    static func selfProcessObjectID() throws -> AudioObjectID {
        var pid = getpid()
        return try withUnsafePointer(to: &pid) { qualifier in
            try CA.value(AudioObjectID(kAudioObjectSystemObject),
                         kAudioHardwarePropertyTranslatePIDToProcessObject,
                         qualifier: UnsafeRawPointer(qualifier),
                         qualifierSize: UInt32(MemoryLayout<pid_t>.size),
                         default: AudioObjectID(kAudioObjectUnknown))
        }
    }

    /// Destroys taps left behind by a previous MacEQ process that died hard.
    static func destroyOrphans() {
        guard let taps = try? CA.array(AudioObjectID(kAudioObjectSystemObject),
                                       kAudioHardwarePropertyTapList,
                                       of: AudioObjectID.self) else { return }
        var removed = 0
        for tap in taps {
            guard let description: CATapDescription = try? CA.value(tap, kAudioTapPropertyDescription,
                                                                    default: CATapDescription()),
                  description.name == "MacEQ Tap" else { continue }
            if AudioHardwareDestroyProcessTap(tap) == noErr { removed += 1 }
        }
        if removed > 0 { Log.info("cleaned up \(removed) orphaned tap(s)") }
    }
}
