import AppKit
import Bonsplit

/// Manages a Content Shell child process for Chromium rendering.
/// The Content Shell window is positioned as a child of cmux's window,
/// overlaying the panel area. Content Shell handles all input natively.
final class ChromiumProcess {

    static let shared = ChromiumProcess()

    private var process: Process?
    private var contentShellPath: String?

    /// Resolve the Content Shell app path.
    func resolveContentShellPath() -> String? {
        if let cached = contentShellPath { return cached }

        // Check common locations
        let candidates = [
            "\(NSHomeDirectory())/chromium/src/out/Release/Content Shell.app/Contents/MacOS/Content Shell",
            Bundle.main.privateFrameworksPath.map { "\($0)/Content Shell.app/Contents/MacOS/Content Shell" },
            "/Applications/Content Shell.app/Contents/MacOS/Content Shell",
        ].compactMap { $0 }

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                contentShellPath = path
                return path
            }
        }
        return nil
    }

    /// Launch Content Shell with a URL. Returns the PID.
    @discardableResult
    func launch(url: String) -> Int32? {
        guard let path = resolveContentShellPath() else {
#if DEBUG
            dlog("chromium.launch: Content Shell not found")
#endif
            return nil
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = [
            "--no-sandbox",
            "--content-shell-hide-toolbar",
            url
        ]

        do {
            try proc.run()
            process = proc
#if DEBUG
            dlog("chromium.launch: pid=\(proc.processIdentifier) url=\(url)")
#endif
            return proc.processIdentifier
        } catch {
#if DEBUG
            dlog("chromium.launch: failed \(error)")
#endif
            return nil
        }
    }

    /// Kill the Content Shell process.
    func terminate() {
        process?.terminate()
        process = nil
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }
}

/// NSView that manages a Content Shell child window overlay.

