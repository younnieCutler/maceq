import CoreAudio
import Foundation

/// Thin wrapper over the AudioObject property API.
/// Every Core Audio read in this project goes through here so the
/// address/size dance is written once.
enum CA {
    struct Error: Swift.Error, CustomStringConvertible {
        let status: OSStatus
        let what: String
        var description: String { "\(what) failed: \(CA.describe(status))" }
    }

    static func describe(_ status: OSStatus) -> String {
        guard status != noErr else { return "noErr" }
        // Core Audio codes are usually four-char codes.
        let chars = [24, 16, 8, 0].map { UInt8((UInt32(bitPattern: status) >> UInt32($0)) & 0xFF) }
        let printable = chars.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        let code = printable ? String(decoding: chars, as: UTF8.self) : "\(status)"
        return "\(code) (\(status))"
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Reads a fixed-size property value.
    static func value<T>(_ objectID: AudioObjectID,
                         _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                         qualifier: UnsafeRawPointer? = nil,
                         qualifierSize: UInt32 = 0,
                         default initial: T) throws -> T {
        var addr = address(selector, scope: scope, element: element)
        var size = UInt32(MemoryLayout<T>.size)
        var result = initial
        let status = AudioObjectGetPropertyData(objectID, &addr, qualifierSize, qualifier, &size, &result)
        guard status == noErr else { throw Error(status: status, what: "get \(fourCC(selector))") }
        return result
    }

    /// Reads a variable-length property into an array.
    static func array<T>(_ objectID: AudioObjectID,
                         _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                         of type: T.Type) throws -> [T] {
        var addr = address(selector, scope: scope, element: element)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size)
        guard status == noErr else { throw Error(status: status, what: "size \(fourCC(selector))") }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](unsafeUninitializedCapacity: count) { _, initialized in initialized = count }
        status = values.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { throw Error(status: status, what: "get \(fourCC(selector))") }
        return values
    }

    static func string(_ objectID: AudioObjectID,
                       _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> String {
        let cf: CFString = try value(objectID, selector, scope: scope, element: element,
                                     default: "" as CFString)
        return cf as String
    }

    static func fourCC(_ code: AudioObjectPropertySelector) -> String {
        let chars = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        guard chars.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "\(code)" }
        return String(decoding: chars, as: UTF8.self)
    }
}

extension AudioStreamBasicDescription {
    var summary: String {
        let interleaved = (mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let float = (mFormatFlags & kAudioFormatFlagIsFloat) != 0
        return "\(Int(mSampleRate)) Hz, \(mChannelsPerFrame) ch, "
            + "\(mBitsPerChannel)-bit \(float ? "float" : "int"), "
            + (interleaved ? "interleaved" : "non-interleaved")
            + ", \(mBytesPerFrame) bytes/frame"
    }
}
