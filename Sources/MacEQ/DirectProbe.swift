import CoreAudio
import Foundation

/// Diagnostic only: installs an IOProc straight on a physical device, with no
/// tap and no aggregate. If this fires but the aggregate one does not, the
/// problem is in the tap/aggregate composition rather than the IOProc plumbing.
enum DirectProbe {
    private final class Counter: @unchecked Sendable {
        var callbacks: UInt64 = 0
        var bytes: UInt32 = 0
    }

    static func run(on device: OutputDevice, seconds: Double = 4) {
        let counter = Counter()
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, nil) {
            _, _, _, outputData, _ in
            counter.callbacks &+= 1
            counter.bytes = outputData.pointee.mBuffers.mDataByteSize
        }
        guard status == noErr, let procID else {
            Log.info("probe: create failed: \(CA.describe(status))")
            return
        }
        let started = AudioDeviceStart(device.id, procID)
        Log.info("probe: AudioDeviceStart -> \(CA.describe(started))")
        Thread.sleep(forTimeInterval: seconds)
        Log.info("probe: \(counter.callbacks) callbacks in \(seconds)s, last \(counter.bytes) bytes")
        AudioDeviceStop(device.id, procID)
        AudioDeviceDestroyIOProcID(device.id, procID)
    }
}
