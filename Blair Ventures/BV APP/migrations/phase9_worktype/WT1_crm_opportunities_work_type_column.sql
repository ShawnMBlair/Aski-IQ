-- =========================================================
-- OPPORTUNITY WORK TYPE v1.1 — WT1: work_type column
-- =========================================================
-- STATUS: APPLIED to staging + prod 2026-05-12 (this is the canonical
-- form after WT1a aligned 'material_sales' → 'material_sale' to match
-- the existing SaleType enum convention).
-- Branch: claude/opportunity-worktype-v1 (off v1.0.0 at 9a86696)
-- Spec:   project_opportunity_worktype_v1_1.md (locked Path A 2026-05-12)
--
-- Adds `work_type` to crm_opportunities. Distinct from the existing
-- free-text `service_type` (trade category like "Insulation",
-- "Scaffolding"); this column classifies how the opportunity
-- monetizes / which downstream module it routes through.
--
-- Five locked values:
--   project_work    → Estimate → Quote → Project → Progress Invoices
--   service_work    → Work Order / Service flow → Invoice (v1.1: falls back to project flow)
--   material_sales  → MaterialSale → Quote/Order/Invoice
--   rental          → Rental record → Return Tracking → Invoice (v1.1: falls back to project flow)
--   direct_invoice  → Invoice (skip estimate + quote)
--
-- Release-group discipline: this is a standalone group (WT1). No
-- downstream migrations needed for v1.1 — service-work / rental
-- module schemas are deferred to v1.2.
--
-- Backfill stance: every existing opportunity defaults to
-- 'project_work'. Safe assumption — pre-feature opportunities
-- almost all followed the estimate-quote-project path. Edge cases
-- (a closed-out opp that was actually a direct invoice) can be
-- corrected manually in the UI post-deploy.

-- =========================================================
-- 1. Column + CHECK constraint
-- =========================================================
alter table public.crm_opportunities
    add column if not exists work_type text not null default 'project_work';

alter table public.crm_opportunities
    drop constraint if exists crm_opportunities_work_type_check;

alter table public.crm_opportunities
    add constraint crm_opportunities_work_type_check check (
        work_type in (
            'project_work',
            'service_work',
            'material_sale',
            'rental',
            'direct_invoice'
        )
    );

-- =========================================================
-- 2. Filter index — pipeline + reports
-- =========================================================
create index if not exists crm_opportunities_company_work_type_idx
    on public.crm_opportunities (company_id, work_type)
    where is_deleted = false;

-- =========================================================
-- 3. Backfill — defensive
-- =========================================================
-- The DEFAULT clause backfills new column for existing rows on the
-- alter. This UPDATE is belt-and-braces: catches any pre-existing
-- rows that somehow had work_type as NULL (shouldn't happen given
-- the NOT NULL DEFAULT, but harmless to run).
update public.crm_opportunities
    set work_type = 'project_work'
    where work_type is null
       or work_type not in (
           'project_work','service_work','material_sale',
           'rental','direct_invoice'
       );

-- =========================================================
-- 4. RLS — no changes
-- =========================================================
-- work_type lives on crm_opportunities which is already RLS-scoped
-- by company_id. No new policies needed. Existing get_my_company_id()
-- tenant gate covers reads/writes of the new column for free.

-- =========================================================
-- Verification queries (run after apply on staging)
-- =========================================================
-- select column_name, data_type, is_nullable, column_default
--   from information_schema.columns
--   where table_schema = 'public'
--     and table_name = 'crm_opportunities'
--     and column_name = 'work_type';
-- -- Expected: work_type | text | NO | 'project_work'::text
--
-- select count(*) from pg_constraint
--   where conname = 'crm_opportunities_work_type_check';
-- -- Expected: 1
--
-- select count(*) from pg_indexes
--   where indexname = 'crm_opportunities_company_work_type_idx';
-- -- Expected: 1
--
-- select work_type, count(*)
--   from public.crm_opportunities
--   where is_deleted = false
--   group by work_type;
-- -- Expected: all existing rows show work_type = 'project_work'

-- =========================================================
-- Rollback (manual)
-- =========================================================
-- drop index if exists public.crm_opportunities_company_work_type_idx;
-- alter table public.crm_opportunities
--     drop constraint if exists crm_opportunities_work_type_check;
-- alter table public.crm_opportunities
--     drop column if exists work_type;
