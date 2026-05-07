-- ============================================================================
-- RM2 — Add override_used column + replace quote_approvals_update policy
-- ============================================================================
-- DRAFT — review-only. Apply with `apply_migration` after sign-off.
-- DEPENDS ON: RM1 (helpers must exist first).
--
-- WHY
--   Today, quote_approvals_update is gated by an inline check:
--     get_my_role() IN ('manager','executive')
--   That blocks office_admin and ignores the tier rules entirely.
--   Tier enforcement lives only in Swift, which means a direct API call
--   could bypass it.
--
--   The schema already carries quote_total (numeric) and threshold_tier
--   (text) on the row. RM2 adds an override_used boolean column with a
--   CHECK constraint that forces decision_notes to be non-empty whenever
--   override_used = true.
--
-- CHANGES
--   1. ALTER TABLE: add override_used boolean NOT NULL DEFAULT false.
--   2. ADD CHECK CONSTRAINT: override_used = false OR length(decision_notes) > 0.
--   3. DROP existing quote_approvals_update policy.
--   4. CREATE replacement policy that calls
--        can_decide_quote_approval(quote_total, threshold_tier, override_used)
--      from RM1.
--
-- DATA SAFETY
--   • New column has DEFAULT false → existing rows are unaffected.
--   • CHECK constraint applies on INSERT/UPDATE — historical rows where
--     override_used = false (the default) trivially pass.
--
-- ROLLBACK
--   DROP POLICY IF EXISTS quote_approvals_update ON public.quote_approvals;
--   CREATE POLICY quote_approvals_update ON public.quote_approvals
--     FOR UPDATE TO authenticated
--     USING (
--       (company_id = ( SELECT profiles.company_id
--                       FROM profiles WHERE profiles.id = auth.uid() ))
--       AND (( SELECT profiles.role FROM profiles WHERE profiles.id = auth.uid() )
--            = ANY (ARRAY['manager'::text, 'executive'::text]))
--     )
--     WITH CHECK (
--       company_id = ( SELECT profiles.company_id
--                      FROM profiles WHERE profiles.id = auth.uid() )
--     );
--   ALTER TABLE public.quote_approvals
--     DROP CONSTRAINT IF EXISTS quote_approvals_override_requires_notes;
--   ALTER TABLE public.quote_approvals DROP COLUMN IF EXISTS override_used;
-- ============================================================================

-- 1. Add the column. Default false → no impact on existing rows.
ALTER TABLE public.quote_approvals
  ADD COLUMN IF NOT EXISTS override_used boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.quote_approvals.override_used IS
'Phase 1 RM2. Approver acknowledged the high-risk override path. Set by Swift client when a sub-tier approver acts on a higher-tier quote. Requires decision_notes when true (CHECK quote_approvals_override_requires_notes).';

-- 2. CHECK: override implies a non-empty reason.
ALTER TABLE public.quote_approvals
  DROP CONSTRAINT IF EXISTS quote_approvals_override_requires_notes;

ALTER TABLE public.quote_approvals
  ADD CONSTRAINT quote_approvals_override_requires_notes
  CHECK (override_used = false OR length(trim(decision_notes)) > 0);

-- 3. Replace the policy. Drop first (capturing original above for rollback).
DROP POLICY IF EXISTS quote_approvals_update ON public.quote_approvals;

-- 4. Tier-aware policy.
--    USING gate is checked before UPDATE; WITH CHECK is checked after.
--    Both must pass — a sub-tier approver cannot escalate themselves
--    by setting override_used inside the same UPDATE because the
--    USING clause is evaluated against the OLD row (where override_used
--    is false) and WITH CHECK against the NEW row.
--
--    NOTE on USING vs WITH CHECK:
--      • USING       sees OLD.* in PostgreSQL semantics
--      • WITH CHECK  sees NEW.*
--    Therefore tier evaluation in USING reflects the row as it was
--    before this UPDATE — which is the safe baseline. Setting override
--    + reason in the same UPDATE is allowed (the WITH CHECK clause
--    evaluates the new value), but the USING gate must permit the
--    approver based on the EXISTING tier facts.
CREATE POLICY quote_approvals_update ON public.quote_approvals
FOR UPDATE TO authenticated
USING (
  company_id = ( SELECT profiles.company_id
                 FROM public.profiles
                 WHERE profiles.id = auth.uid() )
  AND public.can_decide_quote_approval(
        quote_total,
        threshold_tier,
        COALESCE(override_used, false)
      )
)
WITH CHECK (
  company_id = ( SELECT profiles.company_id
                 FROM public.profiles
                 WHERE profiles.id = auth.uid() )
  AND public.can_decide_quote_approval(
        quote_total,
        threshold_tier,
        COALESCE(override_used, false)
      )
);

COMMENT ON POLICY quote_approvals_update ON public.quote_approvals IS
'Phase 1 RM2. Tier-aware approval gate. Defers the role/tier decision to can_decide_quote_approval(quote_total, threshold_tier, override_used). Override path requires non-empty decision_notes via CHECK constraint quote_approvals_override_requires_notes.';

-- ============================================================================
-- VERIFICATION (run after apply)
-- ============================================================================
-- -- As a PM trying to approve a $25K row WITHOUT override → should be denied.
-- UPDATE public.quote_approvals
--   SET status = 'approved', decided_at = now(), decided_by = auth.uid()
--   WHERE quote_total = 25000 AND status = 'pending';
--
-- -- As a PM trying to approve a $25K row WITH override + notes → should succeed.
-- UPDATE public.quote_approvals
--   SET status = 'approved', decided_at = now(), decided_by = auth.uid(),
--       override_used = true, decision_notes = 'PM override: client deadline'
--   WHERE quote_total = 25000 AND status = 'pending';
--
-- -- As ANY role trying to override without notes → CHECK should reject.
-- UPDATE public.quote_approvals
--   SET override_used = true, decision_notes = ''
--   WHERE id = '<some-id>';
