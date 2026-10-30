import AppKit
import Bonsplit
import Combine
import SwiftUI

/// Whether the agent board is expanded. One setting for every window, so the
/// menu item, the shortcut and the toolbar button all agree.
enum AgentBoardSettings {
    static let expandedKey = "agentBoard.isExpanded"

    static func toggle() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: expandedKey), forKey: expandedKey)
    }
}

/// The column an agent card sits in.
enum AgentBoardColumn: Int, CaseIterable, Identifiable {
    case needsInput
    case running
    case waiting

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .needsInput:
            return String(localized: "agentBoard.column.needsInput", defaultValue: "Needs Input")
        case .running:
            return String(localized: "agentBoard.column.running", defaultValue: "Running")
        case .waiting:
            return String(localized: "agentBoard.column.waiting", defaultValue: "Waiting on You")
        }
    }

    var symbol: String {
        switch self {
        case .needsInput: return "exclamationmark.bubble.fill"
        case .running: return "bolt.fill"
        case .waiting: return "pause.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .needsInput: return .orange
        case .running: return .blue
        case .waiting: return .secondary
        }
    }
}

/// Everything a card shows, read once per refresh so the view body stays cheap.
struct AgentBoardCard: Identifiable, Equatable {
    let id: UUID
    let column: AgentBoardColumn
    let workspaceTitle: String
    let sectionName: String?
    let taskHeadline: String?
    let agentName: String?
    let statusDetail: String?
    let prompt: String?
    let lastMessage: String?
    let directory: String?
    let branch: String?
    let branchIsDirty: Bool
    let pullRequestLabel: String?
    let pullRequestURL: URL?
    let pullRequestStatus: SidebarPullRequestStatus?
    let ports: [Int]
    let unreadCount: Int
    let lastActivity: Date?
    let isSelected: Bool
    /// Recent prompts and the agent's latest message, read from its transcript.
    let digest: AgentTranscriptDigest?
    /// One sentence from Claude Haiku: what was asked and where it stands.
    let summary: String?

    /// The focused pane's directory, else the workspace's.
    @MainActor
    static func directory(of workspace: Workspace) -> String? {
        if let focused = workspace.focusedPanelId,
           let dir = workspace.panelDirectories[focused]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dir.isEmpty {
            return dir
        }
        let dir = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.isEmpty ? nil : dir
    }

    @MainActor
    static func make(
        workspace: Workspace,
        tabManager: TabManager,
        notificationStore: TerminalNotificationStore,
        digest: AgentTranscriptDigest?,
        summary: String?
    ) -> AgentBoardCard? {
        let agentEntries = workspace.statusEntries.values.filter(\.isAgentStatus)
        let hasSession = workspace.hasAttachedAgentSession
        let detachedLanes = workspace.visibleDetachedLanes
        // Hooks feed the status pills, but a session the hooks never reached (an
        // older lane, another cmux) still shows when its transcript is found.
        guard !agentEntries.isEmpty || hasSession || !detachedLanes.isEmpty || digest?.isLive == true else {
            return nil
        }

        let latestEntry = agentEntries.max { $0.timestamp < $1.timestamp }
        let column: AgentBoardColumn
        if agentEntries.contains(where: { $0.value == "Needs input" }) {
            column = .needsInput
        } else if agentEntries.contains(where: \.isAgentRunningStatus) {
            column = .running
        } else {
            column = .waiting
        }

        let agentName: String? = {
            switch latestEntry?.key {
            case "claude_code": return "Claude Code"
            case "codex": return "Codex"
            default:
                switch digest?.tool {
                case "claude": return "Claude Code"
                case "codex": return "Codex"
                default: return detachedLanes.first.map { $0.isCodex ? "Codex" : "Claude Code" }
                }
            }
        }()

        // The hooks report "Running" plainly; anything else (a tool description
        // with verbose status on) says what the agent is doing right now.
        let statusDetail: String? = {
            guard let value = latestEntry?.value,
                  !["Running", "Idle", "Needs input"].contains(value) else { return nil }
            return value
        }()

        let notification = notificationStore.latestNotification(forTabId: workspace.id)
        let lastMessage: String? = {
            guard let notification else { return nil }
            let parts = [notification.subtitle, notification.body]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " — ")
        }()

        let directory = directory(of: workspace)

        let statusDate = agentEntries.map(\.timestamp).max()
        let lastActivity = [statusDate, notification?.createdAt, workspace.agentPrompt?.timestamp,
                            digest?.prompts.first?.date, digest?.lastReplyDate]
            .compactMap { $0 }
            .max()

        let headline = workspace.customDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ports = Array(Set(workspace.listeningPorts + workspace.remoteForwardedPorts)).sorted()

        return AgentBoardCard(
            id: workspace.id,
            column: column,
            workspaceTitle: workspace.title,
            sectionName: tabManager.sectionForWorkspace(workspace.id)?.name,
            taskHeadline: (headline?.isEmpty ?? true) ? nil : headline,
            agentName: agentName,
            statusDetail: statusDetail,
            prompt: workspace.agentPrompt?.text,
            lastMessage: lastMessage,
            directory: directory,
            branch: workspace.gitBranch?.branch,
            branchIsDirty: workspace.gitBranch?.isDirty ?? false,
            pullRequestLabel: workspace.pullRequest.map { "\($0.label) #\($0.number)" },
            pullRequestURL: workspace.pullRequest?.url,
            pullRequestStatus: workspace.pullRequest?.status,
            ports: ports,
            unreadCount: notificationStore.unreadCount(forTabId: workspace.id),
            lastActivity: lastActivity,
            isSelected: tabManager.selectedTabId == workspace.id,
            digest: digest,
            summary: summary
        )
    }
}

/// Builds the cards for one window and rebuilds them, at most twice a second,
/// whenever a workspace changes. It only listens while the board is open, so a
/// closed board costs nothing while typing.
@MainActor
final class AgentBoardModel: ObservableObject {
    @Published private(set) var cards: [AgentBoardCard] = []

    private weak var tabManager: TabManager?
    private let notificationStore: TerminalNotificationStore
    private var tabsCancellable: AnyCancellable?
    private var changeCancellable: AnyCancellable?
    private var notificationCancellable: AnyCancellable?
    private var clockCancellable: AnyCancellable?
    private let changes = PassthroughSubject<Void, Never>()
    private var rebuildCancellable: AnyCancellable?

    init(notificationStore: TerminalNotificationStore? = nil) {
        self.notificationStore = notificationStore ?? .shared
    }

    func start(tabManager: TabManager) {
        guard self.tabManager !== tabManager || tabsCancellable == nil else { return }
        self.tabManager = tabManager
        rebuildCancellable = changes
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.rebuild() }
        tabsCancellable = tabManager.$tabs.sink { [weak self] tabs in
            self?.observe(tabs)
        }
        notificationCancellable = notificationStore.objectWillChange.sink { [weak self] _ in
            self?.changes.send()
        }
        tabManager.objectWillChange
            .sink { [weak self] _ in self?.changes.send() }
            .store(in: &extraCancellables)
        // Ages ("4m ago"), agent liveness and transcripts drift with no event to
        // announce them. Unchanged transcripts are not re-read.
        AgentBoardSummarizer.shared.$summaries
            .dropFirst()
            .sink { [weak self] _ in self?.changes.send() }
            .store(in: &extraCancellables)
        clockCancellable = Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.changes.send() }
        rebuild()
    }

    func stop() {
        tabsCancellable = nil
        changeCancellable = nil
        notificationCancellable = nil
        clockCancellable = nil
        rebuildCancellable = nil
        extraCancellables.removeAll()
    }

    private var extraCancellables = Set<AnyCancellable>()

    private func observe(_ tabs: [Workspace]) {
        changeCancellable = Publishers.MergeMany(tabs.map { $0.objectWillChange.map { _ in () } })
            .sink { [weak self] in self?.changes.send() }
        changes.send()
    }

    private var digests: [UUID: AgentTranscriptDigest] = [:]
    private var isReadingTranscripts = false

    private func rebuild() {
        rebuildCards()
        refreshTranscripts()
    }

    /// Reads transcripts off the main thread, then redraws the cards with them.
    private func refreshTranscripts() {
        guard let tabManager, !isReadingTranscripts else { return }
        // Every workspace, not just the carded ones: finding a live session is
        // what puts a workspace with no status pill on the board.
        let locators = tabManager.tabs.map { workspace -> AgentTranscriptLocator in
            var tmux = Set(workspace.ownedTmuxSessions)
            tmux.formUnion(workspace.detachedLanes.map(\.session))
            return AgentTranscriptLocator(
                workspaceId: workspace.id,
                reportedPaths: Array(workspace.agentTranscripts.values),
                agentPIDs: Array(workspace.agentPIDs.values) + workspace.detachedLanes.map(\.panePID),
                tmuxSessions: Array(tmux),
                directory: AgentBoardCard.directory(of: workspace)
            )
        }
        guard !locators.isEmpty else { return }
        isReadingTranscripts = true
        Task.detached(priority: .utility) { [weak self] in
            let read = AgentTranscriptReader.shared.digests(for: locators)
            await MainActor.run {
                guard let self else { return }
                self.isReadingTranscripts = false
                if read != self.digests {
                    self.digests = read
                    self.rebuildCards()
                }
            }
        }
    }

    private func rebuildCards() {
        guard let tabManager else { return }
        let built = tabManager.tabs.compactMap {
            AgentBoardCard.make(
                workspace: $0,
                tabManager: tabManager,
                notificationStore: notificationStore,
                digest: digests[$0.id],
                summary: AgentBoardSummarizer.isEnabled ? AgentBoardSummarizer.shared.summaries[$0.id] : nil
            )
        }
#if DEBUG
        dlog("agentBoard.cards count=\(built.count) digests=\(digests.count)")
#endif
        for card in built {
            // Summarize with the session's own agent; a session of unknown kind is skipped.
            let tool: AgentBoardSummarizer.Tool?
            switch card.digest?.tool ?? card.agentName {
            case "claude", "Claude Code": tool = .claude
            case "codex", "Codex": tool = .codex
            default: tool = nil
            }
            guard let tool else { continue }
            let prompts = card.digest?.prompts.map(\.text) ?? card.prompt.map { [$0] } ?? []
            AgentBoardSummarizer.shared.request(card.id, input: .init(
                tool: tool,
                taskTitle: card.taskHeadline,
                prompts: prompts,
                lastReply: card.digest?.lastReply ?? card.lastMessage
            ))
        }
        // Most recent activity first in every column.
        let sorted = built.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        if sorted != cards {
            cards = sorted
        }
    }

    func cards(in column: AgentBoardColumn) -> [AgentBoardCard] {
        cards.filter { $0.column == column }
    }
}

/// The accordion that drops down above the terminals: one column per agent
/// state, one card per workspace with an agent in it.
struct AgentBoardView: View {
    @ObservedObject var tabManager: TabManager
    @StateObject private var model = AgentBoardModel()
    let onClose: () -> Void

    @AppStorage("agentBoard.height") private var storedHeight: Double = 300
    @AppStorage(AgentBoardSummarizer.enabledKey) private var summariesEnabled = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 10) {
                ForEach(AgentBoardColumn.allCases) { column in
                    columnView(column)
                }
            }
            .padding(10)
        }
        .frame(height: CGFloat(storedHeight))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .overlay(alignment: .bottom) { resizeHandle }
        .onAppear { model.start(tabManager: tabManager) }
        .onDisappear { model.stop() }
        .onExitCommand(perform: onClose)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "agentBoard.accessibilityLabel", defaultValue: "Agent Board"))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.split.3x1")
                .foregroundStyle(.secondary)
            Text(String(localized: "agentBoard.title", defaultValue: "Agent Board"))
                .font(.system(size: 12, weight: .semibold))
            Text(String.localizedStringWithFormat(
                String(localized: "agentBoard.count", defaultValue: "%lld agents"),
                model.cards.count
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            Spacer()
            Toggle(isOn: $summariesEnabled) {
                Image(systemName: "text.badge.star")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help(String(localized: "agentBoard.summaries.tooltip", defaultValue: "Summarize each session with its own agent"))
            .accessibilityLabel(String(localized: "agentBoard.summaries.label", defaultValue: "Summaries"))
            Button(action: onClose) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .help(KeyboardShortcutSettings.Action.toggleAgentBoard.tooltip(
                String(localized: "agentBoard.close.tooltip", defaultValue: "Hide Agent Board")
            ))
            .accessibilityLabel(String(localized: "agentBoard.close.tooltip", defaultValue: "Hide Agent Board"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func columnView(_ column: AgentBoardColumn) -> some View {
        let cards = model.cards(in: column)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: column.symbol)
                    .foregroundStyle(column.tint)
                Text(column.title)
                    .font(.system(size: 11, weight: .semibold))
                Text("\(cards.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 2)
            .accessibilityElement(children: .combine)

            ScrollView(.vertical) {
                LazyVStack(spacing: 6) {
                    if cards.isEmpty {
                        Text(String(localized: "agentBoard.column.empty", defaultValue: "Nothing here"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    ForEach(cards) { card in
                        AgentBoardCardView(
                            card: card,
                            onSelect: { select(card, closing: false) },
                            onOpen: { select(card, closing: true) }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Drag the bottom edge to make the board taller or shorter; the height is remembered.
    private var resizeHandle: some View {
        Color.clear
            .frame(height: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let proposed = storedHeight + value.translation.height - (dragBase ?? 0)
                        dragBase = value.translation.height
                        storedHeight = min(max(proposed, 160), 700)
                    }
                    .onEnded { _ in dragBase = nil }
            )
    }

    @State private var dragBase: CGFloat?

    private func select(_ card: AgentBoardCard, closing: Bool) {
        if let workspace = tabManager.tabs.first(where: { $0.id == card.id }) {
            tabManager.selectWorkspace(workspace)
        }
        if closing { onClose() }
    }
}

private struct AgentBoardCardView: View {
    let card: AgentBoardCard
    let onSelect: () -> Void
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleRow
            if let headline = card.taskHeadline {
                Text(headline)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }
            gist
            footer
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(card.isSelected
                    ? Color.accentColor.opacity(0.16)
                    : Color.primary.opacity(isHovering ? 0.08 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(card.isSelected ? Color.accentColor.opacity(0.6) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // A single click switches at once; the second click of a double-click hides the board.
        .onTapGesture(count: 1, perform: onSelect)
        .simultaneousGesture(TapGesture(count: 2).onEnded(onOpen))
        .contextMenu { contextMenu }
        .help(details)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(String(localized: "agentBoard.card.open", defaultValue: "Go to Workspace")), onSelect)
    }

    /// The one thing to read: Haiku's summary, else the latest prompt, else the
    /// agent's last message. Everything else lives in the tooltip.
    @ViewBuilder
    private var gist: some View {
        if let summary = card.summary {
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(2)
        } else if let text = card.digest?.prompts.first?.text ?? card.prompt ?? card.digest?.lastReply ?? card.lastMessage {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    /// Folder, branch and PR on one quiet line.
    private var footer: some View {
        let parts = [
            card.directory.map(Self.shortPath),
            card.branch.map { card.branchIsDirty ? "\($0) •" : $0 },
            card.pullRequestLabel,
        ].compactMap { $0 }
        return Text(parts.joined(separator: "  ·  "))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// Hover text with the full picture: prompts, reply, path, branch, ports.
    private var details: String {
        var lines: [String] = []
        if let agent = card.agentName { lines.append(agent) }
        if let detail = card.statusDetail { lines.append(detail) }
        let prompts = card.digest?.prompts.map(\.text) ?? card.prompt.map { [$0] } ?? []
        for prompt in prompts {
            lines.append(String.localizedStringWithFormat(
                String(localized: "agentBoard.card.youAsked", defaultValue: "You asked: %@"), prompt
            ))
        }
        if let reply = card.digest?.lastReply ?? card.lastMessage {
            lines.append(String.localizedStringWithFormat(
                String(localized: "agentBoard.card.agentSaid", defaultValue: "Agent said: %@"), reply
            ))
        }
        if let directory = card.directory { lines.append(directory) }
        if !card.ports.isEmpty { lines.append(card.ports.map(String.init).joined(separator: ", ")) }
        if let section = card.sectionName { lines.append(section) }
        lines.append(String(localized: "agentBoard.card.help", defaultValue: "Click to switch to this workspace. Double-click to switch and hide the board."))
        return lines.joined(separator: "\n\n")
    }

    /// The last two folders, which is usually enough to tell repos apart.
    static func shortPath(_ path: String) -> String {
        let components = abbreviated(path).split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 2 else { return abbreviated(path) }
        return "…/" + components.suffix(2).joined(separator: "/")
    }

    private var titleRow: some View {
        HStack(spacing: 5) {
            Text(card.workspaceTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if card.unreadCount > 0 {
                Text("\(min(card.unreadCount, 99))")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(Color.red))
            }
            Spacer(minLength: 4)
            if let date = card.lastActivity {
                Text(date, format: .relative(presentation: .named, unitsStyle: .narrow))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button(String(localized: "agentBoard.card.open", defaultValue: "Go to Workspace"), action: onSelect)
        if let summary = card.summary {
            Button(String(localized: "agentBoard.card.copySummary", defaultValue: "Copy Summary")) {
                Self.copy(summary)
            }
        }
        if let directory = card.directory {
            Divider()
            Button(String(localized: "agentBoard.card.copyPath", defaultValue: "Copy Path")) {
                Self.copy(directory)
            }
            Button(String(localized: "agentBoard.card.revealInFinder", defaultValue: "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
            }
        }
        if let prompt = card.digest?.prompts.first?.text ?? card.prompt {
            Button(String(localized: "agentBoard.card.copyPrompt", defaultValue: "Copy Last Prompt")) {
                Self.copy(prompt)
            }
        }
        if let branch = card.branch {
            Button(String(localized: "agentBoard.card.copyBranch", defaultValue: "Copy Branch Name")) {
                Self.copy(branch)
            }
        }
        if let url = card.pullRequestURL {
            Divider()
            Button(String(localized: "agentBoard.card.openPullRequest", defaultValue: "Open Pull Request")) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
