-- ─────────────────────────────────────────────────────────────────────────────
-- MIGRATION: SupabaseMigration_Quotes_Fix.sql
-- Applied: 2026-04-26
-- Purpose: Adds all columns required by the iOS app to the `quotes` table,
--          adds bi-directional opportunity_id link, enables RLS, and creates
--          tenant-isolation policy.
--
-- ROOT CAUSE FIXED:
--   The `quotes` table was missing estimate_id, subtotal, project_id,
--   assigned_pm_id, assigned_pm_name, approved_by, approved_at, sent_at,
--   accepted_at, and opportunity_id. Every pushPendingQuotes() call was
--   rejected by PostgreSQL with "column does not exist" → silently caught →
--   quotes never persisted to Supabase.
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Missing columns
ALTER TABLE public.quotes
    ADD COLUMN IF NOT EXISTS estimate_id       uuid        REFERENCES public.estimates(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS opportunity_id    uuid        REFERENCES public.crm_opportunities(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS project_id        uuid        REFERENCES public.projects(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS subtotal          numeric     NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS approved_by       text,
    ADD COLUMN IF NOT EXISTS approved_at       timestamptz,
    ADD COLUMN IF NOT EXISTS sent_at           timestamptz,
    ADD COLUMN IF NOT EXISTS accepted_at       timestamptz,
    ADD COLUMN IF NOT EXISTS assigned_pm_id    uuid        REFERENCES public.employees(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS assigned_pm_name  text;

-- 2. Performance indexes
CREATE INDEX IF NOT EXISTS quotes_company_id_idx     ON public.quotes(company_id);
CREATE INDEX IF NOT EXISTS quotes_opportunity_id_idx ON public.quotes(opportunity_id);
CREATE INDEX IF NOT EXISTS quotes_client_id_idx      ON public.quotes(client_id);
CREATE INDEX IF NOT EXISTS quotes_estimate_id_idx    ON public.quotes(estimate_id);

-- 3. updated_at trigger
CREATE OR REPLACE FUNCTION public.set_quotes_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS quotes_set_updated_at ON public.quotes;
CREATE TRIGGER quotes_set_updated_at
    BEFORE UPDATE ON public.quotes
    FOR EACH ROW EXECUTE FUNCTION public.set_quotes_updated_at();

-- 4. Enable RLS
ALTER TABLE public.quotes ENABLE ROW LEVEL SECURITY;

-- 5. Tenant isolation policy
DROP POLICY IF EXISTS "quotes_company_isolation" ON public.quotes;
CREATE POLICY "quotes_company_isolation"
    ON public.quotes
    FOR ALL
    USING (
        company_id = (
            SELECT company_id FROM public.profiles
            WHERE id = auth.uid()
            LIMIT 1
        )
    )
    WITH CHECK (
        company_id = (
            SELECT company_id FROM public.profiles
            WHERE id = auth.uid()
            LIMIT 1
        )
    );

-- 6. Back-fill company_id on orphaned rows using estimate FK
UPDATE public.quotes q
SET    company_id = e.company_id
FROM   public.estimates e
WHERE  q.company_id IS NULL
  AND  q.estimate_id = e.id;
