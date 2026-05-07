-- Aski IQ — Terms & Conditions library, Slice A
--
-- Schema + RLS + version trigger for the reusable T&C template library.
-- Slice A is admin-only — quotes don't reference these templates yet
-- (that lands in Slice B). The applies_to_service_types[] column and
-- the parallel company_cost_codes.service_types[] column are added now
-- so the auto-suggestion logic in Slice C can match without further
-- schema work.
--
-- Roles allowed to manage templates: executive, manager, office_admin.
-- (Spec mentioned "owner" — that role doesn't exist in the app's
-- UserRole enum; executive is the closest analog.)

CREATE TABLE IF NOT EXISTS public.terms_templates (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id               uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,

  title                    text NOT NULL,
  category                 text NOT NULL,
  description              text NOT NULL DEFAULT '',
  body                     text NOT NULL,

  applies_to_service_types text[] NOT NULL DEFAULT '{}'::text[],
  is_default               boolean NOT NULL DEFAULT false,
  is_active                boolean NOT NULL DEFAULT true,

  version                  integer NOT NULL DEFAULT 1,

  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  created_by               uuid REFERENCES auth.users(id),
  updated_by               uuid REFERENCES auth.users(id),

  is_deleted               boolean NOT NULL DEFAULT false,
  deleted_at               timestamptz,
  deleted_by               text,

  sync_status              text NOT NULL DEFAULT 'synced'
);

ALTER TABLE public.terms_templates DROP CONSTRAINT IF EXISTS terms_template_category_chk;
ALTER TABLE public.terms_templates ADD CONSTRAINT terms_template_category_chk
  CHECK (category IN (
    'general', 'material_sales', 'scaffolding', 'containment', 'shrink_wrap',
    'mast_lift', 'equipment_rental', 'installation', 'safety',
    'payment', 'warranty', 'exclusions'
  ));

CREATE INDEX IF NOT EXISTS idx_terms_templates_company
  ON public.terms_templates(company_id) WHERE NOT is_deleted;
CREATE INDEX IF NOT EXISTS idx_terms_templates_category
  ON public.terms_templates(company_id, category) WHERE NOT is_deleted AND is_active;
CREATE INDEX IF NOT EXISTS idx_terms_templates_applies
  ON public.terms_templates USING gin(applies_to_service_types);

-- Auto-bump version only when the rendered output changes.
CREATE OR REPLACE FUNCTION public.bump_terms_template_version() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.body <> OLD.body OR NEW.title <> OLD.title THEN
    NEW.version := OLD.version + 1;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_bump_terms_template_version ON public.terms_templates;
CREATE TRIGGER trg_bump_terms_template_version
  BEFORE UPDATE ON public.terms_templates
  FOR EACH ROW EXECUTE FUNCTION public.bump_terms_template_version();

-- RLS
ALTER TABLE public.terms_templates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS terms_templates_read  ON public.terms_templates;
DROP POLICY IF EXISTS terms_templates_write ON public.terms_templates;

CREATE POLICY terms_templates_read ON public.terms_templates
  FOR SELECT TO authenticated
  USING (
    company_id = (SELECT company_id FROM public.profiles WHERE id = auth.uid())
  );

CREATE POLICY terms_templates_write ON public.terms_templates
  FOR ALL TO authenticated
  USING (
    company_id = (SELECT company_id FROM public.profiles WHERE id = auth.uid())
    AND (SELECT role FROM public.profiles WHERE id = auth.uid())
        IN ('executive', 'manager', 'office_admin')
  )
  WITH CHECK (
    company_id = (SELECT company_id FROM public.profiles WHERE id = auth.uid())
    AND (SELECT role FROM public.profiles WHERE id = auth.uid())
        IN ('executive', 'manager', 'office_admin')
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON public.terms_templates TO authenticated;

-- ─────────────────────────────────────────────────────────────────────
-- company_cost_codes.service_types — enables Slice C auto-suggestion
-- ─────────────────────────────────────────────────────────────────────

ALTER TABLE public.company_cost_codes
  ADD COLUMN IF NOT EXISTS service_types text[] NOT NULL DEFAULT '{}'::text[];

ALTER TABLE public.company_cost_codes DROP CONSTRAINT IF EXISTS company_cost_codes_service_types_chk;
ALTER TABLE public.company_cost_codes ADD CONSTRAINT company_cost_codes_service_types_chk
  CHECK (
    service_types <@ ARRAY[
      'material_sales','scaffolding','containment','shrink_wrap',
      'mast_lift','equipment_rental','installation','safety','general'
    ]::text[]
  );

CREATE INDEX IF NOT EXISTS idx_company_cost_codes_service_types
  ON public.company_cost_codes USING gin(service_types);
