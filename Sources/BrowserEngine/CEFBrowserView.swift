import AppKit
import Combine
import IOSurface
import Bonsplit

/// Orchestrates a CEF browser in OSR mode.
/// Contains a CEFSurfaceView for rendering and forwards input events to CEF.
final class CEFBrowserView: NSView, CEFSurfaceInputDelegate {

    private let surfaceView: CEFSurfaceView
    private var browserHandle: cef_bridge_browser_t?
    private var callbacksStorage: cef_bridge_client_callbacks?

    private var pendingURL: String?
    private var browserCreationAttempted = false

    @Published private(set) var currentURL: String = ""
    @Published private(set) var currentTitle: String = ""
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false

    override init(frame: NSRect) {
        surfaceView = CEFSurfaceView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(frame: frame)
        wantsLayer = true
        addSubview(surfaceView)
        surfaceView.autoresizingMask = [.width, .height]
        surfaceView.inputDelegate = self

        surfaceView.onViewSizeChanged = { [weak self] _ in
            guard let self, let h = self.browserHandle else { return }
            cef_bridge_browser_notify_resized(h)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { destroyBrowser() }

    // MARK: - Browser Lifecycle

    func createBrowser(initialURL: String) {
        guard CEFRuntime.shared.isInitialized else { return }
        guard browserHandle == nil, !browserCreationAttempted else { return }
        pendingURL = initialURL
        if bounds.width > 0, bounds.height > 0, window != nil {
            createBrowserNow()
        }
    }

    private func createBrowserNow() {
        guard pendingURL != nil, !browserCreationAttempted else { return }
        browserCreationAttempted = true
#if DEBUG
        dlog("cef.osr.createBrowserNow bounds=\(bounds)")
#endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.createBrowserImmediate()
        }
    }

    private func createBrowserImmediate() {
        guard let url = pendingURL else { return }

        var callbacks = cef_bridge_client_callbacks()
        // Use passRetained to prevent deallocation while CEF holds callbacks.
        // Released in destroyBrowser().
        let ud = Unmanaged.passRetained(self).toOpaque()
        callbacks.user_data = ud

        // --- OSR rendering callbacks ---
        callbacks.on_accelerated_paint = { _, ioSurfacePtr, _, _, ud in
            guard let ud, let ioSurfacePtr else { return }
            let view = Unmanaged<CEFBrowserView>.fromOpaque(ud).takeUnretainedValue()
            guard view.browserHandle != nil else { return }
            let surface = unsafeBitCast(ioSurfacePtr, to: IOSurfaceRef.self)
            view.surfaceView.updateIOSurface(surface)
        }
        callbacks.on_paint = { _, buffer, width, height, ud in
            guard let ud, let buffer else { return }
            let view = Unmanaged<CEFBrowserView>.fromOpaque(ud).takeUnretainedValue()
            view.surfaceView.updateBitmap(buffer, width: Int(width), height: Int(height))
        }
        callbacks.on_get_view_rect = { _, w, h, ud in
            guard let ud else { return }
            let view = Unmanaged<CEFBrowserView>.fromOpaque(ud).takeUnretainedValue()
            w?.pointee = Int32(view.surfaceView.bounds.width)
            h?.pointee = Int32(view.surfaceView.bounds.height)
        }
        callbacks.on_get_screen_info = { _, scaleFactor, ud in
            guard let ud else { return }
            let view = Unmanaged<CEFBrowserView>.fromOpaque(ud).takeUnretainedValue()
            scaleFactor?.pointee = Float(view.surfaceView.window?.backingScaleFactor ?? 2.0)
        }
        callbacks.on_cursor_change = { _, _, _ in }

        // --- Navigation/display callbacks ---
        callbacks.on_title_change = { _, title, ud in
            guard let ud, let title else { return }
            Unmanaged<CEFBrowserView>.fromOpaque(ud).takeUnretainedValue()
                .currentTitle = String(cString: title)
        }
        callbacks.on_url_change = { _, url, ud in
            guard let ud, let url else { return }
            Unmanaged<CEFBrowserView>.fromOpaque(ud).takeUnretainedValue()
                .currentURL = String(cString: url)
        }
        callbacks.on_loading_state_change = { _, loading, back, fwd, ud in
            guard let ud else { return }
            let v = Unmanaged<CEFBrowserView>.fromOpaque(ud).takeUnretainedValue()
            v.isLoading = loading
            v.canGoBack = back
            v.canGoForward = fwd
        }
        callbacks.on_popup_request = { _, _, _ in false }

        callbacksStorage = callbacks

        let w = Int32(surfaceView.bounds.width)
        let h = Int32(surfaceView.bounds.height)

        browserHandle = withUnsafePointer(to: &callbacksStorage!) { ptr in
            cef_bridge_browser_create(url, w, h, ptr)
        }

#if DEBUG
        dlog("cef.osr.browser browserHandle=\(browserHandle != nil ? "ok" : "NULL")")
#endif

        pendingURL = nil
    }

    func destroyBrowser() {
        if let h = browserHandle {
            cef_bridge_browser_destroy(h)
            browserHandle = nil
        }
        // Release the retained self reference from createBrowserImmediate
        if let cbs = callbacksStorage, let ud = cbs.user_data {
            Unmanaged<CEFBrowserView>.fromOpaque(ud).release()
        }
        callbacksStorage = nil
    }

    // MARK: - Navigation

    func loadURL(_ urlString: String) {
        guard let h = browserHandle else { return }
        cef_bridge_browser_load_url(h, urlString)
    }
    func goBack() { if let h = browserHandle { cef_bridge_browser_go_back(h) } }
    func goForward() { if let h = browserHandle { cef_bridge_browser_go_forward(h) } }
    func reload() { if let h = browserHandle { cef_bridge_browser_reload(h) } }
    func stopLoading() { if let h = browserHandle { cef_bridge_browser_stop(h) } }

    func showDevTools() { if let h = browserHandle { cef_bridge_browser_show_devtools(h) } }
    func closeDevTools() { if let h = browserHandle { cef_bridge_browser_close_devtools(h) } }

    func notifyHidden(_ hidden: Bool) { if let h = browserHandle { cef_bridge_browser_set_hidden(h, hidden) } }

    // MARK: - View Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, bounds.width > 0, bounds.height > 0, pendingURL != nil {
            createBrowserNow()
        }
    }

    override func layout() {
        super.layout()
        if pendingURL != nil, !browserCreationAttempted,
           bounds.width > 0, bounds.height > 0, window != nil {
            createBrowserNow()
        }
    }

    // MARK: - CEFSurfaceInputDelegate

    func sendMouseClick(x: Int32, y: Int32, button: Int32, mouseUp: Bool,
                        clickCount: Int32, modifiers: UInt32) {
        guard let h = browserHandle else { return }
        cef_bridge_browser_send_mouse_click(h, x, y, button, mouseUp, clickCount, modifiers)
    }

    func sendMouseMove(x: Int32, y: Int32, mouseLeave: Bool, modifiers: UInt32) {
        guard let h = browserHandle else { return }
        cef_bridge_browser_send_mouse_move(h, x, y, mouseLeave, modifiers)
    }

    func sendMouseWheel(x: Int32, y: Int32, deltaX: Int32, deltaY: Int32, modifiers: UInt32) {
        guard let h = browserHandle else { return }
        cef_bridge_browser_send_mouse_wheel(h, x, y, deltaX, deltaY, modifiers)
    }

    func sendKeyEvent(_ event: NSEvent, type: Int32) {
        guard let h = browserHandle else { return }
        let wkc = CEFKeyCodeMap.windowsKeyCode(from: event.keyCode)
        let ch: UInt16 = event.characters?.first.map { UInt16($0.asciiValue ?? 0) } ?? 0
        let uch: UInt16 = event.charactersIgnoringModifiers?.first.map { UInt16($0.asciiValue ?? 0) } ?? 0
        let mods = CEFModifiers.from(event)
        let isSys = event.modifierFlags.contains(.command)
        cef_bridge_browser_send_key_event(h, type, wkc, Int32(event.keyCode),
                                           mods, ch, uch, isSys)
    }

    func sendFocus(_ focused: Bool) {
        guard let h = browserHandle else { return }
        cef_bridge_browser_send_focus(h, focused)
    }
}
