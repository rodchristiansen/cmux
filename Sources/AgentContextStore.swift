import Bonsplit
import Combine
import Foundation

/// What a workspace's agent session is about, for its sidebar row: a one-line
/// summary from the session's own agent, and the prompts and reply behind it.
struct AgentSessionContext: Equatable {
    var summary: String?
    /// Newest first.
    var prompts: [String]
    var lastReply: String?

    /// Hover text: what was asked and what the agent said last.
    var details: String? {
        var lines: [String] = []
        if let summary { lines.append(summary) }
        for prompt in prompts {
            lines.append(String.localizedStringWithFormat(
                String(localized: "sidebar.agent.youAsked", defaultValue: "You asked: %@"),
                Self.clipped(prompt)
            ))
        }
        if let lastReply {
            lines.append(String.localizedStringWithFormat(
                String(localized: "sidebar.agent.agentSaid", defaultValue: "Agent said: %@"),
                Self.clipped(lastReply)
            ))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }

    /// Text the sidebar search also matches against.
    var searchText: String {
        ([summary].compactMap { $0 } + prompts).joined(separator: "\n")
    }

    private static func clipped(_ text: String) -> String {
        text.count > 300 ? String(text.prefix(300)) + "…" : text
    }
}

/// Keeps `AgentSessionContext` current for every agent workspace in one window.
/// It reads transcripts off the main thread every few seconds (unchanged files
/// are not re-read) and asks `AgentSummarizer` for a new line when a
/// conversation moves on.
@MainActor
final class AgentContextStore: ObservableObject {
    @Published private(set) var contexts: [UUID: AgentSessionContext] = [:]

    private weak var tabManager: TabManager?
    private var cancellables = Set<AnyCancellable>()
    private var digests: [UUID: AgentTranscriptDigest] = [:]
    private var isReadingTranscripts = false

    func start(tabManager: TabManager) {
        guard self.tabManager !== tabManager || cancellables.isEmpty else { return }
        stop()
        self.tabManager = tabManager
        tabManager.$tabs
            .map { $0.map(\.id) }
            .removeDuplicates()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        AgentSummarizer.shared.$summaries
            .dropFirst()
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        // Prompts, replies and liveness change with no event to announce them.
        Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
    }

    private func refresh() {
        rebuild()
        readTranscripts()
    }

    /// The focused pane's directory, else the workspace's.
    static func directory(of workspace: Workspace) -> String? {
        if let focused = workspace.focusedPanelId,
           let dir = workspace.panelDirectories[focused]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dir.isEmpty {
            return dir
        }
        let dir = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.isEmpty ? nil : dir
    }

    private func readTranscripts() {
        guard let tabManager, !isReadingTranscripts else { return }
        // Every workspace: finding a live session is what gives a workspace
        // with no status pill its summary.
        let locators = tabManager.tabs.map { workspace -> AgentTranscriptLocator in
            var tmux = Set(workspace.ownedTmuxSessions)
            tmux.formUnion(workspace.detachedLanes.map(\.session))
            return AgentTranscriptLocator(
                workspaceId: workspace.id,
                reportedPaths: Array(workspace.agentTranscripts.values),
                agentPIDs: Array(workspace.agentPIDs.values) + workspace.detachedLanes.map(\.panePID),
                tmuxSessions: Array(tmux),
                directory: Self.directory(of: workspace)
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
                    self.rebuild()
                }
            }
        }
    }

    private func rebuild() {
        guard let tabManager else { return }
        let summariesOn = AgentSummarizer.isEnabled
        var next: [UUID: AgentSessionContext] = [:]
        for workspace in tabManager.tabs {
            let digest = digests[workspace.id]
            let agentEntries = workspace.statusEntries.values.filter(\.isAgentStatus)
            let lanes = workspace.visibleDetachedLanes
            guard !agentEntries.isEmpty || workspace.hasAttachedAgentSession || !lanes.isEmpty || digest?.isLive == true else {
                continue
            }
            let prompts = digest?.prompts.map(\.text) ?? workspace.agentPrompt.map { [$0.text] } ?? []
            let lastReply = digest?.lastReply ?? Self.notificationText(for: workspace.id)
            guard !prompts.isEmpty || lastReply != nil else { continue }

            if summariesOn, let tool = Self.tool(entries: agentEntries, digest: digest, lanes: lanes) {
                let title = workspace.customDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
                AgentSummarizer.shared.request(workspace.id, input: .init(
                    tool: tool,
                    taskTitle: (title?.isEmpty ?? true) ? nil : title,
                    prompts: prompts,
                    lastReply: lastReply
                ))
            }
            next[workspace.id] = AgentSessionContext(
                summary: summariesOn ? AgentSummarizer.shared.summaries[workspace.id] : nil,
                prompts: prompts,
                lastReply: lastReply
            )
        }
        if next != contexts {
#if DEBUG
            dlog("agentContext.rebuild count=\(next.count) digests=\(digests.count)")
#endif
            contexts = next
        }
    }

    /// Summarize with the session's own agent; a session of unknown kind is skipped.
    private static func tool(
        entries: [SidebarStatusEntry],
        digest: AgentTranscriptDigest?,
        lanes: [TmuxSessionReaper.DetachedLane]
    ) -> AgentSummarizer.Tool? {
        let latest = entries.max { $0.timestamp < $1.timestamp }?.key
        switch latest {
        case "claude_code": return .claude
        case "codex": return .codex
        default: break
        }
        switch digest?.tool {
        case "claude": return .claude
        case "codex": return .codex
        default: return lanes.first.map { $0.isCodex ? .codex : .claude }
        }
    }

    private static func notificationText(for workspaceId: UUID) -> String? {
        guard let notification = TerminalNotificationStore.shared.latestNotification(forTabId: workspaceId) else {
            return nil
        }
        let parts = [notification.subtitle, notification.body]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }
}
