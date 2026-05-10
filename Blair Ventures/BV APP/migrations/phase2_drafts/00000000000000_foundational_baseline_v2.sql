-- =========================================================
-- FOUNDATIONAL BASELINE v2 — minimal-shape strategy
-- Phase 2 of the Aski IQ stabilization plan.
-- =========================================================
-- Strategy: each pre-history table gets the ABSOLUTE MINIMUM column
-- set — id PK + company_id FK (where applicable) + any column that's
-- NOT NULL with no default in prod's CURRENT schema. Later migrations
-- handle every other column via ADD COLUMN, which succeeds on a
-- fresh branch because the column doesn't exist yet.
--
-- Why minimal-shape rather than snapshot-current:
--   Prod's CURRENT schema has NOT NULL columns added by various later
--   migrations (e.g. change_orders.opportunity_id added by entity-
--   first slice 2). If we put those in the baseline AND the later
--   migration also tries to ADD them, the ADD COLUMN IF NOT EXISTS
--   succeeds but any backfill UPDATE in the later migration may
--   mismatch. By keeping the baseline minimal, we let every column
--   land via its original migration in the order it was authored.
--
-- All FKs to companies(id) use ON DELETE CASCADE per the prevailing
-- tenant-scope pattern. Sub-tables FK to their parent (e.g.
-- estimate_line_items → estimates) using the same cascade.

-- ─────────────────────────────────────────────────────────────────
-- Foundational v1 tables (companies + projects + employees + profiles)
-- ─────────────────────────────────────────────────────────────────
create table if not exists public.companies (
    id          uuid primary key default gen_random_uuid(),
    name        text not null default 'My Company',
    plan        text not null default 'trial',
    created_at  timestamptz not null default now()
);

create table if not exists public.projects (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    name        text not null,
    created_at  timestamptz not null default now()
);

create table if not exists public.employees (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    first_name  text not null,
    last_name   text not null,
    created_at  timestamptz not null default now()
);

create table if not exists public.profiles (
    id          uuid primary key,
    company_id  uuid not null,
    email       text not null,
    full_name   text not null default '',
    role        text not null default 'field_worker',
    created_at  timestamptz not null default now()
);

-- ─────────────────────────────────────────────────────────────────
-- Pre-history tables (alphabetical). Bare minimum: id + company_id.
-- ─────────────────────────────────────────────────────────────────

create table if not exists public.audit_snapshots (
    id           uuid primary key default gen_random_uuid(),
    company_id   uuid not null,
    record_type  text not null default '',
    record_id    uuid not null,
    event_type   text not null default '',
    performed_by text not null default '',
    snapshot_json text not null default '{}',
    created_at   timestamptz not null default now()
);

create table if not exists public.certificates (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    name        text not null default '',
    created_at  timestamptz not null default now()
);

create table if not exists public.clients (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    name        text not null,
    created_at  timestamptz not null default now()
);

create table if not exists public.company_settings (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    created_at  timestamptz not null default now()
);

create table if not exists public.crews (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    name        text not null default '',
    created_at  timestamptz not null default now()
);

create table if not exists public.crew_members (
    id          uuid primary key default gen_random_uuid(),
    crew_id     uuid not null,
    employee_id uuid not null,
    company_id  uuid not null
);

create table if not exists public.crm_opportunities (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    client_id   uuid not null,
    title       text not null default '',
    created_at  timestamptz not null default now()
);

create table if not exists public.crm_contacts (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    client_id   uuid not null,
    created_at  timestamptz not null default now()
);

create table if not exists public.crm_tasks (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    created_at  timestamptz not null default now()
);

create table if not exists public.crm_activities (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    created_at  timestamptz not null default now()
);

create table if not exists public.crm_checklists (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    created_at  timestamptz not null default now()
);

create table if not exists public.estimates (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    name        text not null default '',
    created_at  timestamptz not null default now()
);

create table if not exists public.estimate_line_items (
    id          uuid primary key default gen_random_uuid(),
    estimate_id uuid not null,
    company_id  uuid not null
);

create table if not exists public.quotes (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    expiry_date timestamptz not null default now() + interval '30 days',
    created_at  timestamptz not null default now()
);

create table if not exists public.invoices (
    id             uuid primary key default gen_random_uuid(),
    company_id     uuid not null,
    invoice_number text not null default '',
    due_date       timestamptz not null default now() + interval '30 days',
    created_at     timestamptz not null default now()
);

create table if not exists public.change_orders (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    project_id  uuid not null,
    number      text not null default '',
    title       text not null default '',
    created_at  timestamptz not null default now()
);

create table if not exists public.rfis (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    project_id  uuid not null,
    number      text not null default '',
    title       text not null default '',
    created_at  timestamptz not null default now()
);

create table if not exists public.daily_job_reports (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    report_date date not null default current_date,
    created_at  timestamptz not null default now()
);

create table if not exists public.schedule_entries (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    date        date not null default current_date,
    created_at  timestamptz not null default now()
);

create table if not exists public.timesheet_entries (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    work_date   date not null default current_date,
    created_at  timestamptz not null default now()
);

create table if not exists public.form_templates (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    name        text not null default '',
    created_at  timestamptz not null default now()
);

create table if not exists public.form_submissions (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    created_at  timestamptz not null default now()
);

create table if not exists public.equipment (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    name        text not null default '',
    created_at  timestamptz not null default now()
);

create table if not exists public.exception_logs (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    created_at  timestamptz not null default now()
);

create table if not exists public.incidents (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    title       text not null default '',
    incident_date timestamptz not null default now(),
    incident_time timestamptz not null default now(),
    created_at  timestamptz not null default now()
);

create table if not exists public.invites (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    code        text not null default '',
    expires_at  timestamptz not null default now() + interval '7 days',
    created_at  timestamptz not null default now()
);

create table if not exists public.material_requests (
    id              uuid primary key default gen_random_uuid(),
    company_id      uuid not null,
    request_number  text not null default '',
    created_at      timestamptz not null default now()
);

create table if not exists public.project_assignments (
    id          uuid primary key default gen_random_uuid(),
    project_id  uuid not null,
    user_id     uuid not null,
    company_id  uuid not null
);

create table if not exists public.project_budgets (
    id          uuid primary key default gen_random_uuid(),
    project_id  uuid not null,
    company_id  uuid not null,
    created_at  timestamptz not null default now()
);

create table if not exists public.purchase_orders (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    po_number   text not null default '',
    created_at  timestamptz not null default now()
);

create table if not exists public.purchase_order_acceptance_tokens (
    id                uuid primary key default gen_random_uuid(),
    purchase_order_id uuid not null,
    company_id        uuid not null,
    token             text not null default '',
    expires_at        timestamptz not null default now() + interval '7 days',
    created_at        timestamptz not null default now()
);

create table if not exists public.suppliers (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    name        text not null,
    created_at  timestamptz not null default now()
);

create table if not exists public.subcontractors (
    id           uuid primary key default gen_random_uuid(),
    company_id   uuid not null,
    company_name text not null,
    created_at   timestamptz not null default now()
);

create table if not exists public.sub_contracts (
    id              uuid primary key default gen_random_uuid(),
    company_id      uuid not null,
    subcontractor_id uuid not null,
    project_id      uuid not null,
    contract_number text not null default '',
    created_at      timestamptz not null default now()
);
