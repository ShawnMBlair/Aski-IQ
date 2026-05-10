# Phase 2 — Foundational Baseline Migration

Per the [Aski IQ Major Issue Repair Plan](../../DEVELOPER_ROADMAP.md), Phase 2 closes the gap that prevents Supabase staging branches from replaying migration history cleanly.

## The gotcha (already documented in memory)

Aski IQ's foundational tables (`companies`, `projects`, `employees`, `profiles`, etc.) were created outside Supabase's migration history — likely via the dashboard / SQL editor before migration files were adopted. The first registered migration (`20260426191024_create_company_cost_codes`) references `companies(id)` as a FK target. On a fresh branch, that table doesn't exist yet, so the migration fails:

```
ERROR: relation "companies" does not exist
```

…and the branch goes to `MIGRATIONS_FAILED` status with zero public tables. The procurement migration validation back on 2026-05-09 worked around this by hand-bootstrapping prereq tables on the branch. Phase 2 is supposed to close that workaround by registering a foundational baseline migration.

## Status — 2026-05-10

**Partial v1 done, full v2 deferred.**

`00000000000000_foundational_baseline.sql` covers 4 of the most-FK'd pre-history tables: `companies`, `projects`, `employees`, `profiles`. Verified on branch `phase2-baseline-verify` (now deleted): the 4-table baseline gets the chain through 3 registered migrations (`create_company_cost_codes`, `create_import_batches`, `create_import_rows`) before failing at migration 4 (`quotes_add_missing_columns_and_rls`) for the next set of missing pre-history tables.

The partial baseline was rolled back from prod's `supabase_migrations.schema_migrations` so the migration history stays clean while v2 is in flight.

## Pre-history tables that need v2 coverage

Identified by: tables that exist in prod but no registered migration's SQL contains a `CREATE TABLE` for them.

| | | |
|---|---|---|
| `audit_snapshots` | `certificates` | `change_orders` |
| `clients` | `company_settings` | `crew_members` |
| `crews` | `crm_activities` | `crm_checklists` |
| `crm_contacts` | `crm_opportunities` | `crm_tasks` |
| `daily_job_reports` | `equipment` | `estimate_line_items` |
| `estimates` | `exception_logs` | `form_submissions` |
| `form_templates` | `incidents` | `invites` |
| `invoices` | `material_requests` | `project_assignments` |
| `project_budgets` | `purchase_order_acceptance_tokens` | `purchase_orders` |
| `quotes` | `rfis` | `schedule_entries` |
| `sub_contracts` | `subcontractors` | `suppliers` |
| `timesheet_entries` | | |

Plus the 4 already in v1: `companies`, `projects`, `employees`, `profiles`.

**~34 tables total.** Each needs minimum-viable column shape (just the FK targets and NOT NULL columns the early migrations expect).

## Recommended v2 approach for the dedicated session

1. **Audit each pre-history table's current shape** via `information_schema.columns` on prod. Capture:
   - Primary key column + type
   - All NOT NULL columns (these can't be added later without defaults)
   - All columns referenced by FKs in any registered migration
2. **Build the v2 baseline SQL** with `CREATE TABLE IF NOT EXISTS` for each. Include FK constraints inline.
3. **Test on a fresh branch** by inserting into `supabase_migrations.schema_migrations` with version `00000000000000`, then `create_branch`, then verify status reaches `FUNCTIONS_DEPLOYED` (not `MIGRATIONS_FAILED`).
4. **Iterate** on any migrations that still fail — likely needing column shape adjustments to match what subsequent migrations expect.
5. Once a fresh branch comes up green, **register the v2 baseline on prod** with the same INSERT pattern (idempotent — already a no-op on prod since tables exist).
6. Update [project_supabase_branching.md](../../../../../.claude/projects/-Users-shawnblair-Desktop-Aski-IQ-Desktop---Shawn-s-MacBook-Pro--2--Blair-Ventures-App--Blair-Ventures/memory/project_supabase_branching.md) memory note: replace the bootstrap-then-test workaround with "branches replay cleanly; just create + use".

## Time estimate

A focused session: 2–4 hours for v2 SQL drafting + 1–2 hours iteration on staging + 1 hour registration + verification. Per the original plan, "dedicated, multi-day" was conservative — likely fits in one full day.
