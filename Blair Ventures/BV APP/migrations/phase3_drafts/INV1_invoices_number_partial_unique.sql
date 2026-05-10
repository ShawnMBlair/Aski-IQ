-- =========================================================
-- INVOICES — partial unique index on per-company invoice numbers
-- Phase 3 / Module 1 of the Aski IQ stabilization plan.
-- =========================================================
-- Purpose:
--   Prevent two devices that are offline at the same time from
--   pushing duplicate invoice numbers when they reconnect. Mirrors
--   the procurement pattern (material_requests + purchase_orders)
--   landed in SupabaseMigration_MaterialRequestWorkflow.sql section 18.
--
-- Why partial (`WHERE is_deleted = false`):
--   Soft-deleted rows shouldn't permanently burn their number. A
--   non-partial UNIQUE constraint would block a fresh-install client
--   whose local store has no visibility into prod's soft-deleted
--   invoices (the SyncEngine pull filters is_deleted=false, so the
--   local max+1 calculation can't see them).
--
-- Idempotency:
--   - Drops any existing constraint variant first (in case a previous
--     run installed it as a constraint instead of an index).
--   - Drops the index variant before recreating with the partial
--     predicate so re-applies always end up with the right shape.
--
-- Companion Swift change:
--   Invoice.swift `nextInvoiceNumber()` now uses parsed-max+1 scoped
--   to (company, year), excluding soft-deleted. Same pattern as the
--   procurement helpers.
--
-- Sync engine retry:
--   pushPendingInvoices catches PostgreSQL's 23505 unique_violation
--   via the existing catch path. SyncErrorMapper surfaces it to the
--   user as "This number is already in use. The sync engine will
--   retry with the next available number." Sync engine will need a
--   retry-with-bumped-number path (Phase 5 follow-up); for now the
--   row stays in syncStatus=.failed and the user can manually retry,
--   which re-evaluates nextInvoiceNumber() against the now-pulled
--   server data.

alter table public.invoices
    drop constraint if exists invoices_company_invoice_number_unique;
drop index if exists public.invoices_company_invoice_number_unique;

create unique index invoices_company_invoice_number_unique
    on public.invoices (company_id, invoice_number)
    where is_deleted = false;
