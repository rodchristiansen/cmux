# cmux iOS App

## Licensing
- Files under `ios/**` are proprietary and governed by `ios/LICENSE`.
- Repository-wide license scope is documented in `../LICENSE_SCOPE.md`.

## Sync from a manaflow checkout
From the `ios/` directory:

```bash
./scripts/sync-public-convex-vars.sh --source-root ~/fun/manaflow
./scripts/sync-convex-types.sh --source-root ~/fun/manaflow
```

- `sync-public-convex-vars.sh` copies only whitelisted public env keys into
  `Sources/Config/LocalConfig.plist` (gitignored).
- `sync-convex-types.sh` regenerates
  `Sources/Generated/ConvexApiTypes.swift` using Convex schema from
  the selected `manaflow` checkout or worktree.

## Mobile workspace architecture
- GRDB is the mandatory local read model for the workspace and inbox surface. The app boots from cache first, then reconciles live data.
- Convex is the current operational source of truth for machine presence, workspace rows, unread state, push registration, and daemon metadata.
- iOS side effects go through the mobile HTTP boundary. The app should not call Convex mutations directly for mark-read, push, machine-session, heartbeat, or daemon-ticket flows.
- Live workspace rows still come from a dedicated Convex sync seam, not directly from view models.
- PostHog is analytics only. It is not an operational database and should never receive terminal content, TLS pins, or ticket secrets.

## Living Spec
- Sidebar terminal roadmap and implementation status:
  `docs/terminal-sidebar-living-spec.md`.
