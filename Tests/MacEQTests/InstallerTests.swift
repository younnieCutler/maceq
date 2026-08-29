import XCTest

final class InstallerTests: XCTestCase {
    func testInstallerCreatesMissingDesktopShortcut() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        try fixture.installFakeApp()

        let result = try fixture.runInstaller()
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.desktop.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.shortcut.path),
                       fixture.destination.path)
    }

    func testInstallerRefusesToDeleteNonAppDestination() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        try fixture.installFakeApp()

        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        let sentinel = fixture.destination.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)

        let result = try fixture.runInstaller()
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }
}

private final class InstallerFixture {
    let root: URL
    let home: URL
    let desktop: URL
    let shortcut: URL
    let destination: URL
    private let script: URL
    private let bin: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("maceq-installer-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        desktop = home.appendingPathComponent("Desktop")
        shortcut = desktop.appendingPathComponent("MacEQ.app")
        destination = home.appendingPathComponent("Applications/MacEQ.app")
        script = root.appendingPathComponent("Install MacEQ.command")
        bin = root.appendingPathComponent("bin")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try FileManager.default.copyItem(at: repoRoot.appendingPathComponent("scripts/install.command"),
                                         to: script)

        let openStub = bin.appendingPathComponent("open")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: openStub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: openStub.path)
    }

    func installFakeApp() throws {
        let app = root.appendingPathComponent("MacEQ.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
        """
        try Data(plist.utf8).write(to: app.appendingPathComponent("Info.plist"))
    }

    func runInstaller() throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["PATH"] = "\(bin.path):\(environment["PATH"] ?? "")"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
