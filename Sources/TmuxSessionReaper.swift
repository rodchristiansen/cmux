import Foundation

/// Lifecycle for tmux sessions that cmux workspaces own.
///
/// Launcher scripts that wrap an agent in a persistent `tmux new-session -A` (see
/// `claude-remote`) register the session name against their workspace with
/// `cmux set-tmux-session`. That registration is what makes the session *owned*:
///
/// - Closing the workspace deliberately kills the session, so the agent inside it
///   does not stay resident forever holding its whole heap.
/// - A session nobody registered is never touched.
/// - A cmux crash never runs `closeWorkspace`, so crash-resilient reattach — the
///   reason those wrappers use `new-session -A` in the first place — still works.
///
/// `prune` is the reconcile pass behind the "Clear Orphaned tmux Sessions" command:
/// every live session that no open workspace claims is an orphan. cmux is the only
/// thing that can compute this correctly, because the session name is derived from
/// the workspace's directory *and* its instance index, and the instance index is not
/// recoverable from outside the app.
enum TmuxSessionReaper {

    /// Resolved once: tmux is a Homebrew binary whose prefix differs by architecture,
    /// and a GUI app does not inherit the user's shell PATH.
    static let tmuxPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Names of every session on the current user's tmux server.
    /// Empty when tmux is absent or no server is running — both are normal.
    static func liveSessions() -> [String] {
        guard let tmuxPath else { return [] }
        guard let output = run(tmuxPath, ["list-sessions", "-F", "#{session_name}"]) else {
            return []
        }
        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Kill one session. Returns false if tmux is missing or the session is already gone.
    ///
    /// The `=` prefix forces an exact match. A bare `-t name` falls back to prefix and
    /// then fnmatch, so killing `azdevops` could take `azdevops-40` with it.
    @discardableResult
    static func kill(_ session: String) -> Bool {
        guard let tmuxPath, !session.isEmpty else { return false }
        return run(tmuxPath, ["kill-session", "-t", "=\(session)"]) != nil
    }

    /// Live sessions that no open workspace has registered.
    static func orphans(ownedSessions: Set<String>) -> [String] {
        liveSessions().filter { !ownedSessions.contains($0) }
    }

    private static func run(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
