import AppKit
import SwiftUI

/// Types a message into a workspace's agent, the same as pasting it into the
/// terminal and pressing Return.
@MainActor
enum AgentSteering {
    /// The pane the agent runs in: the focused terminal, else any terminal.
    static func agentTerminal(in workspace: Workspace) -> TerminalPanel? {
        if let focused = workspace.focusedTerminalPanel { return focused }
        return workspace.panels
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .lazy
            .compactMap { $0.value as? TerminalPanel }
            .first
    }

    static func canMessage(_ workspace: Workspace) -> Bool {
        agentTerminal(in: workspace) != nil
    }

    /// Returns false when the workspace has no terminal to type into.
    @discardableResult
    static func send(_ message: String, to workspace: Workspace) -> Bool {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let panel = agentTerminal(in: workspace) else { return false }
        panel.surface.sendText(text)
        // The text arrives as a paste; give the agent's input box a moment to
        // take it before Return submits it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            _ = panel.surface.sendNamedKey("enter")
        }
        return true
    }

    // MARK: - Composer

    private static var composers: [UUID: NSPanel] = [:]

    /// A small window for writing a message to one workspace's agent.
    static func presentComposer(for workspace: Workspace) {
        if let open = composers[workspace.id] {
            open.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 210),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = String.localizedStringWithFormat(
            String(localized: "agentSteering.window.title", defaultValue: "Message %@"),
            workspace.title
        )
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.setFrameAutosaveName("cmux.agentSteering.composer")
        let workspaceId = workspace.id
        let close = { [weak panel] in
            panel?.close()
            composers[workspaceId] = nil
        }
        panel.contentView = NSHostingView(rootView: AgentMessageComposer(
            workspace: workspace,
            onSent: close,
            onCancel: close
        ))
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { _ in
            MainActor.assumeIsolated { composers[workspaceId] = nil }
        }
        composers[workspace.id] = panel
        if panel.frame.origin == .zero { panel.center() }
        panel.makeKeyAndOrderFront(nil)
    }

    /// The selected workspace of the frontmost main window.
    static func selectedWorkspace() -> Workspace? {
        AgentContextStore.all
            .compactMap(\.tabManager)
            .first { $0.window?.isKeyWindow == true || $0.window?.isMainWindow == true }?
            .selectedWorkspace
            ?? AgentContextStore.all.first?.tabManager?.selectedWorkspace
    }
}

private struct AgentMessageComposer: View {
    @ObservedObject var workspace: Workspace
    let onSent: () -> Void
    let onCancel: () -> Void

    @State private var message = ""
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(
                localized: "agentSteering.composer.prompt",
                defaultValue: "Typed into the agent's terminal and sent with Return."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)

            TextEditor(text: $message)
                .font(.body)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor))
                )
                .accessibilityLabel(String(localized: "agentSteering.composer.field", defaultValue: "Message"))

            HStack {
                if failed {
                    Text(String(
                        localized: "agentSteering.composer.noTerminal",
                        defaultValue: "This workspace has no terminal to type into."
                    ))
                    .font(.callout)
                    .foregroundStyle(.red)
                }
                Spacer()
                Button(String(localized: "agentSteering.composer.cancel", defaultValue: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "agentSteering.composer.send", defaultValue: "Send")) {
                    if AgentSteering.send(message, to: workspace) {
                        onSent()
                    } else {
                        failed = true
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(String(localized: "agentSteering.composer.sendHelp", defaultValue: "Send (⌘Return)"))
            }
        }
        .padding(14)
        .frame(minWidth: 360, minHeight: 170)
        .onAppear { focused = true }
    }
}
