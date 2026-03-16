import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func testPreservesStoredTopVisibleRowWhenNewOutputArrives() {
    let plan = ghosttyScrollViewportSyncPlan(
        scrollbar: GhosttyScrollbar(total: 105, offset: 10, len: 20),
        storedTopVisibleRow: 70,
        isExplicitViewportChange: false
    )

    expect(plan.targetTopVisibleRow == 70, "expected stored top row to stay anchored")
    expect(plan.targetRowFromBottom == 15, "expected row-from-bottom to stay aligned with stored top row")
    expect(plan.storedTopVisibleRow == 70, "expected stored top row to persist while off bottom")
}

func testPendingExplicitViewportChangeDoesNotLeakIntoOutputOnlyUpdate() {
    let deferred = ghosttyConsumeExplicitViewportChange(
        pendingExplicitViewportChange: true,
        baselineScrollbar: GhosttyScrollbar(total: 100, offset: 10, len: 20),
        incomingScrollbar: GhosttyScrollbar(total: 100, offset: 10, len: 20)
    )

    expect(
        deferred.isExplicitViewportChange == false,
        "an unchanged scrollbar snapshot should not be treated as an explicit viewport change yet"
    )
    expect(
        deferred.remainingPendingExplicitViewportChange,
        "the explicit viewport change token should stay armed until something actually moves"
    )

    let leaked = ghosttyConsumeExplicitViewportChange(
        pendingExplicitViewportChange: deferred.remainingPendingExplicitViewportChange,
        baselineScrollbar: GhosttyScrollbar(total: 100, offset: 10, len: 20),
        incomingScrollbar: GhosttyScrollbar(total: 105, offset: 10, len: 20)
    )

    expect(
        leaked.isExplicitViewportChange == false,
        "output-only growth at the same anchored top row should not consume the explicit viewport change token as user scroll"
    )
    expect(
        leaked.remainingPendingExplicitViewportChange == false,
        "once a passive output update arrives without a viewport move, the stale explicit token should be cleared"
    )
}

func testPassiveScrollbarAcceptanceReconcilesIncomingOffsetToStoredTopRow() {
    let reconciledScrollbar = ghosttyReconciledViewportScrollbar(
        incomingScrollbar: GhosttyScrollbar(total: 242, offset: 0, len: 72),
        storedTopVisibleRow: 166,
        isExplicitViewportChange: false
    )

    expect(
        reconciledScrollbar == GhosttyScrollbar(total: 242, offset: 166, len: 72),
        "passive scrollbar acceptance should reconcile the incoming offset to the stored top row before viewport sync uses it"
    )
}

func testRegressivePassiveScrollbarSnapshotIsIgnoredWhileReviewingScrollback() {
    expect(
        ghosttyShouldIgnoreStalePassiveScrollbarUpdate(
            previousScrollbar: GhosttyScrollbar(total: 201, offset: 0, len: 102),
            incomingScrollbar: GhosttyScrollbar(total: 172, offset: 70, len: 102),
            resolvedStoredTopVisibleRow: 73,
            resultingStoredTopVisibleRow: nil,
            isExplicitViewportChange: false
        ),
        "regressive passive scrollbar snapshots should be ignored when they would clear an already-resolved scrollback anchor"
    )
}

func testLastSentRowUsesAppKitRowFromBottom() {
    expect(
        ghosttyLastSentRowAfterViewportSync(
            scrollbar: GhosttyScrollbar(total: 100, offset: 15, len: 20)
        ) == 65,
        "the last-sent row should use AppKit's bottom-origin row so live scrolling does not rubber-band"
    )
}

@main
struct TestRunner {
    static func main() {
        testPreservesStoredTopVisibleRowWhenNewOutputArrives()
        testPendingExplicitViewportChangeDoesNotLeakIntoOutputOnlyUpdate()
        testPassiveScrollbarAcceptanceReconcilesIncomingOffsetToStoredTopRow()
        testRegressivePassiveScrollbarSnapshotIsIgnoredWhileReviewingScrollback()
        testLastSentRowUsesAppKitRowFromBottom()
        print("PASS: ghostty viewport sync logic")
    }
}
