# Terminal Autosuggestions

Last updated: March 13, 2026

## Recommendation

cmux should have its own terminal autosuggestions, but it should not try to clone `zsh-autosuggestions` by scraping the rendered terminal.

The right first version is shell-assisted:

1. Keep suggestion ranking and UI in cmux.
2. Extend cmux shell integration to report the live editable command line for shells that can expose it cleanly.
3. Render suggestions in cmux as an overlay, not by mutating shell state until the user accepts.

This fits the current architecture better than a renderer-only approach and avoids a lot of prompt parsing edge cases.

## Why This Fits cmux

cmux already injects shell integration and gives each terminal surface stable IDs plus a socket path. The zsh integration already reports prompt-adjacent metadata like cwd, git branch, PR state, TTY, and port scan hints back into the app.

That matters because autosuggestions need two things:

1. A reliable view of the user's editable buffer.
2. A reliable place to render and accept the suggestion.

cmux already has the second half:

1. The terminal view can ask Ghostty for the live cursor/IME rect, which is enough to anchor ghost text or a small popup.
2. The app already has inline completion logic in the browser omnibar that can be reused as a ranking and acceptance model.

cmux does not yet have the first half:

1. `preexec` and `precmd` tell us when a command starts and when the prompt comes back.
2. They do not tell us what is currently inside the zle edit buffer while the user is typing.

## Why Screen Scraping Is the Wrong Default

cmux can read visible terminal text from Ghostty. That is useful for snapshots and debugging, but it is a weak foundation for autosuggestions.

Problems:

1. Multiline prompts and wrapped commands make it hard to recover the true editable buffer.
2. Right prompts, hidden prompt markers, and redraws already have shell-integration-specific edge cases.
3. Vi mode, partial completion menus, history search, and bracketed paste all change what the screen means.
4. A renderer-driven parser would need shell-specific heuristics anyway, but with less trustworthy data.
5. It would be easy to show the wrong suggestion or accept text into the wrong place.

Screen inference is still useful as a fallback or debug aid. It should not be the primary contract.

## Proposed Architecture

### 1. Add live command-line reporting to shell integration

For zsh, use zle hooks or wrapped widgets to report:

1. `BUFFER`
2. `CURSOR`
3. current keymap (`viins`, `vicmd`, etc.)
4. whether a completion menu or incremental search is active
5. whether the shell is at an editable prompt

Add a new socket command shaped roughly like:

`report_commandline "<buffer>" --cursor=<n> --mode=<mode> --shell=zsh --tab=<id> --panel=<id>`

Also add:

1. `clear_commandline` on `preexec`
2. rate limiting or coalescing so fast typing does not flood the socket
3. a versioned payload if we expect to expand the contract

This keeps shell-specific state acquisition in the shell, where the truth already exists.

### 2. Store per-panel command-line state in cmux

Treat it like existing per-panel metadata such as cwd and git branch:

1. store it by panel ID
2. keep focused-panel mirrors if needed
3. clear it when the panel exits or command execution starts

This should live off the typing hot path, similar to existing shell-reported metadata.

### 3. Build the suggestion engine in cmux

Keep ranking and history ownership in the app.

Initial sources:

1. shell history
2. cwd-sensitive command frequency
3. git-aware suggestions for common repo commands
4. recent accepted suggestions

Initial ranking:

1. exact prefix match
2. token-prefix match on the current word
3. same-directory boost
4. recent use boost
5. shorter completion tie-breaker

The first cut should stay local and deterministic. Do not involve remote or LLM-backed suggestions in the base feature.

### 4. Render as cmux-owned ghost text

Show a suggestion only when:

1. the shell says the prompt is editable
2. the cursor is at the end of the buffer
3. there is no IME marked text
4. terminal copy mode is off
5. there is no active completion menu/search mode from the shell

First UI:

1. inline ghost text only
2. one best suggestion
3. explicit accept shortcut
4. dismiss on normal edits, cursor movement, or mode changes

Later UI:

1. popup list under the cursor
2. next/previous suggestion navigation
3. per-source badges if that becomes useful

### 5. Accept suggestions without breaking shell behavior

Acceptance should send only the suffix beyond what the user typed.

Avoid pretending the suggestion is already in the shell buffer unless we have shell confirmation that it was accepted. The shell remains the source of truth.

The acceptance shortcut should be customizable through `KeyboardShortcutSettings`.

## Suggested Scope for v1

Build only for zsh first.

That keeps the integration honest:

1. zsh already has cmux shell integration
2. zle exposes the buffer directly
3. the user expectation is explicitly anchored to `zsh-autosuggestions`

If the design works, add bash support later through a different shell-side contract. Do not force a fake shell-agnostic abstraction too early.

## Risks

1. Input latency if shell hooks report too often or the app does expensive ranking on every change.
2. Wrong suggestions during IME composition or vi-mode transitions.
3. Keybinding conflicts with shell-native bindings, especially Tab and Right Arrow.
4. History reads becoming expensive if we re-scan large histfiles on every update.
5. Users expecting plugin-level parity immediately, including async completion sources and advanced widgets.

## Implementation Notes

1. Reuse the browser omnibar inline completion model for ranking, suffix display, and acceptance semantics where possible.
2. Keep all expensive work off the terminal key event path.
3. Add UI tests only after the shell-to-app contract is stable enough to avoid test flake.
4. Prefer a tiny, explicit shell protocol over trying to infer shell state from renderer output.

## Milestones

1. Add shell protocol for live command line state in zsh.
2. Store per-panel command line state in cmux and surface it in debug output.
3. Render inline ghost text for one best suggestion.
4. Add accept and dismiss actions, with customizable shortcut.
5. Add history store, ranking, and tests.
6. Decide whether a popup list is worth the added complexity.
