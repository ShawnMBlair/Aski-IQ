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

## Test coverage

| Suite | Covers | Lines | Status |
|---|---|---|---|
| `SyncErrorMapperTests` | All SQLSTATE → user-message mappings, Aski-specific patterns, fallback path | ~150 | ✅ Pure Swift (Wave 1) |
| `NumberGenerationTests` | parsed-max+1 logic for procurement / invoices / quotes / contracts, soft-delete exclusion, year reset, multi-tenant scope | ~200 | ✅ Pure Swift (Wave 1) |
| `FakeSyncClient` | In-memory `AskiSyncClient` test double — records upserts, serves canned select rows, drives error paths | ~80 | ✅ Wave 2 infrastructure |
| `SyncEngineDJRPushTests` | First SyncEngine push test using the protocol seam — daily_job_reports routing, report_number payload regression guard, syncStatus transitions, error-path SyncErrorMapper integration | ~140 | ✅ Wave 2 first slice |

## Phase 5 / Wave 2 — protocol-based sync testing

Wave 2 introduced `AskiSyncClient`, a narrow intent-shaped data-client protocol that replaces SyncEngine's direct dependence on the global `supabase` SupabaseClient. The first migrated push function is `pushPendingDJRs`. Subsequent push/pull functions migrate one at a time onto the same seam.

**Migration recipe** (per push function):
1. Replace `try await supabase.from(table).upsert(payload).execute()` with `try await client.upsert(payload, into: table)`.
2. Drop `private` from the function so `@testable import` can reach it.
3. Add a `SyncEngine<X>PushTests.swift` modeled after `SyncEngineDJRPushTests` — assert routing, payload shape, syncStatus transitions, error path.

**Migration recipe** (per pull function):
1. Replace `try await supabase.from(table).select().eq(...).execute().value` with:
   - No ordering: `try await client.select(RowType.self, from: table, filters: [.eq("company_id", id), .eq("is_deleted", false)])`
   - With ordering: `try await client.select(RowType.self, from: table, filters: [...], orderBy: "name", ascending: true)`
2. Drop `private`.
3. Extend the existing `SyncEngine<X>PushTests.swift` (or add a `…PullTests.swift`) with cases that pre-seed `fake.cannedSelect[table] = [stubbedRow]` and assert on `store.<X>` after the call.

`pullDJRs` (slice 4) is the migrated reference — see `SyncEngineDJRPushTests.test_pullDJRs_issuesCorrectSelectQuery` and `…_skipsExternalRoles` for the assertion shape.

**Migration scope status (commits b260caa → 8bd349c → 1c6f540 + slice 4):**
- ✅ Push: all 31 single-row upserts on `SyncEngine` migrated (slices 1–3)
- 🔄 Pull: 1 of ~25 migrated (`pullDJRs`); rest are mechanical with the orderBy overload
- ⬜ Multi-row pushes (e.g. `upsertBatch` for line items) — not yet on the protocol; add when first call site needs them

## Still deferred (Wave 3+)

- **RLS policy verification** — needs an integration test target that runs against a real Supabase branch (Pro plan dependency, CI-time cost).
- **Approval engine** — once Phase 6 / Wave 4 swaps `canPerform` to engine-driven, build approval-route tests on top.

## What this proves right now

Even with just Wave 1 you get:
- A working test target with continuous-integration scaffolding.
- Regression catch on the parts of the codebase that change most often (number generators, error mappers).
- A pattern other modules can copy — adding tests for new pure-Swift logic is now trivial.

Run the tests on every PR before merging, even informally, until CI is wired up.
