# Phase 1 Migration Drafts

These SQL files are **drafts pending review**. None have been applied.

Apply order (dependencies):
1. `RM1_role_helpers_precise.sql` — adds 3 narrow SQL helpers
2. `RM2_quote_approvals_tier_policy.sql` — depends on RM1; adds `override_used` column + tier-aware policy
3. `RM3_drop_redundant_quotes_policy.sql` — independent; safe to run anytime after audit
4. `RM5_backfill_log_company_split.sql` — independent; tenant-scopes the diagnostic log
5. `RM6_client_hard_delete_guard.sql` — independent; trigger blocks hard-delete with history

Apply each via Supabase MCP `apply_migration` so they show up in `list_migrations`.
**Do not paste into `execute_sql`** — it skips migration tracking and rollback gets messier.

Every file has a `ROLLBACK` block in its header. Run rollback by reversing the order
of statements in that block (drop policies first, drop columns/functions last).

## Verification queries

Each file ends with sample verification SQL. Run those AFTER applying. They are
intentionally outside the migration body so they don't pollute `pg_class` /
`pg_policy` with no-op artefacts.

## Per-file size estimate

| File | Lines | Touches |
|---|---|---|
| RM1 | ~115 | 3 new functions |
| RM2 | ~110 | 1 new column, 1 CHECK constraint, 1 policy replacement |
| RM3 | ~45  | 1 policy drop |
| RM5 | ~85  | 1 column, 1 backfill UPDATE, 1 index, 1 policy swap |
| RM6 | ~165 | 1 function, 1 trigger |

Total: ~520 lines of SQL across 5 files.
