-- ============================================================================
-- RM3 — Drop the redundant quotes_company policy
-- ============================================================================
-- DRAFT — review-only. Apply with `apply_migration` after sign-off.
--
-- WHY
--   The `quotes` table has TWO ALL policies that do the same thing:
--     • quotes_company             (older, get_my_company_id())
--     • quotes_company_isolation   (newer, inline subquery)
--
--   Both gate on `company_id = profiles.company_id` for the current
--   user. Having both is redundant — Postgres evaluates each policy
--   on every query and the OR semantics mean either pass is enough.
--   Keeping `quotes_company_isolation` because it's the inline-subquery
--   variant the rest of the schema migrated to.
--
-- ZERO BEHAVIOUR CHANGE
--   Both policies USING and WITH CHECK clauses resolve to the same
--   logical predicate. Dropping `quotes_company` does not change which
--   rows are visible / writable.
--
-- ROLLBACK
--   CREATE POLICY quotes_company ON public.quotes
--     FOR ALL TO authenticated
--     USING (company_id = get_my_company_id())
--     WITH CHECK (company_id = get_my_company_id());
-- ============================================================================

DROP POLICY IF EXISTS quotes_company ON public.quotes;

-- Confirm the surviving policy is still present (informational; this
-- statement is a no-op SELECT and safe to leave in the migration).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policy p
    JOIN pg_class c ON c.oid = p.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'quotes'
      AND p.polname = 'quotes_company_isolation'
  ) THEN
    RAISE EXCEPTION 'RM3 sanity check failed: quotes_company_isolation policy is missing. Aborting before dropping the redundant duplicate would leave quotes unprotected.';
  END IF;
END
$$;
