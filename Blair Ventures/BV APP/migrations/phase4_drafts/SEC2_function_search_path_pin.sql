-- =========================================================
-- function_search_path_mutable — pin search_path on 34 functions
-- Phase 4 / Item 2 (continued) of the Aski IQ stabilization plan.
-- =========================================================
-- Purpose:
--   PostgreSQL functions that don't pin `search_path` are vulnerable
--   to schema-injection attacks: a caller could prepend a malicious
--   schema to their session search_path and have the function resolve
--   identifiers (table names, function names) to attacker-controlled
--   objects. The mitigation is `SET search_path = public` (or a
--   broader pin) on every SECURITY DEFINER function.
--
--   The project's own `pin_function_search_path` migration covered
--   most functions historically, but 34 functions added since then
--   — primarily the `fn_*_lock_sample_marker` family from the sample-
--   data hardening work — were missed. Same fix, applied in batch.
--
-- Idempotency: ALTER FUNCTION ... SET search_path is repeatable.
-- Re-running this migration is a no-op if the search_path is already
-- pinned.

-- ── Sample-data lock-marker triggers (one per table that carries
--    is_sample_data; ~28 of them, all written from a single template) ──
alter function public.fn_certificates_lock_sample_marker()         set search_path = public;
alter function public.fn_change_orders_lock_sample_marker()        set search_path = public;
alter function public.fn_client_pricings_lock_sample_marker()      set search_path = public;
alter function public.fn_clients_lock_sample_marker()              set search_path = public;
alter function public.fn_contracts_lock_sample_marker()            set search_path = public;
alter function public.fn_crews_lock_sample_marker()                set search_path = public;
alter function public.fn_crm_activities_lock_sample_marker()       set search_path = public;
alter function public.fn_crm_contacts_lock_sample_marker()         set search_path = public;
alter function public.fn_crm_opportunities_lock_sample_marker()    set search_path = public;
alter function public.fn_crm_tasks_lock_sample_marker()            set search_path = public;
alter function public.fn_daily_job_reports_lock_sample_marker()    set search_path = public;
alter function public.fn_equipment_lock_sample_marker()            set search_path = public;
alter function public.fn_estimates_lock_sample_marker()            set search_path = public;
alter function public.fn_exception_logs_lock_sample_marker()       set search_path = public;
alter function public.fn_form_submissions_lock_sample_marker()     set search_path = public;
alter function public.fn_incidents_lock_sample_marker()            set search_path = public;
alter function public.fn_invoices_lock_sample_marker()             set search_path = public;
alter function public.fn_lien_waivers_lock_sample_marker()         set search_path = public;
alter function public.fn_material_requests_lock_sample_marker()    set search_path = public;
alter function public.fn_material_sales_lock_sample_marker()       set search_path = public;
alter function public.fn_product_services_lock_sample_marker()     set search_path = public;
alter function public.fn_project_budgets_lock_sample_marker()      set search_path = public;
alter function public.fn_projects_lock_sample_marker()             set search_path = public;
alter function public.fn_purchase_orders_lock_sample_marker()      set search_path = public;
alter function public.fn_quotes_lock_sample_marker()               set search_path = public;
alter function public.fn_rfis_lock_sample_marker()                 set search_path = public;
alter function public.fn_schedule_entries_lock_sample_marker()     set search_path = public;
alter function public.fn_subcontractors_lock_sample_marker()       set search_path = public;
alter function public.fn_suppliers_lock_sample_marker()            set search_path = public;
alter function public.fn_timesheet_entries_lock_sample_marker()    set search_path = public;

-- ── Other functions ──
alter function public.bump_terms_template_version()                set search_path = public;
alter function public.fn_quote_approvals_touch_updated_at()        set search_path = public;
alter function public.fn_touch_company_email_settings()            set search_path = public;
alter function public.preserve_opportunity_id_on_update()          set search_path = public;
