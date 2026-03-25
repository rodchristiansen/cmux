import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class PaperLayoutWidthPersistenceTests: XCTestCase {

    // MARK: - treeSnapshot divider ratio encoding

    @MainActor
    func testTreeSnapshotEncodesEqualWidths() {
        let controller = PaperLayoutController()
        controller.viewportWidth = 2000
        _ = controller.addPane(width: 1000)
        _ = controller.addPane(width: 1000)

        let tree = controller.treeSnapshot()
        guard case .split(let split) = tree else {
            XCTFail("Expected split node for 2 panes")
            return
        }
        XCTAssertEqual(split.dividerPosition, 0.5, accuracy: 0.001,
                       "Equal-width panes should have divider at 0.5")
    }

    @MainActor
    func testTreeSnapshotEncodesUnequalWidths() {
        let controller = PaperLayoutController()
        controller.viewportWidth = 2100
        _ = controller.addPane(width: 700)   // 1/3
        _ = controller.addPane(width: 1400)  // 2/3

        let tree = controller.treeSnapshot()
        guard case .split(let split) = tree else {
            XCTFail("Expected split node for 2 panes")
            return
        }
        // div = 700 / (700 + 1400) = 0.333
        XCTAssertEqual(split.dividerPosition, 1.0/3.0, accuracy: 0.001,
                       "1/3 + 2/3 split should have divider at 0.333")
    }

    @MainActor
    func testTreeSnapshotEncodesThreePanes() {
        let controller = PaperLayoutController()
        controller.viewportWidth = 2100
        _ = controller.addPane(width: 700)
        _ = controller.addPane(width: 700)
        _ = controller.addPane(width: 700)

        let tree = controller.treeSnapshot()
        // Right-leaning: split(pane0, split(pane1, pane2))
        guard case .split(let outer) = tree else {
            XCTFail("Expected outer split")
            return
        }
        // outer div = 700 / 2100 = 0.333
        XCTAssertEqual(outer.dividerPosition, 1.0/3.0, accuracy: 0.001)

        guard case .split(let inner) = outer.second else {
            XCTFail("Expected inner split")
            return
        }
        // inner div = 700 / 1400 = 0.5
        XCTAssertEqual(inner.dividerPosition, 0.5, accuracy: 0.001)
    }

    // MARK: - Width restoration from divider ratios

    @MainActor
    func testRestoreEqualWidths() {
        // Create a controller with 2 equal panes
        let controller = PaperLayoutController()
        controller.viewportWidth = 2000
        _ = controller.addPane(width: 1000)
        _ = controller.addPane(width: 1000)

        // Record original widths
        let originalWidths = controller.panes.map(\.width)

        // Get tree snapshot (simulating save)
        let tree = controller.treeSnapshot()

        // Create a new controller and simulate restore
        let restored = PaperLayoutController()
        restored.viewportWidth = 2000
        // Simulate: restore creates 2 panes via splitPane
        let pane1 = restored.addPane(width: 2000)
        _ = restored.splitPane(pane1, orientation: .horizontal)
        // Now apply divider ratios
        applyDividerRatios(from: tree, to: restored)

        let restoredWidths = restored.panes.map(\.width)
        XCTAssertEqual(restoredWidths.count, 2)
        for (orig, rest) in zip(originalWidths, restoredWidths) {
            XCTAssertEqual(orig, rest, accuracy: 1.0,
                           "Restored width should match original within 1px")
        }
    }

    @MainActor
    func testRestoreUnequalWidths() {
        let controller = PaperLayoutController()
        controller.viewportWidth = 2100
        _ = controller.addPane(width: 700)
        _ = controller.addPane(width: 1400)

        let originalWidths = controller.panes.map(\.width)
        let tree = controller.treeSnapshot()

        let restored = PaperLayoutController()
        restored.viewportWidth = 2100
        let pane1 = restored.addPane(width: 2100)
        _ = restored.splitPane(pane1, orientation: .horizontal)
        applyDividerRatios(from: tree, to: restored)

        let restoredWidths = restored.panes.map(\.width)
        XCTAssertEqual(restoredWidths.count, 2)
        XCTAssertEqual(restoredWidths[0], originalWidths[0], accuracy: 1.0)
        XCTAssertEqual(restoredWidths[1], originalWidths[1], accuracy: 1.0)
    }

    @MainActor
    func testRestorePreservesRatiosOnDifferentWindowSize() {
        let controller = PaperLayoutController()
        controller.viewportWidth = 2100
        _ = controller.addPane(width: 700)
        _ = controller.addPane(width: 1400)

        let tree = controller.treeSnapshot()

        // Restore to a smaller window
        let restored = PaperLayoutController()
        restored.viewportWidth = 1500
        let pane1 = restored.addPane(width: 1500)
        _ = restored.splitPane(pane1, orientation: .horizontal)
        applyDividerRatios(from: tree, to: restored)

        let total = restored.panes.reduce(CGFloat(0)) { $0 + $1.width }
        let ratio0 = restored.panes[0].width / total
        let ratio1 = restored.panes[1].width / total

        // Original ratios: 700/2100 = 0.333, 1400/2100 = 0.667
        XCTAssertEqual(ratio0, 1.0/3.0, accuracy: 0.01,
                       "Width ratio should be preserved on different window size")
        XCTAssertEqual(ratio1, 2.0/3.0, accuracy: 0.01)
    }

    // MARK: - Helpers

    /// Simulate the divider ratio extraction and application from Workspace.applySessionDividerPositions
    @MainActor
    private func applyDividerRatios(from tree: ExternalTreeNode, to controller: PaperLayoutController) {
        var ratios: [Double] = []
        extractRatios(from: tree, into: &ratios)

        let panes = controller.panes
        guard !ratios.isEmpty, panes.count > 1 else { return }

        let totalWidth = panes.reduce(CGFloat(0)) { $0 + $1.width }
        guard totalWidth > 0 else { return }

        var remaining = totalWidth
        for i in 0..<min(ratios.count, panes.count - 1) {
            let width = remaining * CGFloat(ratios[i])
            panes[i].width = max(width, 100)
            remaining -= panes[i].width
        }
        if let lastPane = panes.last {
            lastPane.width = max(remaining, 100)
        }
    }

    private func extractRatios(from node: ExternalTreeNode, into ratios: inout [Double]) {
        switch node {
        case .split(let split):
            ratios.append(split.dividerPosition)
            extractRatios(from: split.second, into: &ratios)
        case .pane:
            break
        }
    }
}
