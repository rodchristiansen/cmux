import Bonsplit
import Combine
import CryptoKit
import Foundation

/// Writes the one-line status on each agent board card ("Checking whether the
/// Kerberos claims are verified before the report goes out") by asking Claude
/// Haiku through the user's own `claude` CLI. Summaries are cached on disk by
/// the conversation they describe, so a relaunch does not regenerate them.
@MainActor
final class AgentBoardSummarizer: ObservableObject {
    static let shared = AgentBoardSummarizer()
    static let enabledKey = "agentBoard.summaries"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    struct Input: Equatable {
        let taskTitle: String?
        let prompts: [String]
        let lastReply: String?

        /// Changes when the user asks something new; a reply alone changes it too,
        /// but those refreshes are rate-limited while an agent is working.
        var key: String {
            let joined = ([taskTitle ?? ""] + prompts + [lastReply ?? ""]).joined(separator: "\u{1F}")
            return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    private struct Entry: Codable {
        var key: String
        var latestPrompt: String
        var text: String
        var generatedAt: Date
    }

    @Published private(set) var summaries: [UUID: String] = [:]

    private var entries: [UUID: Entry] = [:]
    private var pending: [UUID: Input] = [:]
    private var running: Set<UUID> = []
    private var failedUntil: Date?
    private let maxConcurrent = 2
    /// While an agent works its reply changes constantly; re-summarize at most this often.
    private let replyRefreshInterval: TimeInterval = 180

    private init() {
        load()
    }

    /// Asks for a summary when the conversation moved on since the last one.
    func request(_ workspaceId: UUID, input: Input) {
        guard Self.isEnabled, !input.prompts.isEmpty || input.lastReply != nil else { return }
        let key = input.key
        if let entry = entries[workspaceId] {
            if entry.key == key { return }
            let samePrompt = entry.latestPrompt == (input.prompts.first ?? "")
            if samePrompt, Date().timeIntervalSince(entry.generatedAt) < replyRefreshInterval { return }
        }
        pending[workspaceId] = input
#if DEBUG
        dlog("agentBoard.summary.queue workspace=\(workspaceId.uuidString.prefix(8)) pending=\(pending.count)")
#endif
        drain()
    }

    private func drain() {
        if let failedUntil, failedUntil > Date() { return }
        while running.count < maxConcurrent, let (workspaceId, input) = pending.first(where: { !running.contains($0.key) }) {
            pending.removeValue(forKey: workspaceId)
            running.insert(workspaceId)
            let prompt = Self.prompt(for: input)
            Task.detached(priority: .utility) { [weak self] in
                let text = await Self.runClaude(prompt)
                await MainActor.run {
                    self?.finish(workspaceId, input: input, text: text)
                }
            }
        }
    }

    private func finish(_ workspaceId: UUID, input: Input, text: String?) {
        running.remove(workspaceId)
#if DEBUG
        dlog("agentBoard.summary.done workspace=\(workspaceId.uuidString.prefix(8)) ok=\(text != nil)")
#endif
        if let text {
            entries[workspaceId] = Entry(
                key: input.key,
                latestPrompt: input.prompts.first ?? "",
                text: text,
                generatedAt: Date()
            )
            summaries[workspaceId] = text
            save()
        } else {
            // Not signed in, rate-limited, or no CLI: back off instead of retrying every refresh.
            failedUntil = Date().addingTimeInterval(600)
        }
        drain()
    }

    // MARK: - Claude CLI

    private static func prompt(for input: Input) -> String {
        var lines = [
            "You write status lines for a board of coding-agent sessions.",
            "In one plain sentence of at most 14 words, say what the user wants and where it stands.",
            "No preamble, no quotes, no markdown.",
            "",
        ]
        if let title = input.taskTitle { lines.append("Task title: \(title)") }
        if !input.prompts.isEmpty {
            lines.append("Recent requests, newest first:")
            lines.append(contentsOf: input.prompts.map { "- \($0)" })
        }
        if let reply = input.lastReply { lines.append("Latest agent message: \(reply)") }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func runClaude(_ prompt: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runClaudeBlocking(prompt))
            }
        }
    }

    nonisolated private static func runClaudeBlocking(_ prompt: String) -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        // Local settings only, so the user's hooks (and cmux's) do not run for this call.
        process.arguments = [
            "-p", "--model", "haiku",
            "--setting-sources", "local",
            "--no-session-persistence",
            "--tools", "",
        ]
        let environment = ProcessInfo.processInfo.environment
        // A clean environment: no CMUX_* variables tying the call to a workspace.
        process.environment = [
            "HOME": home,
            "USER": environment["USER"] ?? NSUserName(),
            "LOGNAME": environment["LOGNAME"] ?? NSUserName(),
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()

        if finished.wait(timeout: .now() + 60) == .timedOut {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return cleaned(raw)
    }

    nonisolated static func cleaned(_ raw: String) -> String? {
        guard let line = raw
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        let lowered = line.lowercased()
        let failureMarkers = ["/login", "not logged in", "invalid api key", "rate limit", "usage limit", "hit your limit"]
        if failureMarkers.contains(where: lowered.contains) || lowered.hasPrefix("api error") || lowered.hasPrefix("error:") {
            return nil
        }
        let unquoted = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”*` "))
        guard !unquoted.isEmpty else { return nil }
        return unquoted.count > 180 ? String(unquoted.prefix(180)) + "…" : unquoted
    }

    // MARK: - Cache

    private static var cacheURL: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "cmux", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("agent-board-summaries.json")
    }

    private func load() {
        guard let url = Self.cacheURL,
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        for (id, entry) in stored {
            guard let uuid = UUID(uuidString: id) else { continue }
            entries[uuid] = entry
            summaries[uuid] = entry.text
        }
    }

    private func save() {
        guard let url = Self.cacheURL else { return }
        // Keep the newest few hundred so closed workspaces do not pile up forever.
        let kept = entries.sorted { $0.value.generatedAt > $1.value.generatedAt }.prefix(300)
        let stored = Dictionary(uniqueKeysWithValues: kept.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
