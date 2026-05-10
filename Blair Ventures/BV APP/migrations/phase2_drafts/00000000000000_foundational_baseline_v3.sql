-- =========================================================
-- FOUNDATIONAL BASELINE v3 — minimal-shape + index-derived columns
-- Phase 2 of the Aski IQ stabilization plan.
-- =========================================================
-- Status 2026-05-10: TESTED ON BRANCH, NOT REGISTERED ON PROD.
--
--   v3 builds on v2 by adding all pre-history columns identified via
--   a systematic scan of CREATE INDEX statements across the migration
--   history. Tested on branch `phase2-v3-verify` (now deleted): replay
--   advanced 7 migrations past the historical failure point — through
--   create_company_cost_codes, create_import_batches, create_import_rows,
--   quotes_add_missing_columns_and_rls, quotes_add_discount_tax_rate,
--   create_product_services_and_client_pricings — before failing at
--   `harden_function_grants` (20260428195136).
--
--   Failure root cause: harden_function_grants does
--   `REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM ...`
--   for ~30 PRE-HISTORY FUNCTIONS that don't exist on a fresh branch
--   (handle_new_user, stamp_company_id, set_updated_at, set_quotes_updated_at,
--   update_crm_opportunity_timestamp, get_my_company_id, get_my_role,
--   is_field_role, is_manager_or_above, create_invite, ...).
--
-- v2 → v3 deltas (additive only; tables already in v2 just get more cols):
--   - quotes:           + client_id, project_id, estimate_id, opportunity_id,
--                       assigned_pm_id, job_number, loss_reason, currency
--   - estimates:        + client_id, project_id, opportunity_id,
--                       converted_quote_id, origin_type
--   - invoices:         + client_id, project_id, contract_id, opportunity_id,
--                       quote_id, invoice_type, currency
--   - change_orders:    + contract_id, opportunity_id
--   - material_requests: + project_id, supplier_id, material_sales_id,
--                       requested_by_employee_id, opportunity_id, status,
--                       destination_type
--   - purchase_orders:  + project_id, material_request_id, opportunity_id,
--                       invoice_flagged
--   - sub_contracts:    + linked_contract_id
--   - schedule_entries: + project_id, crew_id
--   - timesheet_entries: + employee_id, project_id, is_deleted
--   - daily_job_reports: + project_id, is_deleted
--   - certificates:     + employee_id
--   - crm_opportunities: + contact_id
--   - crm_tasks:        + client_id, contact_id
--   - crm_activities:   + contact_id
--   - crm_checklists, crews, form_submissions, form_templates, incidents:
--                       + is_deleted boolean default false
--   - equipment:        + assigned_project_id
--
-- Recommended next-step research for v4 (the dedicated session):
--   1. Add CREATE OR REPLACE FUNCTION stubs for the pre-history functions
--      referenced by harden_function_grants and similar migrations:
--        handle_new_user, stamp_company_id, set_updated_at,
--        set_quotes_updated_at, update_crm_opportunity_timestamp,
--        get_my_company_id, get_my_role, is_field_role,
--        is_manager_or_above, create_invite, plus any others surfaced
--        by `grep -E "REVOKE|GRANT.*ON FUNCTION" supabase_migrations`.
--      Function bodies can be no-op stubs (RETURNS trigger AS $$ BEGIN
--      RETURN NEW; END; $$) — later migrations CREATE OR REPLACE them
--      with real implementations.
--
--   2. After v4 passes harden_function_grants, expect the next failure
--      at one of: pin_function_search_path, fix_search_path_keep_schema_visible,
--      or revoke_public_execute_on_helpers — same pattern: pre-history
--      function references. Identify + stub.
--
--   3. After all pre-history functions are stubbed, expect potential
--      issues at migrations that reference pre-history RLS policies
--      or column-level constraints. Each is its own one-line fix once
--      identified.
--
--   4. Iteration continues until the branch comes up green
--      (status = FUNCTIONS_DEPLOYED, not MIGRATIONS_FAILED).

-- ─────────────────────────────────────────────────────────────────
-- Foundational tables
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
-- Pre-history tables — minimum + index-derived pre-history columns
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
    employee_id uuid,
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
    is_deleted  boolean not null default false,
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
    contact_id  uuid,
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
    client_id   uuid,
    contact_id  uuid,
    created_at  timestamptz not null default now()
);

create table if not exists public.crm_activities (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    contact_id  uuid,
    created_at  timestamptz not null default now()
);

create table if not exists public.crm_checklists (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    created_at  timestamptz not null default now()
);

create table if not exists public.estimates (
    id                 uuid primary key default gen_random_uuid(),
    company_id         uuid not null,
    client_id          uuid,
    project_id         uuid,
    opportunity_id     uuid,
    converted_quote_id uuid,
    origin_type        text not null default 'direct_commercial',
    name               text not null default '',
    created_at         timestamptz not null default now()
);

create table if not exists public.estimate_line_items (
    id          uuid primary key default gen_random_uuid(),
    estimate_id uuid not null,
    company_id  uuid not null
);

create table if not exists public.quotes (
    id              uuid primary key default gen_random_uuid(),
    company_id      uuid not null,
    client_id       uuid,
    project_id      uuid,
    estimate_id     uuid,
    opportunity_id  uuid,
    assigned_pm_id  uuid,
    job_number      text not null default '',
    loss_reason     text,
    currency        text not null default 'USD',
    expiry_date     timestamptz not null default now() + interval '30 days',
    created_at      timestamptz not null default now()
);

create table if not exists public.invoices (
    id             uuid primary key default gen_random_uuid(),
    company_id     uuid not null,
    client_id      uuid,
    project_id     uuid,
    contract_id    uuid,
    opportunity_id uuid,
    quote_id       uuid,
    invoice_number text not null default '',
    invoice_type   text not null default 'standard',
    currency       text not null default 'USD',
    due_date       timestamptz not null default now() + interval '30 days',
    created_at     timestamptz not null default now()
);

create table if not exists public.change_orders (
    id             uuid primary key default gen_random_uuid(),
    company_id     uuid not null,
    project_id     uuid not null,
    contract_id    uuid,
    opportunity_id uuid,
    number         text not null default '',
    title          text not null default '',
    created_at     timestamptz not null default now()
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
    project_id  uuid,
    is_deleted  boolean not null default false,
    report_date date not null default current_date,
    created_at  timestamptz not null default now()
);

create table if not exists public.schedule_entries (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    project_id  uuid,
    crew_id     uuid,
    date        date not null default current_date,
    created_at  timestamptz not null default now()
);

create table if not exists public.timesheet_entries (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    employee_id uuid,
    project_id  uuid,
    is_deleted  boolean not null default false,
    work_date   date not null default current_date,
    created_at  timestamptz not null default now()
);

create table if not exists public.form_templates (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    is_deleted  boolean not null default false,
    name        text not null default '',
    created_at  timestamptz not null default now()
);

create table if not exists public.form_submissions (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    is_deleted  boolean not null default false,
    created_at  timestamptz not null default now()
);

create table if not exists public.equipment (
    id                  uuid primary key default gen_random_uuid(),
    company_id          uuid not null,
    assigned_project_id uuid,
    name                text not null default '',
    created_at          timestamptz not null default now()
);

create table if not exists public.exception_logs (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    created_at  timestamptz not null default now()
);

create table if not exists public.incidents (
    id            uuid primary key default gen_random_uuid(),
    company_id    uuid not null,
    is_deleted    boolean not null default false,
    title         text not null default '',
    incident_date timestamptz not null default now(),
    incident_time timestamptz not null default now(),
    created_at    timestamptz not null default now()
);

create table if not exists public.invites (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null,
    code        text not null default '',
    expires_at  timestamptz not null default now() + interval '7 days',
    created_at  timestamptz not null default now()
);

create table if not exists public.material_requests (
    id                       uuid primary key default gen_random_uuid(),
    company_id               uuid not null,
    project_id               uuid,
    supplier_id              uuid,
    material_sales_id        uuid,
    requested_by_employee_id uuid,
    opportunity_id           uuid,
    status                   text not null default 'draft',
    destination_type         text not null default 'internal',
    request_number           text not null default '',
    created_at               timestamptz not null default now()
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
    id                  uuid primary key default gen_random_uuid(),
    company_id          uuid not null,
    project_id          uuid,
    material_request_id uuid,
    opportunity_id      uuid,
    po_number           text not null default '',
    invoice_flagged     boolean not null default false,
    created_at          timestamptz not null default now()
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
    id                 uuid primary key default gen_random_uuid(),
    company_id         uuid not null,
    subcontractor_id   uuid not null,
    project_id         uuid not null,
    linked_contract_id uuid,
    contract_number    text not null default '',
    created_at         timestamptz not null default now()
);
