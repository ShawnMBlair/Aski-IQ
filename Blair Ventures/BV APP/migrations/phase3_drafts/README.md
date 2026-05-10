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
| **Daily Job Reports** | ✅ DailyJobReport.swift `nextDJRNumber` | ✅ `DJR1_daily_job_reports_report_number.sql` (column add + backfill + partial unique) | This PR |
| **Contracts** | ✅ ContractStore.swift `nextContractNumber` | ✅ `CON1_contracts_number_partial_unique.sql` | This PR |
| **Sub-Contracts** | ✅ Subcontractor.swift `nextSubContractNumber` | ✅ `SC1_subcontracts_number_partial_unique.sql` | This PR |
| **Material Sales** | ✅ CRMCommercialBridge.swift `nextSaleNumber` | ✅ `MS1_material_sales_number_partial_unique.sql` | This PR |
| **Suppliers** (visibility only — no number) | n/a | n/a | This PR (SyncErrorMapper extension) |

## Apply order

Migrations in this folder are independent and can be applied in any order — each one only touches its own table's index. The Swift changes that pair with each migration ship in the same commit so a fresh checkout has both halves in sync.

## Phase 3 status — COMPLETE (pending prod-apply approval)

All 8 modules' Swift correctness fixes are landed on `claude/xenodochial-bhaskara-96bfe2`. **8 migration drafts** sit in this folder ready for prod application — `INV1`, `QUO1`, `CO1`, `RFI1`, `CON1`, `SC1`, `MS1`, plus `DJR1` (column add + backfill + partial unique; SyncEngine pull/push wired in the same commit).

**SyncErrorMapper coverage**: 10 of 10 commercial push functions now wire through it (was 1 at start of session) — Material Requests, Purchase Orders, Invoices, Quotes, Change Orders, RFIs, DJRs, Contracts, Sub-Contracts, Material Sales, Suppliers (the count is 11 if you split MR/PO; 10 push functions if grouped). Failed Sync UI shows per-row reasons everywhere now.

## Operator notes

After applying a migration, retry any rows in Failed Syncs that hit the legacy duplicate-number conflict — they should auto-pick the next available number on the second pass.

## Schema gaps surfaced by the Phase 3 audit — RESOLVED

| Module | Gap | Resolution |
|---|---|---|
| Daily Job Reports | Prod `daily_job_reports` had no `report_number` / `number` column. Swift `DailyJobReport.reportNumber` existed locally but `pushPendingDJRs` didn't include it in the upsert payload, so DJR numbers never reached the server. | Closed by `DJR1_daily_job_reports_report_number.sql` (column add + backfill + partial unique) plus SyncEngine `pullDJRs` / `pushPendingDJRs` wiring. After prod-apply, retry any DJRs in Failed Syncs to push their local number. |

