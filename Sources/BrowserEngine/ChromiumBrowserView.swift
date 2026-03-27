import AppKit
import Combine
import Bonsplit
import QuartzCore

/// Displays Chromium content via CALayerHost.
/// Content Shell runs as a child process. Its compositor sends a
/// CAContext ID which we use to create a CALayerHost for zero-copy
/// display. No NSView reparenting, no separate visible window.
final class ChromiumBrowserView: NSView {

    private var pendingURL: String?
    private var launched = false
    private var contextFile: String?
    private var pollTimer: Timer?
    private var hostLayer: CALayer? // CALayerHost

    @Published private(set) var currentURL: String = ""
    @Published private(set) var currentTitle: String = ""
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        pollTimer?.invalidate()
        ChromiumProcess.shared.terminate()
        if let f = contextFile { try? FileManager.default.removeItem(atPath: f) }
    }

    func createBrowser(initialURL: String) {
        pendingURL = initialURL
        if bounds.width > 0, bounds.height > 0, window != nil {
            launchShell()
        }
    }

    private func launchShell() {
        guard !launched, let url = pendingURL else { return }
        launched = true

        ChromiumProcess.shared.ensureContentShell { [weak self] ok in
            guard let self, ok else { return }

            // Create temp file for context ID
            let tmpFile = "/tmp/cmux-ca-context-\(ProcessInfo.processInfo.processIdentifier).txt"
            self.contextFile = tmpFile

            // Launch Content Shell with hidden window and context file
            self.launchContentShell(url: url, contextFile: tmpFile)

            // Poll for the context ID
            self.startPolling()
        }
    }

    private func launchContentShell(url: String, contextFile: String) {
        guard let path = ChromiumProcess.shared.resolveContentShellPath() else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = [
            "--no-sandbox",
            "--content-shell-hide-toolbar",
            // Start offscreen (way off screen so user doesn't see the window)
            "--window-position=-10000,-10000",
            "--window-size=\(Int(bounds.width)),\(Int(bounds.height))",
            url,
        ]
        proc.environment = ProcessInfo.processInfo.environment
        proc.environment?["CMUX_CA_CONTEXT_FILE"] = contextFile

        do {
            try proc.run()
            ChromiumProcess.shared.process = proc
#if DEBUG
            dlog("chromium.launch pid=\(proc.processIdentifier) url=\(url)")
#endif
        } catch {
#if DEBUG
            dlog("chromium.launch failed: \(error)")
#endif
        }
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkContextFile()
        }
    }

    private func checkContextFile() {
        guard let file = contextFile,
              let data = try? String(contentsOfFile: file, encoding: .utf8),
              let contextId = UInt32(data.trimmingCharacters(in: .whitespacesAndNewlines)),
              contextId > 0 else { return }

        pollTimer?.invalidate()
        pollTimer = nil

#if DEBUG
        dlog("chromium.contextId=\(contextId)")
#endif

        // Create CALayerHost with the context ID
        attachCALayerHost(contextId: contextId)
    }

    private func attachCALayerHost(contextId: UInt32) {
        // CALayerHost is a private API. We access it dynamically.
        guard let layerHostClass = NSClassFromString("CALayerHost") as? CALayer.Type else {
#if DEBUG
            dlog("chromium.CALayerHost class not found")
#endif
            return
        }

        let host = layerHostClass.init()
        host.setValue(contextId, forKey: "contextId")
        host.frame = bounds
        host.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        layer?.addSublayer(host)
        hostLayer = host

#if DEBUG
        dlog("chromium.CALayerHost attached contextId=\(contextId)")
#endif
    }

    // MARK: - Navigation (send commands to Content Shell via AppleScript)

    func loadURL(_ s: String) {
        // Relaunch with new URL
        ChromiumProcess.shared.terminate()
        launched = false
        pendingURL = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.launchShell()
        }
    }

    func goBack() { sendKey(key: "[", modifiers: "command down") }
    func goForward() { sendKey(key: "]", modifiers: "command down") }
    func reload() { sendKey(key: "r", modifiers: "command down") }
    func stopLoading() { sendKey(key: ".", modifiers: "command down") }
    func showDevTools() { sendKey(key: "i", modifiers: "command down, option down") }

    private func sendKey(key: String, modifiers: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let script = """
            tell application "System Events"
                tell process "Content Shell"
                    keystroke "\(key)" using {\(modifiers)}
                end tell
            end tell
            """
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }

    func destroyBrowser() {
        pollTimer?.invalidate()
        hostLayer?.removeFromSuperlayer()
        hostLayer = nil
        ChromiumProcess.shared.terminate()
        if let f = contextFile { try? FileManager.default.removeItem(atPath: f) }
    }

    // MARK: - View lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, bounds.width > 0, bounds.height > 0, pendingURL != nil, !launched {
            launchShell()
        }
    }

    override func layout() {
        super.layout()
        if !launched, pendingURL != nil, bounds.width > 0, bounds.height > 0, window != nil {
            launchShell()
        }
        hostLayer?.frame = bounds
    }
}
