import CoreGraphics

struct GhosttyScrollbar: Equatable {
    let total: UInt64
    let offset: UInt64
    let len: UInt64

    init(total: Int, offset: Int, len: Int) {
        self.total = UInt64(max(0, total))
        self.offset = UInt64(max(0, offset))
        self.len = UInt64(max(0, len))
    }

    var totalRows: Int { Int(min(total, UInt64(Int.max))) }
    var offsetRows: Int { Int(min(offset, UInt64(Int.max))) }
    var visibleRows: Int { Int(min(len, UInt64(Int.max))) }
    var maxTopVisibleRow: Int { max(0, totalRows - visibleRows) }
    var incomingTopVisibleRow: Int { max(0, min(maxTopVisibleRow, offsetRows)) }
    var rowFromBottom: Int { max(0, totalRows - incomingTopVisibleRow - visibleRows) }
}

struct GhosttyScrollViewportSyncPlan: Equatable {
    let targetTopVisibleRow: Int
    let targetRowFromBottom: Int
    let storedTopVisibleRow: Int?
}

enum GhosttyViewportChangeSource {
    case userInteraction
    case internalCorrection
}

enum GhosttyViewportInteraction {
    case scrollWheel
    case bindingAction(action: String, source: GhosttyViewportChangeSource)
}

struct GhosttyExplicitViewportChangeConsumption: Equatable {
    let isExplicitViewportChange: Bool
    let remainingPendingExplicitViewportChange: Bool
}

func ghosttyScrollViewportSyncPlan(
    scrollbar: GhosttyScrollbar,
    storedTopVisibleRow: Int?,
    isExplicitViewportChange: Bool
) -> GhosttyScrollViewportSyncPlan {
    let targetTopVisibleRow = scrollbar.incomingTopVisibleRow
    let targetRowFromBottom = scrollbar.rowFromBottom
    let resultingStoredTopVisibleRow = targetRowFromBottom > 0 ? targetTopVisibleRow : nil
    return GhosttyScrollViewportSyncPlan(
        targetTopVisibleRow: targetTopVisibleRow,
        targetRowFromBottom: targetRowFromBottom,
        storedTopVisibleRow: resultingStoredTopVisibleRow
    )
}

func ghosttyBindingActionMutatesViewport(_ action: String) -> Bool {
    action.hasPrefix("scroll_") ||
        action.hasPrefix("jump_to_prompt:") ||
        action == "search:next" ||
        action == "search:previous" ||
        action == "navigate_search:next" ||
        action == "navigate_search:previous"
}

func ghosttyShouldMarkExplicitViewportChange(
    action: String,
    source: GhosttyViewportChangeSource
) -> Bool {
    guard source == .userInteraction else { return false }
    return ghosttyBindingActionMutatesViewport(action)
}

func ghosttyShouldBeginExplicitViewportChange(
    for interaction: GhosttyViewportInteraction
) -> Bool {
    switch interaction {
    case .scrollWheel:
        return true
    case let .bindingAction(action, source):
        return ghosttyShouldMarkExplicitViewportChange(action: action, source: source)
    }
}

func ghosttyConsumeExplicitViewportChange(
    pendingExplicitViewportChange: Bool,
    baselineScrollbar: GhosttyScrollbar?,
    incomingScrollbar: GhosttyScrollbar
) -> GhosttyExplicitViewportChangeConsumption {
    guard pendingExplicitViewportChange else {
        return GhosttyExplicitViewportChangeConsumption(
            isExplicitViewportChange: false,
            remainingPendingExplicitViewportChange: false
        )
    }
    return GhosttyExplicitViewportChangeConsumption(
        isExplicitViewportChange: true,
        remainingPendingExplicitViewportChange: false
    )
}

func ghosttyReconciledViewportScrollbar(
    incomingScrollbar: GhosttyScrollbar,
    storedTopVisibleRow: Int?,
    isExplicitViewportChange: Bool
) -> GhosttyScrollbar {
    incomingScrollbar
}

func ghosttyShouldIgnoreStalePassiveScrollbarUpdate(
    previousScrollbar: GhosttyScrollbar?,
    incomingScrollbar: GhosttyScrollbar,
    resolvedStoredTopVisibleRow: Int?,
    resultingStoredTopVisibleRow: Int?,
    isExplicitViewportChange: Bool
) -> Bool {
    false
}

func ghosttyLastSentRowAfterViewportSync(scrollbar: GhosttyScrollbar) -> Int {
    scrollbar.offsetRows
}

func ghosttyDocumentHeight(
    contentHeight: CGFloat,
    cellHeight: CGFloat,
    scrollbar: GhosttyScrollbar?
) -> CGFloat {
    guard cellHeight > 0, let scrollbar else {
        return contentHeight
    }
    let documentGridHeight = CGFloat(scrollbar.total) * cellHeight
    let padding = contentHeight - (CGFloat(scrollbar.len) * cellHeight)
    return documentGridHeight + padding
}
