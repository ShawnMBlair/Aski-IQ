# v1.2 #5 — AI assistant "next action" upgrade

Closes the highest-leverage item in the v1.2 operational-refinements spec (`project_operational_refinements_v1_2.md`). 1 commit on top of post-Expenses main.

## What this fixes

The in-app AI assistant already detected gap conditions — empty crews, missing project budgets, stalled opportunities, expired certifications, pending expenses, failed syncs — but emitted *descriptions* ("crew has 0 members"). Users had to translate descriptions into actions themselves.

This branch ships a deterministic detection layer that emits *actions* with specific CTAs and deep-link destinations. The user taps the action; the app takes them where they need to go.

## What's in here

### `AskiNextActionEngine.swift` (pure-Swift, no Claude calls)

6 rule families, each capped at 5 items max to keep the dashboard readable:

| # | Rule | Severity | CTA |
|---|---|---|---|
| 1 | Active crew, zero members | warning | Assign Workers |
| 2 | Active project with approved quote + no `ProjectBudget` row | action | Create From Quote |
| 3 | Open opportunity, no open task, no activity in 14+ days | action | Schedule Follow-Up |
| 4 | Certificate expired or expiring within 14 days | critical / warning | Renew |
| 5 | Pending-approval expense ($5K+ → critical) | critical / action | Review |
| 6 | Records in `.failed` sync state (rolled up via `store.totalFailedSyncCount`) | warning | Open Failed Syncs |

Returns sorted by severity desc. `AskiNextAction.Destination` enum carries business-logic types (UUIDs, not SwiftUI types) so the engine is trivially testable.

### `NextActionsCard.swift` (SwiftUI)

- Mounts on the dashboard. Header shows count badge.
- Each action row: severity-colored icon, title, 2-line detail, CTA pill aligned right.
- Empty state: "You're all caught up" — visible reassurance that the detector ran successfully even when there's nothing to act on.
- `failedSyncs` route presents the existing `FailedSyncDetailView` sheet end-to-end.
- The 5 other destinations capture taps into a `pendingDestination` state — full deep-linking lands in v1.3 once each target view gets an `initialID:` init.

### `OfficeDashboardView` mount

The card sits between WeatherCard and the KPI grid — high enough up that opening the app surfaces what needs attention.

## Test plan

- [x] iOS simulator build green (iPhone 17 / iOS 26.4.1)
- [x] Mac Catalyst build green
- [x] 58 unit tests pass (no regressions)
- [ ] Manual smoke — iPad: open dashboard with a clean tenant → empty state shows
- [ ] Manual smoke — iPad: create a crew without members → "Crew has no workers" card appears
- [ ] Manual smoke — iPhone: trigger a sync failure (offline) → "Records didn't save" card appears → tap → Failed Syncs sheet opens
- [ ] Manual smoke — Mac Catalyst: card renders at full width (currently uses 16pt horizontal padding; verify it doesn't look orphaned on wide layouts)

## Deferred to v1.3 (or separate v1.2 commits)

- Deep-link destinations for expense / opportunity / crew / project / certificate (each target view needs an `initialID:` init)
- Foreman dashboard mount (separate dashboard, different roles see different actions)
- Auto-resolve closures (e.g. "Create budget from quote" could one-tap rather than navigate)
- Custom severity ordering / dismissal (user-tier preference)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
