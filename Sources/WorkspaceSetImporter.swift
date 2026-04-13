import Foundation
import Bonsplit

// MARK: - Codable Types

struct WorkspaceSetFile: Codable {
    /// Optional template applied to every workspace: a list of named panels
    /// with optional startup commands.
    var defaultPanels: [WorkspaceSetPanelTemplate]?
    /// Optional layout tree referencing panel titles. Mirrors the session
    /// persistence layout format (split/pane nodes). When omitted, the
    /// default is a single pane containing all panels as tabs.
    var defaultLayout: WorkspaceSetLayoutNode?
    var sections: [WorkspaceSetSection]
}

struct WorkspaceSetSection: Codable {
    var name: String
    var collapsed: Bool?
    var workspaces: [WorkspaceSetEntry]
}

struct WorkspaceSetEntry: Codable {
    var name: String
    var directory: String
    var color: String?
    var description: String?
    var pinned: Bool?
}

struct WorkspaceSetPanelTemplate: Codable {
    var title: String
    var command: String?
}

struct WorkspaceSetSplitLayout: Codable {
    var orientation: String  // "horizontal" or "vertical"
    var dividerPosition: Double
    var first: WorkspaceSetLayoutNode
    var second: WorkspaceSetLayoutNode
}

struct WorkspaceSetPaneLayout: Codable {
    var panels: [String]   // panel titles in tab order
    var selected: String?  // title of selected tab (defaults to first)
}

indirect enum WorkspaceSetLayoutNode: Codable {
    case split(WorkspaceSetSplitLayout)
    case pane(WorkspaceSetPaneLayout)

    private enum CodingKeys: String, CodingKey {
        case type, split, pane
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "split":
            self = .split(try c.decode(WorkspaceSetSplitLayout.self, forKey: .split))
        case "pane":
            self = .pane(try c.decode(WorkspaceSetPaneLayout.self, forKey: .pane))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "layout node type must be 'split' or 'pane', got '\(type)'"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .split(let s):
            try c.encode("split", forKey: .type)
            try c.encode(s, forKey: .split)
        case .pane(let p):
            try c.encode("pane", forKey: .type)
            try c.encode(p, forKey: .pane)
        }
    }
}

// MARK: - Import Result

struct WorkspaceSetImportResult {
    struct Created {
        let name: String
        let directory: String
        let section: String?
    }

    struct Skipped {
        let name: String
        let directory: String
        let reason: String
    }

    let created: [Created]
    let skipped: [Skipped]
    let sectionsCreated: [String]
    let panelsAdded: Int
}

// MARK: - Importer

@MainActor
enum WorkspaceSetImporter {

    static let defaultPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/cmux/workspace-set.json")
    }()

    static func fileExists(at path: String? = nil) -> Bool {
        FileManager.default.fileExists(atPath: path ?? defaultPath)
    }

    /// Load and merge a workspace-set.json into the given TabManager.
    static func importFromFile(
        at path: String? = nil,
        into tabManager: TabManager,
        dryRun: Bool = false
    ) -> Result<WorkspaceSetImportResult, WorkspaceSetImportError> {
        let resolvedPath = path ?? defaultPath

        let workspaceSet: WorkspaceSetFile
        do {
            workspaceSet = try parseFile(at: resolvedPath)
        } catch let error as WorkspaceSetImportError {
            return .failure(error)
        } catch {
            return .failure(.readError(path: resolvedPath, underlying: error.localizedDescription))
        }

        let result = mergeInto(tabManager: tabManager, workspaceSet: workspaceSet, dryRun: dryRun)
        return .success(result)
    }

    /// Rebuild a single workspace's layout from the template in workspace-set.json.
    /// Replaces all panels and layout with the template; then runs each panel's command.
    @discardableResult
    static func rebuildWorkspaceFromTemplate(
        _ workspace: Workspace,
        at path: String? = nil
    ) -> Int? {
        let resolvedPath = path ?? defaultPath
        guard let workspaceSet = try? parseFile(at: resolvedPath) else { return nil }
        guard let templates = workspaceSet.defaultPanels, !templates.isEmpty else { return nil }

        // Reduce the workspace to a single pane with one anchor panel so
        // `restoreSessionSnapshot` doesn't layer new splits on top of the
        // existing layout. Close every non-anchor panel with force=true;
        // bonsplit collapses a pane when its last tab closes, so after this
        // the workspace is in the same shape as a newly-minted one.
        let anchor = workspace.focusedPanelId
        for panelId in Array(workspace.panels.keys) where panelId != anchor {
            _ = workspace.closePanel(panelId, force: true)
        }

        applyFullTemplate(to: workspace, panels: templates, layout: workspaceSet.defaultLayout)
        return templates.count
    }

    // MARK: - Private

    private static func parseFile(at path: String) throws -> WorkspaceSetFile {
        guard FileManager.default.fileExists(atPath: path) else {
            throw WorkspaceSetImportError.fileNotFound(path: path)
        }
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            throw WorkspaceSetImportError.readError(path: path, underlying: "File is empty")
        }
        do {
            return try JSONDecoder().decode(WorkspaceSetFile.self, from: data)
        } catch {
            throw WorkspaceSetImportError.parseError(path: path, underlying: error.localizedDescription)
        }
    }

    private static func mergeInto(
        tabManager: TabManager,
        workspaceSet: WorkspaceSetFile,
        dryRun: Bool
    ) -> WorkspaceSetImportResult {
        var existingByDir: [String: Workspace] = [:]
        for ws in tabManager.tabs {
            existingByDir[normalizedDirectoryKey(ws.currentDirectory)] = ws
        }

        var sectionByName: [String: SidebarSection] = [:]
        for section in tabManager.sections {
            let key = section.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty { sectionByName[key] = section }
        }

        var created: [WorkspaceSetImportResult.Created] = []
        var skipped: [WorkspaceSetImportResult.Skipped] = []
        var sectionsCreated: [String] = []
        var panelsAdded = 0

        for sectionDef in workspaceSet.sections {
            let sectionName = sectionDef.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let sectionKey = sectionName.lowercased()
            let hasSection = !sectionName.isEmpty

            var targetSection: SidebarSection?
            if hasSection {
                if let existing = sectionByName[sectionKey] {
                    targetSection = existing
                } else if !dryRun {
                    let newSection = tabManager.createSection(name: sectionName, triggerRename: false)
                    if let collapsed = sectionDef.collapsed { newSection.setCollapsed(collapsed) }
                    sectionByName[sectionKey] = newSection
                    targetSection = newSection
                    sectionsCreated.append(sectionName)
                } else {
                    sectionsCreated.append(sectionName)
                }
            }

            for entry in sectionDef.workspaces {
                let expandedDir = (entry.directory as NSString).expandingTildeInPath
                let normalizedDir = normalizedDirectoryKey(expandedDir)

                if let existingWs = existingByDir[normalizedDir] {
                    if !dryRun {
                        if let section = targetSection,
                           tabManager.sectionForWorkspace(existingWs.id) == nil {
                            tabManager.moveWorkspaceToSection(tabId: existingWs.id, sectionId: section.id)
                        }
                        // Idle workspaces get fully rebuilt from the template so
                        // their layout + tools match the JSON. Running workspaces
                        // are preserved — only missing panels get added.
                        if let templates = workspaceSet.defaultPanels, !templates.isEmpty {
                            if isWorkspaceIdle(existingWs) {
                                // Tear down and rebuild from template.
                                let anchor = existingWs.focusedPanelId
                                for panelId in Array(existingWs.panels.keys) where panelId != anchor {
                                    _ = existingWs.closePanel(panelId, force: true)
                                }
                                applyFullTemplate(
                                    to: existingWs,
                                    panels: templates,
                                    layout: workspaceSet.defaultLayout
                                )
                                panelsAdded += templates.count
                            } else {
                                panelsAdded += fillMissingPanels(in: existingWs, templates: templates)
                            }
                        }
                    }
                    skipped.append(.init(name: entry.name, directory: entry.directory, reason: "directory_exists"))
                    continue
                }

                guard FileManager.default.fileExists(atPath: expandedDir) else {
                    skipped.append(.init(name: entry.name, directory: entry.directory, reason: "directory_missing"))
                    continue
                }

                if dryRun {
                    created.append(.init(name: entry.name, directory: entry.directory, section: hasSection ? sectionName : nil))
                    continue
                }

                // Create workspace (one bootstrap panel). Name comes from entry.name;
                // panel template + layout is applied right after via session-snapshot
                // rebuild so we get correct splits + divider positions.
                let ws = tabManager.addWorkspace(
                    title: entry.name,
                    workingDirectory: expandedDir,
                    select: false,
                    eagerLoadTerminal: false,
                    autoWelcomeIfNeeded: false
                )

                tabManager.setCustomTitle(tabId: ws.id, title: entry.name)
                if let description = entry.description {
                    tabManager.setCustomDescription(tabId: ws.id, description: description)
                }
                if let color = entry.color {
                    tabManager.setTabColor(tabId: ws.id, color: color)
                }
                if entry.pinned == true {
                    tabManager.setPinned(ws, pinned: true)
                }

                if let section = targetSection {
                    tabManager.moveWorkspaceToSection(tabId: ws.id, sectionId: section.id)
                }

                if let templates = workspaceSet.defaultPanels, !templates.isEmpty {
                    applyFullTemplate(to: ws, panels: templates, layout: workspaceSet.defaultLayout)
                    panelsAdded += max(templates.count - 1, 0)
                }

                existingByDir[normalizedDir] = ws

                created.append(.init(name: entry.name, directory: entry.directory, section: hasSection ? sectionName : nil))
            }
        }

        return WorkspaceSetImportResult(
            created: created, skipped: skipped,
            sectionsCreated: sectionsCreated, panelsAdded: panelsAdded
        )
    }

    // MARK: - Template application (full rebuild via session snapshot)

    /// Build a SessionWorkspaceSnapshot matching the requested template +
    /// layout and call `workspace.restoreSessionSnapshot(...)`. This gives us
    /// exact layout + divider positions out of the box.
    private static func applyFullTemplate(
        to workspace: Workspace,
        panels: [WorkspaceSetPanelTemplate],
        layout layoutNode: WorkspaceSetLayoutNode?
    ) {
        // Generate stable UUIDs per template title so the layout tree can
        // reference them.
        var panelIdByTitle: [String: UUID] = [:]
        for tpl in panels {
            panelIdByTitle[tpl.title.lowercased()] = UUID()
        }

        let cwd = workspace.currentDirectory

        let panelSnapshots: [SessionPanelSnapshot] = panels.map { tpl in
            let id = panelIdByTitle[tpl.title.lowercased()] ?? UUID()
            return SessionPanelSnapshot(
                id: id,
                type: .terminal,
                title: tpl.title,
                customTitle: tpl.title,
                directory: cwd,
                isPinned: false,
                isManuallyUnread: false,
                gitBranch: nil,
                listeningPorts: [],
                ttyName: nil,
                terminal: SessionTerminalPanelSnapshot(workingDirectory: cwd, scrollback: nil),
                browser: nil,
                markdown: nil
            )
        }

        let resolvedLayout: SessionWorkspaceLayoutSnapshot
        if let layoutNode {
            resolvedLayout = buildLayoutSnapshot(node: layoutNode, panelIdByTitle: panelIdByTitle,
                                                 fallbackIds: panels.map { panelIdByTitle[$0.title.lowercased()]! })
        } else {
            // Default: all panels as tabs in a single pane.
            let ids = panels.map { panelIdByTitle[$0.title.lowercased()]! }
            resolvedLayout = .pane(SessionPaneLayoutSnapshot(panelIds: ids, selectedPanelId: ids.first))
        }

        let firstId = panels.first.flatMap { panelIdByTitle[$0.title.lowercased()] }

        let snapshot = SessionWorkspaceSnapshot(
            id: workspace.id,
            processTitle: workspace.title,
            customTitle: workspace.customTitle,
            customDescription: workspace.customDescription,
            customColor: workspace.customColor,
            isPinned: workspace.isPinned,
            currentDirectory: cwd,
            focusedPanelId: firstId,
            layout: resolvedLayout,
            panels: panelSnapshots,
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )

        workspace.restoreSessionSnapshot(snapshot)

        // Look up panels by their custom title after restore. The snapshot
        // UUIDs we generated above are remapped to fresh UUIDs by
        // createPanel; the custom title is preserved, so we match by that.
        var panelIdByTitleAfterRestore: [String: UUID] = [:]
        for (panelId, customTitle) in workspace.panelCustomTitles {
            panelIdByTitleAfterRestore[customTitle.lowercased()] = panelId
        }

        for tpl in panels {
            guard let cmd = tpl.command, !cmd.isEmpty else { continue }
            guard let panelId = panelIdByTitleAfterRestore[tpl.title.lowercased()] else { continue }
            sendCommand(to: panelId, in: workspace, command: cmd)
        }
    }

    /// Transform a WorkspaceSetLayoutNode (title-referenced) into a
    /// SessionWorkspaceLayoutSnapshot (UUID-referenced). Titles not in the
    /// panel set are silently skipped; panes emptied by this pruning get
    /// replaced with a fallback to avoid empty panes.
    private static func buildLayoutSnapshot(
        node: WorkspaceSetLayoutNode,
        panelIdByTitle: [String: UUID],
        fallbackIds: [UUID]
    ) -> SessionWorkspaceLayoutSnapshot {
        switch node {
        case .split(let s):
            let orientation: SessionSplitOrientation = s.orientation.lowercased() == "vertical" ? .vertical : .horizontal
            return .split(SessionSplitLayoutSnapshot(
                orientation: orientation,
                dividerPosition: s.dividerPosition,
                first: buildLayoutSnapshot(node: s.first, panelIdByTitle: panelIdByTitle, fallbackIds: fallbackIds),
                second: buildLayoutSnapshot(node: s.second, panelIdByTitle: panelIdByTitle, fallbackIds: fallbackIds)
            ))
        case .pane(let p):
            let ids = p.panels.compactMap { panelIdByTitle[$0.lowercased()] }
            let selected = p.selected.flatMap { panelIdByTitle[$0.lowercased()] } ?? ids.first
            if ids.isEmpty {
                // Should not happen with a valid layout; fall back to the
                // first template panel so bonsplit stays consistent.
                return .pane(SessionPaneLayoutSnapshot(panelIds: Array(fallbackIds.prefix(1)), selectedPanelId: fallbackIds.first))
            }
            return .pane(SessionPaneLayoutSnapshot(panelIds: ids, selectedPanelId: selected))
        }
    }

    // MARK: - Non-destructive fill of missing panels (Reload Workspace Set)

    /// For an existing workspace, add any template panels whose titles are
    /// missing. Existing panels are left alone to avoid disrupting running work.
    private static func fillMissingPanels(
        in workspace: Workspace,
        templates: [WorkspaceSetPanelTemplate]
    ) -> Int {
        guard !templates.isEmpty else { return 0 }

        var existingTitles = Set<String>()
        for (_, custom) in workspace.panelCustomTitles {
            let t = custom.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !t.isEmpty { existingTitles.insert(t) }
        }

        var missing: [WorkspaceSetPanelTemplate] = []
        for tpl in templates where !existingTitles.contains(tpl.title.lowercased()) {
            missing.append(tpl)
        }
        guard !missing.isEmpty else { return 0 }
        let totalMissing = missing.count

        // Find a pane already holding a non-first template panel so we add
        // tabs alongside it. Otherwise split right from the focused panel.
        let tabManager = workspace.owningTabManager
        var targetPaneId: PaneID?

        let nonFirstTitles = Set(templates.dropFirst().map { $0.title.lowercased() })
        for (panelId, custom) in workspace.panelCustomTitles {
            if nonFirstTitles.contains(custom.lowercased()),
               let pane = workspace.paneId(forPanelId: panelId) {
                targetPaneId = pane
                break
            }
        }

        if targetPaneId == nil {
            guard let anchor = workspace.focusedPanelId,
                  let newId = tabManager?.newSplit(
                    tabId: workspace.id, surfaceId: anchor,
                    direction: .right, focus: false
                  ) else {
                return 0
            }
            let first = missing.removeFirst()
            workspace.setPanelCustomTitle(panelId: newId, title: first.title)
            if let cmd = first.command { sendCommand(to: newId, in: workspace, command: cmd) }
            targetPaneId = workspace.paneId(forPanelId: newId)
        }

        guard let paneId = targetPaneId else { return 0 }

        for tpl in missing {
            guard let panel = workspace.newTerminalSurface(
                inPane: paneId, focus: false, workingDirectory: workspace.currentDirectory
            ) else { continue }
            workspace.setPanelCustomTitle(panelId: panel.id, title: tpl.title)
            if let cmd = tpl.command { sendCommand(to: panel.id, in: workspace, command: cmd) }
        }

        return totalMissing
    }

    /// A workspace is "idle" when no status entry reports as running. Used to
    /// decide whether a reload can safely rebuild its layout from the template.
    private static func isWorkspaceIdle(_ workspace: Workspace) -> Bool {
        for entry in workspace.statusEntries.values {
            if entry.value.range(of: "running", options: .caseInsensitive) != nil {
                return false
            }
        }
        return true
    }

    private static func sendCommand(to panelId: UUID, in workspace: Workspace, command: String) {
        guard let terminalPanel = workspace.terminalPanel(for: panelId) else { return }
        terminalPanel.sendText(command + "\n")
    }

    private static func normalizedDirectoryKey(_ directory: String) -> String {
        var path = (directory as NSString).expandingTildeInPath
        path = (path as NSString).standardizingPath
        if path.hasSuffix("/"), path.count > 1 { path = String(path.dropLast()) }
        return path
    }
}

// MARK: - Error

enum WorkspaceSetImportError: Error, LocalizedError {
    case fileNotFound(path: String)
    case readError(path: String, underlying: String)
    case parseError(path: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Workspace set file not found: \(path)"
        case .readError(let path, let underlying):
            return "Failed to read workspace set file at \(path): \(underlying)"
        case .parseError(let path, let underlying):
            return "Failed to parse workspace set file at \(path): \(underlying)"
        }
    }
}
