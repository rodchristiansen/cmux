import AppKit
import SwiftUI

protocol GhosttyConfigurationErrorsPresenting: AnyObject {
    var displayedErrors: [String] { get set }
    var isShowingConfigurationErrors: Bool { get }
    func showConfigurationErrorsWindow()
    func closeConfigurationErrorsWindow()
}

enum GhosttyConfigurationErrors {
    static func synchronize(
        _ errors: [String],
        presenter: GhosttyConfigurationErrorsPresenting
    ) {
        presenter.displayedErrors = errors

        if errors.isEmpty {
            presenter.closeConfigurationErrorsWindow()
            return
        }

        guard !presenter.isShowingConfigurationErrors else { return }
        presenter.showConfigurationErrorsWindow()
    }
}

private protocol ConfigurationErrorsViewModel: ObservableObject {
    var displayedErrors: [String] { get }
    func ignoreErrors()
    func reloadConfiguration()
}

final class ConfigurationErrorsController: NSWindowController, ObservableObject {
    static let shared = ConfigurationErrorsController()

    @Published var displayedErrors: [String] = []

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        shouldCascadeWindows = false
        window.center()
        window.level = .popUpMenu
        window.minSize = NSSize(width: 560, height: 320)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.configuration-errors")
        window.title = String(
            localized: "config.errors.title",
            defaultValue: "Configuration Errors"
        )
        window.contentView = NSHostingView(rootView: ConfigurationErrorsView(model: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension ConfigurationErrorsController: GhosttyConfigurationErrorsPresenting {
    var isShowingConfigurationErrors: Bool {
        window?.isVisible == true
    }

    func showConfigurationErrorsWindow() {
        guard let window else { return }
        if NSApp.isActive {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    func closeConfigurationErrorsWindow() {
        window?.performClose(nil)
    }
}

extension ConfigurationErrorsController: ConfigurationErrorsViewModel {
    func ignoreErrors() {
        GhosttyConfigurationErrors.synchronize([], presenter: self)
    }

    func reloadConfiguration() {
        GhosttyApp.shared.reloadConfiguration(source: "configuration_errors.reload_button")
    }
}

private struct ConfigurationErrorsView<Model: ConfigurationErrorsViewModel>: View {
    @ObservedObject var model: Model

    private var summaryText: String {
        let format = String(
            localized: "config.errors.summary",
            defaultValue: "%lld error(s) were found while loading the configuration. Please review the errors below and reload your configuration or ignore the erroneous lines."
        )
        return String(
            format: format,
            locale: Locale.current,
            Int64(model.displayedErrors.count)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.system(size: 52))
                    .frame(width: 88, alignment: .center)

                Text(summaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)

            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.displayedErrors, id: \.self) { error in
                            Text(error)
                                .font(.system(size: 12).monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(20)
                    .frame(
                        minWidth: geometry.size.width,
                        minHeight: geometry.size.height,
                        alignment: .topLeading
                    )
                }
                .background(Color(nsColor: .controlBackgroundColor))
            }

            HStack {
                Spacer()
                Button(
                    String(
                        localized: "config.errors.ignore",
                        defaultValue: "Ignore"
                    )
                ) {
                    model.ignoreErrors()
                }
                Button(
                    String(
                        localized: "config.errors.reload",
                        defaultValue: "Reload Configuration"
                    )
                ) {
                    model.reloadConfiguration()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }
}
