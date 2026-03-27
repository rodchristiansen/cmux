import AppKit
import Bonsplit

/// Manages a Content Shell child process for Chromium rendering.
/// The Content Shell window is positioned as a child of cmux's window,
/// overlaying the panel area. Content Shell handles all input natively.
final class ChromiumProcess {

    static let shared = ChromiumProcess()

    private var process: Process?
    private var contentShellPath: String?

    /// Resolve the Content Shell app path. Downloads from GitHub if not found.
    func resolveContentShellPath() -> String? {
        if let cached = contentShellPath { return cached }

        let candidates = [
            "\(NSHomeDirectory())/chromium/src/out/Release/Content Shell.app/Contents/MacOS/Content Shell",
            "\(contentShellDir)/Content Shell.app/Contents/MacOS/Content Shell",
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

    /// Directory for downloaded Content Shell
    var contentShellDir: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        return appSupport.appendingPathComponent(bundleID).appendingPathComponent("ContentShell").path
    }

    /// Download Content Shell from GitHub releases if not present.
    func ensureContentShell(completion: @escaping (Bool) -> Void) {
        if resolveContentShellPath() != nil {
            completion(true)
            return
        }

        let url = URL(string: "https://github.com/manaflow-ai/chromium/releases/download/v0.0.1/chromium-content-shell-arm64-macos.tar.gz")!
        let destDir = contentShellDir

#if DEBUG
        dlog("chromium.download: fetching Content Shell from \(url)")
#endif

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            guard let tempURL, error == nil else {
#if DEBUG
                DispatchQueue.main.async { dlog("chromium.download: failed \(error?.localizedDescription ?? "unknown")") }
#endif
                DispatchQueue.main.async { completion(false) }
                return
            }

            do {
                try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                proc.arguments = ["-xzf", tempURL.path, "-C", destDir]
                try proc.run()
                proc.waitUntilExit()

                DispatchQueue.main.async {
                    self?.contentShellPath = nil // reset cache
                    let found = self?.resolveContentShellPath() != nil
#if DEBUG
                    dlog("chromium.download: extract done, found=\(found)")
#endif
                    completion(found)
                }
            } catch {
#if DEBUG
                DispatchQueue.main.async { dlog("chromium.download: extract error \(error)") }
#endif
                DispatchQueue.main.async { completion(false) }
            }
        }
        task.resume()
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

