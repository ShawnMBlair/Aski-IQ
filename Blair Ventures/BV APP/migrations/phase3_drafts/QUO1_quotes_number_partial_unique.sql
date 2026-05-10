-- =========================================================
-- QUOTES — partial unique index on per-company quote numbers
-- Phase 3 / Module 2 of the Aski IQ stabilization plan.
-- =========================================================
-- Purpose:
--   Prevent two devices from pushing duplicate quote numbers when they
--   reconnect after offline work. Mirrors the procurement and invoice
--   patterns. The Swift side (`QuoteViews.swift::nextQuoteNumber`) already
--   used a parsed-max+1 form pre-Phase-3; this migration just adds the
--   DB-side guarantee.
--
-- Column note:
--   Quotes use `job_number` (text) as the human-readable quote number,
--   format "Q-YYYY-NNNN". Yes, it's confusingly named — `jobNumber` /
--   `job_number` is shared with estimates' job number convention. The
--   index goes on `job_number` regardless of the field name's history.
--
-- Why partial (`WHERE is_deleted = false`):
--   Soft-deleted quotes shouldn't permanently burn their number. Same
--   rationale as procurement and invoices — see commit 5e17387 for the
--   prod incident that prompted this pattern.
--
-- Idempotency:
--   - Drops any existing constraint variant first.
--   - Drops the index variant before recreating with the partial
--     predicate so re-applies always end up with the right shape.
--
-- Companion Swift change (this PR):
--   QuoteViews.swift::nextQuoteNumber tightened to filter by
--   companyID + !isDeleted (was previously filtering only on
--   createdAt year, missing soft-delete + multi-tenant scoping).
--   pushPendingQuotes catch wired to SyncErrorMapper for the Failed
--   Sync visibility surface.

alter table public.quotes
    drop constraint if exists quotes_company_job_number_unique;
drop index if exists public.quotes_company_job_number_unique;

create unique index quotes_company_job_number_unique
    on public.quotes (company_id, job_number)
    where is_deleted = false;
