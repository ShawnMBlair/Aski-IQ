# Phase 3 — Number-generation audit (drafts)

Per the [Aski IQ Major Issue Repair Plan](../../BV%20APP/DEVELOPER_ROADMAP.md), Phase 3 replaces the local `count + 1` number-generation pattern across modules with `parsed-max + 1` scoped to (company, year), backed by a partial unique index on `(company_id, <number>) WHERE is_deleted = false`.

Pattern (proven in procurement):
1. Swift helper rewrites `next<X>Number()` to use the parsed-max+1 form.
2. SQL migration adds a partial unique index.
3. Sync engine catch block reports unique-violation via `SyncErrorMapper`.

## Module status

| Module | Swift helper | DB migration | Pushed |
|---|---|---|---|
| Material Requests | ✅ Procurement.swift | ✅ Section 18 of `SupabaseMigration_MaterialRequestWorkflow.sql` | Procurement PR |
| Purchase Orders | ✅ Procurement.swift | ✅ Section 18 of `SupabaseMigration_MaterialRequestWorkflow.sql` | Procurement PR |
| **Invoices** | ✅ Invoice.swift `nextInvoiceNumber` | ✅ `INV1_invoices_number_partial_unique.sql` | This PR |
| **Quotes** | ✅ QuoteViews.swift `nextQuoteNumber` | ✅ `QUO1_quotes_number_partial_unique.sql` | This PR |
| **Change Orders** | ✅ ChangeOrder.swift `nextCONumber` | ✅ `CO1_change_orders_number_partial_unique.sql` (per-project scope) | This PR |
| **RFIs** | ✅ RFI.swift `nextRFINumber` | ✅ `RFI1_rfis_number_partial_unique.sql` (per-project scope) | This PR |
| **Daily Job Reports** | ✅ DailyJobReport.swift `nextDJRNumber` | ⚠️ Blocked — see Schema Gaps below | This PR (Swift only) |
| Contracts | ⏳ Pending | ⏳ Pending | — |
| Sub-Contracts | ⏳ Pending | ⏳ Pending | — |
| RFIs | ⏳ Pending (per-project) | ⏳ Pending | — |
| Material Sales | ⏳ Audit needed | ⏳ TBD | — |

## Apply order

Migrations in this folder are independent and can be applied in any order — each one only touches its own table's index. The Swift changes that pair with each migration ship in the same commit so a fresh checkout has both halves in sync.

## Operator notes

After applying a migration, retry any rows in Failed Syncs that hit the legacy duplicate-number conflict — they should auto-pick the next available number on the second pass.

## Schema gaps surfaced by the Phase 3 audit

| Module | Gap | Impact | Action |
|---|---|---|---|
| Daily Job Reports | Prod `daily_job_reports` has no `report_number` / `number` column. Swift `DailyJobReport.reportNumber` exists locally but `pushPendingDJRs` doesn't include it in the upsert payload, so DJR numbers never reach the server. | DJR numbers are local-only — different devices show different numbers for the same DJR row. Audit / reporting can't reference a stable DJR identifier. Partial unique index can't apply until column is added. | Pre-Phase-3 migration to **add `report_number text` + backfill** is needed. Track as a separate ticket; the Swift correctness fix landed in this PR is a no-op until the column exists. |

