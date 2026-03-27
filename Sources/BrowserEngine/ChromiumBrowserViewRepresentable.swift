import SwiftUI
import AppKit

/// NSViewRepresentable that hosts a ChromiumBrowserView in SwiftUI.
struct ChromiumBrowserViewRepresentable: NSViewRepresentable {
    let chromiumBrowserView: ChromiumBrowserView

    func makeNSView(context: Context) -> ChromiumBrowserView {
        chromiumBrowserView
    }

    func updateNSView(_ nsView: ChromiumBrowserView, context: Context) {
        // Layout is handled by autoresizing masks and ChromiumBrowserView.layout()
    }
}
