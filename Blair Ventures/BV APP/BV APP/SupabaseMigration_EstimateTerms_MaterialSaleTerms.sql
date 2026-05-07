-- ─────────────────────────────────────────────────────────────────────
-- Aski IQ — Terms & Conditions extension to Estimates and Material Sales
--
-- Path A clone of the existing quote_terms structure. Two new tables,
-- structurally identical to quote_terms but pointing at estimates and
-- material_sales respectively. Master template library
-- (terms_templates) is shared.
--
-- DESIGN NOTE
-- This is intentionally NOT a polymorphic refactor. The existing
-- quote_terms code path is untouched. When all four entities want
-- T&C (estimate / quote / material_sale / change_order) and the
-- pattern stabilizes, a future migration can collapse them into a
-- single commercial_terms table with parent_type + parent_id. For
-- now, ship velocity > de-duplication.
--
-- DEPLOYMENT
-- Safe to apply at any time — additive only. No existing rows
-- touched. Backward-compatible: dropping the new tables and
-- columns would not break any existing code path that doesn't
-- reference them.
-- ─────────────────────────────────────────────────────────────────────


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- estimate_terms
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Per-estimate snapshots of attached T&C templates. Snapshot rule
-- matches quote_terms — once written, title_snapshot/body_snapshot
-- are NEVER read from terms_templates again. Edits to master
-- templates only affect future estimates.
--
-- Custom one-off terms live in the same table with
-- terms_template_id = NULL and is_custom = true.
CREATE TABLE IF NOT EXISTS public.estimate_terms (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  estimate_id              uuid NOT NULL REFERENCES public.estimates(id) ON DELETE CASCADE,
  terms_template_id        uuid REFERENCES public.terms_templates(id) ON DELETE SET NULL,

  title_snapshot           text NOT NULL,
  body_snapshot            text NOT NULL,
  version_snapshot         integer,

  display_order            integer NOT NULL DEFAULT 0,
  is_custom                boolean NOT NULL DEFAULT false,

  created_at               timestamptz NOT NULL DEFAULT now(),
  created_by               text NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_estimate_terms_estimate
  ON public.estimate_terms(estimate_id, display_order);
CREATE INDEX IF NOT EXISTS idx_estimate_terms_template
  ON public.estimate_terms(terms_template_id);

-- Default-templates ledger flag — fires defaults exactly once per estimate
ALTER TABLE public.estimates
  ADD COLUMN IF NOT EXISTS terms_default_applied boolean NOT NULL DEFAULT false;

-- RLS — mirrors estimate visibility (tenant scoping via parent estimate)
ALTER TABLE public.estimate_terms ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS estimate_terms_read  ON public.estimate_terms;
DROP POLICY IF EXISTS estimate_terms_write ON public.estimate_terms;

CREATE POLICY estimate_terms_read ON public.estimate_terms
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.estimates e
    WHERE e.id = estimate_terms.estimate_id
      AND e.company_id = (SELECT company_id FROM public.profiles WHERE id = auth.uid())
  ));

CREATE POLICY estimate_terms_write ON public.estimate_terms
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.estimates e
    WHERE e.id = estimate_terms.estimate_id
      AND e.company_id = (SELECT company_id FROM public.profiles WHERE id = auth.uid())
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.estimates e
    WHERE e.id = estimate_terms.estimate_id
      AND e.company_id = (SELECT company_id FROM public.profiles WHERE id = auth.uid())
  ));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.estimate_terms TO authenticated;


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- material_sale_terms
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Per-sale snapshots. Same shape as quote_terms / estimate_terms.
CREATE TABLE IF NOT EXISTS public.material_sale_terms (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  material_sale_id         uuid NOT NULL REFERENCES public.material_sales(id) ON DELETE CASCADE,
  terms_template_id        uuid REFERENCES public.terms_templates(id) ON DELETE SET NULL,

  title_snapshot           text NOT NULL,
  body_snapshot            text NOT NULL,
  version_snapshot         integer,

  display_order            integer NOT NULL DEFAULT 0,
  is_custom                boolean NOT NULL DEFAULT false,

  created_at               timestamptz NOT NULL DEFAULT now(),
  created_by               text NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_material_sale_terms_sale
  ON public.material_sale_terms(material_sale_id, display_order);
CREATE INDEX IF NOT EXISTS idx_material_sale_terms_template
  ON public.material_sale_terms(terms_template_id);

-- Default-templates ledger flag
ALTER TABLE public.material_sales
  ADD COLUMN IF NOT EXISTS terms_default_applied boolean NOT NULL DEFAULT false;

-- RLS — mirrors material_sales visibility (tenant scoping via parent sale)
ALTER TABLE public.material_sale_terms ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS material_sale_terms_read  ON public.material_sale_terms;
DROP POLICY IF EXISTS material_sale_terms_write ON public.material_sale_terms;

CREATE POLICY material_sale_terms_read ON public.material_sale_terms
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.material_sales s
    WHERE s.id = material_sale_terms.material_sale_id
      AND s.company_id = (SELECT company_id FROM public.profiles WHERE id = auth.uid())
  ));

CREATE POLICY material_sale_terms_write ON public.material_sale_terms
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.material_sales s
    WHERE s.id = material_sale_terms.material_sale_id
      AND s.company_id = (SELECT company_id FROM public.profiles WHERE id = auth.uid())
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.material_sales s
    WHERE s.id = material_sale_terms.material_sale_id
      AND s.company_id = (SELECT company_id FROM public.profiles WHERE id = auth.uid())
  ));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.material_sale_terms TO authenticated;


-- ─────────────────────────────────────────────────────────────────────
-- VERIFICATION (read-only)
--
--   SELECT table_name FROM information_schema.tables
--   WHERE table_schema = 'public'
--     AND table_name IN ('estimate_terms', 'material_sale_terms');
--
--   SELECT column_name FROM information_schema.columns
--   WHERE table_schema = 'public'
--     AND table_name = 'estimates'
--     AND column_name = 'terms_default_applied';
--
--   SELECT column_name FROM information_schema.columns
--   WHERE table_schema = 'public'
--     AND table_name = 'material_sales'
--     AND column_name = 'terms_default_applied';
-- ─────────────────────────────────────────────────────────────────────
