import AppKit
import SwiftUI

private let configurationErrorsWindowSize = NSSize(width: 620, height: 320)

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
        let previousErrors = presenter.displayedErrors
        let wasShowing = presenter.isShowingConfigurationErrors
        presenter.displayedErrors = errors

        if errors.isEmpty {
            presenter.closeConfigurationErrorsWindow()
            return
        }

        if !wasShowing, previousErrors == errors {
            return
        }

        guard !wasShowing else { return }
        presenter.showConfigurationErrorsWindow()
    }
}

private protocol ConfigurationErrorsViewModel: ObservableObject {
    var displayedErrors: [String] { get }
    func dismissWarning()
    func reloadConfiguration()
}

final class ConfigurationErrorsController: NSWindowController, ObservableObject {
    static let shared = ConfigurationErrorsController()

    @Published var displayedErrors: [String] = []

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: configurationErrorsWindowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        shouldCascadeWindows = false
        window.center()
        window.minSize = configurationErrorsWindowSize
        window.maxSize = configurationErrorsWindowSize
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
        window.setContentSize(configurationErrorsWindowSize)
        window.orderFront(nil)
    }

    func closeConfigurationErrorsWindow() {
        window?.performClose(nil)
    }
}

extension ConfigurationErrorsController: ConfigurationErrorsViewModel {
    func dismissWarning() {
        closeConfigurationErrorsWindow()
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
            defaultValue: "%lld configuration error(s) were found. Review them below, reload your configuration, or close this warning and keep working."
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
                        defaultValue: "Close"
                    )
                ) {
                    model.dismissWarning()
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
        .frame(
            width: configurationErrorsWindowSize.width,
            height: configurationErrorsWindowSize.height
        )
    }
}
