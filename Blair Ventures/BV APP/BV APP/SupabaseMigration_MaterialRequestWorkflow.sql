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
