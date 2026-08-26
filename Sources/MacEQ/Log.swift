import Foundation

/// Logs to stdout and to /tmp/maceq.log, since the app is normally launched
/// via `open` (no terminal attached) so TCC attributes the audio-capture
/// grant to MacEQ rather than to the shell.
/// Never call from the audio IO thread.
enum Log {
    private static let handle: FileHandle? = {
        let path = "/tmp/maceq.log"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
        _ = try? h?.seekToEnd()
        return h
    }()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let line = "[\(stamp.string(from: Date()))] \(message)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        handle?.write(Data(line.utf8))
    }
}
