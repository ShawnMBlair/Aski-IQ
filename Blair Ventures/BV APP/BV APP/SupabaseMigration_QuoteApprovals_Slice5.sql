-- Aski IQ — Entity-First CRM, Slice 5: Quote Approval Thresholds
--
-- Spec from the master prompt (Phase 12, Four-Eyes Principle):
--   ≤ $10K       → Sales (no approval)
--   $10K – $50K  → Manager Approval
--   > $50K       → Admin Approval
-- Quote cannot be sent without required approval.
--
-- A separate table (vs fields on quotes) so a quote can have multiple
-- approval cycles in its lifetime (rejected → modified → re-requested)
-- without losing history. Compliance can read the log without quote-
-- edit perms.
--
-- THRESHOLD LOGIC: lives in iOS ApprovalThreshold.swift. Server stores
-- the snapshotted tier (manager / admin) so historical approvals show
-- the threshold context that was in effect at request time, not the
-- current threshold.

CREATE TABLE IF NOT EXISTS public.quote_approvals (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quote_id        uuid NOT NULL REFERENCES public.quotes(id) ON DELETE CASCADE,
  company_id      uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,

  quote_total     numeric NOT NULL,
  threshold_tier  text    NOT NULL,
  currency        text    NOT NULL DEFAULT 'USD',

  requested_by      uuid NOT NULL REFERENCES auth.users(id),
  requested_by_name text NOT NULL DEFAULT '',
  requested_at      timestamptz NOT NULL DEFAULT now(),

  status            text NOT NULL DEFAULT 'pending',
  decided_by        uuid REFERENCES auth.users(id),
  decided_by_name   text NOT NULL DEFAULT '',
  decided_at        timestamptz,
  decision_notes    text NOT NULL DEFAULT '',

  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  sync_status text NOT NULL DEFAULT 'synced',

  CONSTRAINT quote_approvals_status_chk CHECK (status IN ('pending','approved','rejected','cancelled')),
  CONSTRAINT quote_approvals_tier_chk   CHECK (threshold_tier IN ('manager','admin'))
);

CREATE INDEX IF NOT EXISTS idx_quote_approvals_quote   ON public.quote_approvals(quote_id, requested_at DESC);
CREATE INDEX IF NOT EXISTS idx_quote_approvals_pending ON public.quote_approvals(company_id, status) WHERE status = 'pending';

CREATE OR REPLACE FUNCTION public.fn_quote_approvals_touch_updated_at() RETURNS TRIGGER AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_quote_approvals_updated_at ON public.quote_approvals;
CREATE TRIGGER trg_quote_approvals_updated_at
  BEFORE UPDATE ON public.quote_approvals
  FOR EACH ROW EXECUTE FUNCTION public.fn_quote_approvals_touch_updated_at();

ALTER TABLE public.quote_approvals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS quote_approvals_read   ON public.quote_approvals;
DROP POLICY IF EXISTS quote_approvals_insert ON public.quote_approvals;
DROP POLICY IF EXISTS quote_approvals_update ON public.quote_approvals;

CREATE POLICY quote_approvals_read ON public.quote_approvals
  FOR SELECT TO authenticated
  USING (company_id = (SELECT company_id FROM public.profiles WHERE id = auth.uid()));

CREATE POLICY quote_approvals_insert ON public.quote_approvals
  FOR INSERT TO authenticated
  WITH CHECK (
    company_id = (SELECT company_id FROM public.profiles WHERE id = auth.uid())
    AND status = 'pending'
    AND requested_by = auth.uid()
  );

CREATE POLICY quote_approvals_update ON public.quote_approvals
  FOR UPDATE TO authenticated
  USING (
    company_id = (SELECT company_id FROM public.profiles WHERE id = auth.uid())
    AND (SELECT role FROM public.profiles WHERE id = auth.uid()) IN ('manager','executive')
  )
  WITH CHECK (
    company_id = (SELECT company_id FROM public.profiles WHERE id = auth.uid())
  );

GRANT SELECT, INSERT, UPDATE ON public.quote_approvals TO authenticated;
