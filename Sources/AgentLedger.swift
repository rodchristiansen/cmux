import AppKit
import Combine
import Foundation

/// One pull request an agent posted, with what GitHub says about it.
struct AgentPullRequest: Equatable, Identifiable {
    enum State: String {
        case open = "OPEN"
        case merged = "MERGED"
        case closed = "CLOSED"
        case draft = "DRAFT"
    }

    let url: String
    var title: String?
    var state: State?

    var id: String { url }

    /// "cmux#74", or the Azure DevOps repo name and number.
    var shortName: String {
        let parts = url.split(separator: "/").map(String.init)
        if url.contains("github.com"), parts.count >= 6 {
            return "\(parts[3])#\(parts[parts.count - 1])"
        }
        if let git = parts.firstIndex(of: "_git"), git + 1 < parts.count {
            let repo = parts[git + 1].removingPercentEncoding ?? parts[git + 1]
            return "\(repo)!\(parts[parts.count - 1])"
        }
        return url
    }

    var stateLabel: String? {
        switch state {
        case .open: return String(localized: "agentLedger.state.open", defaultValue: "Open")
        case .merged: return String(localized: "agentLedger.state.merged", defaultValue: "Merged")
        case .closed: return String(localized: "agentLedger.state.closed", defaultValue: "Closed")
        case .draft: return String(localized: "agentLedger.state.draft", defaultValue: "Draft")
        case nil: return nil
        }
    }

    /// "#74 Move agent summaries into the sidebar — Merged"
    var menuTitle: String {
        var text = shortName
        if let title { text += " " + title }
        if let stateLabel { text += " — " + stateLabel }
        return text
    }
}

/// Looks up the title and state of pull requests agents posted. GitHub links go
/// through `gh`; an open one is checked again after a few minutes, a merged or
/// closed one never. Azure DevOps links are listed without a state.
@MainActor
final class AgentPullRequestStatusStore: ObservableObject {
    static let shared = AgentPullRequestStatusStore()

    @Published private(set) var info: [String: AgentPullRequest] = [:]

    private var checkedAt: [String: Date] = [:]
    private var inFlight = Set<String>()
    private var seeded = false
    private let queue = DispatchQueue(label: "cmux.agentLedger.gh", qos: .utility)
    private static let openRecheckInterval: TimeInterval = 300

    func pullRequests(for urls: [String]) -> [AgentPullRequest] {
        urls.map { info[$0] ?? AgentPullRequest(url: $0) }
    }

    func request(_ urls: [String]) {
        seedIfNeeded()
        let now = Date()
        for url in urls where url.contains("github.com") && !inFlight.contains(url) {
            if let known = info[url]?.state, known == .merged || known == .closed { continue }
            if let last = checkedAt[url], now.timeIntervalSince(last) < Self.openRecheckInterval { continue }
            inFlight.insert(url)
            checkedAt[url] = now
            queue.async { [weak self] in
                let fetched = Self.fetch(url)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.inFlight.remove(url)
                    if let fetched, self.info[url] != fetched { self.info[url] = fetched }
                }
            }
        }
    }

    /// The Claude Code statusline keeps PR states in `~/.claude/gh-pr-status-cache.json`;
    /// starting from it saves a `gh` call per merged PR.
    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/gh-pr-status-cache.json")
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return }
        for (url, entry) in object {
            guard let state = (entry["state"] as? String).flatMap(AgentPullRequest.State.init(rawValue:)),
                  state == .merged || state == .closed else { continue }
            info[url] = AgentPullRequest(url: url, title: entry["title"] as? String, state: state)
        }
    }

    private nonisolated static func fetch(_ url: String) -> AgentPullRequest? {
        guard let output = TabManager.runCommand(
            directory: NSHomeDirectory(),
            executable: "gh",
            arguments: ["pr", "view", url, "--json", "title,state,isDraft"],
            timeout: 15
        ),
            let data = output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var state = (object["state"] as? String).flatMap(AgentPullRequest.State.init(rawValue:))
        if state == .open, object["isDraft"] as? Bool == true { state = .draft }
        return AgentPullRequest(url: url, title: object["title"] as? String, state: state)
    }
}
