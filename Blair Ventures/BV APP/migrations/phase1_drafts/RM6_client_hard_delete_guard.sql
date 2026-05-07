-- ============================================================================
-- RM6 — Client hard-delete guard (Required, Phase 1.5)
-- ============================================================================
-- DRAFT — review-only. Apply with `apply_migration` after sign-off.
--
-- WHY
--   The v3 audit established the enterprise rule:
--     "No authenticated user — including owner — may hard-delete a
--      client with dependent commercial history through normal app use.
--      Service role bypass is reserved for controlled maintenance only."
--
--   The Swift UI guard is necessary but not sufficient: a direct
--   Supabase request from a JWT could bypass it. This trigger is the
--   server-side last line of defense.
--
-- DEPENDENT RECORDS CHECKED
--   Per Correction 4 in the v3 review, dependent enumeration is
--   grounded in actual FK relationships (verified via information_schema).
--
--   Direct FK to clients.id (7 tables, all confirmed present today):
--     • crm_contacts          (CASCADE)
--     • crm_opportunities     (CASCADE)
--     • crm_activities        (SET NULL)
--     • crm_tasks             (SET NULL)
--     • quotes                (SET NULL)
--     • material_sales        (NO ACTION)
--     • client_pricings       (CASCADE)
--
--   Reachable via crm_opportunities (which CASCADEs from client):
--     • contracts        (opp_id SET NULL)  — lose orphaned contract history
--     • estimates        (opp_id SET NULL)
--     • projects         (opp_id SET NULL)
--     • invoices         (opp_id SET NULL)
--     • purchase_orders  (opp_id SET NULL)
--     • change_orders    (opp_id SET NULL)
--     • material_requests (opp_id SET NULL)
--
--   Reachable via projects (deeper field history) — Correction 4
--   recommended these 5 explicitly:
--     • daily_job_reports
--     • schedule_entries
--     • form_submissions
--     • incidents
--     • rfis
--   Plus timesheet_entries (already on the list).
--
-- BYPASS RULE
--   Only `auth.role() = 'service_role'` bypasses this trigger. That's
--   Supabase's standard service-role JWT. Owner does NOT bypass.
--
-- ROLLBACK
--   DROP TRIGGER IF EXISTS trg_block_client_hard_delete ON public.clients;
--   DROP FUNCTION IF EXISTS public.fn_block_client_hard_delete();
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_block_client_hard_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $$
DECLARE
  has_deps boolean;
  dep_summary text;
  cnt_contacts        integer; cnt_opps             integer;
  cnt_activities      integer; cnt_tasks            integer;
  cnt_quotes          integer; cnt_material_sales   integer;
  cnt_client_pricings integer; cnt_contracts        integer;
  cnt_estimates       integer; cnt_projects         integer;
  cnt_invoices        integer; cnt_purchase_orders  integer;
  cnt_change_orders   integer; cnt_material_requests integer;
  cnt_timesheets      integer; cnt_djr              integer;
  cnt_schedules       integer; cnt_forms            integer;
  cnt_incidents       integer; cnt_rfis             integer;
BEGIN
  -- 1. Service role bypass: maintenance, sample-data reset, tenant
  --    offboarding via edge functions. Standard Supabase pattern —
  --    auth.role() returns 'service_role' for service-key callers,
  --    'authenticated' for users, 'anon' for anonymous.
  IF auth.role() = 'service_role' THEN
    RETURN OLD;
  END IF;

  -- 2. Direct FK dependents (7 tables — all confirmed present).
  SELECT COUNT(*) INTO cnt_contacts        FROM public.crm_contacts       WHERE client_id = OLD.id;
  SELECT COUNT(*) INTO cnt_opps            FROM public.crm_opportunities  WHERE client_id = OLD.id;
  SELECT COUNT(*) INTO cnt_activities      FROM public.crm_activities     WHERE client_id = OLD.id;
  SELECT COUNT(*) INTO cnt_tasks           FROM public.crm_tasks          WHERE client_id = OLD.id;
  SELECT COUNT(*) INTO cnt_quotes          FROM public.quotes             WHERE client_id = OLD.id;
  SELECT COUNT(*) INTO cnt_material_sales  FROM public.material_sales     WHERE client_id = OLD.id;
  SELECT COUNT(*) INTO cnt_client_pricings FROM public.client_pricings    WHERE client_id = OLD.id;

  -- 3. Reachable via opportunities (cascade-deleted from client) — but
  --    historical record exists today, so we count BEFORE the cascade
  --    would fire. Joining lets the trigger refuse before any cascade.
  SELECT COUNT(*) INTO cnt_contracts
    FROM public.contracts c
    WHERE c.opportunity_id IN (SELECT id FROM public.crm_opportunities WHERE client_id = OLD.id);

  SELECT COUNT(*) INTO cnt_estimates
    FROM public.estimates e
    WHERE e.opportunity_id IN (SELECT id FROM public.crm_opportunities WHERE client_id = OLD.id);

  SELECT COUNT(*) INTO cnt_projects
    FROM public.projects p
    WHERE p.opportunity_id IN (SELECT id FROM public.crm_opportunities WHERE client_id = OLD.id);

  SELECT COUNT(*) INTO cnt_invoices
    FROM public.invoices i
    WHERE i.opportunity_id IN (SELECT id FROM public.crm_opportunities WHERE client_id = OLD.id);

  SELECT COUNT(*) INTO cnt_purchase_orders
    FROM public.purchase_orders po
    WHERE po.opportunity_id IN (SELECT id FROM public.crm_opportunities WHERE client_id = OLD.id);

  SELECT COUNT(*) INTO cnt_change_orders
    FROM public.change_orders co
    WHERE co.opportunity_id IN (SELECT id FROM public.crm_opportunities WHERE client_id = OLD.id);

  SELECT COUNT(*) INTO cnt_material_requests
    FROM public.material_requests mr
    WHERE mr.opportunity_id IN (SELECT id FROM public.crm_opportunities WHERE client_id = OLD.id);

  -- 4. Deeper field history (5 recommended extras + timesheets) reachable
  --    via projects. Each is checked individually for clarity in the
  --    error message.
  SELECT COUNT(*) INTO cnt_timesheets
    FROM public.timesheet_entries t
    WHERE t.project_id IN (
      SELECT p.id FROM public.projects p
      WHERE p.opportunity_id IN (SELECT id FROM public.crm_opportunities WHERE client_id = OLD.id)
    );

  SELECT COUNT(*) INTO cnt_djr
    FROM public.daily_job_reports d
    WHERE d.project_id IN (
      SELECT p.id FROM public.projects p
      WHERE p.opportunity_id IN (SELECT id FROM public.crm_opportunities WHERE client_id = OLD.id)
    );

  SELECT COUNT(*) INTO cnt_schedules
    FROM public.schedule_entries s
    WHERE s.project_id IN (
      SELECT p.id FROM public.projects p
      WHERE p.opportunity_id IN (SELECT id FROM public.crm_opportunities WHERE client_id = OLD.id)
    );

  SELECT COUNT(*) INTO cnt_forms
    FROM public.form_submissions f
    WHERE f.project_id IN (
      SELECT p.id FROM public.projects p
      WHERE p.opportunity_id IN (SELECT id FROM public.crm_opportunities WHERE client_id = OLD.id)
    );

  SELECT COUNT(*) INTO cnt_incidents
    FROM public.incidents i
    WHERE i.project_id IN (
      SELECT p.id FROM public.projects p
      WHERE p.opportunity_id IN (SELECT id FROM public.crm_opportunities WHERE client_id = OLD.id)
    );

  SELECT COUNT(*) INTO cnt_rfis
    FROM public.rfis r
    WHERE r.project_id IN (
      SELECT p.id FROM public.projects p
      WHERE p.opportunity_id IN (SELECT id FROM public.crm_opportunities WHERE client_id = OLD.id)
    );

  has_deps := (cnt_contacts        + cnt_opps            + cnt_activities
             + cnt_tasks           + cnt_quotes          + cnt_material_sales
             + cnt_client_pricings + cnt_contracts       + cnt_estimates
             + cnt_projects        + cnt_invoices        + cnt_purchase_orders
             + cnt_change_orders   + cnt_material_requests + cnt_timesheets
             + cnt_djr             + cnt_schedules       + cnt_forms
             + cnt_incidents       + cnt_rfis) > 0;

  IF has_deps THEN
    dep_summary := format(
      'contacts=%s, opportunities=%s, activities=%s, tasks=%s, quotes=%s, '
      'material_sales=%s, client_pricings=%s, contracts=%s, estimates=%s, '
      'projects=%s, invoices=%s, purchase_orders=%s, change_orders=%s, '
      'material_requests=%s, timesheets=%s, daily_job_reports=%s, '
      'schedule_entries=%s, form_submissions=%s, incidents=%s, rfis=%s',
      cnt_contacts, cnt_opps, cnt_activities, cnt_tasks, cnt_quotes,
      cnt_material_sales, cnt_client_pricings, cnt_contracts, cnt_estimates,
      cnt_projects, cnt_invoices, cnt_purchase_orders, cnt_change_orders,
      cnt_material_requests, cnt_timesheets, cnt_djr, cnt_schedules,
      cnt_forms, cnt_incidents, cnt_rfis
    );

    RAISE EXCEPTION
      'Cannot hard-delete client (id=%) with dependent commercial or field history. Use soft-delete (deleted_at) instead. Dependents: %',
      OLD.id, dep_summary
      USING ERRCODE = 'check_violation',
            HINT    = 'Owner does not bypass this rule. Service role bypass is reserved for controlled maintenance only.';
  END IF;

  RETURN OLD;
END;
$$;

COMMENT ON FUNCTION public.fn_block_client_hard_delete() IS
'Phase 1 RM6. Blocks hard-delete of clients with any dependent record across 20 enumerated tables (7 direct FK + 7 opportunity-reachable + 6 project-reachable). Bypassed only by auth.role() = ''service_role''. Owner does not bypass.';

DROP TRIGGER IF EXISTS trg_block_client_hard_delete ON public.clients;

CREATE TRIGGER trg_block_client_hard_delete
BEFORE DELETE ON public.clients
FOR EACH ROW
EXECUTE FUNCTION public.fn_block_client_hard_delete();

-- ============================================================================
-- VERIFICATION (run after apply, with seed data)
-- ============================================================================
-- -- 1. Create a client with no dependents → exec hard-delete should succeed.
-- INSERT INTO clients (id, company_id, name)
--   VALUES (gen_random_uuid(), '<your-company-id>', 'RM6 test - empty');
-- DELETE FROM clients WHERE name = 'RM6 test - empty';
--
-- -- 2. Create a client + a single quote → exec hard-delete should fail with
-- --    the dependency summary.
-- INSERT INTO clients (id, company_id, name)
--   VALUES ('11111111-1111-1111-1111-111111111111', '<your-company-id>', 'RM6 test - has history');
-- INSERT INTO quotes (id, company_id, client_id, ...)
--   VALUES (gen_random_uuid(), '<your-company-id>', '11111111-1111-1111-1111-111111111111', ...);
-- DELETE FROM clients WHERE id = '11111111-1111-1111-1111-111111111111';
-- -- Expected: ERROR with check_violation, listing quotes=1.
