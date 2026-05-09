# Split Divider Position Bug Report

## Summary

Custom workspace layouts defined in `cmux.json` with non-default `split` values (e.g., `0.75`, `0.15`) are ignored at startup. All dividers render at `0.5` (50/50) regardless of the configured value.

## Expected Behavior

A layout configured with `"split": 0.75` should produce a 75/25 split. For example:

```json
{
  "direction": "horizontal",
  "split": 0.75,
  "children": [
    { "surface": { "command": "echo left" } },
    { "surface": { "command": "echo right" } }
  ]
}
```

Should produce a wide left pane (75%) and narrow right pane (25%).

## Actual Behavior

All splits render at 50/50 regardless of the `split` value in the config. The dividers can be manually dragged to the correct position after launch, but the initial layout ignores the configured percentages.

## Root Cause

The bug is in **Bonsplit** (the vendored split view library), specifically in:

```
vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitContainerView.swift
```

### The Animated Code Path (Lines 228-229)

When a split is created with an animation origin (which is the default for new workspace layouts), the target position is hardcoded to `0.5`:

```swift
if animationOrigin != nil {
    let targetPosition = availableSize * 0.5    // BUG: should be splitState.dividerPosition
    splitState.dividerPosition = 0.5            // BUG: overwrites the configured value
```

This means:

1. `Workspace.swift` correctly parses the `cmux.json` split value
2. `CmuxConfig.swift` correctly clamps it to `0.1...0.9`
3. `applyCustomDividerPositions` correctly calls `bonsplitController.setDividerPosition`
4. But the Bonsplit animated entry **overwrites** the position with `0.5`

### The Animation Completion Handler (Line 257)

The completion handler re-asserts the hardcoded value:

```swift
splitState.dividerPosition = 0.5
context.coordinator.lastAppliedPosition = 0.5
```

This creates a race condition: even if `setDividerPosition` fires after the animation starts, the completion handler resets it back to `0.5`.

### The Non-Animated Path Works Correctly (Line 280)

The else branch (no animation) correctly uses the configured value:

```swift
let position = availableSize * splitState.dividerPosition
context.coordinator.setPositionSafely(position, in: splitView, layout: false)
```

This confirms the bug is specifically in the animated code path.

## Call Chain

```
cmux.json "split": 0.75
    -> CmuxConfig.clampedSplitPosition = 0.75        (correct)
    -> Workspace.applyCustomDividerPositions()        (correct)
    -> BonsplitController.setDividerPosition(0.75)    (correct)
    -> SplitContainerView animated path               (BUG: ignores value, uses 0.5)
```

## Relevant Source Files

| File | Key Lines | Role |
|------|-----------|------|
| `vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitContainerView.swift` | 228-229, 257, 280 | Bug site - hardcoded 0.5 in animated path |
| `vendor/bonsplit/Sources/Bonsplit/Public/BonsplitController.swift` | 750 | `setDividerPosition` public API |
| `Sources/Workspace.swift` | 763, 785, 929 | Layout creation and divider position application |
| `Sources/CmuxConfig.swift` | 127, 179, 205 | Config parsing and clamping |

## Suggested Fix

### Option A: Use configured position in animated path (Recommended)

In `SplitContainerView.swift`, replace the hardcoded `0.5` with the actual configured divider position:

```swift
// BEFORE (lines 228-229):
if animationOrigin != nil {
    let targetPosition = availableSize * 0.5
    splitState.dividerPosition = 0.5

// AFTER:
if animationOrigin != nil {
    let targetPosition = availableSize * splitState.dividerPosition
    // Don't overwrite splitState.dividerPosition - it already has the correct value
```

And in the completion handler (line 257):

```swift
// BEFORE:
splitState.dividerPosition = 0.5
context.coordinator.lastAppliedPosition = 0.5

// AFTER:
// splitState.dividerPosition is already correct, just sync the coordinator
context.coordinator.lastAppliedPosition = splitState.dividerPosition
```

### Option B: Disable animation for workspace layouts

Pass `nil` for `animationOrigin` when creating splits from custom workspace commands, so they use the non-animated path which already works correctly.

### Option C: Re-apply positions after animation completes

Add a post-animation hook in `Workspace.swift` that calls `applyCustomDividerPositions` after a short delay (e.g., 0.3s) to override the hardcoded values. This is a workaround, not a proper fix.

## Reproduction

1. Create a `cmux.json` with any non-0.5 split value
2. Run the workspace command from the command palette
3. Observe all splits render at 50/50

## Environment

- cmux: fork from source
- Bonsplit: vendored in `vendor/bonsplit/`
- macOS (NSSplitView-based rendering)
