import Bonsplit
import Combine
import CryptoKit
import Foundation

/// Writes the one-line summary under each agent workspace in the sidebar
/// ("Checking whether the Kerberos claims are verified before the report goes
/// out") by asking the session's own agent CLI. Summaries are cached on disk by
/// the conversation they describe, so a relaunch does not regenerate them.
@MainActor
final class AgentSummarizer: ObservableObject {
    static let shared = AgentSummarizer()
    static let enabledKey = "sidebarShowAgentSummary"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The CLI that summarizes a session: always the one that runs it.
    enum Tool: String {
        case claude
        case codex
    }

    struct Input: Equatable {
        let tool: Tool
        let taskTitle: String?
        let prompts: [String]
        let lastReply: String?

        /// Changes when the user asks something new; a reply alone changes it too,
        /// but those refreshes are rate-limited while an agent is working.
        var key: String {
            let joined = ([tool.rawValue, taskTitle ?? ""] + prompts + [lastReply ?? ""]).joined(separator: "\u{1F}")
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
    /// A tool that just failed (not signed in, rate-limited, missing) rests a while.
    private var failedUntil: [Tool: Date] = [:]
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
        dlog("agentSummary.queue workspace=\(workspaceId.uuidString.prefix(8)) pending=\(pending.count)")
#endif
        drain()
    }

    private func drain() {
        let now = Date()
        let isResting: (Tool) -> Bool = { [failedUntil] tool in (failedUntil[tool] ?? .distantPast) > now }
        while running.count < maxConcurrent,
              let (workspaceId, input) = pending.first(where: { !running.contains($0.key) && !isResting($0.value.tool) }) {
            pending.removeValue(forKey: workspaceId)
            running.insert(workspaceId)
            let prompt = Self.prompt(for: input)
            Task.detached(priority: .utility) { [weak self] in
                let text = await Self.run(input.tool, prompt: prompt)
                await MainActor.run {
                    self?.finish(workspaceId, input: input, text: text)
                }
            }
        }
    }

    private func finish(_ workspaceId: UUID, input: Input, text: String?) {
        running.remove(workspaceId)
#if DEBUG
        dlog("agentSummary.done workspace=\(workspaceId.uuidString.prefix(8)) ok=\(text != nil)")
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
            failedUntil[input.tool] = Date().addingTimeInterval(600)
        }
        drain()
    }

    // MARK: - Agent CLIs

    private static func prompt(for input: Input) -> String {
        var lines = [
            "You write status lines for a sidebar of coding-agent sessions.",
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

    nonisolated private static func run(_ tool: Tool, prompt: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(tool, prompt: prompt))
            }
        }
    }

    nonisolated private static func executable(for tool: Tool) -> String? {
        let home = NSHomeDirectory()
        let name = tool.rawValue
        let candidates = [
            "\(home)/.local/bin/\(name)",
            "\(home)/.claude/local/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs the session's own CLI, so a Claude session is summarized by Claude and
    /// a Codex session by Codex: the conversation never goes to the other vendor.
    nonisolated private static func runBlocking(_ tool: Tool, prompt: String) -> String? {
        guard let path = executable(for: tool) else { return nil }
        let home = NSHomeDirectory()
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-agent-summary-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let codexOutput = scratch.appendingPathComponent("summary.txt")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        switch tool {
        case .claude:
            // Local settings only, so the user's hooks (and cmux's) do not run for this call.
            process.arguments = [
                "-p", "--model", "haiku",
                "--setting-sources", "local",
                "--no-session-persistence",
                "--tools", "",
            ]
        case .codex:
            // No user config, hooks or saved session; read-only and low effort.
            process.arguments = [
                "exec", "--ignore-user-config", "--ephemeral", "--skip-git-repo-check",
                "--sandbox", "read-only",
                "-c", "model_reasoning_effort=\"low\"",
                "-c", "features.hooks=false",
                "--output-last-message", codexOutput.path,
                "-",
            ]
        }
        let environment = ProcessInfo.processInfo.environment
        // A clean environment: no CMUX_* variables tying the call to a workspace.
        process.environment = [
            "HOME": home,
            "USER": environment["USER"] ?? NSUserName(),
            "LOGNAME": environment["LOGNAME"] ?? NSUserName(),
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        ]
        process.currentDirectoryURL = scratch
        let input = Pipe()
        // Output goes to a file, not a pipe, so a hung CLI cannot block the read past the timeout.
        let stdoutFile = scratch.appendingPathComponent("stdout.txt")
        FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: stdoutFile) else { return nil }
        defer { try? output.close() }
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
        if finished.wait(timeout: .now() + 90) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let raw: String?
        switch tool {
        case .claude: raw = try? String(contentsOf: stdoutFile, encoding: .utf8)
        case .codex: raw = try? String(contentsOf: codexOutput, encoding: .utf8)
        }
        return raw.flatMap(cleaned)
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
        let url = folder.appendingPathComponent("agent-summaries.json")
        // Keep summaries written under the old name rather than regenerating them.
        let legacy = folder.appendingPathComponent("agent-board-summaries.json")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.moveItem(at: legacy, to: url)
        }
        return url
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
