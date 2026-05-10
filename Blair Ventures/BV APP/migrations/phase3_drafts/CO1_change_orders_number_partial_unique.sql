-- =========================================================
-- CHANGE ORDERS — partial unique index on per-project CO numbers
-- Phase 3 / Module 3 of the Aski IQ stabilization plan.
-- =========================================================
-- Purpose:
--   Prevent two devices from pushing duplicate CO numbers within the
--   same project after offline work. Mirrors the procurement / invoice /
--   quotes pattern, but the uniqueness scope is (project_id, number)
--   instead of (company_id, number) because CO numbers reset per
--   project (they take the project's job number as a prefix).
--
-- Defense in depth — the company_id is also implied via the project's
-- own company_id, but we don't add company_id to the index because:
--   - Two projects in different companies could legitimately share a
--     project-prefix coincidence (unlikely but possible).
--   - Adding company_id to the predicate would require a join in any
--     future tooling that analyzes the index.
--   - project_id is already strictly unique across companies (RLS +
--     entity-first invariant).
--
-- Why partial (`WHERE is_deleted = false`):
--   Same rationale as procurement / invoices / quotes — soft-deleted
--   change orders shouldn't burn their number permanently.
--
-- Idempotency:
--   - Drops any existing constraint variant first.
--   - Drops the index variant before recreating with the partial
--     predicate so re-applies always end up with the right shape.
--
-- Companion Swift change (this PR):
--   ChangeOrder.swift::nextCONumber tightened to use parsed-max+1
--   scoped to (projectID, companyID), excluding soft-deleted.
--   pushPendingChangeOrders catch wired to SyncErrorMapper.

alter table public.change_orders
    drop constraint if exists change_orders_project_number_unique;
drop index if exists public.change_orders_project_number_unique;

create unique index change_orders_project_number_unique
    on public.change_orders (project_id, number)
    where is_deleted = false;
