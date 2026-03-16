import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GhosttyScrollbarSyncPlanTests: XCTestCase {
    func testPreservesStoredTopVisibleRowWhenNewOutputArrives() {
        let plan = ghosttyScrollViewportSyncPlan(
            scrollbar: GhosttyScrollbar(total: 105, offset: 10, len: 20),
            storedTopVisibleRow: 70,
            isExplicitViewportChange: false
        )

        XCTAssertEqual(plan.targetTopVisibleRow, 70)
        XCTAssertEqual(plan.targetRowFromBottom, 15)
        XCTAssertEqual(plan.storedTopVisibleRow, 70)
    }

    func testPendingExplicitViewportChangeDoesNotLeakIntoOutputOnlyUpdate() {
        let deferred = ghosttyConsumeExplicitViewportChange(
            pendingExplicitViewportChange: true,
            baselineScrollbar: GhosttyScrollbar(total: 100, offset: 10, len: 20),
            incomingScrollbar: GhosttyScrollbar(total: 100, offset: 10, len: 20)
        )

        XCTAssertFalse(deferred.isExplicitViewportChange)
        XCTAssertTrue(deferred.remainingPendingExplicitViewportChange)

        let leaked = ghosttyConsumeExplicitViewportChange(
            pendingExplicitViewportChange: deferred.remainingPendingExplicitViewportChange,
            baselineScrollbar: GhosttyScrollbar(total: 100, offset: 10, len: 20),
            incomingScrollbar: GhosttyScrollbar(total: 105, offset: 10, len: 20)
        )

        XCTAssertFalse(leaked.isExplicitViewportChange)
        XCTAssertFalse(leaked.remainingPendingExplicitViewportChange)
    }

    func testPassiveScrollbarAcceptanceReconcilesIncomingOffsetToStoredTopRow() {
        let reconciledScrollbar = ghosttyReconciledViewportScrollbar(
            incomingScrollbar: GhosttyScrollbar(total: 242, offset: 0, len: 72),
            storedTopVisibleRow: 166,
            isExplicitViewportChange: false
        )

        XCTAssertEqual(reconciledScrollbar, GhosttyScrollbar(total: 242, offset: 166, len: 72))
    }

    func testRegressivePassiveScrollbarSnapshotIsIgnoredWhileReviewingScrollback() {
        XCTAssertTrue(
            ghosttyShouldIgnoreStalePassiveScrollbarUpdate(
                previousScrollbar: GhosttyScrollbar(total: 201, offset: 0, len: 102),
                incomingScrollbar: GhosttyScrollbar(total: 172, offset: 70, len: 102),
                resolvedStoredTopVisibleRow: 73,
                resultingStoredTopVisibleRow: nil,
                isExplicitViewportChange: false
            )
        )
    }

    func testLastSentRowUsesAppKitRowFromBottom() {
        XCTAssertEqual(
            ghosttyLastSentRowAfterViewportSync(
                scrollbar: GhosttyScrollbar(total: 100, offset: 15, len: 20)
            ),
            65
        )
    }
}
