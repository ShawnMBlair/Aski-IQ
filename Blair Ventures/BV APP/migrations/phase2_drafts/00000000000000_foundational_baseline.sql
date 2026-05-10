-- =========================================================
-- FOUNDATIONAL BASELINE — Phase 2 (DRAFT v1, partial coverage)
-- =========================================================
-- Status: 2026-05-10 — PARTIAL DRAFT, NOT REGISTERED ON PROD.
--
--   Tested on branch `phase2-baseline-verify` (project_ref
--   spvxvsbsafaxyxafqngj). Result: this 4-table baseline successfully
--   bootstraps the FK chain past the FIRST 3 registered migrations
--   (create_company_cost_codes, create_import_batches, create_import_rows).
--   It then fails at migration 4 (quotes_add_missing_columns_and_rls)
--   because that migration ALTERs `public.quotes` and references
--   `public.estimates` / `public.crm_opportunities` / others — all
--   pre-history tables not covered by this baseline.
--
--   A prod scan found ~30 pre-history tables that subsequent migrations
--   ALTER but never CREATE. They include: audit_snapshots, certificates,
--   change_orders, clients, company_settings, crew_members, crews,
--   crm_activities, crm_checklists, crm_contacts, crm_opportunities,
--   crm_tasks, daily_job_reports, equipment, estimate_line_items,
--   estimates, exception_logs, form_submissions, form_templates,
--   incidents, invites, invoices, material_requests, project_assignments,
--   project_budgets, purchase_order_acceptance_tokens, purchase_orders,
--   quotes, rfis, schedule_entries, sub_contracts, subcontractors,
--   suppliers, timesheet_entries.
--
--   To fully close Phase 2, this baseline must expand to comprehensive
--   coverage of every pre-history table at minimum-viable column shape.
--   Per the original stabilization plan, this is a "dedicated session,
--   multi-day" item — too large to bolt onto an active workstream.
--   The 4-table v1 stays in this file as the proven foundation a
--   v2 author can build on.
--
-- Original purpose:
--   Closes the "branches come up empty" gotcha. Aski IQ's foundational
--   tables were created outside Supabase's migration history — likely
--   via the dashboard / SQL editor before migration files were adopted.
--   As a result, the first registered migration references companies(id)
--   on a fresh branch and replay fails with `ERROR: relation "companies"
--   does not exist`. Branch ends up in MIGRATIONS_FAILED status with
--   zero public tables.
--
-- Registration plan (when v2 ships):
--   Insert into supabase_migrations.schema_migrations with version
--   '00000000000000' so it sorts BEFORE every existing migration. On
--   prod: every CREATE TABLE IF NOT EXISTS is a no-op. On fresh
--   branches: this creates the minimum-viable foundational schema and
--   subsequent migrations evolve it as they did historically on prod.
--
-- Column shapes here are deliberately MINIMAL — only what's needed for
-- the FK chain. Later migrations add the other columns as they were
-- originally written. This keeps the baseline focused on its single
-- job: provide FK targets so the migration history can replay.

-- ─────────────────────────────────────────────────────────────────
-- companies — the root tenant table. FK target for almost everything.
-- ─────────────────────────────────────────────────────────────────
create table if not exists public.companies (
    id          uuid primary key default gen_random_uuid(),
    name        text not null default 'My Company',
    plan        text not null default 'trial',
    created_at  timestamptz not null default now()
);

-- ─────────────────────────────────────────────────────────────────
-- projects — second-most-FK'd table.
-- ─────────────────────────────────────────────────────────────────
create table if not exists public.projects (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    name        text not null,
    client_name text not null default '',
    status      text not null default 'active',
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    sync_status text not null default 'synced',
    last_modified_by text not null default '',
    last_modified_at timestamptz not null default now()
);

-- FK to companies; named to match prod's existing constraint name where
-- possible. ON DELETE CASCADE matches prod behavior for tenant scoping.
alter table public.projects
    drop constraint if exists projects_company_id_fkey;
alter table public.projects
    add constraint projects_company_id_fkey
    foreign key (company_id) references public.companies(id) on delete cascade;

-- ─────────────────────────────────────────────────────────────────
-- employees — workforce table; referenced by timesheets, schedule,
-- crew_members, etc. Minimal shape: enough to satisfy FK targets.
-- ─────────────────────────────────────────────────────────────────
create table if not exists public.employees (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    first_name  text not null,
    last_name   text not null,
    role        text not null default 'foreman',
    is_active   boolean not null default true,
    certifications text not null default '[]',
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    sync_status text not null default 'synced',
    last_modified_by text not null default '',
    last_modified_at timestamptz not null default now()
);

alter table public.employees
    drop constraint if exists employees_company_id_fkey;
alter table public.employees
    add constraint employees_company_id_fkey
    foreign key (company_id) references public.companies(id) on delete cascade;

-- ─────────────────────────────────────────────────────────────────
-- profiles — auth-side user metadata. id mirrors auth.users(id).
-- Supabase auth.users is managed by the platform so we can FK to it.
-- ─────────────────────────────────────────────────────────────────
create table if not exists public.profiles (
    id          uuid primary key,
    company_id  uuid not null,
    email       text not null,
    full_name   text not null default '',
    role        text not null default 'field_worker',
    is_active   boolean not null default true,
    created_at  timestamptz not null default now()
);

alter table public.profiles
    drop constraint if exists profiles_company_id_fkey;
alter table public.profiles
    add constraint profiles_company_id_fkey
    foreign key (company_id) references public.companies(id) on delete cascade;

-- profiles.id → auth.users(id) FK. Conditional on auth schema existing
-- (it always does on Supabase, but keep defensive).
do $$
begin
    if exists (select 1 from information_schema.tables
               where table_schema = 'auth' and table_name = 'users') then
        alter table public.profiles
            drop constraint if exists profiles_id_fkey;
        alter table public.profiles
            add constraint profiles_id_fkey
            foreign key (id) references auth.users(id) on delete cascade;
    end if;
end $$;
