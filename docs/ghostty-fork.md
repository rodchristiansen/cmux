# Ghostty Fork Changes (manaflow-ai/ghostty)

This repo uses a fork of Ghostty for local patches that aren't upstream yet.
When we change the fork, update this document and the parent submodule SHA.

## Fork update checklist

1) Make changes in `ghostty/`.
2) Commit and push to `manaflow-ai/ghostty`.
3) Update this file with the new change summary + conflict notes.
4) In the parent repo: `git add ghostty` and commit the submodule SHA.

## Current fork changes

### 1) OSC 99 (kitty) notification parser

- Commit: `4713b7e23` (Add OSC 99 notification parser)
- Files:
  - `src/terminal/osc.zig`
  - `src/terminal/osc/parsers.zig`
  - `src/terminal/osc/parsers/kitty_notification.zig`
- Summary:
  - Adds a parser for kitty OSC 99 notifications and wires it into the OSC dispatcher.

### 2) macOS display link restart on display changes

- Commit: `7c2562cbe` (macos: restart display link after display ID change)
- Files:
  - `src/renderer/generic.zig`
- Summary:
  - Restarts the CVDisplayLink when `setMacOSDisplayID` updates the current CGDisplay.
  - Prevents a rare state where vsync is "running" but no callbacks arrive, which can look like a frozen surface until focus/occlusion changes.

### 3) Viewport VT export action for ANSI screen reads

- Commit: `3058878eb` (viewport VT export for read-screen/capture-pane ANSI mode)
- Files:
  - `src/Surface.zig`
  - `src/input/Binding.zig`
  - `src/input/command.zig`
- Summary:
  - Adds a `write_viewport_file` binding action alongside the existing screen/scrollback exports.
  - Lets cmux export just the visible viewport with ANSI escape sequences preserved, which is required for `read-screen --ansi` and `capture-pane --ansi` parity.

## Merge conflict notes

These files change frequently upstream; be careful when rebasing the fork:

- `src/terminal/osc/parsers.zig`
  - Upstream uses `std.testing.refAllDecls(@This())` in `test {}`.
  - Ensure `iterm2` import stays, and keep `kitty_notification` import added by us.

- `src/terminal/osc.zig`
  - OSC dispatch logic moves often. Re-check the integration points for the OSC 99 parser.

- `src/Surface.zig`
  - The binding-action switch and `writeScreenFile` location enum are active upstream areas. Keep the viewport export wired next to the existing screen/history/selection cases.

- `src/input/Binding.zig`
  - `Action` ordering matters for exhaustive switches elsewhere. Preserve the `write_viewport_file` case near the other write-screen actions.

- `src/input/command.zig`
  - If upstream changes command-palette metadata for write-screen actions, mirror those updates for `write_viewport_file` too.

If you resolve a conflict, update this doc with what changed.
