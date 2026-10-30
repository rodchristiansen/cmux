import Darwin
import Foundation

/// What the sidebar shows from a session's transcript: the last few
/// prompts the user gave, and the agent's latest message.
struct AgentTranscriptDigest: Equatable, Sendable {
    struct Prompt: Equatable, Sendable {
        let text: String
        let date: Date?
    }

    /// Newest first, at most `AgentTranscriptReader.promptLimit`.
    var prompts: [Prompt] = []
    var lastReply: String?
    var lastReplyDate: Date?
    /// "claude" or "codex".
    var tool: String?
    /// The session is running now, or its transcript changed recently, so the
    /// workspace gets a summary even without a status pill.
    var isLive = false

    var isEmpty: Bool { prompts.isEmpty && lastReply == nil }
}

/// Everything needed to find one workspace's transcript, captured on the main
/// actor so the file work can run elsewhere.
struct AgentTranscriptLocator: Sendable {
    let workspaceId: UUID
    /// Paths the hooks reported, any tool.
    let reportedPaths: [String]
    let agentPIDs: [Int32]
    let tmuxSessions: [String]
    let directory: String?
}

/// Reads Claude Code and Codex transcripts. Results are cached per file by size
/// and modification date, so a refresh only re-reads files that grew.
final class AgentTranscriptReader: @unchecked Sendable {
    static let shared = AgentTranscriptReader()
    static let promptLimit = 3

    private struct CacheEntry {
        /// Bytes parsed so far, always ending on a line break.
        let consumed: UInt64
        let modified: Date
        let digest: AgentTranscriptDigest
    }

    private struct ClaudeLiveSession {
        let pid: Int32
        let sessionId: String
        let cwd: String
        let tmuxSession: String?
        let startedAt: Double
    }

    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private let fileManager = FileManager.default
    private let home = NSHomeDirectory()

    func digests(for locators: [AgentTranscriptLocator]) -> [UUID: AgentTranscriptDigest] {
        lock.lock()
        defer { lock.unlock() }
        let liveClaude = loadClaudeLiveSessions()
        var claimedByCwd: [String: Int] = [:]
        for session in liveClaude { claimedByCwd[session.cwd, default: 0] += 1 }

        let resolved = locators.compactMap { locator -> (UUID, Resolution)? in
            resolve(locator, liveClaude: liveClaude, claimedByCwd: claimedByCwd).map { (locator.workspaceId, $0) }
        }
        // A session matched only by directory is ambiguous when several workspaces
        // share that directory, or when another workspace owns it outright.
        let firmSessions = Set(resolved.compactMap { $0.1.isDirectoryGuess ? nil : $0.1.path })
        var guessCounts: [String: Int] = [:]
        for (_, resolution) in resolved where resolution.isDirectoryGuess {
            guessCounts[resolution.path, default: 0] += 1
        }

        var result: [UUID: AgentTranscriptDigest] = [:]
        for (workspaceId, resolution) in resolved {
            if resolution.isDirectoryGuess,
               firmSessions.contains(resolution.path) || guessCounts[resolution.path, default: 0] > 1 {
                continue
            }
            guard var digest = digest(atPath: resolution.path), !digest.isEmpty else { continue }
            digest.tool = resolution.path.contains("/.codex/") ? "codex" : "claude"
            digest.isLive = resolution.isRunning
                || (modificationDate(resolution.path).map { Date().timeIntervalSince($0) < 12 * 3600 } ?? false)
            result[workspaceId] = digest
        }
        return result
    }

    private struct Resolution {
        let path: String
        let isRunning: Bool
        let isDirectoryGuess: Bool
    }

    // MARK: - Finding the transcript

    private func resolve(
        _ locator: AgentTranscriptLocator,
        liveClaude: [ClaudeLiveSession],
        claimedByCwd: [String: Int]
    ) -> Resolution? {
        // A hook-reported file wins; with two (Claude and Codex), the busier one.
        let reported = locator.reportedPaths
            .compactMap { path -> (String, Date)? in
                guard let date = modificationDate(path) else { return nil }
                return (path, date)
            }
            .max { $0.1 < $1.1 }
        if let reported { return Resolution(path: reported.0, isRunning: false, isDirectoryGuess: false) }

        // Otherwise find a live Claude Code session by its PID, its tmux session,
        // or, when exactly one live session runs there, its directory.
        let byPID = liveClaude.first { locator.agentPIDs.contains($0.pid) }
        let byTmux = byPID == nil
            ? liveClaude.first { session in
                guard let name = session.tmuxSession else { return false }
                return locator.tmuxSessions.contains(name)
            }
            : nil
        let byDirectory: ClaudeLiveSession? = {
            guard byPID == nil, byTmux == nil,
                  let directory = locator.directory,
                  claimedByCwd[directory] == 1 else { return nil }
            return liveClaude.first { $0.cwd == directory }
        }()
        guard let session = byPID ?? byTmux ?? byDirectory,
              let path = claudeTranscriptPath(sessionId: session.sessionId, cwd: session.cwd) else { return nil }
        return Resolution(path: path, isRunning: true, isDirectoryGuess: byPID == nil && byTmux == nil)
    }

    /// Claude Code writes `~/.claude/sessions/<pid>.json` for every running session.
    private func loadClaudeLiveSessions() -> [ClaudeLiveSession] {
        let directory = (home as NSString).appendingPathComponent(".claude/sessions")
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return [] }
        return names.compactMap { name -> ClaudeLiveSession? in
            guard name.hasSuffix(".json"),
                  let data = fileManager.contents(atPath: (directory as NSString).appendingPathComponent(name)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pidValue = object["pid"] as? Int,
                  let sessionId = object["sessionId"] as? String,
                  let cwd = object["cwd"] as? String else { return nil }
            let pid = Int32(pidValue)
            guard pid > 0, kill(pid, 0) == 0 else { return nil }
            let tmux = (object["tmux"] as? String)?.split(separator: ":").first.map(String.init)
            return ClaudeLiveSession(
                pid: pid,
                sessionId: sessionId,
                cwd: cwd,
                tmuxSession: tmux,
                startedAt: object["startedAt"] as? Double ?? 0
            )
        }
    }

    private func claudeTranscriptPath(sessionId: String, cwd: String) -> String? {
        let slug = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let projects = (home as NSString).appendingPathComponent(".claude/projects")
        let direct = "\(projects)/\(slug)/\(sessionId).jsonl"
        if fileManager.fileExists(atPath: direct) { return direct }
        guard let folders = try? fileManager.contentsOfDirectory(atPath: projects) else { return nil }
        for folder in folders {
            let candidate = "\(projects)/\(folder)/\(sessionId).jsonl"
            if fileManager.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    private func modificationDate(_ path: String) -> Date? {
        (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    // MARK: - Reading

    private func digest(atPath path: String) -> AgentTranscriptDigest? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let cached = cache[path]
        if let cached, cached.modified == modified, cached.consumed <= size {
            return cached.digest
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        // A file that only grew: parse just the new lines and fold them in.
        if let cached, cached.consumed <= size {
            guard (try? handle.seek(toOffset: cached.consumed)) != nil,
                  let data = try? handle.readToEnd() else { return cached.digest }
            let complete = Self.completeLines(data)
            let update = Self.parse(complete, startsMidLine: false)
            let digest = Self.merge(cached.digest, with: update)
            cache[path] = CacheEntry(
                consumed: cached.consumed + UInt64(complete.count),
                modified: modified,
                digest: digest
            )
            return digest
        }

        // First read: the end of the file, widening the window until it holds
        // enough prompts (a long turn can push them far back).
        var digest = AgentTranscriptDigest()
        var consumed: UInt64 = 0
        for window: UInt64 in [2 << 20, 24 << 20] {
            let start = size > window ? size - window : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.readToEnd() else { return nil }
            let complete = Self.completeLines(data)
            digest = Self.parse(complete, startsMidLine: start > 0)
            consumed = start + UInt64(complete.count)
            if digest.prompts.count >= Self.promptLimit || start == 0 { break }
        }
        cache[path] = CacheEntry(consumed: consumed, modified: modified, digest: digest)
        return digest
    }

    /// Drops a trailing line the agent has not finished writing.
    private static func completeLines(_ data: Data) -> Data {
        guard let lastBreak = data.lastIndex(of: UInt8(ascii: "\n")) else { return Data() }
        return data[data.startIndex...lastBreak]
    }

    /// Newer prompts go in front; a newer reply replaces the old one.
    private static func merge(_ old: AgentTranscriptDigest, with new: AgentTranscriptDigest) -> AgentTranscriptDigest {
        var chronological = Array(old.prompts.reversed())
        for prompt in new.prompts.reversed() {
            appendPrompt(prompt.text, date: prompt.date, to: &chronological)
        }
        return AgentTranscriptDigest(
            prompts: Array(chronological.suffix(promptLimit).reversed()),
            lastReply: new.lastReply ?? old.lastReply,
            lastReplyDate: new.lastReply != nil ? new.lastReplyDate : old.lastReplyDate
        )
    }

    static func parse(_ data: Data, startsMidLine: Bool) -> AgentTranscriptDigest {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if startsMidLine, !lines.isEmpty { lines.removeFirst() }

        var prompts: [AgentTranscriptDigest.Prompt] = []
        var lastReply: String?
        var lastReplyDate: Date?

        for line in lines {
            // Large records are mostly API request blobs and tool output; decode one
            // only when it is a user record, which is how a pasted image arrives.
            guard line.count < 400_000 || isLargeUserRecord(line),
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            var date: Date? { (object["timestamp"] as? String).flatMap(parseDate) }
            switch type {
            case "user":
                guard object["isMeta"] as? Bool != true,
                      object["isSidechain"] as? Bool != true,
                      object["isCompactSummary"] as? Bool != true,
                      let message = object["message"] as? [String: Any],
                      let text = claudeUserText(message["content"]) else { continue }
                appendPrompt(text, date: date, to: &prompts)
            case "queue-operation":
                // A message typed while the agent was working.
                guard object["operation"] as? String == "enqueue",
                      let text = object["content"] as? String,
                      let cleaned = cleanedPrompt(text) else { continue }
                appendPrompt(cleaned, date: date, to: &prompts)
            case "assistant":
                guard object["isSidechain"] as? Bool != true,
                      let message = object["message"] as? [String: Any],
                      let blocks = message["content"] as? [[String: Any]] else { continue }
                let text = blocks
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: " ")
                if let reply = cleanedReply(text) {
                    lastReply = reply
                    lastReplyDate = date
                }
            case "response_item":
                guard let payload = object["payload"] as? [String: Any],
                      payload["type"] as? String == "message",
                      let role = payload["role"] as? String,
                      let content = payload["content"] as? [[String: Any]] else { continue }
                let texts = content.compactMap { $0["text"] as? String }
                if role == "user" {
                    let text = texts.filter { !isCodexContextBlock($0) }.joined(separator: " ")
                    if let cleaned = cleanedPrompt(text) {
                        appendPrompt(cleaned, date: date, to: &prompts)
                    }
                } else if role == "assistant", let reply = cleanedReply(texts.joined(separator: " ")) {
                    lastReply = reply
                    lastReplyDate = date
                }
            default:
                continue
            }
        }

        return AgentTranscriptDigest(
            prompts: Array(prompts.suffix(promptLimit).reversed()),
            lastReply: lastReply,
            lastReplyDate: lastReplyDate
        )
    }

    private static let userTypeMarker = Data(#""type":"user""#.utf8)
    private static let requestMarker = Data(#""type":"api-request"#.utf8)

    private static func isLargeUserRecord(_ line: Data.SubSequence) -> Bool {
        guard line.count < 32 << 20 else { return false }
        let head = line.prefix(512)
        return head.range(of: requestMarker) == nil && line.range(of: userTypeMarker) != nil
    }

    private static func claudeUserText(_ content: Any?) -> String? {
        if let text = content as? String { return cleanedPrompt(text) }
        guard let blocks = content as? [[String: Any]] else { return nil }
        // Tool results come back as user records; they are not prompts.
        if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .filter { !$0.hasPrefix("<") }
            .joined(separator: " ")
        return cleanedPrompt(text)
    }

    private static func isCodexContextBlock(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<") || trimmed.hasPrefix("# AGENTS.md instructions")
    }

    /// The same prompt can land twice (a queued message, then its user record),
    /// and a partial record can precede the full one.
    private static func appendPrompt(_ text: String, date: Date?, to prompts: inout [AgentTranscriptDigest.Prompt]) {
        if let last = prompts.last {
            if last.text == text || text.hasPrefix(last.text) {
                prompts[prompts.count - 1] = .init(text: text, date: date ?? last.date)
                return
            }
            if last.text.hasPrefix(text) { return }
        }
        prompts.append(.init(text: text, date: date))
    }

    static func cleanedPrompt(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("<"),
              !trimmed.hasPrefix("Caveat:"),
              !trimmed.hasPrefix("This session is being continued from a previous conversation"),
              !trimmed.hasPrefix("[Request interrupted") else { return nil }
        let withoutImages = trimmed.replacingOccurrences(
            of: #"\[Image #\d+\]"#, with: "", options: .regularExpression
        )
        return condensed(withoutImages, limit: 240)
    }

    static func cleanedReply(_ raw: String) -> String? {
        let plain = raw
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
        return condensed(plain, limit: 320)
    }

    private static func condensed(_ text: String, limit: Int) -> String? {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainDateFormatter = ISO8601DateFormatter()

    private static func parseDate(_ string: String) -> Date? {
        fractionalDateFormatter.date(from: string) ?? plainDateFormatter.date(from: string)
    }
}
