# Phase 2 — Foundational Baseline Migration ✅ CLOSED 2026-05-10

Per the [Aski IQ Major Issue Repair Plan](../../DEVELOPER_ROADMAP.md), Phase 2 closes the gap that prevented Supabase staging branches from replaying migration history cleanly.

## Status: GREEN

The foundational baseline is **registered on prod** at `supabase_migrations.schema_migrations` version `00000000000000` and **verified on a fresh branch**: replays all 104 historical migrations and reaches `FUNCTIONS_DEPLOYED` status with 77 public tables created.

The "branches come up empty" gotcha is closed. Future migration testing follows the simple flow: `create_branch` → wait → `apply_migration` for the new migration under test → verify. No more bootstrap workaround.

## What was the gotcha?

Aski IQ's foundational tables (`companies`, `projects`, `employees`, `profiles`, etc.) were created outside Supabase's migration history — likely via the dashboard / SQL editor before migration files were adopted. The first registered migration (`20260426191024_create_company_cost_codes`) referenced `companies(id)` as a FK target. On a fresh branch, that table didn't exist yet, so the migration failed:

```
ERROR: relation "companies" does not exist
```

…and the branch went to `MIGRATIONS_FAILED` status with zero public tables. Beyond foundational tables, ~30 pre-history functions (RLS helpers, trigger functions, RPCs) were also missing from a fresh branch's state.

## How v1 → v8 converged

Eight iterations on staging branches discovered each layer of pre-history dependencies:

| Version | Coverage added | Migrations replayed |
|---|---|---|
| v1 | 4 foundational tables | 0 → 3 |
| v2 | 34 more pre-history tables (minimal) | 0 → 4 |
| v3 | 25 index-derived columns | 0 → 7 |
| v4 | 10 pre-history function stubs | 0 → 18 |
| v5 | `updated_at` on 25 tables | 0 → 45 |
| v6 | Comprehensive prod column shapes (all ~250 pre-history columns) | 0 → 59 |
| v7 | Blair Ventures company seed (FK target for tenant-scoped seed migration) | 0 → 101 |
| **v8** ✅ | 37 more function stubs (7 SEC1 RPCs + 30 fn_*_lock_sample_marker triggers) | **0 → 104** all green |

## What v8 contains (the canonical baseline)

`00000000000000_foundational_baseline.sql` in this directory documents the structure. The full SQL is registered on prod's `supabase_migrations.schema_migrations` (read it via `SELECT statements FROM supabase_migrations.schema_migrations WHERE version = '00000000000000'` if you need to inspect or re-register on another project).

Contents:
- 38 `CREATE TABLE IF NOT EXISTS` statements for pre-history tables, with full prod column shapes
- 1 INSERT seeding the Blair Ventures company UUID (`bd75d321-01e3-4312-beca-ecbb9a3cf490`)
- 47 `CREATE OR REPLACE FUNCTION` stubs:
  - 7 trigger functions (return NEW)
  - 4 RLS helpers / predicates
  - 6 RPCs with proper signatures
  - 30 `fn_*_lock_sample_marker` trigger stubs

All operations are idempotent. On prod: every statement is a no-op (everything already exists). On fresh branches: this provides the foundational schema + function stubs so subsequent migrations replay cleanly.

## Verification on a future branch

```sql
-- Should always show '00000000000000' as the first version, with name
-- starting with 'phase2_foundational_baseline'.
SELECT version, name FROM supabase_migrations.schema_migrations ORDER BY version LIMIT 1;
```

When you create a branch, expect:
- Status: `FUNCTIONS_DEPLOYED` (not `MIGRATIONS_FAILED`)
- 104+ migrations applied
- 77+ public tables

## Re-registering on a different project

If you ever need to register this baseline on a different Supabase project (e.g. a new prod or for testing), copy the array from the existing prod row:

```sql
SELECT statements FROM supabase_migrations.schema_migrations WHERE version = '00000000000000';
```

Then INSERT it into the target project's `supabase_migrations.schema_migrations` table.

## Files in this directory

- `00000000000000_foundational_baseline.sql` — canonical structure documentation of v8 (header explains iteration history; sections cover foundational tables, pre-history table list, tenant seed, and all 47 function stubs).
- `README.md` — this file.

Intermediate files (`*_v2.sql` … `*_v5.sql`) were deleted after v8 closed the loop. Their content is preserved in the iteration commits if anyone wants to study the discovery process.
