-- =========================================================
-- RFIs — partial unique index on per-project RFI numbers
-- Phase 3 / Module 4 of the Aski IQ stabilization plan.
-- =========================================================
-- Purpose:
--   Prevent two devices from pushing duplicate RFI numbers within the
--   same project. Same shape as Change Orders (CO1) — RFI numbers
--   reset per-project and use the project's job-number as a prefix.
--
-- Companion Swift change (this PR):
--   RFI.swift::nextRFINumber tightened to use parsed-max+1 over
--   (projectID, companyID), excluding soft-deleted.
--   pushPendingRFIs catch wired to SyncErrorMapper.

alter table public.rfis
    drop constraint if exists rfis_project_number_unique;
drop index if exists public.rfis_project_number_unique;

create unique index rfis_project_number_unique
    on public.rfis (project_id, number)
    where is_deleted = false;
