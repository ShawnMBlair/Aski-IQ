-- Aski IQ — Entity-First CRM, Slice 1: foundation
--
-- Non-breaking additions only. This migration:
--   1. Adds opportunity_id (nullable) to commercial child tables that
--      didn't have it (projects, change_orders, invoices,
--      purchase_orders, material_requests, contracts).
--   2. Adds partial indexes (WHERE opportunity_id IS NOT NULL) on every
--      opportunity_id column. Cheap; supports later cascade queries
--      and the eventual NOT NULL move in Slice 2.
--   3. Creates backfill_log table — durable audit of every backfill
--      decision (linked-via-heuristic vs created-synthetic-opp vs
--      no-action). Admin-only RLS.
--   4. Backfills existing projects + contracts via reverse-lookup
--      heuristics. For projects with no source quote, creates a
--      synthetic CRM opportunity and links the project to it.
--
-- After this migration runs, every commercial child table has
-- ZERO orphans (rows with NULL opportunity_id). That's the
-- prerequisite for Slice 2's NOT NULL move.
--
-- Slice 1 deliberately does NOT:
--   • Set NOT NULL anywhere
--   • Add server-side guardrails rejecting missing opportunity_id
--   • Change any iOS code
--
-- Verified post-deploy:
--   • estimates       6 rows / 0 orphans
--   • quotes          4 rows / 0 orphans
--   • material_sales  1 row  / 0 orphans
--   • projects        5 rows / 0 orphans (4 linked, 1 synthetic)
--   • change_orders   0 rows
--   • invoices        0 rows
--   • purchase_orders 0 rows
--   • material_requests 0 rows
--   • contracts       2 rows / 0 orphans (both linked via quote.opp)
--
-- Backfill log entries: 7 (run_label = 'entity_first_slice_1')

-- 1. Add opportunity_id (nullable) where missing
ALTER TABLE public.projects
  ADD COLUMN IF NOT EXISTS opportunity_id uuid REFERENCES public.crm_opportunities(id) ON DELETE SET NULL;
ALTER TABLE public.change_orders
  ADD COLUMN IF NOT EXISTS opportunity_id uuid REFERENCES public.crm_opportunities(id) ON DELETE SET NULL;
ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS opportunity_id uuid REFERENCES public.crm_opportunities(id) ON DELETE SET NULL;
ALTER TABLE public.purchase_orders
  ADD COLUMN IF NOT EXISTS opportunity_id uuid REFERENCES public.crm_opportunities(id) ON DELETE SET NULL;
ALTER TABLE public.material_requests
  ADD COLUMN IF NOT EXISTS opportunity_id uuid REFERENCES public.crm_opportunities(id) ON DELETE SET NULL;
ALTER TABLE public.contracts
  ADD COLUMN IF NOT EXISTS opportunity_id uuid REFERENCES public.crm_opportunities(id) ON DELETE SET NULL;

-- 2. Partial indexes (small until Slice 2 sets NOT NULL)
CREATE INDEX IF NOT EXISTS idx_estimates_opportunity_id        ON public.estimates(opportunity_id)        WHERE opportunity_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_quotes_opportunity_id           ON public.quotes(opportunity_id)           WHERE opportunity_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_material_sales_opportunity_id   ON public.material_sales(opportunity_id)   WHERE opportunity_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_projects_opportunity_id         ON public.projects(opportunity_id)         WHERE opportunity_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_change_orders_opportunity_id    ON public.change_orders(opportunity_id)    WHERE opportunity_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_invoices_opportunity_id         ON public.invoices(opportunity_id)         WHERE opportunity_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_purchase_orders_opportunity_id  ON public.purchase_orders(opportunity_id)  WHERE opportunity_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_material_requests_opportunity_id ON public.material_requests(opportunity_id) WHERE opportunity_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_contracts_opportunity_id        ON public.contracts(opportunity_id)        WHERE opportunity_id IS NOT NULL;

-- 3. backfill_log table
CREATE TABLE IF NOT EXISTS public.backfill_log (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_at          timestamptz NOT NULL DEFAULT now(),
  run_label       text NOT NULL,
  table_name      text NOT NULL,
  row_id          uuid NOT NULL,
  action          text NOT NULL,
  source_path     text,
  opportunity_id  uuid REFERENCES public.crm_opportunities(id) ON DELETE SET NULL,
  details         jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_backfill_log_label  ON public.backfill_log(run_label);
CREATE INDEX IF NOT EXISTS idx_backfill_log_table  ON public.backfill_log(table_name);

ALTER TABLE public.backfill_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS backfill_log_admin_read ON public.backfill_log;
CREATE POLICY backfill_log_admin_read ON public.backfill_log
  FOR SELECT TO authenticated
  USING ((SELECT role FROM public.profiles WHERE id = auth.uid()) IN ('executive','manager','office_admin'));

-- 4. Backfills (idempotent — re-running is safe; WHERE opportunity_id IS NULL filters)
-- See live migration `entity_first_slice_1_columns_indexes_backfill` for full payload.
-- Synthetic-opportunity creation for project BV-2025-041 ran as a separate one-off
-- (see backfill_log row with action = 'created_synthetic_opportunity').
