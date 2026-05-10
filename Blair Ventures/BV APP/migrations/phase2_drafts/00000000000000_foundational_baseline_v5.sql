-- =========================================================
-- FOUNDATIONAL BASELINE v5 — v4 + updated_at on 25 pre-history tables
-- Phase 2 of the Aski IQ stabilization plan.
-- =========================================================
-- Status 2026-05-10: TESTED ON BRANCH, NOT REGISTERED ON PROD.
--
-- v5 is the most-advanced baseline this session. Tested on branch
-- `phase2-v5-verify` (now deleted): replay advanced 45 historical
-- migrations (vs v4's 18). Failure at migration 46
-- (`estimate_converted_status`) on missing pre-history column
-- `estimates.status` referenced by a CHECK constraint.
--
-- v4 → v5 delta: added `updated_at timestamptz NOT NULL DEFAULT now()`
-- to 25 pre-history tables. The `add_soft_delete_and_timestamp_columns`
-- migration only adds updated_at to 5 specific tables (crm_activities,
-- crm_checklists, crm_contacts, crm_tasks, suppliers); for every other
-- table it ASSUMES updated_at already exists pre-history. v5 supplies
-- it on the rest.
--
-- Tables that DO NOT get updated_at in this baseline (because they
-- either get it from the soft-delete migration or never had it):
--   crm_activities, crm_checklists, crm_contacts, crm_tasks, suppliers
--   (added by add_soft_delete_and_timestamp_columns)
--   profiles, audit_snapshots, crew_members, project_assignments,
--   estimate_line_items, invites, purchase_order_acceptance_tokens
--   (these never had updated_at in prod's current schema)
--
-- v6+ research surfaced (during v5 failure analysis) — pre-history
-- columns referenced by CHECK constraints across the migration history:
--
-- estimates:        status, contingency_percent, overhead_percent,
--                   profit_percent, loss_reason
-- contracts:        counterparty_type, expiry_date, effective_date,
--                   retainage_percent, contract_value
-- quotes:           contingency_percent, discount_percent, tax_rate,
--                   quote_date
-- invoices:         tax_rate, invoice_date
-- crm_opportunities: stage  (already a NOT NULL DEFAULT in baseline)
-- material_sales:   tax_rate
-- projects:         start_date, end_date, contract_value
-- sub_contracts:    retention_percent, start_date, end_date,
--                   contract_value, invoiced_to_date, paid_to_date
-- schedule_entries: assignment_mode  (already in baseline)
-- schedule_recommendations: status  (table not in baseline yet — added
--                   by `schedule_recommendations` migration; would need
--                   to be added if v6 covers up through that migration)
--
-- These are the v6 starting point. Add the missing columns as nullable
-- (or NOT NULL DEFAULT 0 for numerics) to the relevant tables, re-test,
-- iterate. Each iteration likely uncovers one or two more layers of
-- pre-history columns until the chain comes up green.

-- ─────────────────────────────────────────────────────────────────
-- v5 SQL — full text (38 tables + 10 function stubs)
-- ─────────────────────────────────────────────────────────────────

create table if not exists public.companies (
    id uuid primary key default gen_random_uuid(),
    name text not null default 'My Company',
    plan text not null default 'trial',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.projects (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    name text not null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.employees (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    first_name text not null,
    last_name text not null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.profiles (
    id uuid primary key,
    company_id uuid not null,
    email text not null,
    full_name text not null default '',
    role text not null default 'field_worker',
    created_at timestamptz not null default now()
);

create table if not exists public.audit_snapshots (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    record_type text not null default '',
    record_id uuid not null,
    event_type text not null default '',
    performed_by text not null default '',
    snapshot_json text not null default '{}',
    created_at timestamptz not null default now()
);

create table if not exists public.certificates (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    employee_id uuid,
    name text not null default '',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.clients (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    name text not null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.company_settings (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.crews (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    name text not null default '',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.crew_members (
    id uuid primary key default gen_random_uuid(),
    crew_id uuid not null,
    employee_id uuid not null,
    company_id uuid not null
);

create table if not exists public.crm_opportunities (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    client_id uuid not null,
    contact_id uuid,
    title text not null default '',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.crm_contacts (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    client_id uuid not null,
    created_at timestamptz not null default now()
);

create table if not exists public.crm_tasks (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    client_id uuid,
    contact_id uuid,
    created_at timestamptz not null default now()
);

create table if not exists public.crm_activities (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    contact_id uuid
);

create table if not exists public.crm_checklists (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null
);

create table if not exists public.estimates (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    client_id uuid,
    project_id uuid,
    opportunity_id uuid,
    converted_quote_id uuid,
    origin_type text not null default 'direct_commercial',
    name text not null default '',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.estimate_line_items (
    id uuid primary key default gen_random_uuid(),
    estimate_id uuid not null,
    company_id uuid not null
);

create table if not exists public.quotes (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    client_id uuid,
    project_id uuid,
    estimate_id uuid,
    opportunity_id uuid,
    assigned_pm_id uuid,
    job_number text not null default '',
    loss_reason text,
    currency text not null default 'USD',
    expiry_date timestamptz not null default now() + interval '30 days',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.invoices (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    client_id uuid,
    project_id uuid,
    contract_id uuid,
    opportunity_id uuid,
    quote_id uuid,
    invoice_number text not null default '',
    invoice_type text not null default 'standard',
    currency text not null default 'USD',
    due_date timestamptz not null default now() + interval '30 days',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.change_orders (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    project_id uuid not null,
    contract_id uuid,
    opportunity_id uuid,
    number text not null default '',
    title text not null default '',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.rfis (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    project_id uuid not null,
    number text not null default '',
    title text not null default '',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.daily_job_reports (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    project_id uuid,
    report_date date not null default current_date,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.schedule_entries (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    project_id uuid,
    crew_id uuid,
    date date not null default current_date,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.timesheet_entries (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    employee_id uuid,
    project_id uuid,
    work_date date not null default current_date,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.form_templates (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    name text not null default '',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.form_submissions (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.equipment (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    assigned_project_id uuid,
    name text not null default '',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.exception_logs (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.incidents (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    title text not null default '',
    incident_date timestamptz not null default now(),
    incident_time timestamptz not null default now(),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.invites (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    code text not null default '',
    expires_at timestamptz not null default now() + interval '7 days',
    created_at timestamptz not null default now()
);

create table if not exists public.material_requests (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    project_id uuid,
    supplier_id uuid,
    material_sales_id uuid,
    requested_by_employee_id uuid,
    opportunity_id uuid,
    status text not null default 'draft',
    destination_type text not null default 'internal',
    request_number text not null default '',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.project_assignments (
    id uuid primary key default gen_random_uuid(),
    project_id uuid not null,
    user_id uuid not null,
    company_id uuid not null
);

create table if not exists public.project_budgets (
    id uuid primary key default gen_random_uuid(),
    project_id uuid not null,
    company_id uuid not null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.purchase_orders (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    project_id uuid,
    material_request_id uuid,
    opportunity_id uuid,
    po_number text not null default '',
    invoice_flagged boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.purchase_order_acceptance_tokens (
    id uuid primary key default gen_random_uuid(),
    purchase_order_id uuid not null,
    company_id uuid not null,
    token text not null default '',
    expires_at timestamptz not null default now() + interval '7 days',
    created_at timestamptz not null default now()
);

create table if not exists public.suppliers (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    name text not null,
    created_at timestamptz not null default now()
);

create table if not exists public.subcontractors (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    company_name text not null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.sub_contracts (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null,
    subcontractor_id uuid not null,
    project_id uuid not null,
    linked_contract_id uuid,
    contract_number text not null default '',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

-- ─────────────────────────────────────────────────────────────────
-- Pre-history function stubs (10 functions)
-- ─────────────────────────────────────────────────────────────────

create or replace function public.handle_new_user()
    returns trigger language plpgsql as $f$ begin return new; end; $f$;

create or replace function public.stamp_company_id()
    returns trigger language plpgsql as $f$ begin return new; end; $f$;

create or replace function public.set_updated_at()
    returns trigger language plpgsql as $f$ begin new.updated_at := now(); return new; end; $f$;

create or replace function public.set_quotes_updated_at()
    returns trigger language plpgsql as $f$ begin new.updated_at := now(); return new; end; $f$;

create or replace function public.update_crm_opportunity_timestamp()
    returns trigger language plpgsql as $f$ begin new.updated_at := now(); return new; end; $f$;

create or replace function public.get_my_company_id()
    returns uuid language sql stable as $f$ select null::uuid $f$;

create or replace function public.get_my_role()
    returns text language sql stable as $f$ select 'field_worker'::text $f$;

create or replace function public.is_field_role()
    returns boolean language sql stable as $f$ select false $f$;

create or replace function public.is_manager_or_above()
    returns boolean language sql stable as $f$ select false $f$;

create or replace function public.create_invite(p_role text)
    returns text language sql as $f$ select ''::text $f$;
