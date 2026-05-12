-- =========================================================
-- OPPORTUNITY WORK TYPE v1.1 — WT1a: align constraint to SaleType enum
-- =========================================================
-- STATUS: APPLIED to staging + prod 2026-05-12
-- Depends on: WT1_crm_opportunities_work_type_column.sql
--
-- The initial WT1 draft used 'material_sales' (plural) for the
-- material-sale enum value. During the Swift refactor we discovered
-- the pre-existing `SaleType` enum in MaterialSale.swift used the
-- singular 'material_sale' and already covered the same 5 cases
-- (project_work / service_work / material_sale / rental / direct_invoice).
--
-- Right call: unify on SaleType as the single source of truth instead
-- of carrying a duplicate enum. This migration aligns the DB CHECK
-- to match.
--
-- Safe to run: zero rows on prod or staging carried the old plural
-- value (verified via `select count(*) from crm_opportunities where
-- work_type = 'material_sales'` before this ran). All 62 existing
-- prod rows were 'project_work' from the WT1 backfill.

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
-- Verification (already passed)
-- =========================================================
-- select pg_get_constraintdef(oid) from pg_constraint
--   where conname = 'crm_opportunities_work_type_check';
-- -- Expected: CHECK (work_type = ANY (ARRAY['project_work',
-- --   'service_work', 'material_sale', 'rental', 'direct_invoice']))

-- =========================================================
-- Rollback (manual, would restore the old plural-value constraint)
-- =========================================================
-- alter table public.crm_opportunities
--     drop constraint if exists crm_opportunities_work_type_check;
-- alter table public.crm_opportunities
--     add constraint crm_opportunities_work_type_check check (
--         work_type in (
--             'project_work','service_work','material_sales',
--             'rental','direct_invoice'
--         )
--     );
