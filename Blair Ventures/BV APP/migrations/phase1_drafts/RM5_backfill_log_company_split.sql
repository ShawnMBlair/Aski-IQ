-- ============================================================================
-- RM5 — backfill_log company isolation (split strategy, no guessing)
-- ============================================================================
-- DRAFT — review-only. Apply with `apply_migration` after sign-off.
--
-- WHY
--   Today: backfill_log_admin_read policy returns rows to ANY user with
--   role IN ('executive','manager','office_admin') REGARDLESS of tenant.
--   That's a cross-tenant info disclosure (low impact, internal table —
--   but a real leak).
--
--   Schema fact (verified via information_schema):
--     backfill_log columns: id, run_at, run_label, table_name, row_id,
--                           action, source_path, opportunity_id, details
--     There is NO company_id today. opportunity_id is the only FK.
--
--   Row count fact (verified at audit time): 22 rows total. 16 carry
--   opportunity_id; 6 do NOT.
--
-- STRATEGY (per Correction 6 in the v3 review)
--   • Add company_id column (nullable — we cannot guarantee every row
--     can be mapped).
--   • Backfill the 16 rows that have opportunity_id by joining
--     crm_opportunities.
--   • Leave the 6 unmappable rows with NULL company_id.
--   • New policy returns rows ONLY when company_id IS NOT NULL AND
--     matches the caller AND the caller's role is executive/owner.
--   • Rows with NULL company_id are inaccessible to authenticated users.
--     Service role bypasses RLS, so diagnostics from edge functions
--     still work.
--
-- DATA SAFETY
--   • Adding a nullable column is non-destructive.
--   • UPDATE only touches rows with non-null opportunity_id.
--   • The new policy is strictly tighter than the one being dropped.
--
-- ROLLBACK
--   DROP POLICY IF EXISTS backfill_log_tenant_admin_read ON public.backfill_log;
--   CREATE POLICY backfill_log_admin_read ON public.backfill_log
--     FOR SELECT TO authenticated
--     USING (
--       (( SELECT profiles.role FROM profiles WHERE profiles.id = auth.uid() )
--        = ANY (ARRAY['executive'::text, 'manager'::text, 'office_admin'::text]))
--     );
--   DROP INDEX IF EXISTS public.idx_backfill_log_company_id;
--   ALTER TABLE public.backfill_log DROP COLUMN IF EXISTS company_id;
-- ============================================================================

-- 1. Add nullable company_id column with FK to companies.
ALTER TABLE public.backfill_log
  ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES public.companies(id);

COMMENT ON COLUMN public.backfill_log.company_id IS
'Phase 1 RM5. Backfilled for rows with opportunity_id via crm_opportunities. NULL for unmappable rows (inaccessible to authenticated users; service role only).';

-- 2. Backfill from crm_opportunities for the rows we CAN map confidently.
UPDATE public.backfill_log bl
SET company_id = co.company_id
FROM public.crm_opportunities co
WHERE bl.opportunity_id = co.id
  AND bl.opportunity_id IS NOT NULL
  AND bl.company_id IS NULL;  -- Only stamp empties; idempotent.

-- 3. Index for the new policy (small table today, but cheap insurance).
CREATE INDEX IF NOT EXISTS idx_backfill_log_company_id
  ON public.backfill_log(company_id);

-- 4. Drop the cross-tenant policy.
DROP POLICY IF EXISTS backfill_log_admin_read ON public.backfill_log;

-- 5. Tenant-scoped read for executive/owner only (matrix C.2).
CREATE POLICY backfill_log_tenant_admin_read ON public.backfill_log
FOR SELECT TO authenticated
USING (
  company_id IS NOT NULL
  AND company_id = ( SELECT profiles.company_id
                     FROM public.profiles
                     WHERE profiles.id = auth.uid() )
  AND ( SELECT profiles.role
        FROM public.profiles
        WHERE profiles.id = auth.uid() ) IN ('executive', 'owner')
);

COMMENT ON POLICY backfill_log_tenant_admin_read ON public.backfill_log IS
'Phase 1 RM5. Tenant-scoped to executive/owner. Rows with NULL company_id (the 6 unmappable historical rows + any future entries the trigger could not classify) are inaccessible to authenticated users; service role only.';

-- ============================================================================
-- VERIFICATION
-- ============================================================================
-- -- Row breakdown after backfill:
-- SELECT COUNT(*) FILTER (WHERE company_id IS NOT NULL) AS mapped,
--        COUNT(*) FILTER (WHERE company_id IS NULL)     AS unmapped,
--        COUNT(*)                                       AS total
-- FROM public.backfill_log;
-- -- Expected: mapped >= 16, unmapped <= 6, total = 22 (or higher if new rows).
--
-- -- As Tenant A executive — should return only Tenant A's mapped rows:
-- SELECT id, table_name, action FROM public.backfill_log;
--
-- -- As Tenant B executive — must NOT include Tenant A's IDs:
-- SELECT id FROM public.backfill_log WHERE id IN (<list-from-above>);
-- -- Expected: empty.
