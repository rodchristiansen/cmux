import Foundation

// MARK: - Codable Types

struct WorkspaceSetFile: Codable {
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

        // Read and parse file
        let workspaceSet: WorkspaceSetFile
        do {
            workspaceSet = try parseFile(at: resolvedPath)
        } catch let error as WorkspaceSetImportError {
            return .failure(error)
        } catch {
            return .failure(.readError(path: resolvedPath, underlying: error.localizedDescription))
        }

        // Perform the merge
        let result = mergeInto(tabManager: tabManager, workspaceSet: workspaceSet, dryRun: dryRun)
        return .success(result)
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
        // Build dedup index: normalized directory → existing workspace
        var existingByDir: [String: Workspace] = [:]
        for ws in tabManager.tabs {
            let key = normalizedDirectoryKey(ws.currentDirectory)
            existingByDir[key] = ws
        }

        // Build section lookup: lowercased name → existing section
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

        for sectionDef in workspaceSet.sections {
            let sectionName = sectionDef.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let sectionKey = sectionName.lowercased()
            let hasSection = !sectionName.isEmpty

            // Find or create section
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
                    // Workspace already exists — move to section if needed
                    if !dryRun, let section = targetSection {
                        let alreadyInSection = tabManager.sectionForWorkspace(existingWs.id)
                        if alreadyInSection == nil {
                            tabManager.moveWorkspaceToSection(tabId: existingWs.id, sectionId: section.id)
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

                // Create workspace
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

                // Assign to section
                if let section = targetSection {
                    tabManager.moveWorkspaceToSection(tabId: ws.id, sectionId: section.id)
                }

                // Add to dedup index so later duplicates in the same file are caught
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
            sectionsCreated: sectionsCreated
        )
    }

    /// Normalize a directory path for dedup comparison.
    /// Expands tilde, resolves `.`/`..`/double-slashes, strips trailing `/`.
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
