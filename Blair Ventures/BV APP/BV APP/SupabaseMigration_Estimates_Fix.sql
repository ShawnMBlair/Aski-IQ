-- Aski IQ — estimates schema fix
-- =============================================================================
-- The Commercial migration updated 11 sibling tables (quotes, change_orders,
-- rfis, invoices, etc.) but skipped `estimates`. The iOS Row struct in
-- SyncEngineCommercial.pushPendingEstimates encodes 14 columns the server
-- never received an ALTER for, so every upsert is rejected by PostgREST with
-- "Could not find the 'X' column of 'estimates' in the schema cache".
--
-- This migration is idempotent: every column is ADD COLUMN IF NOT EXISTS,
-- every constraint is wrapped in a DO block that traps duplicate_object.
-- Safe to re-run.
--
-- After this runs:
--   • pushPendingEstimates upserts will succeed
--   • pullEstimates Row struct decodes cleanly (it already references these
--     fields; previously the catch swallowed the schema mismatch)
--   • CRM linkage persists via opportunity_id + origin_type
--   • bidirectional Estimate ↔ Quote linkage works (converted_quote_id was
--     already in iOS code)

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────
-- 1. Add the missing columns
-- ─────────────────────────────────────────────────────────────────────────
ALTER TABLE public.estimates
    ADD COLUMN IF NOT EXISTS rfq_received_date    TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS submitted_date       TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS awarded_date         TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS converted_quote_id   UUID,
    ADD COLUMN IF NOT EXISTS internal_review_by   TEXT,
    ADD COLUMN IF NOT EXISTS internal_notes       TEXT,
    ADD COLUMN IF NOT EXISTS internal_approved_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS loss_reason          TEXT,
    ADD COLUMN IF NOT EXISTS competitor_name      TEXT,
    ADD COLUMN IF NOT EXISTS win_loss_notes       TEXT,
    ADD COLUMN IF NOT EXISTS awarded_value        NUMERIC(14,2),
    ADD COLUMN IF NOT EXISTS line_items_json      TEXT NOT NULL DEFAULT '[]',
    -- New: CRM linkage fields (model has them at Estimate.swift:228/230,
    -- iOS Row will be updated in the same PR to send them).
    ADD COLUMN IF NOT EXISTS origin_type          TEXT NOT NULL DEFAULT 'direct_commercial',
    ADD COLUMN IF NOT EXISTS opportunity_id       UUID;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. Foreign keys for new ID columns (DO blocks so re-runs are clean)
-- ─────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    ALTER TABLE public.estimates
        ADD CONSTRAINT estimates_opportunity_id_fkey
        FOREIGN KEY (opportunity_id)
        REFERENCES public.crm_opportunities(id)
        ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
    ALTER TABLE public.estimates
        ADD CONSTRAINT estimates_converted_quote_id_fkey
        FOREIGN KEY (converted_quote_id)
        REFERENCES public.quotes(id)
        ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3. Bound the new enum-like text columns
-- (avoids garbage values; cheaper than enums to evolve later)
-- ─────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
    ALTER TABLE public.estimates
        ADD CONSTRAINT estimates_origin_type_chk CHECK (
            origin_type IN (
                'direct_commercial',
                'crm_opportunity',
                'project',
                'material_sale'
            )
        );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- loss_reason: nullable text, must match the iOS LossReason enum if set
DO $$
BEGIN
    ALTER TABLE public.estimates
        ADD CONSTRAINT estimates_loss_reason_chk CHECK (
            loss_reason IS NULL OR loss_reason IN (
                'price', 'timeline', 'scope', 'relationship',
                'no_decision', 'incumbent', 'other'
            )
        );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. Indexes for the new FKs (CRM list queries hit opportunity_id often)
-- ─────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_estimates_opportunity_id
    ON public.estimates(opportunity_id) WHERE opportunity_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_estimates_converted_quote_id
    ON public.estimates(converted_quote_id) WHERE converted_quote_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_estimates_origin_type
    ON public.estimates(origin_type);

-- ─────────────────────────────────────────────────────────────────────────
-- 5. Confirm RLS is the tenant-scoped policy from the multitenancy migration
-- (this is a no-op if it's already in place, but defensive against drift)
-- ─────────────────────────────────────────────────────────────────────────
ALTER TABLE public.estimates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "estimates_auth"    ON public.estimates;
DROP POLICY IF EXISTS "estimates_company" ON public.estimates;

CREATE POLICY "estimates_company" ON public.estimates
    FOR ALL TO authenticated
    USING      (company_id = get_my_company_id())
    WITH CHECK (company_id = get_my_company_id());

COMMIT;

-- ─────────────────────────────────────────────────────────────────────────
-- 6. Verification queries — run after COMMIT to sanity-check
-- ─────────────────────────────────────────────────────────────────────────
-- SELECT column_name, data_type, is_nullable
-- FROM information_schema.columns
-- WHERE table_schema = 'public' AND table_name = 'estimates'
-- ORDER BY ordinal_position;
--
-- SELECT polname, polcmd, pg_get_expr(polqual, polrelid) AS using_clause
-- FROM pg_policy WHERE polrelid = 'public.estimates'::regclass;
