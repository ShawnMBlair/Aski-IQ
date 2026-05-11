-- =========================================================
-- EXPENSES v1 — EXP2: expense_attachments table
-- =========================================================
-- STATUS: DRAFT — NOT APPLIED
-- Depends on: EXP1_expenses_table.sql (FK references public.expenses)
--
-- Receipt photos / PDFs attached to an expense row. v1 stores
-- binary inline (bytea) to match the existing CRM-attachment and
-- certificate-file pattern. If payload size becomes a problem we
-- migrate to Supabase Storage with a URL reference in a future
-- EXP3 migration.

create table if not exists public.expense_attachments (
    id              uuid primary key default gen_random_uuid(),
    company_id      uuid not null references public.companies(id) on delete cascade,
    expense_id      uuid not null references public.expenses(id) on delete cascade,
    external_id     text,

    -- File metadata
    file_name       text not null default '',
    file_type       text not null default 'image' check (
        file_type in ('image','pdf','other')
    ),
    file_size_bytes integer not null default 0,
    mime_type       text not null default '',

    -- Binary payload. Base64-encoded on the wire (PostgREST quirk);
    -- iOS decodes via the existing CRM-attachment sync pattern.
    file_data       bytea,
    thumbnail_data  bytea,

    -- Capture provenance
    source          text not null default 'camera' check (
        source in ('camera','library','file_picker','email','ocr_scan')
    ),
    is_primary_receipt boolean not null default true,

    -- Audit + soft delete
    created_at       timestamptz not null default now(),
    updated_at       timestamptz not null default now(),
    last_modified_by text not null default '',
    last_modified_at timestamptz not null default now(),
    sync_status      text not null default 'synced',
    is_deleted       boolean not null default false,
    deleted_at       timestamptz,
    deleted_by       text
);

-- Lookup by parent expense — every detail-view fetch is bounded by
-- expense_id. Live-only partial index keeps it small.
create index if not exists expense_attachments_expense_idx
    on public.expense_attachments (expense_id)
    where is_deleted = false;

-- =========================================================
-- RLS
-- =========================================================
alter table public.expense_attachments enable row level security;

drop policy if exists "expense_attachments_company_select" on public.expense_attachments;
create policy "expense_attachments_company_select"
    on public.expense_attachments for select
    using (company_id = public.get_my_company_id());

drop policy if exists "expense_attachments_company_insert" on public.expense_attachments;
create policy "expense_attachments_company_insert"
    on public.expense_attachments for insert
    with check (company_id = public.get_my_company_id());

drop policy if exists "expense_attachments_company_update" on public.expense_attachments;
create policy "expense_attachments_company_update"
    on public.expense_attachments for update
    using (company_id = public.get_my_company_id())
    with check (company_id = public.get_my_company_id());

drop policy if exists "expense_attachments_company_delete" on public.expense_attachments;
create policy "expense_attachments_company_delete"
    on public.expense_attachments for delete
    using (company_id = public.get_my_company_id());

-- =========================================================
-- Trigger: updated_at
-- =========================================================
drop trigger if exists set_expense_attachments_updated_at on public.expense_attachments;
create trigger set_expense_attachments_updated_at
    before update on public.expense_attachments
    for each row
    execute function public.set_updated_at();

-- =========================================================
-- Rollback (manual)
-- =========================================================
-- drop trigger if exists set_expense_attachments_updated_at on public.expense_attachments;
-- drop table if exists public.expense_attachments cascade;
