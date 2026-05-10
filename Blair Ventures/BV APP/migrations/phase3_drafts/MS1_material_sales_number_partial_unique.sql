-- =========================================================
-- MATERIAL SALES — partial unique index on per-company sale numbers
-- Phase 3 / Module 8 of the Aski IQ stabilization plan.
-- =========================================================
-- Purpose:
--   Final Phase 3 module. Mirrors invoices / quotes — top-level numbered
--   commercial document, format MS-YYYY-NNNN.
--
-- Companion Swift change (this PR):
--   CRMCommercialBridge.swift::nextSaleNumber tightened to filter by
--   companyID + !isDeleted and use saleNumber prefix-match for the
--   year filter. pushPendingMaterialSales catch wired to
--   SyncErrorMapper.

alter table public.material_sales
    drop constraint if exists material_sales_company_sale_number_unique;
drop index if exists public.material_sales_company_sale_number_unique;

create unique index material_sales_company_sale_number_unique
    on public.material_sales (company_id, sale_number)
    where is_deleted = false;
