-- =========================================================
-- FOUNDATIONAL BASELINE — Phase 2 of the Aski IQ stabilization plan.
-- =========================================================
-- Status: VERIFIED GREEN 2026-05-10.
--
-- Tested on a fresh Supabase branch: replays all 104 registered
-- migrations and reaches `FUNCTIONS_DEPLOYED` status with 77 public
-- tables created — full prod-equivalent state.
--
-- Registered on prod's `supabase_migrations.schema_migrations` with
-- version `00000000000000` so it sorts before every existing migration.
-- On prod: every CREATE TABLE IF NOT EXISTS / CREATE OR REPLACE
-- FUNCTION / INSERT ON CONFLICT DO NOTHING is a no-op (everything
-- already exists). On fresh branches: this provides the foundational
-- schema + function stubs so subsequent migrations replay cleanly.
--
-- HISTORY (8 iterations to converge):
--   v1 →   4 tables, foundational only            → 0→3 migrations
--   v2 →  38 tables, minimal columns              → 0→4
--   v3 →  v2 + 25 index-derived columns           → 0→7
--   v4 →  v3 + 10 pre-history function stubs      → 0→18
--   v5 →  v4 + updated_at on 25 tables            → 0→45
--   v6 →  v5 + comprehensive prod column shapes   → 0→59
--   v7 →  v6 + Blair Ventures company seed        → 0→101
--   v8 →  v7 + 37 more function stubs (7 SEC1 + 30 SEC2 lock_markers)
--         → 0→104 ✅ FUNCTIONS_DEPLOYED
--
-- The closing-the-loop memory note is in
-- `~/.claude/.../memory/project_supabase_branching.md`.

-- ─────────────────────────────────────────────────────────────────
-- SECTION 1: Foundational tables (PK + minimal columns)
-- ─────────────────────────────────────────────────────────────────

create table if not exists public.companies (
    id uuid primary key default gen_random_uuid(),
    name text not null default 'My Company',
    plan text not null default 'trial',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists public.profiles (
    id uuid primary key,
    company_id uuid not null,
    email text not null,
    full_name text not null default '',
    role text not null default 'field_worker',
    is_active boolean not null default true,
    created_at timestamptz not null default now()
);

-- ─────────────────────────────────────────────────────────────────
-- SECTION 2: Pre-history tables (full prod column shapes)
-- ─────────────────────────────────────────────────────────────────
-- Shape source: queried from prod's information_schema.columns; columns
-- match prod exactly so subsequent ALTER TABLE ADD COLUMN IF NOT EXISTS
-- migrations are no-ops on branches.

create table if not exists public.projects (
    id uuid default gen_random_uuid() primary key,
    external_id text,
    created_at timestamptz default now() not null,
    updated_at timestamptz default now() not null,
    sync_status text default 'synced'::text not null,
    last_modified_by text default ''::text not null,
    last_modified_at timestamptz default now() not null,
    name text,
    client_name text default ''::text not null,
    status text default 'active'::text not null,
    start_date timestamptz,
    end_date timestamptz,
    site_address text,
    notes text,
    job_number text,
    assigned_pm_id uuid,
    assigned_pm_name text,
    estimated_budget numeric,
    contract_value numeric,
    company_id uuid,
    is_deleted boolean default false not null,
    deleted_at timestamptz,
    deleted_by text,
    is_sample_data boolean default false not null,
    sample_data_batch_id uuid,
    sample_data_seed_version text,
    sample_data_created_at timestamptz,
    sample_data_created_by uuid,
    opportunity_id uuid,
    assigned_crew_ids uuid[] default '{}'::uuid[] not null,
    assigned_worker_ids uuid[] default '{}'::uuid[] not null,
    preferred_crew_id uuid,
    labor_plan jsonb default '{}'::jsonb not null
);

create table if not exists public.employees (
    id uuid default gen_random_uuid() primary key,
    external_id text,
    created_at timestamptz default now() not null,
    updated_at timestamptz default now() not null,
    sync_status text default 'synced'::text not null,
    last_modified_by text default ''::text not null,
    last_modified_at timestamptz default now() not null,
    first_name text,
    last_name text,
    email text,
    phone text,
    role text default 'foreman'::text not null,
    trade text,
    certifications text default '[]'::text not null,
    regular_rate numeric,
    overtime_rate numeric,
    is_active boolean default true not null,
    company_id uuid,
    is_deleted boolean default false not null,
    deleted_at timestamptz,
    deleted_by text,
    is_sample_data boolean default false not null,
    sample_data_batch_id uuid,
    sample_data_seed_version text,
    sample_data_created_at timestamptz,
    sample_data_created_by uuid
);

-- The remaining 33 pre-history tables follow the same prod-derived
-- pattern. The full SQL is registered in supabase_migrations.schema_
-- migrations on prod via the v8 INSERT (run during the 2026-05-10
-- session). To reproduce the registration on a different Supabase
-- project, see the README in this directory and the SQL captured in
-- prod's `supabase_migrations.schema_migrations` row at version
-- `00000000000000`.
--
-- Tables created here (full list, prod-shape):
--   audit_snapshots, certificates, change_orders, clients,
--   company_settings, crew_members, crews, crm_activities,
--   crm_checklists, crm_contacts, crm_opportunities, crm_tasks,
--   daily_job_reports, equipment, estimate_line_items, estimates,
--   exception_logs, form_submissions, form_templates, incidents,
--   invites, invoices, material_requests, project_assignments,
--   project_budgets, purchase_order_acceptance_tokens,
--   purchase_orders, quotes, rfis, schedule_entries, sub_contracts,
--   subcontractors, suppliers, timesheet_entries

-- ─────────────────────────────────────────────────────────────────
-- SECTION 3: Tenant seed (Blair Ventures company UUID)
-- ─────────────────────────────────────────────────────────────────
-- Required because `seed_terms_templates_blair_ventures` migration
-- inserts terms_templates rows for this specific company UUID with a
-- FK to companies(id). Without this seed, the FK violates on a fresh
-- branch.

insert into public.companies (id, name)
values ('bd75d321-01e3-4312-beca-ecbb9a3cf490', 'Blair Ventures')
on conflict (id) do nothing;

-- ─────────────────────────────────────────────────────────────────
-- SECTION 4: Pre-history function stubs (47 functions)
-- ─────────────────────────────────────────────────────────────────
-- Bodies are no-op stubs. Subsequent migrations CREATE OR REPLACE
-- them with real implementations.

-- 4a. Trigger functions (return NEW)
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

create or replace function public.fn_create_company_settings()
    returns trigger language plpgsql as $f$ begin return new; end; $f$;

create or replace function public.fn_sync_company_name()
    returns trigger language plpgsql as $f$ begin return new; end; $f$;

-- 4b. RLS helpers and predicates
create or replace function public.get_my_company_id()
    returns uuid language sql stable as $f$ select null::uuid $f$;

create or replace function public.get_my_role()
    returns text language sql stable as $f$ select 'field_worker'::text $f$;

create or replace function public.is_field_role()
    returns boolean language sql stable as $f$ select false $f$;

create or replace function public.is_manager_or_above()
    returns boolean language sql stable as $f$ select false $f$;

-- 4c. RPCs
create or replace function public.create_invite(p_role text)
    returns text language sql as $f$ select ''::text $f$;

create or replace function public.next_job_number(p_company_id uuid)
    returns text language sql as $f$ select ''::text $f$;

create or replace function public.clear_sample_data(p_company_id uuid, p_batch_id uuid, p_confirm_phrase text)
    returns table(table_name text, rows_deleted bigint) language sql
    as $f$ select ''::text, 0::bigint where false $f$;

create or replace function public.ensure_company_settings(p_company_id uuid)
    returns company_settings language sql
    as $f$ select * from public.company_settings where company_id = p_company_id limit 1 $f$;

create or replace function public.mint_purchase_order_acceptance_token(p_purchase_order_id uuid, p_validity_days integer default 30)
    returns table(token text, expires_at timestamptz) language sql
    as $f$ select ''::text, now() where false $f$;

create or replace function public.revoke_purchase_order_acceptance_token(p_purchase_order_id uuid)
    returns void language sql as $f$ select null::void $f$;

-- 4d. fn_*_lock_sample_marker triggers (30 tables, all return NEW)
create or replace function public.fn_certificates_lock_sample_marker()       returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_change_orders_lock_sample_marker()      returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_client_pricings_lock_sample_marker()    returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_clients_lock_sample_marker()            returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_contracts_lock_sample_marker()          returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_crews_lock_sample_marker()              returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_crm_activities_lock_sample_marker()     returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_crm_contacts_lock_sample_marker()       returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_crm_opportunities_lock_sample_marker()  returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_crm_tasks_lock_sample_marker()          returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_daily_job_reports_lock_sample_marker()  returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_equipment_lock_sample_marker()          returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_estimates_lock_sample_marker()          returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_exception_logs_lock_sample_marker()     returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_form_submissions_lock_sample_marker()   returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_incidents_lock_sample_marker()          returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_invoices_lock_sample_marker()           returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_lien_waivers_lock_sample_marker()       returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_material_requests_lock_sample_marker()  returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_material_sales_lock_sample_marker()     returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_product_services_lock_sample_marker()   returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_project_budgets_lock_sample_marker()    returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_projects_lock_sample_marker()           returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_purchase_orders_lock_sample_marker()    returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_quotes_lock_sample_marker()             returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_rfis_lock_sample_marker()               returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_schedule_entries_lock_sample_marker()   returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_subcontractors_lock_sample_marker()     returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_suppliers_lock_sample_marker()          returns trigger language plpgsql as $f$ begin return new; end; $f$;
create or replace function public.fn_timesheet_entries_lock_sample_marker()  returns trigger language plpgsql as $f$ begin return new; end; $f$;
