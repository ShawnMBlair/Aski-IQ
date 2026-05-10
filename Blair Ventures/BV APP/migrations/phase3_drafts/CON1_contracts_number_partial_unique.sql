-- =========================================================
-- CONTRACTS — partial unique index on per-company contract numbers
-- Phase 3 / Module 6 of the Aski IQ stabilization plan.
-- =========================================================
-- Purpose:
--   Mirror procurement / invoices / quotes pattern for top-level
--   contracts. Format is C-YYYY-NNN.
--
-- Note on nullability:
--   contracts.contract_number is nullable (some contracts are imported
--   without one). The unique index naturally ignores null values
--   (Postgres semantic), so multiple rows with NULL contract_number
--   coexist freely. Only non-null + non-deleted rows compete.
--
-- Companion Swift change (this PR):
--   ContractStore.swift::nextContractNumber tightened with companyID
--   + !isDeleted filters. pushPendingContracts catch wired to
--   SyncErrorMapper. Subcontractor.swift inline `contracts.count + 1`
--   default value replaced with a call to nextContractNumber().

alter table public.contracts
    drop constraint if exists contracts_company_contract_number_unique;
drop index if exists public.contracts_company_contract_number_unique;

create unique index contracts_company_contract_number_unique
    on public.contracts (company_id, contract_number)
    where is_deleted = false and contract_number is not null;
