-- =========================================================
-- ENTERPRISE MATERIAL REQUEST WORKFLOW MIGRATION
-- Purpose:
-- Adds workflow settings, audit logging, line-item receiving,
-- approval limits, PDF tracking, and stronger MR structure.
-- =========================================================

-- =========================================================
-- 1. Optional enum types
-- =========================================================
do $$
begin
    if not exists (
        select 1 from pg_type where typname = 'material_request_destination_type'
    ) then
        create type material_request_destination_type as enum (
            'project',
            'material_sales',
            'internal'
        );
    end if;
end $$;

-- Status enum — values must match Swift's MaterialRequestStatus.rawValue
-- (Procurement.swift). The Swift enum is the established API and is what
-- the app pushes via the `status` column today. The DB-only values
-- (pending / rejected / closed) are kept for future-Phase routing flows
-- the app doesn't emit yet.
do $$
begin
    if not exists (
        select 1 from pg_type where typname = 'material_request_status'
    ) then
        create type material_request_status as enum (
            'draft',
            'submitted',
            'pending',     -- DB-only; future use
            'approved',
            'rejected',    -- DB-only; future use
            'ordered',
            'partial',
            'delivered',   -- ↔ Swift .delivered (NOT 'received'; align with rawValue)
            'closed',      -- DB-only; future use
            'cancelled'
        );
    end if;
    -- Idempotent: if the enum was previously created with 'received'
    -- (pre-fix) and not yet wired into a typed column, normalize.
    -- Wrapped in another guard because alter type ... add value if not
    -- exists is non-transactional and only runs on >= PG12.
    if exists (
        select 1 from pg_type t
        join pg_enum e on e.enumtypid = t.oid
        where t.typname = 'material_request_status'
        and e.enumlabel = 'received'
    ) and not exists (
        select 1 from pg_type t
        join pg_enum e on e.enumtypid = t.oid
        where t.typname = 'material_request_status'
        and e.enumlabel = 'delivered'
    ) then
        -- Add 'delivered' alongside the legacy 'received' so both are
        -- accepted; data backfill (received → delivered) belongs in a
        -- separate one-shot migration once any rows reference it.
        alter type material_request_status add value 'delivered';
    end if;
end $$;

-- =========================================================
-- 2. Workflow settings table
-- Stores approval limits by role
-- =========================================================
create table if not exists public.workflow_settings (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null references public.companies(id) on delete cascade,
    role_key text not null,
    approval_limit_amount numeric(12,2) not null default 0,
    can_self_approve boolean not null default false,
    can_create_material_request boolean not null default true,
    can_approve_material_request boolean not null default false,
    can_send_to_supplier boolean not null default false,
    can_receive_materials boolean not null default false,
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    created_by uuid null references auth.users(id),
    updated_by uuid null references auth.users(id),
    constraint workflow_settings_company_role_unique unique (company_id, role_key)
);

create index if not exists idx_workflow_settings_company_id
on public.workflow_settings(company_id);

create index if not exists idx_workflow_settings_role_key
on public.workflow_settings(role_key);

-- =========================================================
-- 3. Material request table updates
-- Assumes material_requests already exists
-- =========================================================
alter table public.material_requests
add column if not exists requested_by_employee_id uuid null references public.employees(id),
add column if not exists submitted_by_user_id uuid null references auth.users(id),
add column if not exists submitted_at timestamptz null,
add column if not exists approved_by_user_id uuid null references auth.users(id),
add column if not exists approved_at timestamptz null,
add column if not exists approval_note text null,
add column if not exists destination_type material_request_destination_type not null default 'internal',
add column if not exists project_id uuid null references public.projects(id),
add column if not exists material_sales_id uuid null,
add column if not exists supplier_id uuid null,
add column if not exists required_date date null,
add column if not exists delivery_location text null,
add column if not exists total_estimated_cost numeric(12,2) not null default 0,
add column if not exists status material_request_status not null default 'draft',
add column if not exists pdf_storage_path text null,
add column if not exists pdf_generated_at timestamptz null,
add column if not exists delivery_photo_url text null,
add column if not exists receipt_scan_path text null,
add column if not exists requested_by_email text null,
add column if not exists received_by_user_id uuid null references auth.users(id),
add column if not exists received_at timestamptz null,
add column if not exists ordered_at timestamptz null,
add column if not exists closed_at timestamptz null,
add column if not exists created_by uuid null references auth.users(id),
add column if not exists updated_by uuid null references auth.users(id),
add column if not exists created_at timestamptz not null default now(),
add column if not exists updated_at timestamptz not null default now();

create index if not exists idx_material_requests_requested_by_employee_id
on public.material_requests(requested_by_employee_id);

create index if not exists idx_material_requests_project_id
on public.material_requests(project_id);

create index if not exists idx_material_requests_material_sales_id
on public.material_requests(material_sales_id);

create index if not exists idx_material_requests_supplier_id
on public.material_requests(supplier_id);

create index if not exists idx_material_requests_status
on public.material_requests(status);

create index if not exists idx_material_requests_destination_type
on public.material_requests(destination_type);

-- Foreign key on material_sales_id — wrapped in a DO block so re-runs
-- don't error on the duplicate constraint. ON DELETE SET NULL because
-- a material sale being deleted shouldn't cascade-delete its sourcing
-- requests; the audit trail should remain pointing at the (now nil)
-- former destination.
do $$
begin
    if not exists (
        select 1 from pg_constraint
        where conname = 'material_requests_material_sales_id_fkey'
    ) then
        alter table public.material_requests
        add constraint material_requests_material_sales_id_fkey
        foreign key (material_sales_id)
        references public.material_sales(id)
        on delete set null;
    end if;
end $$;

-- =========================================================
-- 3a. Backfill destination_type for existing rows
-- =========================================================
-- The DEFAULT on destination_type is 'internal', which means legacy rows
-- (created before this migration) all get destination_type='internal'
-- when the column is added. Section 4's CHECK constraint then rejects
-- any such row that has project_id or material_sales_id set, blocking
-- the entire migration.
--
-- Backfill those rows BEFORE the constraint is added so the constraint
-- creation succeeds. Idempotent — re-running this on a fully-migrated
-- database is a no-op since the WHERE clauses won't match.
update public.material_requests
set destination_type = 'project'
where project_id is not null
  and destination_type = 'internal';

update public.material_requests
set destination_type = 'material_sales'
where material_sales_id is not null
  and destination_type = 'internal';

-- =========================================================
-- 4. Guardrail: only one destination should be selected
-- =========================================================
alter table public.material_requests
drop constraint if exists material_requests_single_destination_check;

alter table public.material_requests
add constraint material_requests_single_destination_check
check (
    (
        destination_type = 'project'
        and project_id is not null
        and material_sales_id is null
    )
    or
    (
        destination_type = 'material_sales'
        and material_sales_id is not null
        and project_id is null
    )
    or
    (
        destination_type = 'internal'
        and project_id is null
        and material_sales_id is null
    )
);

-- =========================================================
-- 4a. Purchase Orders — delivery proof photo + invoice match fields
-- =========================================================
-- delivery_photo_url mirrors material_requests.delivery_photo_url —
-- required by the PO receive flow's photo gate.
-- invoice_* columns power the Phase 3 invoice 3-way matching workflow:
-- supplier invoice number/date/amount + scan path are stamped on the
-- PO when an office-admin / manager runs the Invoice Match sheet.
alter table public.purchase_orders
add column if not exists delivery_photo_url text null,
add column if not exists invoice_number text null,
add column if not exists invoice_date date null,
add column if not exists invoice_amount numeric(14,2) null,
add column if not exists invoice_scan_path text null,
add column if not exists invoice_matched_at timestamptz null,
add column if not exists invoice_matched_by uuid null references auth.users(id),
add column if not exists invoice_match_note text null,
add column if not exists invoice_flagged boolean not null default false;

create index if not exists idx_purchase_orders_invoice_flagged
on public.purchase_orders(invoice_flagged)
where invoice_flagged = true;

-- =========================================================
-- 5. Material request items table
-- Tracks requested and received quantities
-- =========================================================
create table if not exists public.material_request_items (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null references public.companies(id) on delete cascade,
    material_request_id uuid not null references public.material_requests(id) on delete cascade,
    item_id uuid null,
    item_name text not null,
    item_description text null,
    unit text null,
    quantity_requested numeric(12,2) not null default 0,
    quantity_received numeric(12,2) not null default 0,
    unit_cost numeric(12,2) not null default 0,
    estimated_total numeric(12,2) generated always as (
        quantity_requested * unit_cost
    ) stored,
    supplier_id uuid null,
    notes text null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    created_by uuid null references auth.users(id),
    updated_by uuid null references auth.users(id),
    constraint material_request_items_qty_requested_check
        check (quantity_requested >= 0),
    constraint material_request_items_qty_received_check
        check (quantity_received >= 0)
);

create index if not exists idx_material_request_items_company_id
on public.material_request_items(company_id);

create index if not exists idx_material_request_items_material_request_id
on public.material_request_items(material_request_id);

create index if not exists idx_material_request_items_item_id
on public.material_request_items(item_id);

create index if not exists idx_material_request_items_supplier_id
on public.material_request_items(supplier_id);

-- =========================================================
-- 6. Material request audit table
-- =========================================================
create table if not exists public.material_request_audit (
    id uuid primary key default gen_random_uuid(),
    company_id uuid not null references public.companies(id) on delete cascade,
    material_request_id uuid not null references public.material_requests(id) on delete cascade,
    action text not null,
    performed_by uuid null references auth.users(id),
    performed_at timestamptz not null default now(),
    old_status text null,
    new_status text null,
    metadata jsonb not null default '{}'::jsonb
);

create index if not exists idx_material_request_audit_company_id
on public.material_request_audit(company_id);

create index if not exists idx_material_request_audit_material_request_id
on public.material_request_audit(material_request_id);

create index if not exists idx_material_request_audit_action
on public.material_request_audit(action);

create index if not exists idx_material_request_audit_performed_at
on public.material_request_audit(performed_at desc);

-- =========================================================
-- 7. Updated at trigger function
-- Reuse if already exists
-- =========================================================
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists trg_workflow_settings_updated_at on public.workflow_settings;
create trigger trg_workflow_settings_updated_at
before update on public.workflow_settings
for each row
execute function public.set_updated_at();

drop trigger if exists trg_material_requests_updated_at on public.material_requests;
create trigger trg_material_requests_updated_at
before update on public.material_requests
for each row
execute function public.set_updated_at();

drop trigger if exists trg_material_request_items_updated_at on public.material_request_items;
create trigger trg_material_request_items_updated_at
before update on public.material_request_items
for each row
execute function public.set_updated_at();

-- =========================================================
-- 8. Audit trigger for material request status changes
-- =========================================================
create or replace function public.log_material_request_status_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if tg_op = 'INSERT' then
        insert into public.material_request_audit (
            company_id,
            material_request_id,
            action,
            performed_by,
            old_status,
            new_status,
            metadata
        )
        values (
            new.company_id,
            new.id,
            'created',
            auth.uid(),
            null,
            new.status::text,
            jsonb_build_object(
                'destination_type', new.destination_type,
                'project_id', new.project_id,
                'material_sales_id', new.material_sales_id,
                'requested_by_employee_id', new.requested_by_employee_id
            )
        );
        return new;
    end if;

    if tg_op = 'UPDATE' and old.status is distinct from new.status then
        insert into public.material_request_audit (
            company_id,
            material_request_id,
            action,
            performed_by,
            old_status,
            new_status,
            metadata
        )
        values (
            new.company_id,
            new.id,
            'status_changed',
            auth.uid(),
            old.status::text,
            new.status::text,
            jsonb_build_object(
                'old_pdf_storage_path', old.pdf_storage_path,
                'new_pdf_storage_path', new.pdf_storage_path,
                'approved_by_user_id', new.approved_by_user_id,
                'received_by_user_id', new.received_by_user_id
            )
        );
    end if;

    return new;
end;
$$;

drop trigger if exists trg_material_request_audit_insert_update
on public.material_requests;

create trigger trg_material_request_audit_insert_update
after insert or update on public.material_requests
for each row
execute function public.log_material_request_status_change();

-- =========================================================
-- 9. Helper function: recalculate MR total from line items
-- =========================================================
-- IMPORTANT: when no child rows exist (typical Phase 1 state — Swift
-- still uses embedded line_items_json on the parent row), preserve the
-- value already on the parent rather than forcing it to 0. Otherwise
-- any UPDATE that touches a child-less request would silently zero out
-- the total the client just pushed.
-- Once the Swift sync starts populating material_request_items (Phase 3
-- invoice-matching prep), child rows become the source of truth and the
-- coalesce naturally falls through to the SUM.
create or replace function public.recalculate_material_request_total(
    p_material_request_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    update public.material_requests mr
    set total_estimated_cost = coalesce((
        select sum(mri.estimated_total)
        from public.material_request_items mri
        where mri.material_request_id = p_material_request_id
    ), mr.total_estimated_cost)
    where mr.id = p_material_request_id;
end;
$$;

-- =========================================================
-- 10. Trigger to update total when items change
-- =========================================================
create or replace function public.material_request_items_recalculate_total()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    target_request_id uuid;
begin
    target_request_id := coalesce(new.material_request_id, old.material_request_id);
    perform public.recalculate_material_request_total(target_request_id);
    return coalesce(new, old);
end;
$$;

drop trigger if exists trg_material_request_items_recalculate_total
on public.material_request_items;

create trigger trg_material_request_items_recalculate_total
after insert or update or delete on public.material_request_items
for each row
execute function public.material_request_items_recalculate_total();

-- =========================================================
-- 11. Enable RLS
-- =========================================================
alter table public.workflow_settings enable row level security;
alter table public.material_request_items enable row level security;
alter table public.material_request_audit enable row level security;

-- =========================================================
-- 12. RLS helper assumption
-- IMPORTANT:
-- This assumes user membership exists in a company_users or profiles table.
-- Adjust role lookup to match your actual app schema.
-- =========================================================
-- Example helper: current user's company
-- Modify if your app uses profiles.company_id or company_memberships.
create or replace function public.current_user_company_id()
returns uuid
language sql
security definer
set search_path = public
as $$
    select p.company_id
    from public.profiles p
    where p.id = auth.uid()
    limit 1;
$$;

create or replace function public.current_user_role_key()
returns text
language sql
security definer
set search_path = public
as $$
    select lower(p.role)
    from public.profiles p
    where p.id = auth.uid()
    limit 1;
$$;

create or replace function public.current_user_is_admin_or_pm()
returns boolean
language sql
security definer
set search_path = public
as $$
    select public.current_user_role_key() in (
        'admin',
        'executive',
        'manager',
        'pm',
        'project_manager'
    );
$$;

-- =========================================================
-- 13. RLS policies: workflow_settings
-- Admins can manage, users can read their company settings
-- =========================================================
drop policy if exists workflow_settings_select_company
on public.workflow_settings;
create policy workflow_settings_select_company
on public.workflow_settings
for select
to authenticated
using (
    company_id = public.current_user_company_id()
);

drop policy if exists workflow_settings_admin_manage
on public.workflow_settings;
create policy workflow_settings_admin_manage
on public.workflow_settings
for all
to authenticated
using (
    company_id = public.current_user_company_id()
    and public.current_user_role_key() = 'admin'
)
with check (
    company_id = public.current_user_company_id()
    and public.current_user_role_key() = 'admin'
);

-- =========================================================
-- 14. RLS policies: material_request_items
-- Users can access items for visible material requests
-- =========================================================
drop policy if exists material_request_items_select_company
on public.material_request_items;
create policy material_request_items_select_company
on public.material_request_items
for select
to authenticated
using (
    company_id = public.current_user_company_id()
);

drop policy if exists material_request_items_insert_company
on public.material_request_items;
create policy material_request_items_insert_company
on public.material_request_items
for insert
to authenticated
with check (
    company_id = public.current_user_company_id()
);

drop policy if exists material_request_items_update_company
on public.material_request_items;
create policy material_request_items_update_company
on public.material_request_items
for update
to authenticated
using (
    company_id = public.current_user_company_id()
)
with check (
    company_id = public.current_user_company_id()
);

drop policy if exists material_request_items_delete_admin_pm
on public.material_request_items;
create policy material_request_items_delete_admin_pm
on public.material_request_items
for delete
to authenticated
using (
    company_id = public.current_user_company_id()
    and public.current_user_is_admin_or_pm()
);

-- =========================================================
-- 15. RLS policies: material_request_audit
-- Everyone can read audit in company if authorized.
-- Inserts should mostly happen through triggers/functions.
-- =========================================================
drop policy if exists material_request_audit_select_company
on public.material_request_audit;
create policy material_request_audit_select_company
on public.material_request_audit
for select
to authenticated
using (
    company_id = public.current_user_company_id()
);

drop policy if exists material_request_audit_insert_company
on public.material_request_audit;
create policy material_request_audit_insert_company
on public.material_request_audit
for insert
to authenticated
with check (
    company_id = public.current_user_company_id()
);

-- =========================================================
-- 16. Seed default workflow settings
-- Adjust role names to match your actual profiles.role values
-- =========================================================
insert into public.workflow_settings (
    company_id,
    role_key,
    approval_limit_amount,
    can_self_approve,
    can_create_material_request,
    can_approve_material_request,
    can_send_to_supplier,
    can_receive_materials
)
select
    c.id,
    role_data.role_key,
    role_data.approval_limit_amount,
    role_data.can_self_approve,
    role_data.can_create_material_request,
    role_data.can_approve_material_request,
    role_data.can_send_to_supplier,
    role_data.can_receive_materials
from public.companies c
cross join (
    values
        -- role_key matches Swift's UserRole.rawValue (BaseModel.swift)
        ('field_worker',    0,         false, true,  false, false, true),
        ('foreman',         1000,      false, true,  true,  false, true),
        ('safety_advisor',  0,         false, false, false, false, false),
        ('project_manager', 10000,     false, true,  true,  true,  true),
        ('estimator',       0,         false, true,  false, false, false),
        ('office_admin',    2500,      false, true,  true,  true,  true),
        ('manager',         25000,     true,  true,  true,  true,  true),
        ('executive',       999999999, true,  true,  true,  true,  true),
        ('owner',           999999999, true,  true,  true,  true,  true),
        ('client',          0,         false, false, false, false, false)
) as role_data(
    role_key,
    approval_limit_amount,
    can_self_approve,
    can_create_material_request,
    can_approve_material_request,
    can_send_to_supplier,
    can_receive_materials
)
on conflict (company_id, role_key) do nothing;

-- =========================================================
-- 17. Hardening — surfaced by Supabase advisor on staging
-- =========================================================

-- Pin search_path on set_updated_at to match every other helper. The
-- broader project's pin_function_search_path migration deliberately
-- locks search_path on every SECURITY-sensitive function; this one
-- was missed when the trigger function was added in section 7.
alter function public.set_updated_at() set search_path = public;

-- Trigger-only functions should not be reachable via PostgREST.
-- They still need SECURITY DEFINER to bypass RLS on their target
-- tables (audit log, item totals), but no client role should call
-- them directly via /rest/v1/rpc/<name>. Postgres grants EXECUTE to
-- PUBLIC by default when CREATE FUNCTION runs, so revoking only from
-- `anon`/`authenticated` is a no-op (they inherit from PUBLIC).
-- Revoke from PUBLIC and explicitly from anon/authenticated as a
-- belt-and-suspenders defense.
revoke execute on function public.log_material_request_status_change()       from public;
revoke execute on function public.log_material_request_status_change()       from anon, authenticated;
revoke execute on function public.material_request_items_recalculate_total() from public;
revoke execute on function public.material_request_items_recalculate_total() from anon, authenticated;
revoke execute on function public.recalculate_material_request_total(uuid)   from public;
revoke execute on function public.recalculate_material_request_total(uuid)   from anon, authenticated;

-- The RLS helper functions (current_user_*) DO need to be callable
-- by signed-in users — RLS policies invoke them on every query —
-- but should not be reachable by `anon` (unauthenticated requests
-- have no business introspecting role helpers, even though they'd
-- return null without an auth.uid()).
--
-- Revoking only from anon doesn't work because Postgres grants
-- EXECUTE to PUBLIC on CREATE FUNCTION; anon inherits from PUBLIC.
-- Pattern: revoke from PUBLIC, grant explicitly to authenticated.
revoke execute on function public.current_user_company_id()     from public;
revoke execute on function public.current_user_company_id()     from anon;
grant  execute on function public.current_user_company_id()     to authenticated;
revoke execute on function public.current_user_role_key()       from public;
revoke execute on function public.current_user_role_key()       from anon;
grant  execute on function public.current_user_role_key()       to authenticated;
revoke execute on function public.current_user_is_admin_or_pm() from public;
revoke execute on function public.current_user_is_admin_or_pm() from anon;
grant  execute on function public.current_user_is_admin_or_pm() to authenticated;

-- =========================================================
-- 18. Number-collision defense — partial UNIQUE on live rows only
-- =========================================================
-- The Swift client picks request_number / po_number from a local
-- max+1 within (company, year). Two devices offline at the same max
-- both emit the same number; when they reconnect, both rows push and
-- the pipeline ends up with duplicates unless the DB rejects one.
--
-- IMPORTANT: must be a PARTIAL unique index (WHERE is_deleted = false),
-- NOT a table-level UNIQUE constraint. The non-partial form would block
-- a fresh client from re-using a number that was previously soft-deleted
-- — which is wrong: soft-deleted rows should not permanently burn their
-- number. The first cut of this section used a non-partial UNIQUE and
-- broke a live device whose local store was empty (no visibility into
-- soft-deleted prod rows) — see commit history for the partial-index
-- fix that landed this form.
--
-- Drop both the constraint variant (legacy) and the index variant before
-- re-creating, so the migration is idempotent regardless of which shape
-- a previous run installed.
alter table public.material_requests
    drop constraint if exists material_requests_company_request_number_unique;
drop index if exists public.material_requests_company_request_number_unique;
create unique index material_requests_company_request_number_unique
    on public.material_requests (company_id, request_number)
    where is_deleted = false;

alter table public.purchase_orders
    drop constraint if exists purchase_orders_company_po_number_unique;
drop index if exists public.purchase_orders_company_po_number_unique;
create unique index purchase_orders_company_po_number_unique
    on public.purchase_orders (company_id, po_number)
    where is_deleted = false;

-- =========================================================
-- 19. Auto-link opportunity — fallback for material_requests / purchase_orders
-- =========================================================
-- The auto_link_opportunity_for_commercial_record() trigger originally
-- only resolved opportunity_id from the linked project's opportunity_id.
-- When project_id was null OR the project had no opportunity_id, the
-- trigger gave up; the row insert then failed the NOT NULL on
-- opportunity_id. This blocked field-side procurement on devices whose
-- local store hadn't yet pulled the relevant project / opportunity.
--
-- Other commercial branches (estimates / quotes / invoices / material_sales /
-- contracts) already set v_client_id and feed an existing find/create-opp
-- fallback at the bottom of the function. The MR/PO branch did not.
-- This section replaces the function with three additive changes:
--
--   (1) MR branch: when the project's opportunity_id is null, derive
--       v_client_id from project.client_name → clients table → falls
--       through to the existing find/create-opp logic.
--   (2) PO branch: same as (1).
--   (3) NEW terminal fallback for MR/PO only: when v_client_id couldn't
--       be resolved (e.g. orphan internal MR), reuse any open
--       opportunity in the same company. Does NOT auto-create a
--       clientless synthetic opp because crm_opportunities.client_id
--       is NOT NULL — guessing a client would corrupt entity-first
--       semantics. If no open opp exists, the row insert still fails
--       NOT NULL on opportunity_id (correct behavior — operator must
--       create an opportunity first).
--
-- All other branches (estimates / quotes / material_sales / projects /
-- change_orders / invoices / contracts) preserved verbatim.
--
-- Implementation note: split the original IN ('purchase_orders',
-- 'material_requests') branch into two ELSIF arms because plpgsql
-- resolves NEW.<column> references at compile time per trigger context,
-- and the two tables have different "title" columns (request_number vs
-- po_number). A CASE WHEN over both fails compile-time validation.

CREATE OR REPLACE FUNCTION public.auto_link_opportunity_for_commercial_record()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_opp_id              uuid;
  v_client_id           uuid;
  v_company_id          uuid;
  v_title               text;
  v_source              text;
  v_action              text;
  v_project_client_name text;
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

  ELSIF TG_TABLE_NAME = 'material_requests' THEN
    v_company_id := NEW.company_id;
    v_title      := COALESCE(NEW.request_number, 'Material Request');
    IF NEW.project_id IS NOT NULL THEN
      SELECT opportunity_id INTO v_opp_id
      FROM public.projects
      WHERE id = NEW.project_id AND opportunity_id IS NOT NULL;
      IF v_opp_id IS NOT NULL THEN
        v_source := 'parent_project.opportunity_id';
      ELSE
        SELECT client_name INTO v_project_client_name
        FROM public.projects
        WHERE id = NEW.project_id;
        IF v_project_client_name IS NOT NULL AND v_company_id IS NOT NULL THEN
          SELECT id INTO v_client_id
          FROM public.clients
          WHERE company_id = v_company_id
            AND lower(name) = lower(btrim(v_project_client_name))
            AND NOT is_deleted
          ORDER BY updated_at DESC NULLS LAST
          LIMIT 1;
        END IF;
      END IF;
    END IF;

  ELSIF TG_TABLE_NAME = 'purchase_orders' THEN
    v_company_id := NEW.company_id;
    v_title      := COALESCE(NEW.po_number, 'Purchase Order');
    IF NEW.project_id IS NOT NULL THEN
      SELECT opportunity_id INTO v_opp_id
      FROM public.projects
      WHERE id = NEW.project_id AND opportunity_id IS NOT NULL;
      IF v_opp_id IS NOT NULL THEN
        v_source := 'parent_project.opportunity_id';
      ELSE
        SELECT client_name INTO v_project_client_name
        FROM public.projects
        WHERE id = NEW.project_id;
        IF v_project_client_name IS NOT NULL AND v_company_id IS NOT NULL THEN
          SELECT id INTO v_client_id
          FROM public.clients
          WHERE company_id = v_company_id
            AND lower(name) = lower(btrim(v_project_client_name))
            AND NOT is_deleted
          ORDER BY updated_at DESC NULLS LAST
          LIMIT 1;
        END IF;
      END IF;
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

  -- Find an open opp by client (existing).
  IF v_opp_id IS NULL AND v_client_id IS NOT NULL AND v_company_id IS NOT NULL THEN
    SELECT id INTO v_opp_id
    FROM public.crm_opportunities
    WHERE client_id = v_client_id
      AND company_id = v_company_id
      AND NOT is_deleted
      AND stage NOT IN ('Won', 'Lost')
    ORDER BY updated_at DESC NULLS LAST
    LIMIT 1;
    IF v_opp_id IS NOT NULL THEN v_source := 'open_opp_for_client'; END IF;
  END IF;

  -- Create a synthetic opp for the client (existing).
  IF v_opp_id IS NULL AND v_client_id IS NOT NULL AND v_company_id IS NOT NULL THEN
    INSERT INTO public.crm_opportunities (
      company_id, client_id, title, stage, source, probability, notes
    ) VALUES (
      v_company_id, v_client_id, v_title, 'New Lead', 'auto_link_trigger', 50,
      'Auto-created when ' || TG_TABLE_NAME || ' record was inserted without an opportunity link.'
    )
    RETURNING id INTO v_opp_id;
    v_source := 'no_existing_open_opp';
  END IF;

  -- (NEW) MR/PO terminal fallback — when client couldn't be resolved
  -- (orphan or unmatched project), reuse any open opp in the company.
  -- See header comment for rationale on why we don't auto-create a
  -- clientless synthetic opp here.
  IF v_opp_id IS NULL
     AND TG_TABLE_NAME IN ('purchase_orders','material_requests')
     AND v_company_id IS NOT NULL THEN
    SELECT id INTO v_opp_id
    FROM public.crm_opportunities
    WHERE company_id = v_company_id
      AND NOT is_deleted
      AND stage NOT IN ('Won', 'Lost')
    ORDER BY updated_at DESC NULLS LAST
    LIMIT 1;
    IF v_opp_id IS NOT NULL THEN
      v_source := 'open_opp_in_company_clientless_fallback';
    END IF;
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
