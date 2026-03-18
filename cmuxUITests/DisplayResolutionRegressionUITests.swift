import XCTest
import Foundation

final class DisplayResolutionRegressionUITests: XCTestCase {
    private let displayHarnessManifestPath = "/tmp/cmux-ui-test-display-harness.json"
    private var launchTag = ""
    private var socketPath = ""
    private var diagnosticsPath = ""
    private var displayReadyPath = ""
    private var displayIDPath = ""
    private var displayStartPath = ""
    private var displayDonePath = ""
    private var helperBinaryPath = ""
    private var helperLogPath = ""
    private var launchedApp: XCUIApplication?
    private var helperProcess: Process?
    private var socketClient: ControlSocketClient?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        let token = UUID().uuidString
        launchTag = "ui-tests-display-resolution-\(token.prefix(8))"
        socketPath = "/tmp/cmux-ui-test-display-churn-\(token).sock"
        diagnosticsPath = "/tmp/cmux-ui-test-display-churn-\(token).json"
        displayReadyPath = "/tmp/cmux-ui-test-display-ready-\(token)"
        displayIDPath = "/tmp/cmux-ui-test-display-id-\(token)"
        displayStartPath = "/tmp/cmux-ui-test-display-start-\(token)"
        displayDonePath = "/tmp/cmux-ui-test-display-done-\(token)"
        helperBinaryPath = "/tmp/cmux-ui-test-display-helper-\(token)"
        helperLogPath = "/tmp/cmux-ui-test-display-helper-\(token).log"

        removeTestArtifacts()
    }

    override func tearDown() {
        terminateLaunchedAppIfNeeded()
        helperProcess?.terminate()
        helperProcess?.waitUntilExit()
        helperProcess = nil
        socketClient = nil
        removeTestArtifacts()
        super.tearDown()
    }

    func testRapidDisplayResolutionChangesKeepTerminalResponsive() throws {
        try prepareDisplayHarnessIfNeeded()

        XCTAssertTrue(waitForFile(atPath: displayReadyPath, timeout: 12.0), "Expected display harness ready file at \(displayReadyPath)")
        guard let targetDisplayID = readTrimmedFile(atPath: displayIDPath), !targetDisplayID.isEmpty else {
            XCTFail("Missing target display ID at \(displayIDPath)")
            return
        }

        try launchAppProcess(targetDisplayID: targetDisplayID)
        guard let resolvedSocketPath = resolveSocketPath(timeout: 12.0) else {
            XCTFail(
                "Expected control socket to respond. requested=\(socketPath) tag=\(launchTag) " +
                "candidates=\(expectedSocketCandidates(includeFallback: true)) diagnostics=\(loadDiagnostics() ?? [:]) " +
                "app=\(launchedAppDiagnostics())"
            )
            return
        }
        socketPath = resolvedSocketPath
        XCTAssertTrue(waitForSocketPong(timeout: 4.0), "Expected control socket to respond at \(socketPath)")
        XCTAssertTrue(
            waitForTargetDisplayMove(targetDisplayID: targetDisplayID, timeout: 12.0),
            "Expected app window to move to display \(targetDisplayID). diagnostics=\(loadDiagnostics() ?? [:]) app=\(launchedAppDiagnostics())"
        )

        guard let baselineStats = waitForRenderStats(timeout: 8.0) else {
            XCTFail("Missing initial render_stats response")
            return
        }
        let baselinePresentCount = baselineStats.presentCount

        XCTAssertTrue(
            FileManager.default.createFile(atPath: displayStartPath, contents: Data("start\n".utf8)),
            "Expected start signal file to be created"
        )

        let deadline = Date().addingTimeInterval(30.0)
        var maxPresentCount = baselinePresentCount
        var lastStats = baselineStats
        var socketFailures = 0

        while Date() < deadline {
            if let stats = renderStats(responseTimeout: 2.0) {
                lastStats = stats
                maxPresentCount = max(maxPresentCount, stats.presentCount)
            } else {
                socketFailures += 1
            }

            let doneMarker = readTrimmedFile(atPath: displayDonePath)
            if doneMarker == "done" && maxPresentCount >= baselinePresentCount + 8 {
                break
            }
            if let doneMarker, doneMarker.hasPrefix("error:") {
                XCTFail("Display churn helper failed: \(doneMarker). log=\(readTrimmedFile(atPath: helperLogPath) ?? "<missing>")")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }

        XCTAssertEqual(readTrimmedFile(atPath: displayDonePath), "done", "Expected display churn to finish. helperLog=\(readTrimmedFile(atPath: helperLogPath) ?? "<missing>")")
        guard let finalStats = waitForRenderStats(timeout: 6.0) else {
            XCTFail("Expected render_stats after display churn. socketFailures=\(socketFailures)")
            return
        }

        maxPresentCount = max(maxPresentCount, finalStats.presentCount)
        XCTAssertGreaterThanOrEqual(
            maxPresentCount - baselinePresentCount,
            8,
            "Expected terminal presents to keep advancing during display churn. baseline=\(baselineStats) last=\(lastStats) final=\(finalStats)"
        )
        XCTAssertLessThanOrEqual(socketFailures, 8, "Too many socket timeouts while display modes changed")
    }

    private func prepareDisplayHarnessIfNeeded() throws {
        let env = ProcessInfo.processInfo.environment
        if let externalHarness = loadExternalHarnessFromEnvironment(env) ?? loadExternalHarnessFromManifest() {
            displayReadyPath = externalHarness.readyPath
            displayIDPath = externalHarness.displayIDPath
            displayStartPath = externalHarness.startPath
            displayDonePath = externalHarness.donePath
            if let logPath = externalHarness.logPath, !logPath.isEmpty {
                helperLogPath = logPath
            }
            return
        }

        try buildDisplayHelper()
        try launchDisplayHelper()
    }

    private func loadExternalHarnessFromEnvironment(_ env: [String: String]) -> ExternalDisplayHarness? {
        guard let readyPath = env["CMUX_UI_TEST_DISPLAY_READY_PATH"], !readyPath.isEmpty,
              let displayIDPath = env["CMUX_UI_TEST_DISPLAY_ID_PATH"], !displayIDPath.isEmpty,
              let startPath = env["CMUX_UI_TEST_DISPLAY_START_PATH"], !startPath.isEmpty,
              let donePath = env["CMUX_UI_TEST_DISPLAY_DONE_PATH"], !donePath.isEmpty else {
            return nil
        }

        return ExternalDisplayHarness(
            readyPath: readyPath,
            displayIDPath: displayIDPath,
            startPath: startPath,
            donePath: donePath,
            logPath: env["CMUX_UI_TEST_DISPLAY_LOG_PATH"]
        )
    }

    private func loadExternalHarnessFromManifest() -> ExternalDisplayHarness? {
        let manifestURL = URL(fileURLWithPath: displayHarnessManifestPath)
        guard let data = try? Data(contentsOf: manifestURL) else {
            return nil
        }
        return try? JSONDecoder().decode(ExternalDisplayHarness.self, from: data)
    }

    private func buildDisplayHelper() throws {
        let sourceURL = repoRootURL.appendingPathComponent("scripts/create-virtual-display.m")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        proc.arguments = [
            "-framework", "Foundation",
            "-framework", "CoreGraphics",
            "-o", helperBinaryPath,
            sourceURL.path,
        ]

        let stderrPipe = Pipe()
        proc.standardError = stderrPipe

        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "DisplayResolutionRegressionUITests", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "Failed to build display helper: \(stderr)"
            ])
        }
    }

    private func launchDisplayHelper() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: helperBinaryPath)
        proc.arguments = [
            "--modes", "1920x1080,1728x1117,1600x900,1440x810",
            "--ready-path", displayReadyPath,
            "--display-id-path", displayIDPath,
            "--start-path", displayStartPath,
            "--done-path", displayDonePath,
            "--iterations", "40",
            "--interval-ms", "40",
        ]

        let logHandle = FileHandle(forWritingAtPath: helperLogPath) ?? {
            FileManager.default.createFile(atPath: helperLogPath, contents: nil)
            return FileHandle(forWritingAtPath: helperLogPath)
        }()
        proc.standardOutput = logHandle
        proc.standardError = logHandle

        try proc.run()
        helperProcess = proc
    }

    private func launchAppProcess(targetDisplayID: String) throws {
        let app = XCUIApplication()
        app.launchArguments += ["-socketControlMode", "allowAll"]
        for (key, value) in launchEnvironment(targetDisplayID: targetDisplayID) {
            app.launchEnvironment[key] = value
        }
        app.launch()
        guard ensureForegroundAfterLaunch(app, timeout: 12.0) else {
            throw NSError(domain: "DisplayResolutionRegressionUITests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "XCUIApplication failed to reach foreground. state=\(app.state.rawValue)"
            ])
        }
        launchedApp = app
    }

    private func launchEnvironment(targetDisplayID: String) -> [String: String] {
        [
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_SOCKET_MODE": "allowAll",
            "CMUX_SOCKET_ENABLE": "1",
            "CMUX_UI_TEST_MODE": "1",
            "CMUX_UI_TEST_SOCKET_SANITY": "1",
            "CMUX_UI_TEST_DIAGNOSTICS_PATH": diagnosticsPath,
            "CMUX_UI_TEST_TARGET_DISPLAY_ID": targetDisplayID,
            "CMUX_TAG": launchTag,
        ]
    }

    private func terminateLaunchedAppIfNeeded() {
        guard let launchedApp else { return }
        defer { self.launchedApp = nil }

        if launchedApp.state == .notRunning {
            return
        }

        launchedApp.terminate()
        _ = launchedApp.wait(for: .notRunning, timeout: 5.0)
    }

    private func launchedAppDiagnostics() -> String {
        guard let launchedApp else { return "not-launched" }
        return "state=\(launchedApp.state.rawValue)"
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }

    private func waitForTargetDisplayMove(targetDisplayID: String, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let diagnostics = self.loadDiagnostics() else { return false }
            return diagnostics["targetDisplayMoveSucceeded"] == "1" &&
                diagnostics["windowScreenDisplayIDs"]?.contains(targetDisplayID) == true
        }
    }

    private func resolveSocketPath(timeout: TimeInterval) -> String? {
        if let diagnostics = loadDiagnostics(),
           diagnostics["socketReady"] == "1",
           let diagnosticsPath = diagnostics["socketExpectedPath"],
           !diagnosticsPath.isEmpty {
            return diagnosticsPath
        }

        let primaryCandidates = expectedSocketCandidates(includeFallback: false)
        let fallbackCandidates = expectedSocketCandidates(includeFallback: true)
            .filter { !primaryCandidates.contains($0) }

        var resolvedPath: String?
        _ = waitForCondition(timeout: timeout) {
            for candidate in primaryCandidates {
                if self.socketRespondsToPing(at: candidate) {
                    resolvedPath = candidate
                    return true
                }
            }
            for candidate in fallbackCandidates {
                if self.socketRespondsToPing(at: candidate) {
                    resolvedPath = candidate
                    return true
                }
            }
            return false
        }

        return resolvedPath
    }

    private func expectedSocketCandidates(includeFallback: Bool) -> [String] {
        var candidates = [socketPath]
        let sanitizedTag = sanitizeTagSlug(launchTag)
        if !sanitizedTag.isEmpty {
            candidates.append("/tmp/cmux-debug-\(sanitizedTag).sock")
            candidates.append("/tmp/cmux-\(sanitizedTag).sock")
        }

        if includeFallback {
            candidates.append(contentsOf: lastSocketPathCandidates())
            candidates.append(contentsOf: discoverTmpSocketCandidates(limit: 12))
            candidates.append("/tmp/cmux-debug.sock")
            candidates.append(stableSocketPath())
            candidates.append("/tmp/cmux.sock")
        }

        var unique: [String] = []
        var seen = Set<String>()
        for candidate in candidates where !candidate.isEmpty {
            if seen.insert(candidate).inserted {
                unique.append(candidate)
            }
        }
        return unique
    }

    private func sanitizeTagSlug(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }

        let pieces = trimmed
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let slug = pieces.joined(separator: "-")
        return slug.isEmpty ? "agent" : slug
    }

    private func lastSocketPathCandidates() -> [String] {
        [
            readTrimmedFile(atPath: stableSocketDirectory().appendingPathComponent("last-socket-path").path),
            readTrimmedFile(atPath: "/tmp/cmux-last-socket-path"),
        ]
        .compactMap { $0 }
    }

    private func stableSocketPath() -> String {
        stableSocketDirectory()
            .appendingPathComponent("cmux.sock")
            .path
    }

    private func stableSocketDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("cmux", isDirectory: true)
            ?? URL(fileURLWithPath: "/tmp")
    }

    private func discoverTmpSocketCandidates(limit: Int) -> [String] {
        let tmpPath = "/tmp"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: tmpPath) else {
            return []
        }

        let matches = entries.filter { $0.hasPrefix("cmux") && $0.hasSuffix(".sock") }
        let sorted = matches.compactMap { entry -> (path: String, mtime: Date)? in
            let fullPath = (tmpPath as NSString).appendingPathComponent(entry)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath) else {
                return nil
            }
            let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
            return (fullPath, mtime)
        }
        .sorted { $0.mtime > $1.mtime }

        return Array(sorted.prefix(limit)).map(\.path)
    }

    private func socketRespondsToPing(at path: String) -> Bool {
        let originalPath = socketPath
        let originalClient = socketClient
        socketPath = path
        socketClient = ControlSocketClient(path: path)
        defer {
            socketPath = originalPath
            socketClient = originalClient
        }
        return socketCommand("ping", responseTimeout: 2.0) == "PONG"
    }

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            self.socketCommand("ping", responseTimeout: 2.0) == "PONG"
        }
    }

    private func waitForRenderStats(timeout: TimeInterval) -> RenderStats? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let stats = renderStats(responseTimeout: 2.0) {
                return stats
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return nil
    }

    private func renderStats(responseTimeout: TimeInterval) -> RenderStats? {
        guard let response = socketCommand("render_stats", responseTimeout: responseTimeout),
              response.hasPrefix("OK ") else {
            return nil
        }

        let json = String(response.dropFirst(3))
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RenderStats.self, from: data)
    }

    private func socketCommand(_ command: String, responseTimeout: TimeInterval) -> String? {
        if socketClient?.path != socketPath {
            socketClient = ControlSocketClient(path: socketPath)
        }
        if let response = socketClient?.sendLine(command, timeout: responseTimeout) {
            return response
        }
        return socketCommandViaNetcat(command, responseTimeout: responseTimeout)
    }

    private func loadDiagnostics() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
    }

    private func waitForCondition(timeout: TimeInterval, pollInterval: TimeInterval = 0.15, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }

    private func waitForFile(atPath path: String, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            FileManager.default.fileExists(atPath: path)
        }
    }

    private func readTrimmedFile(atPath path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var repoRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func removeTestArtifacts() {
        for path in [
            socketPath,
            diagnosticsPath,
            displayReadyPath,
            displayIDPath,
            displayStartPath,
            displayDonePath,
            helperBinaryPath,
            helperLogPath,
        ] {
            guard !path.isEmpty else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func socketCommandViaNetcat(_ command: String, responseTimeout: TimeInterval) -> String? {
        let nc = "/usr/bin/nc"
        guard FileManager.default.isExecutableFile(atPath: nc) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nc)
        proc.arguments = ["-U", socketPath, "-w", String(max(1, Int(ceil(responseTimeout))))]

        let inPipe = Pipe()
        let outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = Pipe()

        do {
            try proc.run()
        } catch {
            return nil
        }

        if let data = (command + "\n").data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        inPipe.fileHandleForWriting.closeFile()

        proc.waitUntilExit()

        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if let firstLine = output.split(separator: "\n", maxSplits: 1).first {
            let trimmed = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private struct RenderStats: Decodable, CustomStringConvertible {
        let drawCount: Int
        let presentCount: Int
        let lastPresentTime: Double
        let inWindow: Bool
        let windowIsKey: Bool
        let windowOcclusionVisible: Bool

        var description: String {
            "draw=\(drawCount) present=\(presentCount) lastPresent=\(String(format: "%.3f", lastPresentTime)) inWindow=\(inWindow) key=\(windowIsKey) visible=\(windowOcclusionVisible)"
        }
    }

    private struct ExternalDisplayHarness: Decodable {
        let readyPath: String
        let displayIDPath: String
        let startPath: String
        let donePath: String
        let logPath: String?
    }

    private final class ControlSocketClient {
        let path: String

        init(path: String) {
            self.path = path
        }

        func sendLine(_ line: String, timeout: TimeInterval) -> String? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var socketTimeout = makeSocketTimeout(timeout)
            _ = withUnsafePointer(to: &socketTimeout) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_RCVTIMEO,
                    ptr,
                    socklen_t(MemoryLayout<timeval>.size)
                )
            }
            _ = withUnsafePointer(to: &socketTimeout) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_SNDTIMEO,
                    ptr,
                    socklen_t(MemoryLayout<timeval>.size)
                )
            }

#if os(macOS)
            var noSigPipe: Int32 = 1
            _ = withUnsafePointer(to: &noSigPipe) { ptr in
                setsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    ptr,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
#endif

            var addr = sockaddr_un()
            memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
            addr.sun_family = sa_family_t(AF_UNIX)

            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= maxLen else { return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let destination = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                memset(destination, 0, maxLen)
                for index in 0..<bytes.count {
                    destination[index] = bytes[index]
                }
            }

            let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            let addrLen = socklen_t(pathOffset + bytes.count)
#if os(macOS)
            addr.sun_len = UInt8(min(Int(addrLen), 255))
#endif

            let connectResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    connect(fd, sockaddrPtr, addrLen)
                }
            }
            guard connectResult == 0 else { return nil }

            let payload = line + "\n"
            let wrotePayload: Bool = payload.withCString { cString in
                var remaining = strlen(cString)
                var pointer = UnsafeRawPointer(cString)
                while remaining > 0 {
                    let written = write(fd, pointer, remaining)
                    if written <= 0 { return false }
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                }
                return true
            }
            guard wrotePayload else { return nil }

            var buffer = [UInt8](repeating: 0, count: 4096)
            var accumulated = ""
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                if let chunk = String(bytes: buffer[0..<count], encoding: .utf8) {
                    accumulated.append(chunk)
                    if let newline = accumulated.firstIndex(of: "\n") {
                        return String(accumulated[..<newline])
                    }
                }
            }
            let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private func makeSocketTimeout(_ timeout: TimeInterval) -> timeval {
            let normalizedTimeout = max(timeout, 0)
            let seconds = floor(normalizedTimeout)
            let microseconds = (normalizedTimeout - seconds) * 1_000_000
            return timeval(tv_sec: Int(seconds), tv_usec: Int32(microseconds.rounded()))
        }
    }
}
