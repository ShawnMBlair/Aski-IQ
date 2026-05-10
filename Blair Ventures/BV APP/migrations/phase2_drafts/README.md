# Phase 2 — Foundational Baseline Migration

Per the [Aski IQ Major Issue Repair Plan](../../DEVELOPER_ROADMAP.md), Phase 2 closes the gap that prevents Supabase staging branches from replaying migration history cleanly.

## The gotcha

Aski IQ's foundational tables (`companies`, `projects`, `employees`, `profiles`, etc.) were created outside Supabase's migration history — likely via the dashboard / SQL editor before migration files were adopted. The first registered migration (`20260426191024_create_company_cost_codes`) references `companies(id)` as a FK target. On a fresh branch, that table doesn't exist yet, so the migration fails:

```
ERROR: relation "companies" does not exist
```

…and the branch goes to `MIGRATIONS_FAILED` status with zero public tables.

## Status — 2026-05-10

**Five iterations tested; v6+ deferred to dedicated session.**

Each iteration tested on a fresh staging branch advanced the chain further before hitting the next layer of pre-history dependencies. Each version was registered with version `00000000000000` (sorts before all real migrations), tested, then rolled back to keep prod migration history clean.

| Version | Coverage | Migrations replayed |
|---|---|---|
| `*_foundational_baseline.sql` (v1) | 4 tables | 0 → 3 |
| `*_v2.sql` | 38 tables (minimal) | 0 → 4 |
| `*_v3.sql` | 38 tables + 25 index-derived columns | 0 → 7 |
| `*_v4.sql` | v3 + 10 pre-history function stubs | 0 → 18 |
| **`*_v5.sql`** ← latest | v4 + `updated_at` on 25 tables | **0 → 45** ← most-advanced |

v5 passes ~50% of the migration history. **All five SQL files remain in this directory** as documented progress for the v6 author.

## The progression each iteration uncovered

| Layer | What was missing | Fixed in |
|---|---|---|
| Foundational tables | companies, projects, employees, profiles | v1 |
| Other pre-history tables (~34) | quotes, estimates, clients, crm_*, invoices, etc. | v2 |
| Pre-history columns referenced by indexes | client_id, project_id, opportunity_id, contact_id, is_deleted, etc. (~25 total) | v3 |
| Pre-history functions (10) | handle_new_user, stamp_company_id, set_updated_at, get_my_company_id, etc. | v4 |
| Pre-history `updated_at` columns | 25 tables that the soft-delete migration assumes already have updated_at | v5 |
| **Pre-history columns referenced by CHECK constraints** | **status, contingency_percent, start_date, end_date, etc.** | **v6 (next)** |

## v5 migration sequence (what worked)

The 45 migrations v5 cleared, grouped — useful as a "known good" reference:

- v5 baseline (38 tables + 10 function stubs)
- create_company_cost_codes / create_import_batches / create_import_rows
- quotes_add_missing_columns_and_rls / quotes_add_discount_tax_rate
- create_product_services_and_client_pricings
- harden_function_grants / pin_function_search_path / fix_search_path_keep_schema_visible / revoke_public_execute_on_helpers
- drop_permissive_audit_snapshots_select / add_quote_estimate_revisions
- add_soft_delete_and_timestamp_columns / create_material_sales_table / add_soft_delete_to_djr_and_incidents / add_soft_delete_to_remaining_tables
- align_clients_table_with_swift_payload / cleanup_sample_data_for_aski_iq_tenant
- 8 enforce_*_company_id_not_null migrations
- cleanup_orphan_company_id_rows / add_account_deletion_log
- AI hardening: per-company key, limits, vault, RPCs, idempotency (5 migrations)
- quote_acceptance_tokens
- contracts_module_phase1 + phase2a/b/c/f (5 migrations)
- stripe_payment_recording / qbo_integration / esignature_requests
- workflow_automation_sync / role_based_rls_for_financial_tables
- **(fails here at estimate_converted_status)**

## v6 next-step plan

v5 fails at migration 46 (`estimate_converted_status`) on missing `estimates.status` referenced by a new CHECK constraint. Diagnostic SQL run during v5 analysis surfaced the full set of CHECK-constraint columns to add for v6:

| Table | Missing pre-history columns to add |
|---|---|
| `estimates` | `status text`, `contingency_percent numeric DEFAULT 0`, `overhead_percent numeric DEFAULT 0`, `profit_percent numeric DEFAULT 0`, `loss_reason text` |
| `quotes` | `contingency_percent numeric DEFAULT 0`, `discount_percent numeric DEFAULT 0`, `tax_rate numeric`, `quote_date timestamptz DEFAULT now()` |
| `invoices` | `tax_rate numeric`, `invoice_date timestamptz DEFAULT now()` |
| `material_sales` | (table created by `create_material_sales_table`; CHECK on `tax_rate` — column needs to be on the migration's CREATE TABLE) |
| `projects` | `start_date timestamptz`, `end_date timestamptz`, `contract_value numeric` |
| `sub_contracts` | `retention_percent numeric DEFAULT 10`, `start_date timestamptz`, `end_date timestamptz`, `contract_value numeric DEFAULT 0`, `invoiced_to_date numeric DEFAULT 0`, `paid_to_date numeric DEFAULT 0` |

After v6 passes through `estimate_converted_status` and the next ~10 migrations, expect the next failure layer. The discovery loop will continue; each iteration should advance ~5-10 migrations before the next missing object surfaces.

## Recommended v6 approach for the dedicated session

1. Start from v5 SQL.
2. Add the column list above to v6.
3. Test on a fresh branch (the same INSERT-then-create-branch pattern). Look at what failed via:
   ```sql
   -- On the failed branch:
   SELECT version, name FROM supabase_migrations.schema_migrations ORDER BY version;
   -- The last entry is the highest-applied; the next-version entry in main's
   -- full migration list is what failed.
   ```
4. If failure is column-related, add the column to v7. If function-related, add a stub. If RLS/policy-related, look for missing helpers.
5. Iterate until the branch comes up `FUNCTIONS_DEPLOYED`.
6. Once green:
   - Update [project_supabase_branching.md](../../../../../.claude/projects/-Users-shawnblair-Desktop-Aski-IQ-Desktop---Shawn-s-MacBook-Pro--2--Blair-Ventures-App--Blair-Ventures/memory/project_supabase_branching.md) memory note to mark the gotcha closed.
   - Save the working SQL as `00000000000000_foundational_baseline.sql` (canonical) — overwrite v1.
   - Optionally: register on prod (no-op there since all objects already exist).

## Estimated remaining work

v5 → green: probably 5-10 more iterations, each ~5 minutes (branch creation + replay + analysis + edit). 1-2 hours of focused work. The pattern is mechanical now that the iteration framework is established.
