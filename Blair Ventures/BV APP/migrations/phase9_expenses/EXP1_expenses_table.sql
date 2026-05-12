-- =========================================================
-- EXPENSES v1 — EXP1: expenses table
-- =========================================================
-- STATUS: APPLIED to staging (hlkdgnsrisrnbyebezvh) + prod (uiwjvkutaezyismkjwxj) 2026-05-12
-- Branch: claude/expenses-v1
-- Spec: project_expenses_v1_spec.md (locked 2026-05-11)
--
-- Release-group discipline: deploy EXP1 + EXP2 separately. EXP1
-- creates the parent table; EXP2 adds attachments and depends on
-- EXP1's PK. Each is independently rollbackable.
--
-- Tenant scope: company_id NOT NULL, FK to companies, RLS enforces
-- get_my_company_id() match. Pattern mirrors procurement.
--
-- Soft delete: standard (is_deleted / deleted_at / deleted_by).
-- All UNIQUE constraints are partial on is_deleted = false so a
-- soft-deleted expense_number doesn't block reuse — but the
-- iOS NumberGenerationService also won't reuse numbers (per the
-- 2026-05-10 monotonic fix in commit 7136299).
--
-- Three-destination CHECK: exactly one of (project_id,
-- material_request_id, company_destination_label) must be non-empty.
-- Same pattern as material_requests' single-destination CHECK.

-- =========================================================
-- 1. expenses
-- =========================================================
create table if not exists public.expenses (
    id                      uuid primary key default gen_random_uuid(),
    company_id              uuid not null references public.companies(id) on delete cascade,
    external_id             text,

    -- Identity
    expense_number          text not null,

    -- Core
    vendor                  text not null default '',
    expense_date            date not null default current_date,
    amount                  numeric(12,2) not null default 0,
    currency                text not null default 'CAD',
    memo                    text not null default '',
    category                text not null default 'other' check (
        category in (
            'meal','fuel','lodging','supplies','tools',
            'subcontractor','travel','equipment_rental',
            'parking','other'
        )
    ),
    payment_method          text not null default 'company_card' check (
        payment_method in (
            'company_card','personal_paid','company_cheque',
            'e_transfer','cash','other'
        )
    ),

    -- Cost destination
    destination             text not null default 'company' check (
        destination in ('company','project','material_request')
    ),
    project_id              uuid references public.projects(id) on delete set null,
    material_request_id     uuid references public.material_requests(id) on delete set null,
    company_destination_label text not null default '',

    -- Reimbursement
    is_reimbursable                 boolean not null default false,
    reimbursement_paid_at           timestamptz,
    reimbursement_paid_by           uuid references public.employees(id) on delete set null,
    reimbursement_payment_method    text check (
        reimbursement_payment_method in (
            'company_card','personal_paid','company_cheque',
            'e_transfer','cash','other'
        )
    ),

    -- Approval workflow
    approval_state          text not null default 'draft' check (
        approval_state in (
            'draft','pending_approval','auto_approved',
            'approved','rejected','paid'
        )
    ),
    approved_by             uuid references public.employees(id) on delete set null,
    approved_at             timestamptz,
    rejected_by             uuid references public.employees(id) on delete set null,
    rejected_at             timestamptz,
    rejection_reason        text not null default '',

    -- Submitted-on-behalf-of (4-field provenance per spec)
    created_by                  uuid references public.employees(id) on delete set null,
    submitted_by                uuid references public.employees(id) on delete set null,
    expense_owner_employee_id   uuid references public.employees(id) on delete set null,
    submitted_on_behalf_of      boolean not null default false,

    -- Duplicate hint
    possible_duplicate_of   uuid references public.expenses(id) on delete set null,

    -- Audit + soft delete
    created_at              timestamptz not null default now(),
    updated_at              timestamptz not null default now(),
    last_modified_by        text not null default '',
    last_modified_at        timestamptz not null default now(),
    sync_status             text not null default 'synced',
    is_deleted              boolean not null default false,
    deleted_at              timestamptz,
    deleted_by              text,

    -- Sample data (matches existing pattern)
    is_sample_data              boolean not null default false,
    sample_data_batch_id        uuid,
    sample_data_seed_version    text,
    sample_data_created_at      timestamptz,
    sample_data_created_by      uuid
);

-- Single-destination CHECK: exactly one of the three destination
-- targets must be populated. Same pattern as material_requests.
alter table public.expenses
    add constraint expenses_single_destination_check check (
        (destination = 'project'          and project_id is not null and material_request_id is null and company_destination_label = '') or
        (destination = 'material_request' and material_request_id is not null and project_id is null and company_destination_label = '') or
        (destination = 'company'          and project_id is null and material_request_id is null)
    );

-- Reimbursement-consistency CHECK: is_reimbursable true ⇒
-- payment_method = personal_paid; and vice versa.
alter table public.expenses
    add constraint expenses_reimbursement_consistency_check check (
        (is_reimbursable = (payment_method = 'personal_paid'))
    );

-- Self-approval CHECK at the DB level — belt-and-braces beyond the
-- iOS ExpenseApprovalService. Approver cannot be the submitter or
-- the expense owner. NULL approved_by skips the check (pre-approval).
alter table public.expenses
    add constraint expenses_no_self_approval_check check (
        approved_by is null
        or (approved_by <> submitted_by and approved_by <> expense_owner_employee_id)
    );

-- =========================================================
-- 2. Indexes
-- =========================================================

-- Per-company per-year unique expense_number on live rows.
drop index if exists public.expenses_company_number_unique;
create unique index expenses_company_number_unique
    on public.expenses (company_id, expense_number)
    where is_deleted = false;

-- Approval queue: fetch pending expenses for the company.
create index if not exists expenses_company_approval_state_idx
    on public.expenses (company_id, approval_state)
    where is_deleted = false;

-- Reimbursement queue: fetch approved-but-unpaid reimbursements.
create index if not exists expenses_company_reimbursement_idx
    on public.expenses (company_id, is_reimbursable, approval_state)
    where is_deleted = false
      and is_reimbursable = true
      and approval_state in ('approved');

-- Project / MR scoped lookup for the "Costs" tab on those screens.
create index if not exists expenses_project_idx
    on public.expenses (project_id, expense_date)
    where is_deleted = false and project_id is not null;

create index if not exists expenses_material_request_idx
    on public.expenses (material_request_id, expense_date)
    where is_deleted = false and material_request_id is not null;

-- Owner-scoped lookup for "My Expenses" view.
create index if not exists expenses_owner_idx
    on public.expenses (expense_owner_employee_id, expense_date desc)
    where is_deleted = false and expense_owner_employee_id is not null;

-- =========================================================
-- 3. RLS
-- =========================================================
alter table public.expenses enable row level security;

-- Per-tenant isolation. Same pattern as material_requests and PO.
drop policy if exists "expenses_company_select" on public.expenses;
create policy "expenses_company_select"
    on public.expenses for select
    using (company_id = public.get_my_company_id());

drop policy if exists "expenses_company_insert" on public.expenses;
create policy "expenses_company_insert"
    on public.expenses for insert
    with check (company_id = public.get_my_company_id());

drop policy if exists "expenses_company_update" on public.expenses;
create policy "expenses_company_update"
    on public.expenses for update
    using (company_id = public.get_my_company_id())
    with check (company_id = public.get_my_company_id());

drop policy if exists "expenses_company_delete" on public.expenses;
create policy "expenses_company_delete"
    on public.expenses for delete
    using (company_id = public.get_my_company_id());

-- =========================================================
-- 4. Entity-numbering counter seed
-- =========================================================
-- Adds EXP as a recognized prefix in entity_numbering_counters.
-- The iOS NumberGenerationService will call the counter via RPC;
-- existing counters table already supports new entity_type values.
-- No schema change to the counter table itself.

-- =========================================================
-- 5. Trigger: updated_at
-- =========================================================
drop trigger if exists set_expenses_updated_at on public.expenses;
create trigger set_expenses_updated_at
    before update on public.expenses
    for each row
    execute function public.set_updated_at();

-- =========================================================
-- Rollback (manual)
-- =========================================================
-- drop trigger if exists set_expenses_updated_at on public.expenses;
-- drop table if exists public.expenses cascade;
-- Note: cascading drop removes RLS policies + indexes automatically.
