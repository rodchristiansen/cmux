import AppKit
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

    @MainActor
    static func make(
        workspace: Workspace,
        tabManager: TabManager,
        notificationStore: TerminalNotificationStore,
        digest: AgentTranscriptDigest?
    ) -> AgentBoardCard? {
        let agentEntries = workspace.statusEntries.values.filter(\.isAgentStatus)
        let hasSession = workspace.hasAttachedAgentSession
        guard !agentEntries.isEmpty || hasSession else { return nil }

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
            default: return nil
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

        let directory: String? = {
            if let focused = workspace.focusedPanelId,
               let dir = workspace.panelDirectories[focused]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !dir.isEmpty {
                return dir
            }
            let dir = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            return dir.isEmpty ? nil : dir
        }()

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
            digest: digest
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
        let locators = tabManager.tabs.compactMap { workspace -> AgentTranscriptLocator? in
            guard cards.contains(where: { $0.id == workspace.id }) else { return nil }
            var tmux = Set(workspace.ownedTmuxSessions)
            tmux.formUnion(workspace.detachedLanes.map(\.session))
            return AgentTranscriptLocator(
                workspaceId: workspace.id,
                reportedPaths: Array(workspace.agentTranscripts.values),
                agentPIDs: Array(workspace.agentPIDs.values) + workspace.detachedLanes.map(\.panePID),
                tmuxSessions: Array(tmux),
                directory: cards.first(where: { $0.id == workspace.id })?.directory
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
                digest: digests[$0.id]
            )
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
            conversation
            if let detail = card.statusDetail {
                labeled(symbol: "gearshape", text: detail, lines: 1)
            }
            contextRow
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
        .help(String(localized: "agentBoard.card.help", defaultValue: "Click to switch to this workspace. Double-click to switch and hide the board."))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(String(localized: "agentBoard.card.open", defaultValue: "Go to Workspace")), onSelect)
    }

    /// What you last asked, newest first, then what the agent last said.
    @ViewBuilder
    private var conversation: some View {
        let prompts = card.digest?.prompts ?? []
        if prompts.isEmpty, let prompt = card.prompt {
            promptRow(prompt, date: nil, isLatest: true)
        }
        ForEach(Array(prompts.enumerated()), id: \.offset) { index, prompt in
            promptRow(prompt.text, date: prompt.date, isLatest: index == 0)
        }
        if let reply = card.digest?.lastReply ?? card.lastMessage {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "sparkle")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 11)
                Text(reply)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .padding(.top, 1)
            .help(reply)
            .accessibilityLabel(Text(String.localizedStringWithFormat(
                String(localized: "agentBoard.card.agentSaid", defaultValue: "Agent said: %@"), reply
            )))
        }
    }

    private func promptRow(_ text: String, date: Date?, isLatest: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "person.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 11)
                .opacity(isLatest ? 1 : 0)
            Text(text)
                .font(.system(size: 11, weight: isLatest ? .medium : .regular))
                .foregroundStyle(isLatest ? Color.primary : Color.secondary)
                .lineLimit(isLatest ? 2 : 1)
            Spacer(minLength: 2)
            if let date {
                Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .help(text)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(String.localizedStringWithFormat(
            String(localized: "agentBoard.card.youAsked", defaultValue: "You asked: %@"), text
        )))
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

    private var contextRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let directory = card.directory {
                labeled(symbol: "folder", text: Self.abbreviated(directory), lines: 1, middle: true)
                    .help(directory)
            }
            HStack(spacing: 8) {
                if let agent = card.agentName {
                    chip(symbol: "sparkles", text: agent)
                }
                if let branch = card.branch {
                    chip(symbol: "arrow.triangle.branch", text: card.branchIsDirty ? "\(branch) •" : branch)
                }
                if let pr = card.pullRequestLabel {
                    chip(symbol: Self.pullRequestSymbol(card.pullRequestStatus), text: pr)
                }
                if !card.ports.isEmpty {
                    chip(symbol: "network", text: card.ports.prefix(3).map(String.init).joined(separator: ", "))
                }
                if let section = card.sectionName {
                    chip(symbol: "square.stack", text: section)
                }
            }
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button(String(localized: "agentBoard.card.open", defaultValue: "Go to Workspace"), action: onSelect)
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

    private func labeled(symbol: String, text: String, lines: Int, middle: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 11)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(lines)
                .truncationMode(middle ? .middle : .tail)
        }
    }

    private func chip(symbol: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10))
                .truncationMode(.middle)
        }
        .foregroundStyle(.secondary)
    }

    private static func pullRequestSymbol(_ status: SidebarPullRequestStatus?) -> String {
        switch status {
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        default: return "arrow.triangle.pull"
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
