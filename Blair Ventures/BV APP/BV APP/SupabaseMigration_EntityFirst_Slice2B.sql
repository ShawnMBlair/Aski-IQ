-- Aski IQ — Entity-First CRM, Slice 2B: close the projects loop
--
-- Slice 2A left projects.opportunity_id NULLABLE because the table has
-- no client_id FK (only client_name text), so the auto-link trigger
-- couldn't directly resolve. Slice 2B adds a projects-specific
-- resolution path: lookup clients.id by (company_id, lower(name))
-- match against NEW.client_name, then fall through to the standard
-- find-or-create-by-client logic.
--
-- The Swift Project model already gained `opportunityID` in Slice 2A,
-- and `convertQuoteToProject` already populates it from the source
-- quote. So the happy path doesn't need the trigger — it's the
-- standalone ProjectCreateEditView path the trigger backstops.
--
-- ProjectCreateEditView already enforces selectedClientID (line 299
-- "Pick a client from the CRM picker") so client_name will match an
-- existing clients row. Trigger resolves cleanly.
--
-- After this migration: all 9 commercial child tables have
-- opportunity_id NOT NULL.
--
-- SMOKE TESTS PASSED (2026-05-04):
--   • Insert with valid client_name + NULL opp → trigger filled it ✓
--   • Insert with unrecognized client_name → NOT NULL violation ✓

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

  ELSIF TG_TABLE_NAME = 'projects' THEN
    v_company_id := NEW.company_id;
    v_title      := COALESCE(NEW.name, 'Project');
    -- No client_id column on projects — derive it from client_name
    -- via a tenant-scoped, case-insensitive name match.
    IF NEW.client_name IS NOT NULL AND v_company_id IS NOT NULL THEN
      SELECT id INTO v_client_id
      FROM public.clients
      WHERE company_id = v_company_id
        AND lower(name) = lower(btrim(NEW.client_name))
        AND NOT is_deleted
      ORDER BY updated_at DESC NULLS LAST
      LIMIT 1;
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

DROP TRIGGER IF EXISTS trg_auto_link_opportunity ON public.projects;
CREATE TRIGGER trg_auto_link_opportunity
  BEFORE INSERT ON public.projects
  FOR EACH ROW EXECUTE FUNCTION public.auto_link_opportunity_for_commercial_record();

DROP TRIGGER IF EXISTS trg_preserve_opportunity_id ON public.projects;
CREATE TRIGGER trg_preserve_opportunity_id
  BEFORE UPDATE ON public.projects
  FOR EACH ROW EXECUTE FUNCTION public.preserve_opportunity_id_on_update();

ALTER TABLE public.projects ALTER COLUMN opportunity_id SET NOT NULL;
