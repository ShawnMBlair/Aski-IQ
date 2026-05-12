# Phase 9 — Expenses v1.1 migrations

**Status:** DRAFT — NOT APPLIED to any environment. Review before staging.

Locked spec: `~/.claude/.../memory/project_expenses_v1_spec.md`.
Build branch: `claude/expenses-v1` (forked off v1.0 head `943f0a2`).

## Release-group plan

Per the user's standing rule (release migrations in named small groups, never one big package), Expenses ships as two independently deployable migrations:

| File | Purpose | Depends on | Rollback |
|---|---|---|---|
| `EXP1_expenses_table.sql` | Parent table, FK guards, RLS, partial unique index, three-destination CHECK, self-approval CHECK, indexes for approval / reimbursement / project / MR / owner queues | `companies`, `projects`, `material_requests`, `employees`, `set_updated_at()`, `get_my_company_id()` | `drop table public.expenses cascade;` |
| `EXP2_expense_attachments_table.sql` | Receipt photos / PDFs (bytea inline), per-tenant RLS | EXP1 | `drop table public.expense_attachments cascade;` |

## Deploy sequence (when approved for staging)

1. Apply EXP1 to `aski-iq-staging` Supabase branch. Verify:
   - `select count(*) from pg_constraint where conname = 'expenses_single_destination_check';` → 1
   - `select count(*) from pg_constraint where conname = 'expenses_no_self_approval_check';` → 1
   - `select count(*) from pg_indexes where indexname = 'expenses_company_number_unique';` → 1
   - `select count(*) from pg_policies where tablename = 'expenses';` → 4
2. Apply EXP2 to staging. Verify:
   - `select count(*) from pg_indexes where indexname = 'expense_attachments_expense_idx';` → 1
   - `select count(*) from pg_policies where tablename = 'expense_attachments';` → 4
3. Smoke-test from staging iOS build: create a personal-paid receipt with no project → verify it lands; create a $5,500 personal-paid → verify approval_state forced to `pending_approval`.
4. Apply EXP1 + EXP2 to prod in that order.

## Out of scope for Phase 9

- **EXP3 (deferred):** approval audit log table. v1 stores `approved_by` / `approved_at` / `rejected_by` / `rejected_at` / `rejection_reason` directly on the expense row. If we need full state-transition history later, EXP3 adds an append-only `expense_approval_log` table.
- **EXP4 (deferred):** Supabase Storage migration for `file_data`. v1 stores bytea inline (matches CRM attachments + certificates). If payloads exceed the PostgREST 10 MB practical limit we move to Storage with a URL reference, exactly like the DJR PDF migration path.
- **CSV export schema:** depends on Helen's accounting-software answer (Sage / QuickBooks / Xero / other). No DB work needed — the CSV is generated client-side from the expenses table.

## Risks

- **Bytea payload size.** Receipts > 5 MB will push the row size and slow `select *`. Mitigation: never `select file_data` in list-view queries; always filter to per-row detail fetches. Document in iOS sync engine.
- **Self-approval CHECK timing.** If iOS sends `approved_by = submitted_by` due to a UX bug, the constraint rejects. iOS must catch this and surface a clear error. Wired through `SyncErrorMapper` already (catch block emits row-level `recordSyncError`).
- **Single-destination CHECK + destination_type backfill.** Mirrors the procurement migration pattern — no backfill needed here since the table is new.
- **`get_my_company_id()` dependency.** Confirmed live on prod since Phase 4. No new function required.
