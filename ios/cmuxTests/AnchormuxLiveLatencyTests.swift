import Foundation
import XCTest
@testable import cmux_DEV

final class AnchormuxLiveLatencyTests: XCTestCase {
    func testDesktopAndIOSLatency() async throws {
        guard let config = LiveAnchormuxConfig.resolveForLiveTest() else {
            throw XCTSkip("Live Anchormux env not configured: \(LiveAnchormuxConfig.debugDescription())")
        }
        guard let readyToken = config.readyToken,
              let desktopToken = config.desktopToken else {
            throw XCTSkip("Live Anchormux tokens missing: \(LiveAnchormuxConfig.debugDescription())")
        }

        let eventWriter = AnchormuxLatencyEventWriter(path: ProcessInfo.processInfo.environment["CMUX_LIVE_ANCHORMUX_EVENT_PATH"])
        try eventWriter.append(name: "test_start")

        let transport = try await LatencyLiveSupport.connectClient(host: config.host, port: config.port)
        let client = TerminalRemoteDaemonClient(transport: transport)
        let hello = try await withTimeout("hello", seconds: 3) {
            try await client.sendHello()
        }
        XCTAssertEqual(hello.name, "cmuxd-remote")
        XCTAssertTrue(hello.capabilities.contains("terminal.stream"))

        let (surfaceView, delegate) = try await MainActor.run {
            let runtime = try GhosttyRuntime.shared()
            let delegate = AnchormuxLatencySurfaceDelegate()
            let surfaceView = GhosttySurfaceView(runtime: runtime, delegate: delegate)
            surfaceView.frame = CGRect(x: 0, y: 0, width: 640, height: 420)
            surfaceView.layoutIfNeeded()
            return (surfaceView, delegate)
        }
        let initialSize = try await MainActor.run {
            try XCTUnwrap(delegate.lastSize)
        }

        let sessionTransport = TerminalRemoteDaemonSessionTransport(
            client: client,
            command: "printf READY; stty raw -echo -onlcr; exec cat",
            preferredSessionID: config.sessionID,
            readTimeoutMilliseconds: 100
        )

        await MainActor.run {
            delegate.onInput = { data in
                Task {
                    try await sessionTransport.send(data)
                }
            }
        }

        let connectedExpectation = expectation(description: "connected")
        sessionTransport.eventHandler = { event in
            switch event {
            case .connected:
                connectedExpectation.fulfill()
            case .output(let data):
                Task { @MainActor in
                    surfaceView.processOutput(data)
                }
            default:
                break
            }
        }

        do {
            try await withTimeout("sessionTransport.connect", seconds: 5) {
                try await sessionTransport.connect(initialSize: initialSize)
            }
        } catch {
            await sessionTransport.disconnect()
            await MainActor.run {
                surfaceView.disposeSurface()
            }
            XCTFail("sessionTransport.connect failed: \(error)")
            return
        }

        await fulfillment(of: [connectedExpectation], timeout: 5.0)
        try eventWriter.append(name: "connected")

        _ = try await waitForRenderedText(
            in: surfaceView,
            containing: desktopToken,
            timeout: 30.0
        )
        try eventWriter.append(name: "desktop_seen_on_ios", token: desktopToken)

        try eventWriter.append(name: "ios_send", token: readyToken)
        await MainActor.run {
            surfaceView.simulateTextInputForTesting("echo \(readyToken)\n")
        }

        _ = try await waitForRenderedText(
            in: surfaceView,
            containing: readyToken,
            timeout: 15.0
        )
        try eventWriter.append(name: "ios_render", token: readyToken)

        await sessionTransport.disconnect()
        await MainActor.run {
            surfaceView.disposeSurface()
        }
        try eventWriter.append(name: "test_complete")
    }

    private func waitForRenderedText(
        in surfaceView: GhosttySurfaceView,
        containing needle: String,
        timeout: TimeInterval
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var lastText = ""

        while Date() < deadline {
            lastText = await MainActor.run {
                surfaceView.renderedTextForTesting() ?? ""
            }
            if lastText.contains(needle) {
                return lastText
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTFail("Timed out waiting for \(needle) in rendered text: \(lastText)")
        return lastText
    }

    private func withTimeout<T: Sendable>(
        _ name: String,
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw AnchormuxLatencyTestError.timeout(name)
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

private enum AnchormuxLatencyTestError: LocalizedError {
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let name):
            return "Timed out waiting for \(name)"
        }
    }
}

@MainActor
private final class AnchormuxLatencySurfaceDelegate: GhosttySurfaceViewDelegate {
    var lastSize: TerminalGridSize?
    var onInput: ((Data) -> Void)?

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {
        onInput?(data)
    }

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize) {
        lastSize = size
    }
}

private enum LatencyLiveSupport {
    static func connectClient(host: String, port: UInt16) async throws -> LiveTCPDaemonTransport {
        try await LiveTCPDaemonTransport.connect(
            host: host,
            port: port
        )
    }
}

private struct AnchormuxLatencyEvent: Encodable {
    let name: String
    let epochMs: Int64
    let token: String?

    enum CodingKeys: String, CodingKey {
        case name
        case epochMs = "epoch_ms"
        case token
    }
}

private final class AnchormuxLatencyEventWriter {
    private let path: String?
    private let encoder = JSONEncoder()

    init(path: String?) {
        self.path = path?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func append(name: String, token: String? = nil) throws {
        guard let path, !path.isEmpty else { return }
        let event = AnchormuxLatencyEvent(
            name: name,
            epochMs: Int64(Date().timeIntervalSince1970 * 1000),
            token: token
        )
        let data = try encoder.encode(event)
        let line = data + Data([0x0A])
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            return
        }
        try line.write(to: url, options: .atomic)
    }
}
