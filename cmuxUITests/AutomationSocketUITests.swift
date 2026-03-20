import XCTest
import Foundation

final class AutomationSocketUITests: XCTestCase {
    private struct CmuxCommandResult {
        let terminationStatus: Int32
        let stdout: String
        let stderr: String
    }

    private var socketPath = ""
    private var diagnosticsPath = ""
    private var ensureTerminalSurfaceFailure = ""
    private let defaultsDomain = "com.cmuxterm.app.debug"
    private let modeKey = "socketControlMode"
    private let legacyKey = "socketControlEnabled"
    private let launchTag = "ui-tests-automation-socket"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-debug-\(UUID().uuidString).sock"
        diagnosticsPath = "/tmp/cmux-ui-test-diagnostics-\(UUID().uuidString).json"
        ensureTerminalSurfaceFailure = ""
        resetSocketDefaults()
        removeSocketFile()
        try? FileManager.default.removeItem(atPath: diagnosticsPath)
    }

    func testSocketToggleDisablesAndEnables() {
        let app = configuredApp(mode: "cmuxOnly")
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for socket toggle test. state=\(app.state.rawValue)"
        )

        guard let resolvedPath = resolveSocketPath(timeout: 5.0) else {
            XCTFail("Expected control socket to exist. diagnostics=\(loadDiagnostics() ?? [:])")
            return
        }
        socketPath = resolvedPath
        XCTAssertTrue(waitForSocket(exists: true, timeout: 2.0))
        app.terminate()
    }

    func testSocketDisabledWhenSettingOff() {
        let app = configuredApp(mode: "off")
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for socket off test. state=\(app.state.rawValue)"
        )

        XCTAssertTrue(waitForSocket(exists: false, timeout: 3.0))
        app.terminate()
    }

    func testSurfaceListStillRespondsAfterRepeatedSendKey() {
        let app = configuredApp(mode: "automation")
        app.launch()
        defer {
            if app.state != .notRunning {
                app.terminate()
            }
        }

        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for repeated send-key socket test. state=\(app.state.rawValue)"
        )

        guard let resolvedPath = resolveSocketPath(timeout: 5.0) else {
            XCTFail(
                "Expected control socket to exist for repeated send-key socket test. " +
                "diagnostics=\(loadDiagnostics() ?? [:])"
            )
            return
        }
        socketPath = resolvedPath

        guard let target = ensureTerminalSurface(timeout: 10.0) else {
            XCTFail(
                "Expected a terminal surface before repeated send-key socket test. " +
                "socket=\(socketPath) diagnostics=\(loadDiagnostics() ?? [:]) " +
                "trace=\(ensureTerminalSurfaceFailure)"
            )
            return
        }

        for iteration in 1...8 {
            XCTAssertEqual(
                runCmuxCommand(arguments: ["ping"], responseTimeoutSeconds: 1.5).stdout,
                "PONG",
                "Expected ping before send_key on iteration \(iteration)"
            )

            XCTAssertNotNil(
                runCmuxJSON(
                    arguments: [
                        "--window",
                        target.windowId,
                        "send-key",
                        "--workspace",
                        target.workspaceId,
                        "--surface",
                        target.surfaceId,
                        "enter",
                    ],
                    responseTimeoutSeconds: 4.0
                )?.payload,
                "Expected surface.send_key to succeed on iteration \(iteration)"
            )

            XCTAssertEqual(
                runCmuxCommand(arguments: ["ping"], responseTimeoutSeconds: 1.5).stdout,
                "PONG",
                "Expected ping after send_key on iteration \(iteration)"
            )

            guard let payload = runCmuxJSON(
                arguments: [
                    "--window",
                    target.windowId,
                    "list-panels",
                    "--workspace",
                    target.workspaceId,
                ],
                responseTimeoutSeconds: 4.0
            )?.payload,
                  let surfaces = payload["surfaces"] as? [[String: Any]] else {
                XCTFail("Expected surface.list to respond after send_key on iteration \(iteration)")
                return
            }

            XCTAssertFalse(
                surfaces.isEmpty,
                "Expected surface.list to keep returning surfaces after send_key on iteration \(iteration)"
            )
        }
    }

    private func configuredApp(mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-\(modeKey)", mode]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        // Debug launches require a tag outside reload.sh; provide one in UITests so CI
        // does not fail with "Application ... does not have a process ID".
        app.launchEnvironment["CMUX_TAG"] = launchTag
        return app
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        // On busy UI runners the app can launch backgrounded; activate once before failing.
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }

    private func waitForCondition(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                predicate()
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForSocket(exists: Bool, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: self.socketPath) == exists
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func resolveSocketPath(timeout: TimeInterval) -> String? {
        guard waitForSocket(exists: true, timeout: timeout) else {
            return nil
        }
        return socketPath
    }

    private func ensureTerminalSurface(timeout: TimeInterval) -> (windowId: String, workspaceId: String, surfaceId: String)? {
        ensureTerminalSurfaceFailure = ""
        let windowsResult = runCmuxJSON(arguments: ["list-windows"], responseTimeoutSeconds: 4.0)
        let initialWindowId = resolvedWindowId(from: windowsResult?.payload)
        var traceParts: [String] = [
            "list-windows=\(describeCommandResult(windowsResult))",
            "list-workspaces.initial=\(describeCommandResult(workspaceList(windowId: initialWindowId)))",
            "list-panels.initial=\(describeCommandResult(panelList(windowId: initialWindowId, workspaceId: nil)))",
        ]
        guard let initialWindowId else {
            ensureTerminalSurfaceFailure = traceParts.joined(separator: " | ")
            return nil
        }

        if let target = terminalSurface(windowId: initialWindowId) {
            ensureTerminalSurfaceFailure = traceParts.joined(separator: " | ")
            return (windowId: initialWindowId, workspaceId: target.workspaceId, surfaceId: target.surfaceId)
        }

        let workspaceCreateResult = runCmuxJSON(
            arguments: [
                "--window",
                initialWindowId,
                "new-workspace",
            ],
            responseTimeoutSeconds: 4.0
        )
        traceParts.append("new-workspace=\(describeCommandResult(workspaceCreateResult))")
        guard let workspacePayload = workspaceCreateResult?.payload,
              let workspaceId = workspacePayload["workspace_id"] as? String else {
            ensureTerminalSurfaceFailure = traceParts.joined(separator: " | ")
            return nil
        }
        let workspaceSelectResult = runCmuxJSON(
            arguments: [
                "--window",
                initialWindowId,
                "select-workspace",
                "--workspace",
                workspaceId,
            ],
            responseTimeoutSeconds: 4.0
        )
        traceParts.append("select-workspace=\(describeCommandResult(workspaceSelectResult))")

        let ready = waitForCondition(timeout: timeout) {
            self.terminalSurface(windowId: initialWindowId, workspaceId: workspaceId) != nil
        }
        traceParts.append(
            "list-workspaces.created=\(describeCommandResult(self.workspaceList(windowId: initialWindowId)))"
        )
        traceParts.append(
            "list-panels.created=\(describeCommandResult(self.panelList(windowId: initialWindowId, workspaceId: workspaceId)))"
        )
        ensureTerminalSurfaceFailure = traceParts.joined(separator: " | ")
        guard ready else { return nil }
        guard let target = terminalSurface(windowId: initialWindowId, workspaceId: workspaceId) else {
            return nil
        }
        return (windowId: initialWindowId, workspaceId: target.workspaceId, surfaceId: target.surfaceId)
    }

    private func terminalSurface(
        windowId: String? = nil,
        workspaceId: String? = nil
    ) -> (workspaceId: String, surfaceId: String)? {
        guard let payload = panelList(windowId: windowId, workspaceId: workspaceId)?.payload,
              let resolvedWorkspaceId = payload["workspace_id"] as? String,
              let surfaces = payload["surfaces"] as? [[String: Any]],
              let surface = surfaces.first(where: { surface in
                  guard let surfaceId = surface["id"] as? String, !surfaceId.isEmpty else {
                      return false
                  }
                  let type = surface["type"] as? String
                  return type == nil || type == "terminal"
              }),
              let surfaceId = surface["id"] as? String else {
            return nil
        }
        return (workspaceId: resolvedWorkspaceId, surfaceId: surfaceId)
    }

    private func resolvedWindowId(from payload: [String: Any]?) -> String? {
        guard let windows = payload?["windows"] as? [[String: Any]], !windows.isEmpty else {
            return nil
        }
        let preferred = windows.first(where: { ($0["key"] as? Bool) == true }) ??
            windows.first(where: { ($0["visible"] as? Bool) == true }) ??
            windows.first
        guard let windowId = preferred?["id"] as? String, !windowId.isEmpty else {
            return nil
        }
        return windowId
    }

    private func workspaceList(windowId: String?) -> (command: CmuxCommandResult, payload: [String: Any]?)? {
        guard let windowId, !windowId.isEmpty else { return nil }
        return runCmuxJSON(
            arguments: [
                "--window",
                windowId,
                "list-workspaces",
            ],
            responseTimeoutSeconds: 4.0
        )
    }

    private func panelList(
        windowId: String?,
        workspaceId: String?
    ) -> (command: CmuxCommandResult, payload: [String: Any]?)? {
        guard let windowId, !windowId.isEmpty else { return nil }
        var arguments = [
            "--window",
            windowId,
            "list-panels",
        ]
        if let workspaceId, !workspaceId.isEmpty {
            arguments.append(contentsOf: ["--workspace", workspaceId])
        }
        return runCmuxJSON(arguments: arguments, responseTimeoutSeconds: 4.0)
    }

    private func runCmuxJSON(
        arguments: [String],
        responseTimeoutSeconds: Double = 3.0
    ) -> (command: CmuxCommandResult, payload: [String: Any]?)? {
        let command = runCmuxCommand(
            arguments: ["--json", "--id-format", "uuids"] + arguments,
            responseTimeoutSeconds: responseTimeoutSeconds
        )
        let raw = command.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return (command: command, payload: nil)
        }
        guard let data = raw.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (command: command, payload: nil)
        }
        return (command: command, payload: payload)
    }

    private func runCmuxCommand(
        arguments: [String],
        responseTimeoutSeconds: Double = 3.0
    ) -> CmuxCommandResult {
        var args = ["--socket", socketPath]
        args.append(contentsOf: arguments)

        var environment = ProcessInfo.processInfo.environment
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = String(responseTimeoutSeconds)

        let cliPaths = resolveCmuxCLIPaths()
        if cliPaths.isEmpty {
            return CmuxCommandResult(
                terminationStatus: -1,
                stdout: "",
                stderr: "Failed to locate bundled cmux CLI"
            )
        }

        var lastPermissionFailure: CmuxCommandResult?
        for cliPath in cliPaths {
            let result = executeCmuxCommand(
                executablePath: cliPath,
                arguments: args,
                environment: environment
            )
            if result.terminationStatus == 0 {
                return result
            }
            if isSocketPermissionFailure(result.stderr) {
                lastPermissionFailure = result
                continue
            }
            return result
        }

        return lastPermissionFailure ?? CmuxCommandResult(
            terminationStatus: -1,
            stdout: "",
            stderr: "Bundled cmux CLI command failed without an executable path"
        )
    }

    private func describeCommandResult(_ result: (command: CmuxCommandResult, payload: [String: Any]?)?) -> String {
        guard let result else { return "<nil>" }
        let stdout = result.command.stdout.isEmpty ? "<empty>" : result.command.stdout
        let stderr = result.command.stderr.isEmpty ? "<empty>" : result.command.stderr
        return "status=\(result.command.terminationStatus) stdout=\(stdout) stderr=\(stderr)"
    }

    private func resolveCmuxCLIPaths() -> [String] {
        let fileManager = FileManager.default
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        var productDirectories: [String] = []

        for key in ["CMUX_UI_TEST_CLI_PATH", "CMUXTERM_CLI"] {
            if let value = env[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                candidates.append(value)
            }
        }

        if let builtProductsDir = env["BUILT_PRODUCTS_DIR"], !builtProductsDir.isEmpty {
            productDirectories.append(builtProductsDir)
        }

        if let hostPath = env["TEST_HOST"], !hostPath.isEmpty {
            let hostURL = URL(fileURLWithPath: hostPath)
            let productsDir = hostURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
            productDirectories.append(productsDir)
        }

        productDirectories.append(contentsOf: inferredBuildProductsDirectories())
        for productsDir in uniquePaths(productDirectories) {
            appendCLIPathCandidates(fromProductsDirectory: productsDir, to: &candidates)
        }

        candidates.append("/tmp/cmux-\(launchTag)/Build/Products/Debug/cmux DEV.app/Contents/Resources/bin/cmux")
        candidates.append("/tmp/cmux-\(launchTag)/Build/Products/Debug/cmux.app/Contents/Resources/bin/cmux")

        var resolvedPaths: [String] = []
        for path in uniquePaths(candidates) {
            guard fileManager.isExecutableFile(atPath: path) else { continue }
            resolvedPaths.append(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        }
        return uniquePaths(resolvedPaths)
    }

    private func inferredBuildProductsDirectories() -> [String] {
        let bundleURLs = [
            Bundle.main.bundleURL,
            Bundle(for: Self.self).bundleURL,
        ]

        return bundleURLs.compactMap { bundleURL in
            let standardizedPath = bundleURL.standardizedFileURL.path
            let components = standardizedPath.split(separator: "/")
            guard let productsIndex = components.firstIndex(of: "Products"),
                  productsIndex + 1 < components.count else {
                return nil
            }
            let prefixComponents = components.prefix(productsIndex + 2)
            return "/" + prefixComponents.joined(separator: "/")
        }
    }

    private func appendCLIPathCandidates(fromProductsDirectory productsDir: String, to candidates: inout [String]) {
        candidates.append("\(productsDir)/cmux DEV.app/Contents/Resources/bin/cmux")
        candidates.append("\(productsDir)/cmux.app/Contents/Resources/bin/cmux")

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: productsDir) else {
            return
        }

        for entry in entries.sorted() where entry.hasSuffix(".app") {
            let cliPath = URL(fileURLWithPath: productsDir)
                .appendingPathComponent(entry)
                .appendingPathComponent("Contents/Resources/bin/cmux")
                .path
            candidates.append(cliPath)
        }
    }

    private func executeCmuxCommand(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) -> CmuxCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CmuxCommandResult(
                terminationStatus: -1,
                stdout: "",
                stderr: "Failed to run cmux command: \(error.localizedDescription) (cliPath=\(executablePath))"
            )
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawStderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = rawStderr.isEmpty ? "" : "\(rawStderr) (cliPath=\(executablePath))"
        return CmuxCommandResult(
            terminationStatus: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    private func isSocketPermissionFailure(_ stderr: String?) -> Bool {
        guard let stderr, !stderr.isEmpty else { return false }
        return stderr.localizedCaseInsensitiveContains("failed to connect to socket") &&
            stderr.localizedCaseInsensitiveContains("operation not permitted")
    }

    private func uniquePaths(_ paths: [String]) -> [String] {
        var unique: [String] = []
        var seen = Set<String>()
        for path in paths {
            if seen.insert(path).inserted {
                unique.append(path)
            }
        }
        return unique
    }

    private func resetSocketDefaults() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["delete", defaultsDomain, modeKey]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
        let legacy = Process()
        legacy.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        legacy.arguments = ["delete", defaultsDomain, legacyKey]
        do {
            try legacy.run()
            legacy.waitUntilExit()
        } catch {
            return
        }
    }

    private func removeSocketFile() {
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func loadDiagnostics() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return object
    }
}
