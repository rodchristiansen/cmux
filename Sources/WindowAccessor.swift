import AppKit
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    let dedupeByWindow: Bool

    init(dedupeByWindow: Bool = true, onWindow: @escaping (NSWindow) -> Void) {
        self.onWindow = onWindow
        self.dedupeByWindow = dedupeByWindow
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView()
        view.onWindow = { window in
            guard !dedupeByWindow || context.coordinator.lastWindow !== window else { return }
            context.coordinator.lastWindow = window
            onWindow(window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowObservingView, context: Context) {
        nsView.onWindow = { window in
            guard !dedupeByWindow || context.coordinator.lastWindow !== window else { return }
            context.coordinator.lastWindow = window
            onWindow(window)
        }
        if let window = nsView.window {
            nsView.onWindow?(window)
        }
    }
}

extension WindowAccessor {
    final class Coordinator {
        weak var lastWindow: NSWindow?
    }
}

final class WindowObservingView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let newWindow {
            onWindow?(newWindow)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindow?(window)
        }
    }
}

struct WindowTrafficLightMetrics: Equatable {
    let leadingInset: CGFloat
    let topInset: CGFloat
}

struct WindowTrafficLightMetricsReader: NSViewRepresentable {
    let onMetrics: (WindowTrafficLightMetrics) -> Void

    func makeNSView(context: Context) -> WindowTrafficLightMetricsView {
        let view = WindowTrafficLightMetricsView()
        view.onMetrics = onMetrics
        return view
    }

    func updateNSView(_ nsView: WindowTrafficLightMetricsView, context: Context) {
        nsView.onMetrics = onMetrics
        nsView.publishMetricsIfPossible()
    }
}

final class WindowTrafficLightMetricsView: NSView {
    var onMetrics: ((WindowTrafficLightMetrics) -> Void)?

    private weak var observedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var lastPublishedMetrics: WindowTrafficLightMetrics?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window !== observedWindow {
            reinstallObservers(for: window)
        }
        publishMetricsIfPossible()
    }

    override func layout() {
        super.layout()
        publishMetricsIfPossible()
    }

    deinit {
        removeObservers()
    }

    func publishMetricsIfPossible() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let window = self.window ?? self.observedWindow,
                  let contentView = window.contentView else {
                return
            }

            let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            let frames = buttonTypes.compactMap { type -> CGRect? in
                guard let button = window.standardWindowButton(type), !button.isHidden else { return nil }
                return contentView.convert(button.bounds, from: button)
            }
            guard !frames.isEmpty else { return }

            let metrics = WindowTrafficLightMetrics(
                leadingInset: (frames.map(\.maxX).max() ?? 0) + 14,
                topInset: (frames.map { max(0, contentView.bounds.maxY - $0.minY) }.max() ?? 0) + 8
            )
            guard metrics != self.lastPublishedMetrics else { return }
            self.lastPublishedMetrics = metrics
            self.onMetrics?(metrics)
        }
    }

    private func reinstallObservers(for window: NSWindow?) {
        removeObservers()
        observedWindow = window
        guard let window else { return }

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.publishMetricsIfPossible()
            }
        }
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }
}
