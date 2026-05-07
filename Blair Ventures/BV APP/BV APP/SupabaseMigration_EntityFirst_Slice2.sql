-- Aski IQ — Entity-First CRM, Slice 2: server-side auto-link triggers + NOT NULL
--
-- Strategy: instead of refactoring every iOS Create flow to require
-- opportunityID upfront (high risk of breaking existing pushes), the
-- server enforces the invariant via two triggers per commercial child
-- table. iOS keeps sending nil during transition; the server fills it
-- in. Postgres' NOT NULL constraint is the safety net.
--
-- TRIGGERS
--   BEFORE INSERT  auto_link_opportunity_for_commercial_record():
--     If NEW.opportunity_id is NULL, derive it via per-table
--     heuristics (parent estimate/quote/project/contract → its opp,
--     or client_id → find open opp / create synthetic). Logs every
--     decision to backfill_log with run_label='auto_link_trigger'.
--
--   BEFORE UPDATE  preserve_opportunity_id_on_update():
--     If NEW.opportunity_id is NULL but OLD has a value, keep OLD.
--     Protects against iOS upsert payloads that send opportunity_id=null
--     when the local Swift model has nil for a record the server
--     already linked.
--
-- AFTER THIS MIGRATION
--   estimates / quotes / material_sales / change_orders / invoices /
--   purchase_orders / material_requests / contracts:
--     opportunity_id NOT NULL — guaranteed for all rows
--   projects:
--     opportunity_id still NULLABLE — needs Swift model change first
--     (Project.swift updated in same slice; NOT NULL deferred to 2B)
--
-- SMOKE TEST RESULT (2026-05-04): inserting an estimate with
-- opportunity_id=NULL → trigger filled it, audit log row written ✓.

CREATE OR REPLACE FUNCTION public.auto_link_opportunity_for_commercial_record()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_opp_id      uuid;
  v_client_id   uuid;
  v_company_id  uuid;
  v_title       text;
  v_source      text;
  v_action      text;
BEGIN
  IF NEW.opportunity_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- Per-table parent inheritance (priority-ordered).
  IF TG_TABLE_NAME = 'estimates' THEN
    v_client_id  := NEW.client_id;
    v_company_id := NEW.company_id;
    v_title      := COALESCE(NEW.name, NEW.job_number, 'Estimate');

  ELSIF TG_TABLE_NAME = 'quotes' THEN
    v_client_id  := NEW.client_id;
    v_company_id := NEW.company_id;
    v_title      := COALESCE(NEW.client_name, NEW.job_number, 'Quote');
    IF NEW.estimate_id IS NOT NULL THEN
      SELECT opportunity_id INTO v_opp_id FROM public.estimates
      WHERE id = NEW.estimate_id AND opportunity_id IS NOT NULL;
      IF v_opp_id IS NOT NULL THEN v_source := 'parent_estimate.opportunity_id'; END IF;
    END IF;

  ELSIF TG_TABLE_NAME = 'material_sales' THEN
    v_client_id  := NEW.client_id;
    v_company_id := NEW.company_id;
    v_title      := COALESCE(NEW.sale_number, 'Material Sale');
    IF NEW.quote_id IS NOT NULL THEN
      SELECT opportunity_id INTO v_opp_id FROM public.quotes
      WHERE id = NEW.quote_id AND opportunity_id IS NOT NULL;
      IF v_opp_id IS NOT NULL THEN v_source := 'parent_quote.opportunity_id'; END IF;
    END IF;

  ELSIF TG_TABLE_NAME = 'change_orders' THEN
    v_company_id := NEW.company_id;
    IF NEW.project_id IS NOT NULL THEN
      SELECT opportunity_id INTO v_opp_id FROM public.projects
      WHERE id = NEW.project_id AND opportunity_id IS NOT NULL;
      IF v_opp_id IS NOT NULL THEN v_source := 'parent_project.opportunity_id'; END IF;
    END IF;
    IF v_opp_id IS NULL AND NEW.contract_id IS NOT NULL THEN
      SELECT opportunity_id INTO v_opp_id FROM public.contracts
      WHERE id = NEW.contract_id AND opportunity_id IS NOT NULL;
      IF v_opp_id IS NOT NULL THEN v_source := 'parent_contract.opportunity_id'; END IF;
    END IF;

  ELSIF TG_TABLE_NAME = 'invoices' THEN
    v_client_id  := NEW.client_id;
    v_company_id := NEW.company_id;
    v_title      := COALESCE(NEW.invoice_number, 'Invoice');
    IF NEW.quote_id IS NOT NULL THEN
      SELECT opportunity_id INTO v_opp_id FROM public.quotes
      WHERE id = NEW.quote_id AND opportunity_id IS NOT NULL;
      IF v_opp_id IS NOT NULL THEN v_source := 'parent_quote.opportunity_id'; END IF;
    END IF;
    IF v_opp_id IS NULL AND NEW.project_id IS NOT NULL THEN
      SELECT opportunity_id INTO v_opp_id FROM public.projects
      WHERE id = NEW.project_id AND opportunity_id IS NOT NULL;
      IF v_opp_id IS NOT NULL THEN v_source := 'parent_project.opportunity_id'; END IF;
    END IF;
    IF v_opp_id IS NULL AND NEW.contract_id IS NOT NULL THEN
      SELECT opportunity_id INTO v_opp_id FROM public.contracts
      WHERE id = NEW.contract_id AND opportunity_id IS NOT NULL;
      IF v_opp_id IS NOT NULL THEN v_source := 'parent_contract.opportunity_id'; END IF;
    END IF;

  ELSIF TG_TABLE_NAME IN ('purchase_orders','material_requests') THEN
    v_company_id := NEW.company_id;
    IF NEW.project_id IS NOT NULL THEN
      SELECT opportunity_id INTO v_opp_id FROM public.projects
      WHERE id = NEW.project_id AND opportunity_id IS NOT NULL;
      IF v_opp_id IS NOT NULL THEN v_source := 'parent_project.opportunity_id'; END IF;
    END IF;

  ELSIF TG_TABLE_NAME = 'contracts' THEN
    v_company_id := NEW.company_id;
    v_title      := COALESCE(NEW.title, NEW.contract_number, 'Contract');
    IF NEW.quote_id IS NOT NULL THEN
      SELECT opportunity_id INTO v_opp_id FROM public.quotes
      WHERE id = NEW.quote_id AND opportunity_id IS NOT NULL;
      IF v_opp_id IS NOT NULL THEN v_source := 'parent_quote.opportunity_id'; END IF;
    END IF;
    IF v_opp_id IS NULL AND NEW.project_id IS NOT NULL THEN
      SELECT opportunity_id INTO v_opp_id FROM public.projects
      WHERE id = NEW.project_id AND opportunity_id IS NOT NULL;
      IF v_opp_id IS NOT NULL THEN v_source := 'parent_project.opportunity_id'; END IF;
    END IF;
  END IF;

  -- Fallback: find an open opp for this client, or create a new one.
  IF v_opp_id IS NULL AND v_client_id IS NOT NULL AND v_company_id IS NOT NULL THEN
    SELECT id INTO v_opp_id
    FROM public.crm_opportunities
    WHERE client_id = v_client_id
      AND company_id = v_company_id
      AND NOT is_deleted
      AND lower(stage) NOT IN ('lost', 'won')
    ORDER BY updated_at DESC NULLS LAST
    LIMIT 1;
    IF v_opp_id IS NOT NULL THEN v_source := 'open_opp_for_client'; END IF;
  END IF;

  IF v_opp_id IS NULL AND v_client_id IS NOT NULL AND v_company_id IS NOT NULL THEN
    INSERT INTO public.crm_opportunities (
      company_id, client_id, title, stage, source, probability, notes
    ) VALUES (
      v_company_id, v_client_id, v_title, 'new_lead', 'auto_link_trigger', 50,
      'Auto-created when ' || TG_TABLE_NAME || ' record was inserted without an opportunity link.'
    )
    RETURNING id INTO v_opp_id;
    v_source := 'no_existing_open_opp';
  END IF;

  -- Stamp + audit-log if resolved. NOT NULL constraint catches the
  -- "couldn't resolve" case with a clear Postgres error.
  IF v_opp_id IS NOT NULL THEN
    NEW.opportunity_id := v_opp_id;
    v_action := CASE
      WHEN v_source = 'no_existing_open_opp' THEN 'created_synthetic_opportunity'
      ELSE 'linked_via_trigger'
    END;
    INSERT INTO public.backfill_log (
      run_label, table_name, row_id, action, source_path, opportunity_id, details
    ) VALUES (
      'auto_link_trigger', TG_TABLE_NAME, NEW.id, v_action, v_source, v_opp_id,
      jsonb_build_object('client_id', v_client_id, 'company_id', v_company_id)
    );
  END IF;

  RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION public.preserve_opportunity_id_on_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.opportunity_id IS NULL AND OLD.opportunity_id IS NOT NULL THEN
    NEW.opportunity_id := OLD.opportunity_id;
  END IF;
  RETURN NEW;
END $function$;

DO $$
DECLARE tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    'estimates','quotes','material_sales','change_orders',
    'invoices','purchase_orders','material_requests','contracts'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_auto_link_opportunity ON public.%I', tbl);
    EXECUTE format(
      'CREATE TRIGGER trg_auto_link_opportunity BEFORE INSERT ON public.%I ' ||
      'FOR EACH ROW EXECUTE FUNCTION public.auto_link_opportunity_for_commercial_record()',
      tbl
    );
    EXECUTE format('DROP TRIGGER IF EXISTS trg_preserve_opportunity_id ON public.%I', tbl);
    EXECUTE format(
      'CREATE TRIGGER trg_preserve_opportunity_id BEFORE UPDATE ON public.%I ' ||
      'FOR EACH ROW EXECUTE FUNCTION public.preserve_opportunity_id_on_update()',
      tbl
    );
  END LOOP;
END $$;

ALTER TABLE public.estimates         ALTER COLUMN opportunity_id SET NOT NULL;
ALTER TABLE public.quotes            ALTER COLUMN opportunity_id SET NOT NULL;
ALTER TABLE public.material_sales    ALTER COLUMN opportunity_id SET NOT NULL;
ALTER TABLE public.change_orders     ALTER COLUMN opportunity_id SET NOT NULL;
ALTER TABLE public.invoices          ALTER COLUMN opportunity_id SET NOT NULL;
ALTER TABLE public.purchase_orders   ALTER COLUMN opportunity_id SET NOT NULL;
ALTER TABLE public.material_requests ALTER COLUMN opportunity_id SET NOT NULL;
ALTER TABLE public.contracts         ALTER COLUMN opportunity_id SET NOT NULL;
-- projects: NOT NULL deferred to Slice 2B once iOS push always carries opportunity_id.
