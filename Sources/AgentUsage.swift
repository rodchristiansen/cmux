import AppKit
import Combine
import SwiftUI

/// How much of a plan's usage limit is spent.
struct AgentUsageWindow: Equatable {
    /// 0–100.
    let percent: Int
    let resetsAt: Date?
    /// Length of the limit window in minutes, when known.
    let windowMinutes: Int?

    /// "5h" or "wk".
    var shortLabel: String {
        guard let windowMinutes else { return "" }
        if windowMinutes >= 7 * 24 * 60 {
            return String(localized: "agentUsage.window.week", defaultValue: "wk")
        }
        let hours = max(1, windowMinutes / 60)
        return String.localizedStringWithFormat(
            String(localized: "agentUsage.window.hours", defaultValue: "%lldh"), hours
        )
    }
}

struct AgentUsage: Equatable {
    var claude: [AgentUsageWindow] = []
    var codex: [AgentUsageWindow] = []

    var isEmpty: Bool { claude.isEmpty && codex.isEmpty }
}

/// Reads plan usage for the sidebar footer once a minute:
/// - Claude from `~/.claude/.statusline-usage-cache`, which the Claude Usage
///   app writes for the Claude Code statusline.
/// - Codex from the `rate_limits` it logs in its newest session file.
/// A source that is missing or stale is left out.
@MainActor
final class AgentUsageStore: ObservableObject {
    static let shared = AgentUsageStore()

    @Published private(set) var usage = AgentUsage()

    private var timer: AnyCancellable?
    private var isReading = false

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard !isReading else { return }
        isReading = true
        Task.detached(priority: .utility) { [weak self] in
            let read = AgentUsage(claude: Self.readClaude(), codex: Self.readCodex())
            await MainActor.run {
                guard let self else { return }
                self.isReading = false
                if read != self.usage { self.usage = read }
            }
        }
    }

    // MARK: - Claude

    private nonisolated static func readClaude(now: Date = Date()) -> [AgentUsageWindow] {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/.statusline-usage-cache")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        // The app refreshes every few minutes; an hour-old number is not worth showing.
        guard let stamp = values["TIMESTAMP"].flatMap(TimeInterval.init),
              now.timeIntervalSince1970 - stamp < 3600 else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainISO = ISO8601DateFormatter()
        func date(_ key: String) -> Date? {
            guard let raw = values[key] else { return nil }
            return iso.date(from: raw) ?? plainISO.date(from: raw)
        }
        var windows: [AgentUsageWindow] = []
        if let session = values["UTILIZATION"].flatMap(Int.init) {
            windows.append(.init(percent: session, resetsAt: date("RESETS_AT"), windowMinutes: 300))
        }
        if let weekly = values["WEEKLY_UTILIZATION"].flatMap(Int.init) {
            windows.append(.init(percent: weekly, resetsAt: date("WEEKLY_RESETS_AT"), windowMinutes: 7 * 24 * 60))
        }
        return windows
    }

    // MARK: - Codex

    private nonisolated static func readCodex(now: Date = Date()) -> [AgentUsageWindow] {
        guard let path = newestCodexSession(now: now),
              let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 1 << 20
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd() else { return [] }
        let marker = Data(#""rate_limits":{"#.utf8)
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: marker) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            return ["primary", "secondary"].compactMap { key -> AgentUsageWindow? in
                guard let entry = limits[key] as? [String: Any],
                      let used = entry["used_percent"] as? Double else { return nil }
                let resets = (entry["resets_at"] as? Double).map(Date.init(timeIntervalSince1970:))
                // Past its reset, the logged number no longer applies.
                if let resets, resets < now { return nil }
                return AgentUsageWindow(
                    percent: Int(used.rounded()),
                    resetsAt: resets,
                    windowMinutes: entry["window_minutes"] as? Int
                )
            }
        }
        return []
    }

    /// Codex files sessions under `~/.codex/sessions/<y>/<m>/<d>/`; today's or
    /// yesterday's newest file has the latest limits.
    private nonisolated static func newestCodexSession(now: Date) -> String? {
        let fileManager = FileManager.default
        let root = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/sessions")
        let calendar = Calendar(identifier: .gregorian)
        var newest: (path: String, date: Date)?
        for offset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { continue }
            let folder = String(format: "%@/%04d/%02d/%02d", root, year, month, dayOfMonth)
            guard let names = try? fileManager.contentsOfDirectory(atPath: folder) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let path = (folder as NSString).appendingPathComponent(name)
                guard let modified = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
                if newest == nil || modified > newest!.date { newest = (path, modified) }
            }
        }
        return newest?.path
    }
}

/// "Claude 6% · 5h  Codex 1% · wk" in the sidebar footer, with reset times on hover.
struct SidebarAgentUsageView: View {
    @ObservedObject private var store = AgentUsageStore.shared
    @AppStorage(AgentUsageStore.showInSidebarKey) private var isEnabled = true

    var body: some View {
        Group {
            if isEnabled, !store.usage.isEmpty {
                HStack(spacing: 8) {
                    if let claude = store.usage.claude.max(by: { $0.percent < $1.percent }) {
                        meter(String(localized: "agentUsage.claude", defaultValue: "Claude"), claude)
                    }
                    if let codex = store.usage.codex.max(by: { $0.percent < $1.percent }) {
                        meter(String(localized: "agentUsage.codex", defaultValue: "Codex"), codex)
                    }
                }
                .help(tooltip)
                .accessibilityElement(children: .combine)
            }
        }
        .onAppear { store.start() }
    }

    private func meter(_ name: String, _ window: AgentUsageWindow) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .foregroundStyle(.secondary)
            Gauge(value: Double(min(max(window.percent, 0), 100)), in: 0...100) {
                EmptyView()
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(color(for: window.percent))
            .frame(width: 34)
            Text(verbatim: "\(window.percent)%")
                .monospacedDigit()
                .foregroundStyle(window.percent >= 80 ? color(for: window.percent) : .primary)
        }
        .font(.system(size: 10.5))
    }

    private func color(for percent: Int) -> Color {
        switch percent {
        case ..<60: return .accentColor
        case ..<85: return .orange
        default: return .red
        }
    }

    private var tooltip: String {
        var lines: [String] = []
        func describe(_ name: String, _ windows: [AgentUsageWindow]) {
            for window in windows {
                var line = String.localizedStringWithFormat(
                    String(localized: "agentUsage.tooltip.line", defaultValue: "%@ %@: %lld%% used"),
                    name, window.shortLabel, window.percent
                )
                if let resets = window.resetsAt {
                    line += " — " + String.localizedStringWithFormat(
                        String(localized: "agentUsage.tooltip.resets", defaultValue: "resets %@"),
                        resets.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                lines.append(line)
            }
        }
        describe(String(localized: "agentUsage.claude", defaultValue: "Claude"), store.usage.claude)
        describe(String(localized: "agentUsage.codex", defaultValue: "Codex"), store.usage.codex)
        return lines.joined(separator: "\n")
    }
}

extension AgentUsageStore {
    nonisolated static let showInSidebarKey = "sidebarShowAgentUsage"
}
