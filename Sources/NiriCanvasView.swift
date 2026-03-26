#if DEBUG
import AppKit
import QuartzCore

/// Niri/PaperWM-style horizontal strip with real ghostty terminal surfaces.
/// Each panel has its own width preset. Resize only affects the focused panel.
final class NiriCanvasView: NSView {

    private struct Slot {
        let surface: TerminalSurface
        var closing: Bool = false
        var closeProgress: CGFloat = 1.0
        var presetIndex: Int = 1        // default to 0.67
        var currentWidth: CGFloat = 0.67
        var targetWidth: CGFloat = 0.67
    }

    private var slots: [Slot] = []
    private(set) var focusedIndex: Int = 0
    private var scrollOffset: CGFloat = 0
    private var targetOffset: CGFloat = 0
    private var displayLink: CVDisplayLink?

    private let panelGap: CGFloat = 12
    private let peekWidth: CGFloat = 60
    private let springK: CGFloat = 0.16
    private let widthPresets: [CGFloat] = [0.33, 0.67, 1.0]

    // MARK: - Init

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer!.backgroundColor = NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1).cgColor
        startDisplayLink()
    }

    deinit { if let displayLink { CVDisplayLinkStop(displayLink) } }

    // MARK: - Surfaces

    func setSurfaces(_ newSurfaces: [TerminalSurface]) {
        for s in slots { s.surface.hostedView.removeFromSuperview() }
        slots = newSurfaces.map { Slot(surface: $0) }
        for s in slots { let h = s.surface.hostedView; h.removeFromSuperview(); addSubview(h) }
        focusedIndex = min(focusedIndex, max(0, liveCount - 1))
        targetOffset = stripX(forLive: focusedIndex)
        scrollOffset = targetOffset
        layoutStrip()
    }

    private var liveCount: Int { slots.count(where: { !$0.closing }) }

    private var liveIndices: [(slot: Int, live: Int)] {
        var result: [(Int, Int)] = []
        var li = 0
        for (i, s) in slots.enumerated() where !s.closing {
            result.append((i, li)); li += 1
        }
        return result
    }

    var focusedSurface: TerminalSurface? {
        let live = liveIndices
        guard focusedIndex >= 0, focusedIndex < live.count else { return nil }
        return slots[live[focusedIndex].slot].surface
    }

    // MARK: - Geometry

    private var maxW: CGFloat { bounds.width - peekWidth * 2 - panelGap * 2 }

    private func pw(for slot: Slot) -> CGFloat { max(300, maxW * slot.currentWidth) }

    /// Strip-space X for a live index, based on current (animated) widths.
    private func stripX(forLive target: Int) -> CGFloat {
        var x: CGFloat = 0; var li = 0
        for s in slots {
            if s.closing { x += pw(for: s) * s.closeProgress + panelGap * s.closeProgress; continue }
            if li == target { return x }
            x += pw(for: s) + panelGap; li += 1
        }
        return x
    }

    // MARK: - Layout

    private func layoutStrip() {
        let ph = max(300, bounds.height - 20)
        let topY = (bounds.height - ph) / 2
        var xCursor: CGFloat = 0; var li = 0

        for i in 0..<slots.count {
            let s = slots[i]; let hosted = s.surface.hostedView
            let progress = s.closing ? s.closeProgress : 1.0
            let w = pw(for: s) * progress; let gap = panelGap * progress
            let screenX = peekWidth + panelGap + (xCursor - scrollOffset)
            let isFocused = !s.closing && li == focusedIndex
            let opacity: CGFloat = s.closing ? max(0, progress) : 1.0

            hosted.frame = CGRect(x: screenX, y: topY, width: max(0, w), height: ph)
            hosted.alphaValue = CGFloat(opacity)

            if let l = hosted.layer {
                l.transform = CATransform3DIdentity; l.zPosition = 0
                l.cornerRadius = 0; l.masksToBounds = true
                l.borderWidth = isFocused ? 2 : 1
                l.borderColor = isFocused
                    ? NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
                    : NSColor.white.withAlphaComponent(0.08).cgColor
            }
            xCursor += w + gap
            if !s.closing { li += 1 }
        }
    }

    override func layout() { super.layout(); layoutStrip() }

    // MARK: - Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = f.contains(.command), opt = f.contains(.option), ctrl = f.contains(.control)
        let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if cmd && opt {
            if event.keyCode == 123 { navigateLeft(); return true }
            if event.keyCode == 124 { navigateRight(); return true }
        }
        if cmd && ctrl {
            if ch == "h" { navigateLeft(); return true }
            if ch == "l" { navigateRight(); return true }
            if ch == "r" { cycleResize(); return true }
        }
        if cmd && !ctrl && !opt && ch == "w" { closeFocusedTerminal(); return true }
        if cmd && !ctrl && !opt && ch == "t" { addNewTerminal(); return true }
        return super.performKeyEquivalent(with: event)
    }

    func handleCtrlD() { closeFocusedTerminal() }

    // MARK: - Navigation

    func navigateLeft() {
        guard focusedIndex > 0 else { return }
        focusedIndex -= 1; scrollToReveal(); focusCurrentTerminal()
    }

    func navigateRight() {
        guard focusedIndex < liveCount - 1 else { return }
        focusedIndex += 1; scrollToReveal(); focusCurrentTerminal()
    }

    /// Adjust targetOffset so the focused panel is fully visible.
    /// If the panel is wider than the viewport, left-align it.
    /// Otherwise, scroll the minimum amount to bring both edges into view.
    private func scrollToReveal() {
        let live = liveIndices
        guard focusedIndex < live.count else { return }
        let panelStart = stripX(forLive: focusedIndex)
        let w = pw(for: slots[live[focusedIndex].slot])
        ensureVisible(panelStart: panelStart, panelWidth: w)
    }

    /// Like scrollToReveal but uses the target (final) width for resize preview.
    private func scrollToRevealTarget() {
        let live = liveIndices
        guard focusedIndex < live.count else { return }
        let panelStart = stripX(forLive: focusedIndex)
        let slot = slots[live[focusedIndex].slot]
        let w = max(300, maxW * slot.targetWidth)
        ensureVisible(panelStart: panelStart, panelWidth: w)
    }

    private func ensureVisible(panelStart: CGFloat, panelWidth w: CGFloat) {
        let viewport = maxW

        if w >= viewport {
            // Panel wider than viewport: left-align
            targetOffset = panelStart
        } else {
            // Valid scroll range to keep both edges visible:
            //   panelStart + w - viewport <= targetOffset <= panelStart
            let minOffset = panelStart + w - viewport
            let maxOffset = panelStart

            if targetOffset > maxOffset {
                targetOffset = maxOffset  // left edge was off-screen
            } else if targetOffset < minOffset {
                targetOffset = minOffset  // right edge was off-screen
            }
            // else: already fully visible, don't move
        }
        targetOffset = max(0, targetOffset)
    }

    // MARK: - Resize

    func cycleResize() {
        let live = liveIndices
        guard focusedIndex < live.count else { return }
        let si = live[focusedIndex].slot
        slots[si].presetIndex = (slots[si].presetIndex + 1) % widthPresets.count
        slots[si].targetWidth = widthPresets[slots[si].presetIndex]
        // Immediately ensure the final size will be visible (scroll starts animating now)
        scrollToRevealTarget()
    }

    // MARK: - Close / Add

    func closeFocusedTerminal() {
        let live = liveIndices
        guard !live.isEmpty, focusedIndex < live.count else { return }
        let si = live[focusedIndex].slot
        slots[si].closing = true
        if let s = slots[si].surface.surface { ghostty_surface_request_close(s) }
        if liveCount > 0 {
            focusedIndex = min(focusedIndex, liveCount - 1)
            focusCurrentTerminal()
        }
    }

    func addNewTerminal() {
        guard GhosttyApp.shared.app != nil else { return }
        let surface = TerminalSurface(tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT, configTemplate: nil)
        let live = liveIndices
        let insertAt = focusedIndex < live.count ? live[focusedIndex].slot + 1 : slots.count
        slots.insert(Slot(surface: surface), at: insertAt)
        surface.hostedView.removeFromSuperview(); addSubview(surface.hostedView)
        focusedIndex += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.focusCurrentTerminal()
        }
    }

    // MARK: - Focus

    func focusCurrentTerminal() {
        guard let surface = focusedSurface else { return }
        if let gv = findGhosttyNSView(in: surface.hostedView) {
            window?.makeFirstResponder(gv)
        }
    }

    private func findGhosttyNSView(in view: NSView) -> NSView? {
        if type(of: view) == GhosttyNSView.self { return view }
        for sub in view.subviews { if let v = findGhosttyNSView(in: sub) { return v } }
        return nil
    }

    // MARK: - Scroll

    override func scrollWheel(with event: NSEvent) {
        var dx = event.scrollingDeltaX; var dy = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { dx = -dx; dy = -dy }
        let delta = abs(dx) > abs(dy) ? dx : dy
        targetOffset += delta * 2.0
        targetOffset = max(0, targetOffset)
        let newFocus = nearestLiveIndex(forOffset: targetOffset)
        if newFocus != focusedIndex { focusedIndex = newFocus; focusCurrentTerminal() }
    }

    private func nearestLiveIndex(forOffset offset: CGFloat) -> Int {
        var best = 0; var bestDist = CGFloat.infinity; var x: CGFloat = 0; var li = 0
        for s in slots where !s.closing {
            let mid = x + pw(for: s) / 2
            let d = abs(mid - offset)
            if d < bestDist { bestDist = d; best = li }
            x += pw(for: s) + panelGap; li += 1
        }
        return best
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Display Link

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let displayLink else { return }
        let cb: CVDisplayLinkOutputCallback = { _, _, _, _, _, ud -> CVReturn in
            let v = Unmanaged<NiriCanvasView>.fromOpaque(ud!).takeUnretainedValue()
            DispatchQueue.main.async { v.tick() }; return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(displayLink, cb, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(displayLink)
    }

    private func tick() {
        // Animate per-slot widths
        var anyResizing = false
        for i in 0..<slots.count {
            let d = slots[i].targetWidth - slots[i].currentWidth
            if abs(d) < 0.001 { slots[i].currentWidth = slots[i].targetWidth }
            else { slots[i].currentWidth += d * 0.14; anyResizing = true }
        }

        // During resize: directly clamp scroll to keep focused panel visible.
        // No separate scroll spring, scroll is derived from width animation.
        if anyResizing {
            let live = liveIndices
            if focusedIndex < live.count {
                let panelStart = stripX(forLive: focusedIndex)
                let w = pw(for: slots[live[focusedIndex].slot])
                let viewport = maxW

                if w >= viewport {
                    scrollOffset = panelStart
                } else {
                    let minScroll = panelStart + w - viewport
                    let maxScroll = panelStart
                    scrollOffset = max(minScroll, min(maxScroll, scrollOffset))
                }
                scrollOffset = max(0, scrollOffset)
                targetOffset = scrollOffset
            }
        }

        // Animate closing
        var removed = false
        for i in (0..<slots.count).reversed() where slots[i].closing {
            slots[i].closeProgress -= 0.06
            if slots[i].closeProgress <= 0 {
                slots[i].surface.hostedView.removeFromSuperview()
                slots.remove(at: i); removed = true
            }
        }
        if removed && liveCount == 0 { window?.close(); return }

        // Animate scroll (only when not resizing, resize drives scroll directly above)
        if !anyResizing {
            let diff = targetOffset - scrollOffset
            if abs(diff) < 0.3 { scrollOffset = targetOffset }
            else { scrollOffset += diff * springK }
        }

        layoutStrip()
    }
}

// MARK: - Window

private final class NiriCanvasWindow: NSWindow {
    weak var canvasView: NiriCanvasView?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let c = canvasView, c.performKeyEquivalent(with: event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let ctrlOnly = f.contains(.control) && !f.contains(.command) && !f.contains(.option)
            let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if ctrlOnly && (ch == "d" || event.characters == "\u{04}") {
                canvasView?.handleCtrlD(); return
            }
        }
        super.sendEvent(event)
    }
}

// MARK: - Controller

final class NiriCanvasWindowController: NSWindowController {
    private let canvasView: NiriCanvasView

    init() {
        let scr = NSScreen.main!.frame
        let win = NiriCanvasWindow(
            contentRect: NSRect(x: scr.midX - 700, y: scr.midY - 350, width: 1400, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        win.title = "Terminal Canvas"
        win.titlebarAppearsTransparent = true
        win.backgroundColor = NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)
        win.titleVisibility = .hidden
        win.minSize = NSSize(width: 800, height: 400)

        canvasView = NiriCanvasView(frame: win.contentView!.bounds)
        canvasView.autoresizingMask = [.width, .height]
        win.contentView!.addSubview(canvasView)
        win.canvasView = canvasView
        super.init(window: win)
    }

    required init?(coder: NSCoder) { fatalError() }

    func open(terminalCount: Int = 3) {
        guard GhosttyApp.shared.app != nil else { return }
        let surfaces = (0..<terminalCount).map { _ in
            TerminalSurface(tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT, configTemplate: nil)
        }
        canvasView.setSurfaces(surfaces)
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.canvasView.focusCurrentTerminal()
        }
    }

    func openWithExisting(_ surfaces: [TerminalSurface]) {
        canvasView.setSurfaces(surfaces)
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.canvasView.focusCurrentTerminal()
        }
    }

    var canvas: NiriCanvasView { canvasView }
}
#endif
