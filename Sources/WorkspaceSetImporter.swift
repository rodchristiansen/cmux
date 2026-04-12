import Foundation
import Bonsplit

// MARK: - Codable Types

struct WorkspaceSetFile: Codable {
    /// Optional template applied to every workspace: a list of named panels
    /// with optional startup commands. Layout: first panel is the main pane;
    /// remaining panels are added as tabs in a right-side split (75/25).
    var defaultPanels: [WorkspaceSetPanelTemplate]?
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
    /// Returns a summary of what was created and what was skipped.
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
    /// Closes all existing panels and recreates them from the `defaultPanels` template.
    /// Returns the number of panels recreated, or nil if no template is configured.
    @discardableResult
    static func rebuildWorkspaceFromTemplate(
        _ workspace: Workspace,
        at path: String? = nil
    ) -> Int? {
        let resolvedPath = path ?? defaultPath
        guard let workspaceSet = try? parseFile(at: resolvedPath) else { return nil }
        guard let templates = workspaceSet.defaultPanels, !templates.isEmpty else { return nil }

        // Close every panel except the focused one, then apply the template
        // (which will rename/command the remaining panel and add the rest).
        let keepId = workspace.focusedPanelId
        let toClose = workspace.panels.keys.filter { $0 != keepId }
        for panelId in toClose {
            _ = workspace.closePanel(panelId, force: true)
        }
        applyPanelTemplate(to: workspace, templates: templates, isFresh: false)
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
            let key = normalizedDirectoryKey(ws.currentDirectory)
            existingByDir[key] = ws
        }

        var sectionByName: [String: SidebarSection] = [:]
        for section in tabManager.sections {
            let key = section.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty {
                sectionByName[key] = section
            }
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
                    if let collapsed = sectionDef.collapsed {
                        newSection.setCollapsed(collapsed)
                    }
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
                        if let templates = workspaceSet.defaultPanels {
                            panelsAdded += fillMissingPanels(in: existingWs, templates: templates)
                        }
                    }
                    skipped.append(.init(
                        name: entry.name,
                        directory: entry.directory,
                        reason: "directory_exists"
                    ))
                    continue
                }

                guard FileManager.default.fileExists(atPath: expandedDir) else {
                    skipped.append(.init(
                        name: entry.name,
                        directory: entry.directory,
                        reason: "directory_missing"
                    ))
                    continue
                }

                if dryRun {
                    created.append(.init(
                        name: entry.name,
                        directory: entry.directory,
                        section: hasSection ? sectionName : nil
                    ))
                    continue
                }

                // Create workspace. If a template exists, use its first panel's
                // command as the initial terminal command so the main panel
                // starts with its tool running.
                let firstTemplate = workspaceSet.defaultPanels?.first
                let ws = tabManager.addWorkspace(
                    title: firstTemplate?.title ?? entry.name,
                    workingDirectory: expandedDir,
                    initialTerminalCommand: firstTemplate?.command,
                    select: false,
                    eagerLoadTerminal: true,
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
                    applyPanelTemplate(to: ws, templates: templates, isFresh: true)
                    panelsAdded += max(templates.count - 1, 0)
                }

                existingByDir[normalizedDir] = ws

                created.append(.init(
                    name: entry.name,
                    directory: entry.directory,
                    section: hasSection ? sectionName : nil
                ))
            }
        }

        return WorkspaceSetImportResult(
            created: created,
            skipped: skipped,
            sectionsCreated: sectionsCreated,
            panelsAdded: panelsAdded
        )
    }

    // MARK: - Panel template application

    /// Apply a panel template to a workspace. The workspace should already have
    /// one terminal panel (from `addWorkspace`). For `isFresh == true`, the
    /// first template panel is assumed already applied via `initialTerminalCommand`;
    /// this method only adds panels 2..n. For `isFresh == false` (rebuild from
    /// template), the first panel is also renamed and its command is re-sent.
    private static func applyPanelTemplate(
        to workspace: Workspace,
        templates: [WorkspaceSetPanelTemplate],
        isFresh: Bool
    ) {
        guard !templates.isEmpty else { return }
        guard let firstPanelId = workspace.focusedPanelId else { return }

        // Rename the existing main panel to match the first template entry.
        workspace.setPanelCustomTitle(panelId: firstPanelId, title: templates[0].title)

        if !isFresh, let cmd = templates[0].command {
            sendCommand(to: firstPanelId, in: workspace, command: cmd)
        }

        guard templates.count > 1 else { return }

        // Create the right-side split holding the remaining panels as tabs.
        guard let secondPanelId = workspace.owningTabManager?.newSplit(
            tabId: workspace.id,
            surfaceId: firstPanelId,
            direction: .right,
            focus: false
        ) else { return }

        workspace.setPanelCustomTitle(panelId: secondPanelId, title: templates[1].title)
        if let cmd = templates[1].command {
            sendCommand(to: secondPanelId, in: workspace, command: cmd)
        }

        // Additional panels become tabs in the same pane as panel #2.
        guard let rightPaneId = workspace.paneId(forPanelId: secondPanelId) else { return }

        for i in 2..<templates.count {
            let tpl = templates[i]
            guard let panel = workspace.newTerminalSurface(
                inPane: rightPaneId,
                focus: false,
                workingDirectory: workspace.currentDirectory
            ) else { continue }
            workspace.setPanelCustomTitle(panelId: panel.id, title: tpl.title)
            if let cmd = tpl.command {
                sendCommand(to: panel.id, in: workspace, command: cmd)
            }
        }

        // Refocus the main terminal so the user lands on it, not the last tab.
        workspace.focusPanel(firstPanelId)
    }

    /// For an existing workspace, add any template panels that are missing by
    /// title. Existing panels (even bare-shell ones) are left alone to avoid
    /// disrupting running work. Returns the count of panels added.
    private static func fillMissingPanels(
        in workspace: Workspace,
        templates: [WorkspaceSetPanelTemplate]
    ) -> Int {
        guard !templates.isEmpty else { return 0 }

        // Set of existing panel custom titles (normalized to lowercase).
        var existingTitles = Set<String>()
        for (_, custom) in workspace.panelCustomTitles {
            let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !trimmed.isEmpty { existingTitles.insert(trimmed) }
        }

        var missing: [WorkspaceSetPanelTemplate] = []
        for tpl in templates {
            if !existingTitles.contains(tpl.title.lowercased()) {
                missing.append(tpl)
            }
        }

        guard !missing.isEmpty else { return 0 }
        let totalMissing = missing.count

        // Pick a pane to host missing panels. Prefer a pane that already holds
        // a non-first template panel so tabs stack together; otherwise split
        // right from the focused panel.
        let tabManager = workspace.owningTabManager
        var targetPaneId: PaneID?

        let nonFirstTitles = Set(templates.dropFirst().map { $0.title.lowercased() })
        for (panelId, custom) in workspace.panelCustomTitles {
            let title = custom.lowercased()
            if nonFirstTitles.contains(title), let pane = workspace.paneId(forPanelId: panelId) {
                targetPaneId = pane
                break
            }
        }

        if targetPaneId == nil {
            // No right-side pane exists — split right from the main panel
            // to create one, unless the first template panel itself is missing
            // (in which case we'll place them adjacent to the focused panel).
            guard let anchor = workspace.focusedPanelId,
                  let newId = tabManager?.newSplit(
                    tabId: workspace.id,
                    surfaceId: anchor,
                    direction: .right,
                    focus: false
                  ) else {
                return 0
            }
            // The first missing panel becomes the seed of the new pane.
            let first = missing.removeFirst()
            workspace.setPanelCustomTitle(panelId: newId, title: first.title)
            if let cmd = first.command {
                sendCommand(to: newId, in: workspace, command: cmd)
            }
            targetPaneId = workspace.paneId(forPanelId: newId)
        }

        guard let paneId = targetPaneId else { return 0 }

        for tpl in missing {
            guard let panel = workspace.newTerminalSurface(
                inPane: paneId,
                focus: false,
                workingDirectory: workspace.currentDirectory
            ) else { continue }
            workspace.setPanelCustomTitle(panelId: panel.id, title: tpl.title)
            if let cmd = tpl.command {
                sendCommand(to: panel.id, in: workspace, command: cmd)
            }
        }

        return totalMissing
    }

    /// Send a command + newline to a terminal panel. Works even if the surface
    /// isn't started yet — the input is queued and flushed on surface start.
    private static func sendCommand(to panelId: UUID, in workspace: Workspace, command: String) {
        guard let terminalPanel = workspace.terminalPanel(for: panelId) else { return }
        terminalPanel.sendText(command + "\n")
    }

    /// Normalize a directory path for dedup comparison.
    private static func normalizedDirectoryKey(_ directory: String) -> String {
        var path = (directory as NSString).expandingTildeInPath
        path = (path as NSString).standardizingPath
        if path.hasSuffix("/"), path.count > 1 {
            path = String(path.dropLast())
        }
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
