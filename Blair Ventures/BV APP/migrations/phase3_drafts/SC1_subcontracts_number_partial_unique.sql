-- =========================================================
-- SUB-CONTRACTS — partial unique index on per-company numbers
-- Phase 3 / Module 7 of the Aski IQ stabilization plan.
-- =========================================================
-- Purpose:
--   Same shape as Contracts (CON1). Sub-contracts have a NOT NULL
--   contract_number per the Swift model — no need for the
--   `contract_number IS NOT NULL` predicate that CON1 carries.
--
-- Companion Swift change (this PR):
--   Subcontractor.swift::nextSubContractNumber rewritten from
--   `count + 1` to parsed-max+1 over (companyID, year), excluding
--   soft-deleted. pushPendingSubContracts catch wired to
--   SyncErrorMapper.

alter table public.sub_contracts
    drop constraint if exists sub_contracts_company_contract_number_unique;
drop index if exists public.sub_contracts_company_contract_number_unique;

create unique index sub_contracts_company_contract_number_unique
    on public.sub_contracts (company_id, contract_number)
    where is_deleted = false;
