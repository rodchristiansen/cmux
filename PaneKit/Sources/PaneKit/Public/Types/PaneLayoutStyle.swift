import Foundation

/// Internal layout engine selection for pane geometry.
///
/// `splitTree` preserves the legacy Bonsplit divider model.
/// `paperCanvas` keeps pane sizes stable on a larger scrollable canvas.
public enum PaneLayoutStyle: Sendable {
    case splitTree
    case paperCanvas
}
