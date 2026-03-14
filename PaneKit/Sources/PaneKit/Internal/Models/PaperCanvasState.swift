import Foundation
import SwiftUI

@Observable
final class PaperCanvasPane: Identifiable {
    let pane: PaneState
    var frame: CGRect

    var id: PaneID { pane.id }

    init(pane: PaneState, frame: CGRect) {
        self.pane = pane
        self.frame = frame.integral
    }
}

@Observable
final class PaperCanvasState {
    var panes: [PaperCanvasPane]
    var viewportOrigin: CGPoint
    var viewportSize: CGSize
    var canvasBounds: CGRect
    let paneGap: CGFloat

    init(
        panes: [PaperCanvasPane],
        viewportOrigin: CGPoint = .zero,
        viewportSize: CGSize = .zero,
        paneGap: CGFloat = 16
    ) {
        self.panes = panes
        self.viewportOrigin = viewportOrigin
        self.viewportSize = viewportSize
        self.paneGap = paneGap
        self.canvasBounds = .zero
        recomputeCanvasBounds()
        clampViewportOrigin()
    }

    func pane(_ paneId: PaneID) -> PaperCanvasPane? {
        panes.first { $0.pane.id == paneId }
    }

    var allPanes: [PaneState] {
        panes.map(\.pane)
    }

    var allPaneIds: [PaneID] {
        panes.map(\.pane.id)
    }

    @discardableResult
    func addPane(_ pane: PaneState, frame: CGRect) -> PaperCanvasPane {
        let placement = PaperCanvasPane(pane: pane, frame: frame)
        panes.append(placement)
        recomputeCanvasBounds()
        return placement
    }

    @discardableResult
    func removePane(_ paneId: PaneID) -> PaperCanvasPane? {
        guard let index = panes.firstIndex(where: { $0.pane.id == paneId }) else { return nil }
        let removed = panes.remove(at: index)
        recomputeCanvasBounds()
        return removed
    }

    func updateViewportSize(_ size: CGSize) {
        viewportSize = size
        recomputeCanvasBounds()
        clampViewportOrigin()
    }

    func reveal(_ frame: CGRect, margin: CGFloat = 32) {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        var nextOrigin = viewportOrigin
        if frame.minX < viewportOrigin.x + margin {
            nextOrigin.x = frame.minX - margin
        } else if frame.maxX > viewportOrigin.x + viewportSize.width - margin {
            nextOrigin.x = frame.maxX - viewportSize.width + margin
        }

        if frame.minY < viewportOrigin.y + margin {
            nextOrigin.y = frame.minY - margin
        } else if frame.maxY > viewportOrigin.y + viewportSize.height - margin {
            nextOrigin.y = frame.maxY - viewportSize.height + margin
        }

        viewportOrigin = nextOrigin
        clampViewportOrigin()
    }

    func centerViewport(on frame: CGRect) {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        viewportOrigin = CGPoint(
            x: frame.midX - viewportSize.width / 2,
            y: frame.midY - viewportSize.height / 2
        )
        clampViewportOrigin()
    }

    func panViewport(by delta: CGSize) {
        viewportOrigin.x += delta.width
        viewportOrigin.y += delta.height
        clampViewportOrigin()
    }

    func recomputeCanvasBounds() {
        let union = panes.reduce(into: CGRect.null) { partial, placement in
            partial = partial.union(placement.frame)
        }

        let minimumBounds = CGRect(origin: .zero, size: viewportSize)
        canvasBounds = union.isNull ? minimumBounds : union.union(minimumBounds)
    }

    func clampViewportOrigin() {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        let minX = canvasBounds.minX
        let maxX = max(canvasBounds.minX, canvasBounds.maxX - viewportSize.width)
        let minY = canvasBounds.minY
        let maxY = max(canvasBounds.minY, canvasBounds.maxY - viewportSize.height)

        viewportOrigin.x = min(max(viewportOrigin.x, minX), maxX)
        viewportOrigin.y = min(max(viewportOrigin.y, minY), maxY)
    }

    func resolvedSplitFrame(
        for targetFrame: CGRect,
        orientation: SplitOrientation,
        insertFirst: Bool
    ) -> CGRect {
        let translated = adjacentFrame(for: targetFrame, orientation: orientation, insertFirst: insertFirst)
        return resolveCollisions(for: translated, orientation: orientation, insertFirst: insertFirst)
    }

    private func adjacentFrame(
        for targetFrame: CGRect,
        orientation: SplitOrientation,
        insertFirst: Bool
    ) -> CGRect {
        switch orientation {
        case .horizontal:
            return CGRect(
                x: insertFirst ? targetFrame.minX - targetFrame.width - paneGap : targetFrame.maxX + paneGap,
                y: targetFrame.minY,
                width: targetFrame.width,
                height: targetFrame.height
            )
        case .vertical:
            return CGRect(
                x: targetFrame.minX,
                y: insertFirst ? targetFrame.minY - targetFrame.height - paneGap : targetFrame.maxY + paneGap,
                width: targetFrame.width,
                height: targetFrame.height
            )
        }
    }

    private func resolveCollisions(
        for proposedFrame: CGRect,
        orientation: SplitOrientation,
        insertFirst: Bool
    ) -> CGRect {
        let delta = orientation == .horizontal
            ? CGSize(width: (proposedFrame.width + paneGap) * (insertFirst ? -1 : 1), height: 0)
            : CGSize(width: 0, height: (proposedFrame.height + paneGap) * (insertFirst ? -1 : 1))

        var queue: [CGRect] = [proposedFrame]
        var shiftedPaneIds = Set<PaneID>()

        while let collisionFrame = queue.popLast() {
            let overlapping = panes.filter { placement in
                if shiftedPaneIds.contains(placement.pane.id) {
                    return false
                }

                switch orientation {
                case .horizontal:
                    let overlapsLane = placement.frame.maxY > collisionFrame.minY && placement.frame.minY < collisionFrame.maxY
                    let isInTravelDirection = insertFirst
                        ? placement.frame.minX <= collisionFrame.maxX
                        : placement.frame.maxX >= collisionFrame.minX
                    return overlapsLane && isInTravelDirection && placement.frame.intersects(collisionFrame.insetBy(dx: -paneGap / 2, dy: 0))
                case .vertical:
                    let overlapsLane = placement.frame.maxX > collisionFrame.minX && placement.frame.minX < collisionFrame.maxX
                    let isInTravelDirection = insertFirst
                        ? placement.frame.minY <= collisionFrame.maxY
                        : placement.frame.maxY >= collisionFrame.minY
                    return overlapsLane && isInTravelDirection && placement.frame.intersects(collisionFrame.insetBy(dx: 0, dy: -paneGap / 2))
                }
            }

            guard !overlapping.isEmpty else { continue }
            for placement in overlapping {
                shiftedPaneIds.insert(placement.pane.id)
                placement.frame = placement.frame.offsetBy(dx: delta.width, dy: delta.height).integral
                queue.append(placement.frame)
            }
        }

        recomputeCanvasBounds()
        return proposedFrame.integral
    }
}
