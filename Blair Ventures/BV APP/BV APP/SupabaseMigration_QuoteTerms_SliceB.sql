-- Aski IQ — Terms & Conditions library, Slice B
--
-- quote_terms: per-quote snapshots of attached T&C templates.
-- Once a quote is sent, edits to the master template never reach
-- already-sent quotes — the rendered text always comes from the
-- frozen title_snapshot/body_snapshot columns here.
--
-- Custom one-off terms live in the same table with
-- terms_template_id = NULL and is_custom = true.

CREATE TABLE IF NOT EXISTS public.quote_terms (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quote_id                 uuid NOT NULL REFERENCES public.quotes(id) ON DELETE CASCADE,
  terms_template_id        uuid REFERENCES public.terms_templates(id) ON DELETE SET NULL,

  title_snapshot           text NOT NULL,
  body_snapshot            text NOT NULL,
  version_snapshot         integer,

  display_order            integer NOT NULL DEFAULT 0,
  is_custom                boolean NOT NULL DEFAULT false,

  created_at               timestamptz NOT NULL DEFAULT now(),
  created_by               text NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_quote_terms_quote
  ON public.quote_terms(quote_id, display_order);
CREATE INDEX IF NOT EXISTS idx_quote_terms_template
  ON public.quote_terms(terms_template_id);

-- Default-templates ledger flag — fires defaults exactly once per quote
ALTER TABLE public.quotes
  ADD COLUMN IF NOT EXISTS terms_default_applied boolean NOT NULL DEFAULT false;

-- RLS — mirrors quote visibility
ALTER TABLE public.quote_terms ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS quote_terms_read  ON public.quote_terms;
DROP POLICY IF EXISTS quote_terms_write ON public.quote_terms;

CREATE POLICY quote_terms_read ON public.quote_terms
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.quotes q
    WHERE q.id = quote_terms.quote_id
      AND q.company_id = (SELECT company_id FROM public.profiles WHERE id = auth.uid())
  ));

CREATE POLICY quote_terms_write ON public.quote_terms
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.quotes q
    WHERE q.id = quote_terms.quote_id
      AND q.company_id = (SELECT company_id FROM public.profiles WHERE id = auth.uid())
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.quotes q
    WHERE q.id = quote_terms.quote_id
      AND q.company_id = (SELECT company_id FROM public.profiles WHERE id = auth.uid())
  ));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.quote_terms TO authenticated;
