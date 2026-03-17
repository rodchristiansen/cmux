import Foundation

/// Batched port scanner that replaces per-shell `ps + lsof` scanning.
///
/// Each shell sends a lightweight `report_tty` + `ports_kick` over the socket.
/// PortScanner coalesces kicks across all panels, then runs a single
/// `ps -t <ttys>` + `lsof -p <pids>` covering every panel that needs scanning.
///
/// Kick → coalesce → burst flow:
/// 1. `kick()` adds panel to `pendingKicks` set
/// 2. If no burst is active, starts a 200ms coalesce timer
/// 3. Coalesce fires → snapshots pending set → starts burst of 6 scans
/// 4. New kicks during burst merge into the active burst
/// 5. After last scan, if new kicks arrived, start a new coalesce cycle
final class PortScanner: @unchecked Sendable {
    static let shared = PortScanner()

    struct PanelScanResult: Equatable {
        let ports: [Int]
        let sshHost: String?
    }

    struct TTYProcess: Equatable {
        let pid: Int
        let tty: String
        let command: String
        let arguments: [String]
    }

    /// Callback delivers `(workspaceId, panelId, result)` on main thread.
    var onPanelScanned: ((_ workspaceId: UUID, _ panelId: UUID, _ result: PanelScanResult) -> Void)?

    // MARK: - State (all guarded by `queue`)

    private let queue = DispatchQueue(label: "com.cmux.port-scanner", qos: .utility)

    /// TTY name per (workspace, panel).
    private var ttyNames: [PanelKey: String] = [:]

    /// Panels that requested a scan since the last coalesce snapshot.
    private var pendingKicks: Set<PanelKey> = []

    /// Whether a burst sequence is currently running.
    private var burstActive = false

    /// Coalesce timer (200ms after first kick).
    private var coalesceTimer: DispatchSourceTimer?

    /// Burst scan offsets in seconds from the start of the burst.
    /// Each scan fires at this absolute offset; the recursive scheduler
    /// converts to relative delays between consecutive scans.
    private static let burstOffsets: [Double] = [0.5, 1.5, 3, 5, 7.5, 10]
    nonisolated private static let sshCommands = Set(["ssh", "autossh"])
    nonisolated private static let sshOptionsWithArguments = Set([
        Character("B"),
        Character("b"),
        Character("c"),
        Character("D"),
        Character("E"),
        Character("e"),
        Character("F"),
        Character("I"),
        Character("i"),
        Character("J"),
        Character("L"),
        Character("l"),
        Character("M"),
        Character("m"),
        Character("O"),
        Character("o"),
        Character("p"),
        Character("Q"),
        Character("R"),
        Character("S"),
        Character("W"),
        Character("w"),
    ])

    // MARK: - Public API

    struct PanelKey: Hashable {
        let workspaceId: UUID
        let panelId: UUID
    }

    func registerTTY(workspaceId: UUID, panelId: UUID, ttyName: String) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            guard ttyNames[key] != ttyName else { return }
            ttyNames[key] = ttyName
        }
    }

    func unregisterPanel(workspaceId: UUID, panelId: UUID) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            ttyNames.removeValue(forKey: key)
            pendingKicks.remove(key)
        }
    }

    func kick(workspaceId: UUID, panelId: UUID) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            guard ttyNames[key] != nil else { return }
            pendingKicks.insert(key)

            if !burstActive {
                startCoalesce()
            }
            // If burst is active, the next scan iteration will pick up the new kick.
        }
    }

    // MARK: - Coalesce + Burst

    private func startCoalesce() {
        // Already on `queue`.
        coalesceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2)
        timer.setEventHandler { [weak self] in
            self?.coalesceTimerFired()
        }
        coalesceTimer = timer
        timer.resume()
    }

    private func coalesceTimerFired() {
        // Already on `queue`.
        coalesceTimer?.cancel()
        coalesceTimer = nil

        guard !pendingKicks.isEmpty else { return }
        burstActive = true
        runBurst(index: 0)
    }

    private func runBurst(index: Int, burstStart: DispatchTime? = nil) {
        // Already on `queue`.
        guard index < Self.burstOffsets.count else {
            burstActive = false
            // If new kicks arrived during the burst, start a new coalesce cycle.
            if !pendingKicks.isEmpty {
                startCoalesce()
            }
            return
        }

        let start = burstStart ?? .now()
        let deadline = start + Self.burstOffsets[index]
        queue.asyncAfter(deadline: deadline) { [weak self] in
            guard let self else { return }
            self.runScan()
            self.runBurst(index: index + 1, burstStart: start)
        }
    }

    // MARK: - Scan

    private func runScan() {
        // Already on `queue`. Snapshot which panels to scan and their TTYs.
        // We scan all registered panels, not just pending ones, since ports can
        // appear/disappear on any panel.
        let snapshot = ttyNames

        guard !snapshot.isEmpty else {
            pendingKicks.removeAll()
            return
        }

        // Clear pending kicks — they're accounted for in this scan.
        pendingKicks.removeAll()

        // Build TTY set (deduplicated).
        let uniqueTTYs = Set(snapshot.values)
        let ttyList = uniqueTTYs.joined(separator: ",")

        // 1. ps -t tty1,tty2,... -o pid=,tty=,comm=,args=
        let processes = runPS(ttyList: ttyList)
        guard !processes.isEmpty else {
            // No processes on any TTY. Clear ephemeral scan-derived metadata.
            let results = snapshot.map { ($0.key, PanelScanResult(ports: [], sshHost: nil)) }
            deliverResults(results)
            return
        }

        // 2. lsof -nP -a -p <all_pids> -iTCP -sTCP:LISTEN -F pn
        let pidToTTY = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0.tty) })
        let allPids = pidToTTY.keys.sorted().map(String.init).joined(separator: ",")
        let pidToPorts = runLsof(pidsCsv: allPids)

        // 3. Join: PID→TTY + PID→ports → TTY→ports
        var portsByTTY: [String: Set<Int>] = [:]
        for (pid, ports) in pidToPorts {
            guard let tty = pidToTTY[pid] else { continue }
            portsByTTY[tty, default: []].formUnion(ports)
        }

        let processesByTTY = Dictionary(grouping: processes, by: \.tty)

        // 4. Map to per-panel port lists.
        var results: [(PanelKey, PanelScanResult)] = []
        for (key, tty) in snapshot {
            let ports = portsByTTY[tty].map { Array($0).sorted() } ?? []
            let sshHost = processesByTTY[tty].flatMap(Self.detectedSSHHost(in:))
            results.append((key, PanelScanResult(ports: ports, sshHost: sshHost)))
        }

        deliverResults(results)
    }

    private func deliverResults(_ results: [(PanelKey, PanelScanResult)]) {
        guard let callback = onPanelScanned else { return }
        DispatchQueue.main.async {
            for (key, result) in results {
                callback(key.workspaceId, key.panelId, result)
            }
        }
    }

    // MARK: - Process helpers

    nonisolated static func detectedSSHHost(in processes: [TTYProcess]) -> String? {
        let sorted = processes.sorted { lhs, rhs in
            if lhs.pid == rhs.pid {
                return lhs.command < rhs.command
            }
            return lhs.pid < rhs.pid
        }

        for process in sorted.reversed() {
            let commandName = normalizedCommandName(process.command)
            guard sshCommands.contains(commandName) else { continue }
            if let host = sshHost(fromArguments: process.arguments) {
                return host
            }
        }

        return nil
    }

    nonisolated static func sshHost(fromArguments arguments: [String]) -> String? {
        guard !arguments.isEmpty else { return nil }

        var index = 0
        if sshCommands.contains(normalizedCommandName(arguments[0])) {
            index = 1
        }

        while index < arguments.count {
            let token = arguments[index]
            guard !token.isEmpty else {
                index += 1
                continue
            }

            if token == "--" {
                index += 1
                break
            }

            if let first = token.first, first == "-" {
                let shortName = token.dropFirst().first
                if let shortName,
                   sshOptionsWithArguments.contains(shortName),
                   token.count == 2 {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }

            return normalizedSSHDestination(token)
        }

        while index < arguments.count {
            let token = arguments[index]
            if let destination = normalizedSSHDestination(token) {
                return destination
            }
            index += 1
        }

        return nil
    }

    private static func normalizedCommandName(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return (trimmed as NSString).lastPathComponent.lowercased()
    }

    private static func normalizedSSHDestination(_ rawDestination: String) -> String? {
        let trimmed = rawDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed),
           let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            return host
        }

        var destination = trimmed
        if let atIndex = destination.lastIndex(of: "@") {
            destination = String(destination[destination.index(after: atIndex)...])
        }

        if destination.hasPrefix("["),
           let closingBracket = destination.firstIndex(of: "]") {
            let host = destination[destination.index(after: destination.startIndex)..<closingBracket]
            let normalized = String(host).trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }

        return destination
    }

    private func runPS(ttyList: String) -> [TTYProcess] {
        // Targeted scan, much cheaper than `ps -ax`.
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-t", ttyList, "-o", "pid=,tty=,comm=,args="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return Self.parsePSOutput(output)
    }

    private static func parsePSOutput(_ output: String) -> [TTYProcess] {
        var processes: [TTYProcess] = []

        for line in output.split(separator: "\n") {
            let parts = line.split(
                maxSplits: 3,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard parts.count >= 3,
                  let pid = Int(parts[0]) else {
                continue
            }

            let tty = String(parts[1])
            let command = String(parts[2])
            let argumentSource = parts.count == 4 ? String(parts[3]) : command
            let arguments = argumentSource
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)

            processes.append(
                TTYProcess(
                    pid: pid,
                    tty: tty,
                    command: command,
                    arguments: arguments.isEmpty ? [command] : arguments
                )
            )
        }

        return processes
    }

    private func runLsof(pidsCsv: String) -> [Int: Set<Int>] {
        // `lsof -nP -a -p <pids> -iTCP -sTCP:LISTEN -F pn`
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", pidsCsv, "-iTCP", "-sTCP:LISTEN", "-Fpn"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        // Parse lsof -F output: lines starting with 'p' = PID, 'n' = name (host:port).
        var result: [Int: Set<Int>] = [:]
        var currentPid: Int?
        for line in output.split(separator: "\n") {
            guard let first = line.first else { continue }
            switch first {
            case "p":
                currentPid = Int(line.dropFirst())
            case "n":
                guard let pid = currentPid else { continue }
                var name = String(line.dropFirst())
                // Strip remote endpoint if present.
                if let arrowIdx = name.range(of: "->") {
                    name = String(name[..<arrowIdx.lowerBound])
                }
                // Port is after the last colon.
                if let colonIdx = name.lastIndex(of: ":") {
                    let portStr = name[name.index(after: colonIdx)...]
                    // Strip anything non-numeric.
                    let cleaned = portStr.prefix(while: \.isNumber)
                    if let port = Int(cleaned), port > 0, port <= 65535 {
                        result[pid, default: []].insert(port)
                    }
                }
            default:
                break
            }
        }
        return result
    }
}
