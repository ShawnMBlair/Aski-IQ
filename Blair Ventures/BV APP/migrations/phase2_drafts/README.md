# Phase 2 — Foundational Baseline Migration

Per the [Aski IQ Major Issue Repair Plan](../../DEVELOPER_ROADMAP.md), Phase 2 closes the gap that prevents Supabase staging branches from replaying migration history cleanly.

## The gotcha (already documented in memory)

Aski IQ's foundational tables (`companies`, `projects`, `employees`, `profiles`, etc.) were created outside Supabase's migration history — likely via the dashboard / SQL editor before migration files were adopted. The first registered migration (`20260426191024_create_company_cost_codes`) references `companies(id)` as a FK target. On a fresh branch, that table doesn't exist yet, so the migration fails:

```
ERROR: relation "companies" does not exist
```

…and the branch goes to `MIGRATIONS_FAILED` status with zero public tables.

## Status — 2026-05-10

**Three iterations tested; v4 deferred to dedicated session.**

Each iteration tested on a fresh staging branch advanced the chain further before hitting the next layer of pre-history dependencies:

| Version | Coverage | Replay outcome |
|---|---|---|
| `00000000000000_foundational_baseline.sql` (v1) | 4 tables: companies, projects, employees, profiles | Advanced 0→3 historical migrations. Failed at `quotes_add_missing_columns_and_rls` on missing pre-history tables (quotes, estimates, crm_opportunities). |
| `00000000000000_foundational_baseline_v2.sql` | 38 tables (v1 + 34 pre-history tables, minimal column shapes) | Advanced 0→4 historical migrations. Failed at same migration on missing pre-history column `quotes.client_id`. |
| `00000000000000_foundational_baseline_v3.sql` | 38 tables + ~25 index-derived pre-history columns | Advanced 0→7 historical migrations (through the 3 quote-related migrations + create_product_services_and_client_pricings). Failed at `harden_function_grants` on missing pre-history **functions**. |

All three versions were rolled back from `supabase_migrations.schema_migrations` after testing so prod migration history stays clean while v4 is in flight. The three SQL files in this directory remain as the foundation a v4 author can build on.

## Next layer to address (v4)

`harden_function_grants` (`20260428195136`) does `REVOKE EXECUTE ON FUNCTION` for ~30 pre-history functions. v4 needs `CREATE OR REPLACE FUNCTION` stubs for each. Identified by inspecting the failing migration's text:

- `handle_new_user()` — new-user trigger (populates profiles row)
- `stamp_company_id()` — generic `NEW.company_id` stamper trigger
- `set_updated_at()` — generic `NEW.updated_at = now()` trigger
- `set_quotes_updated_at()` — quote-specific updated_at trigger
- `update_crm_opportunity_timestamp()` — CRM opp updated_at trigger
- `get_my_company_id()` — RLS helper, returns `(select company_id from profiles where id = auth.uid())`
- `get_my_role()` — RLS helper for role lookup
- `is_field_role()` — predicate for role check
- `is_manager_or_above()` — predicate for role check
- `create_invite(...)` — invite-issuance RPC

Bodies can be no-op stubs at the baseline (e.g. `RETURNS trigger AS $$ BEGIN RETURN NEW; END; $$`) — later migrations `CREATE OR REPLACE` them with real implementations. Helpers that return values may need a real-shaped stub returning the simplest valid value (e.g. `RETURNS uuid AS $$ SELECT NULL::uuid $$`).

After v4 passes `harden_function_grants`, expect the next failure at one of `pin_function_search_path`, `fix_search_path_keep_schema_visible`, or `revoke_public_execute_on_helpers` — same pattern of pre-history function references. Identify + stub each. Continue until the test branch comes up green (status = `FUNCTIONS_DEPLOYED`, not `MIGRATIONS_FAILED`).

## Pre-history tables already covered (v3)

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

Plus the 4 in v1: `companies`, `projects`, `employees`, `profiles`. **38 tables total.**

## Recommended v4 approach for the dedicated session

1. Start from v3 SQL.
2. Add `CREATE OR REPLACE FUNCTION` stubs for the ~10 functions listed above.
3. Test on a fresh branch (the same INSERT-then-create-branch pattern). Identify next failing migration via:
   ```sql
   SELECT version, name FROM supabase_migrations.schema_migrations ORDER BY version;
   ```
   The last entry is the highest-applied; the next-version entry in main's full migration list is what failed.
4. If failure is another function-related migration, look at its text via:
   ```sql
   SELECT statements FROM supabase_migrations.schema_migrations WHERE version = '<failing version>';
   ```
   Extract function names. Add stubs. Re-test.
5. Iterate until green. Each cycle is ~3–5 minutes (branch creation + replay) + however long it takes to write the next batch of stubs.
6. Once the branch comes up `FUNCTIONS_DEPLOYED`:
   - Update [project_supabase_branching.md](../../../../../.claude/projects/-Users-shawnblair-Desktop-Aski-IQ-Desktop---Shawn-s-MacBook-Pro--2--Blair-Ventures-App--Blair-Ventures/memory/project_supabase_branching.md) memory note: replace the bootstrap-then-test workaround with "branches replay cleanly; just create + use".
   - Save the working SQL as `00000000000000_foundational_baseline.sql` (overwrite v1) — the canonical baseline.
   - Optionally: register on prod (it's a no-op there since all tables/functions already exist).

## Time estimate (v4 → green)

Probably 2–4 hours of focused work, dominated by the iteration cycles. The pattern is mechanical once the function-stub approach is established.
