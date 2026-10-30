import AppKit
import Combine
import SwiftUI

/// One workspace whose agent has stopped and is waiting on you.
struct AgentInboxItem: Identifiable, Equatable {
    enum Kind: Int, Comparable {
        /// It asked a question, or posted a notification you have not read.
        case asking = 0
        /// Its turn ended with nothing unread.
        case idle = 1

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: UUID
    let title: String
    let kind: Kind
    let summary: String?
    /// What the agent said last, which is usually the question.
    let message: String?
    let lastPrompt: String?
    let pullRequests: [String]
    let since: Date?
}

/// Builds the inbox from every main window's workspaces.
@MainActor
final class AgentInboxModel: ObservableObject {
    static let shared = AgentInboxModel()

    @Published private(set) var items: [AgentInboxItem] = []

    var askingCount: Int { items.filter { $0.kind == .asking }.count }

    private var cancellables = Set<AnyCancellable>()

    func start() {
        guard cancellables.isEmpty else { return }
        rebuild()
        Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        TerminalNotificationStore.shared.$notifications
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.rebuild() } }
            .store(in: &cancellables)
    }

    func workspace(_ id: UUID) -> Workspace? {
        for store in AgentContextStore.all {
            if let workspace = store.tabManager?.tabs.first(where: { $0.id == id }) { return workspace }
        }
        return nil
    }

    func rebuild() {
        let notifications = TerminalNotificationStore.shared
        var next: [AgentInboxItem] = []
        var seen = Set<UUID>()
        for store in AgentContextStore.all {
            guard let tabManager = store.tabManager else { continue }
            for workspace in tabManager.tabs where seen.insert(workspace.id).inserted {
                let entries = workspace.statusEntries.values.filter(\.isAgentStatus)
                if entries.contains(where: \.isAgentRunningStatus) { continue }
                let hasAgent = !entries.isEmpty || workspace.hasAttachedAgentSession
                    || !workspace.visibleDetachedLanes.isEmpty
                guard hasAgent else { continue }
                let context = store.contexts[workspace.id]
                let asked = entries.contains { $0.value == "Needs input" }
                let unread = notifications.unreadCount(forTabId: workspace.id) > 0
                let latest = notifications.latestNotification(forTabId: workspace.id)
                let statusDate = entries.map(\.timestamp).max()
                next.append(AgentInboxItem(
                    id: workspace.id,
                    title: workspace.title,
                    kind: asked || unread ? .asking : .idle,
                    summary: context?.summary,
                    message: context?.lastReply ?? latest.map { [$0.subtitle, $0.body].filter { !$0.isEmpty }.joined(separator: " — ") },
                    lastPrompt: context?.prompts.first,
                    pullRequests: context?.pullRequests ?? [],
                    since: [statusDate, latest?.createdAt].compactMap { $0 }.max()
                ))
            }
        }
        next.sort { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return (lhs.since ?? .distantPast) > (rhs.since ?? .distantPast)
        }
        if next != items { items = next }
    }

    func open(_ id: UUID) {
        _ = AppDelegate.shared?.openNotification(tabId: id, surfaceId: nil, notificationId: nil)
    }

    func markRead(_ id: UUID) {
        TerminalNotificationStore.shared.markRead(forTabId: id)
        rebuild()
    }
}

/// The Agent Inbox window: every agent waiting on you, answered in place.
@MainActor
final class AgentInboxWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AgentInboxWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "agentInbox.window.title", defaultValue: "Agent Inbox")
        window.identifier = NSUserInterfaceItemIdentifier("cmux.agentInbox")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 320)
        window.contentView = NSHostingView(rootView: AgentInboxView())
        window.setFrameAutosaveName("cmux.agentInbox")
        if !window.setFrameUsingName("cmux.agentInbox") { window.center() }
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        AgentInboxModel.shared.start()
        AgentInboxModel.shared.rebuild()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggle() {
        if let window, window.isVisible, window.isKeyWindow {
            window.close()
        } else {
            show()
        }
    }
}

struct AgentInboxView: View {
    @ObservedObject private var model = AgentInboxModel.shared
    @ObservedObject private var pullRequests = AgentPullRequestStatusStore.shared
    @SceneStorage("agentInbox.showIdle") private var showIdle = true
    @State private var selection: UUID?

    private var asking: [AgentInboxItem] { model.items.filter { $0.kind == .asking } }
    private var idle: [AgentInboxItem] { model.items.filter { $0.kind == .idle } }

    var body: some View {
        Group {
            if model.items.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    if !asking.isEmpty {
                        Section(String.localizedStringWithFormat(
                            String(localized: "agentInbox.section.asking", defaultValue: "Asking You (%lld)"),
                            asking.count
                        )) {
                            ForEach(asking) { row($0) }
                        }
                    }
                    if !idle.isEmpty {
                        Section(isExpanded: $showIdle) {
                            ForEach(idle) { row($0) }
                        } header: {
                            Text(String.localizedStringWithFormat(
                                String(localized: "agentInbox.section.idle", defaultValue: "Finished, Waiting for Next Step (%lld)"),
                                idle.count
                            ))
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first, let item = model.items.first(where: { $0.id == id }) {
                        menu(for: item)
                    }
                } primaryAction: { ids in
                    if let id = ids.first { model.open(id) }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    for item in asking { model.markRead(item.id) }
                } label: {
                    Label(String(localized: "agentInbox.markAllRead", defaultValue: "Mark All Read"), systemImage: "envelope.open")
                }
                .help(String(localized: "agentInbox.markAllRead", defaultValue: "Mark All Read"))
                .disabled(asking.isEmpty)
            }
        }
        .onAppear { model.start() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(String(localized: "agentInbox.empty.title", defaultValue: "No agent is waiting on you"))
                .font(.headline)
            Text(String(localized: "agentInbox.empty.description", defaultValue: "Agents show up here when they stop to ask something or finish a turn."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ item: AgentInboxItem) -> some View {
        AgentInboxRow(
            item: item,
            pullRequests: pullRequests.pullRequests(for: item.pullRequests),
            onOpen: { model.open(item.id) },
            onSend: { text in
                guard let workspace = model.workspace(item.id) else { return false }
                let sent = AgentSteering.send(text, to: workspace)
                if sent { TerminalNotificationStore.shared.markRead(forTabId: item.id) }
                return sent
            }
        )
        .tag(item.id)
    }

    @ViewBuilder
    private func menu(for item: AgentInboxItem) -> some View {
        Button(String(localized: "agentInbox.menu.open", defaultValue: "Open Workspace")) { model.open(item.id) }
        Button(String(localized: "agentInbox.menu.message", defaultValue: "Message Agent…")) {
            if let workspace = model.workspace(item.id) { AgentSteering.presentComposer(for: workspace) }
        }
        if item.kind == .asking {
            Button(String(localized: "agentInbox.menu.markRead", defaultValue: "Mark Read")) { model.markRead(item.id) }
        }
        if let message = item.message {
            Divider()
            Button(String(localized: "agentInbox.menu.copyMessage", defaultValue: "Copy Agent Message")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
            }
        }
        AgentPullRequestMenu(urls: item.pullRequests)
    }
}

private struct AgentInboxRow: View {
    let item: AgentInboxItem
    let pullRequests: [AgentPullRequest]
    let onOpen: () -> Void
    let onSend: (String) -> Bool

    @State private var reply = ""
    @State private var sentAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if item.kind == .asking {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(String(localized: "agentInbox.row.asking", defaultValue: "Asking you"))
                }
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let since = item.since {
                    Text(since, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button(String(localized: "agentInbox.row.open", defaultValue: "Open"), action: onOpen)
                    .controlSize(.small)
            }

            if let summary = item.summary {
                Text(summary)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
            }

            if let message = item.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .textSelection(.enabled)
            }

            if !pullRequests.isEmpty {
                HStack(spacing: 6) {
                    ForEach(pullRequests.suffix(4)) { pr in
                        AgentPullRequestChip(pullRequest: pr)
                    }
                }
            }

            HStack(spacing: 6) {
                TextField(
                    String(localized: "agentInbox.row.replyPlaceholder", defaultValue: "Reply to the agent…"),
                    text: $reply
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
                Button(String(localized: "agentInbox.row.send", defaultValue: "Send"), action: send)
                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if sentAt != nil {
                Text(String(localized: "agentInbox.row.sent", defaultValue: "Sent"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func send() {
        guard onSend(reply) else { return }
        reply = ""
        sentAt = Date()
    }
}

/// "cmux#74 · Merged", opening the pull request when clicked.
struct AgentPullRequestChip: View {
    let pullRequest: AgentPullRequest

    var body: some View {
        Button {
            if let url = URL(string: pullRequest.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(pullRequest.shortName)
                if let state = pullRequest.stateLabel {
                    Text(state).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .buttonStyle(.link)
        .help(pullRequest.title ?? pullRequest.url)
    }

    private var icon: String {
        switch pullRequest.state {
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        default: return "arrow.triangle.pull"
        }
    }

    private var color: Color {
        switch pullRequest.state {
        case .merged: return .purple
        case .closed: return .red
        case .open: return .green
        default: return .secondary
        }
    }
}

/// "Agent Pull Requests ▸" listing each one, newest first.
struct AgentPullRequestMenu: View {
    let urls: [String]
    @ObservedObject private var store = AgentPullRequestStatusStore.shared

    var body: some View {
        if !urls.isEmpty {
            Menu(String(localized: "agentLedger.menu.title", defaultValue: "Agent Pull Requests")) {
                ForEach(store.pullRequests(for: urls.reversed())) { pr in
                    Button(pr.menuTitle) {
                        if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
                    }
                }
                Divider()
                Button(String(localized: "agentLedger.menu.copyLinks", defaultValue: "Copy Links")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(urls.joined(separator: "\n"), forType: .string)
                }
            }
        }
    }
}
