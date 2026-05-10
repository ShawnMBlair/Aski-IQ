# BV APP Tests — Phase 5 of the Aski IQ stabilization plan

This directory holds the first wave of unit tests for Aski IQ. The tests are **pure Swift** — they don't need a Supabase mock, network access, or any external dependencies. They cover logic that lives in plain types: error mapping, number generation, and the like.

## Why test target setup is documented, not automated

Adding an Xcode unit-testing-bundle target requires editing `BV APP.xcodeproj/project.pbxproj`, which is a fragile binary-ish file format. A bad edit can break the whole project. The 5-minute manual setup in Xcode is the safer path. Once the target exists, future test files are simple drag-and-drop adds.

## Setup steps (one-time, ~5 minutes)

1. Open `BV APP.xcodeproj` in Xcode.
2. **File → New → Target…**
3. Choose **iOS → Unit Testing Bundle**.
4. **Product Name:** `BV APP Tests`. **Target to be tested:** `BV APP`.
5. Click Finish. Xcode creates a new `BV APP Tests/` group with a placeholder `BV_APP_Tests.swift`.
6. Delete the placeholder Xcode created.
7. **Drag** every `.swift` file from this directory into the new `BV APP Tests` group in Xcode's project navigator. Make sure "Add to target: **BV APP Tests**" is checked, "Add to target: **BV APP**" is unchecked.
8. ⌘U to run the tests. They should all pass.

After that, every future test file is just: drop into this directory + drag into the Xcode group.

## Test coverage as of Phase 5 / Wave 1

| Suite | Covers | Lines | Status |
|---|---|---|---|
| `SyncErrorMapperTests` | All SQLSTATE → user-message mappings, Aski-specific patterns, fallback path | ~150 | ✅ Pure Swift |
| `NumberGenerationTests` | parsed-max+1 logic for procurement / invoices / quotes / contracts, soft-delete exclusion, year reset, multi-tenant scope | ~200 | ✅ Pure Swift |

## What's deferred to Phase 5 / Wave 2

The following test areas need infrastructure work (a protocol-shaped `SupabaseClient` to inject mocks) before they can ship as unit tests:

- **Sync push success / failure paths** — `pushPendingMaterialRequests` etc. The current code calls `supabase.from(...)` directly. Refactoring to take a `SupabaseClientProtocol` parameter unlocks mockability. Substantial scope (~30 push functions); recommend a focused session.
- **Sync pull / merge** — same shape.
- **RLS policy verification** — needs an integration test target that runs against a real Supabase branch (Pro plan dependency you've already met, but each integration test costs CI time).
- **Approval engine** — once the workflow_settings generalization (Phase 6) lands, build approval-route tests on top.

These are tracked as Phase 5 / Wave 2 in the strategic plan.

## What this proves right now

Even with just Wave 1 you get:
- A working test target with continuous-integration scaffolding.
- Regression catch on the parts of the codebase that change most often (number generators, error mappers).
- A pattern other modules can copy — adding tests for new pure-Swift logic is now trivial.

Run the tests on every PR before merging, even informally, until CI is wired up.
