-- ============================================================================
-- RM1 — Precise role helpers (replaces the broad "is_approval_admin" idea)
-- ============================================================================
-- DRAFT — review-only. Apply with `apply_migration` after sign-off.
--
-- WHY
--   The v3 audit found that quote_approvals_update was gated by inline
--   manager/executive checks, blocking office_admin even though Swift's
--   approval hierarchy puts office_admin at level 5 (above PM at 4).
--
--   We deliberately AVOID a single broad helper because that would
--   accidentally grant approval rights to estimators (who appear in
--   `is_estimating_admin` for write rights but should NOT approve).
--
--   This migration adds three NARROW helpers, each mapped 1:1 to an
--   approval surface. RM2 then uses them in policies.
--
-- HELPERS ADDED
--   1. is_quote_approval_admin()       — who can approve quote_approvals
--   2. is_commercial_decision_admin()  — who can approve change_orders / financial
--   3. can_decide_quote_approval(p_total, p_tier, p_override)
--        — TIER-AWARE per-row gate; reads quote_total + threshold_tier
--          + override_used directly off the row being approved.
--
-- TIER RULES (mirror C.2 matrix and ApprovalAuthority.canApproveQuoteApproval)
--   Low  (≤$10K):    PM+ approve directly.
--   Mid  ($10K–$50K): Office Admin+ direct; PM only with override.
--   High (>$50K):    Executive/Owner direct; Manager only with override.
--
-- DEPENDENCIES
--   • get_my_role() — already exists (verified via pg_get_functiondef).
--
-- ROLLBACK
--   DROP FUNCTION IF EXISTS public.is_quote_approval_admin();
--   DROP FUNCTION IF EXISTS public.is_commercial_decision_admin();
--   DROP FUNCTION IF EXISTS public.can_decide_quote_approval(numeric, text, boolean);
-- ============================================================================

-- 1. Quote approval admin: PM, Office Admin, Manager, Executive, Owner.
--    Estimator EXCLUDED (matrix C.2: estimator can create/edit but NOT approve).
CREATE OR REPLACE FUNCTION public.is_quote_approval_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $$
  SELECT COALESCE(
    (SELECT role IN ('project_manager','office_admin','manager','executive','owner')
     FROM public.profiles WHERE id = auth.uid()),
    false
  );
$$;

COMMENT ON FUNCTION public.is_quote_approval_admin() IS
'Phase 1 RM1. Returns true if caller can act on quote_approvals rows at the DOMAIN level. Tier gating happens in can_decide_quote_approval(...). Excludes estimator (write-only role per C.2 matrix).';

-- 2. Commercial decision admin: Office Admin, Manager, Executive, Owner.
--    Used by change_orders / financial gates. PM EXCLUDED for change_orders
--    per matrix; PM is allowed for material_request and PO via existing
--    column-list policies, not this helper.
CREATE OR REPLACE FUNCTION public.is_commercial_decision_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $$
  SELECT COALESCE(
    (SELECT role IN ('office_admin','manager','executive','owner')
     FROM public.profiles WHERE id = auth.uid()),
    false
  );
$$;

COMMENT ON FUNCTION public.is_commercial_decision_admin() IS
'Phase 1 RM1. Returns true for office_admin and above. Used by change_order approval policies. Tier-gated for office_admin at the call site.';

-- 3. Tier-aware quote approval gate.
--    Reads quote_total, threshold_tier, and override_used directly off
--    the row being approved. RM2 wires this into quote_approvals_update.
--
--    p_total      — quote_approvals.quote_total
--    p_tier       — quote_approvals.threshold_tier (informational; the
--                   gate uses p_total for tier resolution to avoid drift
--                   if threshold_tier is stale)
--    p_override   — quote_approvals.override_used (boolean, default false)
CREATE OR REPLACE FUNCTION public.can_decide_quote_approval(
  p_total numeric,
  p_tier  text,
  p_override boolean DEFAULT false
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $$
  SELECT CASE
    -- High tier (> $50K): Executive/Owner direct; Manager only with override.
    WHEN p_total > 50000 THEN
      get_my_role() IN ('executive','owner')
      OR (p_override AND get_my_role() = 'manager')
    -- Mid tier ($10K–$50K): Office Admin+ direct; PM only with override.
    WHEN p_total > 10000 THEN
      get_my_role() IN ('office_admin','manager','executive','owner')
      OR (p_override AND get_my_role() = 'project_manager')
    -- Low tier (≤$10K): PM+ approve directly.
    ELSE
      get_my_role() IN ('project_manager','office_admin','manager','executive','owner')
  END;
$$;

COMMENT ON FUNCTION public.can_decide_quote_approval(numeric, text, boolean) IS
'Phase 1 RM1. Tier-aware quote approval gate. Mirrors Swift ApprovalAuthority.canApproveQuoteApproval. p_total is authoritative; p_tier is informational. Override (p_override=true) requires non-empty decision_notes — enforced by CHECK constraint added in RM2.';

-- Lock down execution to authenticated role (default in Supabase).
GRANT EXECUTE ON FUNCTION public.is_quote_approval_admin()        TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_commercial_decision_admin()   TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_decide_quote_approval(numeric, text, boolean) TO authenticated;

-- ============================================================================
-- VERIFICATION QUERIES (run after apply, NOT part of the migration)
-- ============================================================================
-- SELECT public.is_quote_approval_admin();          -- expect true for PM+
-- SELECT public.is_commercial_decision_admin();     -- expect true for office_admin+
-- SELECT public.can_decide_quote_approval(5000, 'low',  false);   -- PM: true
-- SELECT public.can_decide_quote_approval(25000, 'mid', false);   -- PM: false
-- SELECT public.can_decide_quote_approval(25000, 'mid', true);    -- PM: true
-- SELECT public.can_decide_quote_approval(75000, 'high', false);  -- Mgr: false
-- SELECT public.can_decide_quote_approval(75000, 'high', true);   -- Mgr: true
