import AppKit
import Combine
import Bonsplit

/// Positions the Content Shell window over this view's area.
final class ChromiumBrowserView: NSView {

    private var shellPID: Int32?
    private var shellWindow: NSWindow?
    private var observations: [NSObjectProtocol] = []
    private var pendingURL: String?
    private var launched = false

    @Published private(set) var currentURL: String = ""
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false
    @Published private(set) var currentTitle: String = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        detachShellWindow()
        // Don't kill the process on deinit - it may be reused
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

        // Launch Content Shell
        shellPID = ChromiumProcess.shared.launch(url: url)

        // Wait for the Content Shell window to appear, then attach it
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.findAndAttachShellWindow()
        }
    }

    private func findAndAttachShellWindow() {
        // Find the Content Shell window by looking at NSApp's windows
        // (won't work - Content Shell is a separate process)
        // Instead, use CGWindowList to find it by PID
        guard let pid = shellPID else { return }

        let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == pid,
                  let windowNumber = windowInfo[kCGWindowNumber as String] as? Int else {
                continue
            }

            // Found the Content Shell window
            // Use NSWindow(windowRef:) or addChildWindow to attach it
#if DEBUG
            dlog("chromium.findWindow: found window \(windowNumber) for pid \(pid)")
#endif

            // Get the NSWindow reference for the Content Shell window
            // This requires the window to be in the same process - it's not.
            // For cross-process window management, we need to use
            // CGWindowListCreateImage for screenshots, or Accessibility API
            // for positioning. Or use AppleScript.

            positionShellWindow(windowNumber: windowNumber)
            startTrackingPosition()
            return
        }

#if DEBUG
        dlog("chromium.findWindow: no window found for pid \(pid), retrying...")
#endif
        // Retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.findAndAttachShellWindow()
        }
    }

    private func positionShellWindow(windowNumber: Int) {
        guard let parentWindow = self.window else { return }

        // Convert our bounds to screen coordinates
        let frameInWindow = convert(bounds, to: nil)
        let frameOnScreen = parentWindow.convertToScreen(frameInWindow)

        // Position the Content Shell window using AppleScript
        // (cross-process window positioning)
        let script = """
        tell application "System Events"
            tell process "Content Shell"
                set position of window 1 to {\(Int(frameOnScreen.origin.x)), \(Int(NSScreen.main!.frame.height - frameOnScreen.maxY))}
                set size of window 1 to {\(Int(frameOnScreen.width)), \(Int(frameOnScreen.height))}
            end tell
        end tell
        """

        DispatchQueue.global(qos: .userInitiated).async {
            let appleScript = NSAppleScript(source: script)
            var error: NSDictionary?
            appleScript?.executeAndReturnError(&error)
            if let error {
#if DEBUG
                DispatchQueue.main.async {
                    dlog("chromium.position: error \(error)")
                }
#endif
            }
        }
    }

    private func startTrackingPosition() {
        // Track our view's frame changes to reposition the shell window
        postsFrameChangedNotifications = true
        let obs = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: self, queue: .main
        ) { [weak self] _ in
            guard let self, let pid = self.shellPID else { return }
            // Re-find and reposition
            let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
            for info in windowList {
                if let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
                   ownerPID == pid,
                   let wn = info[kCGWindowNumber as String] as? Int {
                    self.positionShellWindow(windowNumber: wn)
                    break
                }
            }
        }
        observations.append(obs)

        // Also track parent window move
        if let parentWindow = window {
            let moveObs = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: parentWindow, queue: .main
            ) { [weak self] _ in
                guard let self, let pid = self.shellPID else { return }
                let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
                for info in windowList {
                    if let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
                       ownerPID == pid,
                       let wn = info[kCGWindowNumber as String] as? Int {
                        self.positionShellWindow(windowNumber: wn)
                        break
                    }
                }
            }
            observations.append(moveObs)
        }
    }

    private func detachShellWindow() {
        for obs in observations {
            NotificationCenter.default.removeObserver(obs)
        }
        observations.removeAll()
    }

    func destroyBrowser() {
        detachShellWindow()
        ChromiumProcess.shared.terminate()
        shellPID = nil
        launched = false
    }

    // Navigation via AppleScript (temporary until we add IPC)
    func loadURL(_ urlString: String) {
        // For now, just relaunch with new URL
        ChromiumProcess.shared.terminate()
        launched = false
        pendingURL = urlString
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.launchShell()
        }
    }

    func goBack() { sendKeyToShell(key: "[", modifiers: "command down") }
    func goForward() { sendKeyToShell(key: "]", modifiers: "command down") }
    func reload() { sendKeyToShell(key: "r", modifiers: "command down") }
    func stopLoading() { sendKeyToShell(key: ".", modifiers: "command down") }

    private func sendKeyToShell(key: String, modifiers: String) {
        let script = """
        tell application "System Events"
            tell process "Content Shell"
                keystroke "\(key)" using {\(modifiers)}
            end tell
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }

    func showDevTools() { sendKeyToShell(key: "i", modifiers: "command down, option down") }

    // View lifecycle
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
    }
}
