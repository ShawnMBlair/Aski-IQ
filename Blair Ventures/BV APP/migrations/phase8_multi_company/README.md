# Phase 8 / Multi-Company server-side enablement

**Status:** ✅ Applied to prod 2026-05-10 via `phase8-v2-supabase` branch merge.

## Files

| File | Purpose |
|---|---|
| `MULTI1_company_memberships.sql` | Core migration: table, helpers, relaxed RLS, backfill, auto-membership trigger. |
| `MULTI1b_anon_revoke.sql` | Follow-up: revokes anon EXECUTE on the new SECURITY DEFINER functions. Same SEC3 pattern. |

## What changed on prod

| Before | After |
|---|---|
| Each user belongs to exactly one company via `profiles.company_id` (NOT NULL). | Each user has 1+ rows in `company_memberships`, one flagged `is_primary`. `profiles.company_id` still exists and holds the **currently-active** company. |
| `companies` RLS: `id = profiles.company_id` (single row). | `companies` RLS: `id IN (SELECT current_user_company_ids())` — user sees every company they belong to. |
| No way to swap active company. | iOS calls `set_active_company(uuid)` RPC, which verifies membership then updates `profiles.company_id`. |
| New signup creates 1 profile row; no membership tracking. | `trg_profile_company_membership` trigger auto-inserts a `company_memberships` row whenever a profile's company_id changes, preventing drift. |

## What did NOT change

- `get_my_company_id()` — still returns `profiles.company_id`. Every existing tenant-scoped RLS policy in the codebase continues to work without modification.
- All other tables' RLS policies — unchanged.
- iOS `currentCompanyID` flow — unchanged for single-membership users.

## Verification (prod, post-merge)

- INV2 columns: `reorder_point`, `reorder_quantity` present on `inventory_items`.
- `company_memberships` count: 3 (matches the 3 active profiles backfilled).
- `is_primary = true` count: 3 (every profile got a primary membership).
- `companies_read` policy: `id IN (SELECT current_user_company_ids())` ✅.
- Functions present: `current_user_company_ids`, `set_active_company`, `fn_ensure_company_membership` ✅.
- Advisor warnings introduced: 5 → reduced to 2 after `MULTI1b_anon_revoke`. Remaining 2 (`authenticated` can call `current_user_company_ids` + `set_active_company`) are INTENTIONAL — `current_user_company_ids` is invoked by RLS; `set_active_company` is the iOS swap entry point.

## iOS wiring

The iOS layer (`MultiCompany.swift`, commit `5a1fd19`) already:
- Pulls from the `companies` table via `pullCompanyMemberships()` — now returns N rows for multi-tenant users.
- Calls `switchToCompany(uuid)` on the AppStore which:
  - Flushes pending writes for the outgoing tenant.
  - Wipes in-memory caches.
  - Updates `currentCompanyID`.
  - Re-attaches local persistence.
  - Re-pulls everything.

**TODO follow-up:** the iOS `switchToCompany` updates `AppStore.currentCompanyID` locally but doesn't yet call the server-side `set_active_company()` RPC. Without the RPC call, the user's `profiles.company_id` server-side stays on the OLD company — which means the next time `get_my_company_id()` runs (on a fresh sync from another device, or after the iOS in-memory state resets), reads go back to the original tenant. To complete the round-trip, `MultiCompany.swift:switchToCompany` should `await client.rpc("set_active_company", params: ["p_company_id": companyID.uuidString])` before kicking the pull. Filed as a Phase 8 v3 follow-up.

## Rollback plan

If something goes wrong post-deploy:

```sql
-- 1. Restore the strict companies RLS.
DROP POLICY IF EXISTS companies_read ON public.companies;
CREATE POLICY companies_read
    ON public.companies
    FOR SELECT
    TO authenticated
    USING (id = (SELECT company_id FROM profiles WHERE id = auth.uid()));

-- 2. Drop the new helpers (must run AFTER the RLS rollback above, since
--    the policy depends on current_user_company_ids).
DROP FUNCTION IF EXISTS public.set_active_company(uuid);
DROP FUNCTION IF EXISTS public.current_user_company_ids();

-- 3. Drop the trigger first, then the function.
DROP TRIGGER IF EXISTS trg_profile_company_membership ON public.profiles;
DROP FUNCTION IF EXISTS public.fn_ensure_company_membership();

-- 4. Optionally drop the table (preserves backfilled data if you skip).
-- DROP TABLE IF EXISTS public.company_memberships;
```

Step 4 is optional — leaving the table in place is safe because nothing else references it after the rollback above. Drop only if you want a clean slate before re-applying a corrected version.
