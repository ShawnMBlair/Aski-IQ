-- =========================================================
-- FOUNDATIONAL BASELINE v4 — v3 + 10 pre-history function stubs
-- Phase 2 of the Aski IQ stabilization plan.
-- =========================================================
-- Status 2026-05-10: TESTED ON BRANCH, NOT REGISTERED ON PROD.
--
-- v4 builds on v3 by adding CREATE OR REPLACE FUNCTION stubs for the
-- ~10 pre-history functions referenced by harden_function_grants and
-- the early function-related migrations:
--   - handle_new_user, stamp_company_id, set_updated_at,
--     set_quotes_updated_at, update_crm_opportunity_timestamp
--     (trigger functions — return NEW; some set updated_at)
--   - get_my_company_id, get_my_role (RLS helpers)
--   - is_field_role, is_manager_or_above (predicates)
--   - create_invite (RPC)
--
-- Bodies are no-op stubs. Later migrations CREATE OR REPLACE them
-- with real implementations.
--
-- Tested on branch `phase2-v4-verify` (now deleted): replay advanced
-- 18 historical migrations (vs v3's 7) — passing through all 5
-- function-related migrations and the soft-delete additions, before
-- failing at `cleanup_sample_data_for_aski_iq_tenant` on missing
-- pre-history column `updated_at` on projects/clients/crm_opportunities.
-- See `*_v5.sql` for the next iteration's fix.

-- (Tables identical to v3 — see v3 file for shape; only the function
-- stubs at the bottom are new in v4.)

-- ─────────────────────────────────────────────────────────────────
-- Foundational tables (same as v3)
-- ─────────────────────────────────────────────────────────────────
create table if not exists public.companies (
    id uuid primary key default gen_random_uuid(),
    name text not null default 'My Company',
    plan text not null default 'trial',
    created_at timestamptz not null default now()
);

-- ... (other 37 tables match v3 exactly; see v3 file for full text) ...

-- ─────────────────────────────────────────────────────────────────
-- Pre-history function stubs (NEW IN v4)
-- ─────────────────────────────────────────────────────────────────
create or replace function public.handle_new_user()
    returns trigger language plpgsql as $f$ begin return new; end; $f$;

create or replace function public.stamp_company_id()
    returns trigger language plpgsql as $f$ begin return new; end; $f$;

create or replace function public.set_updated_at()
    returns trigger language plpgsql as $f$ begin new.updated_at := now(); return new; end; $f$;

create or replace function public.set_quotes_updated_at()
    returns trigger language plpgsql as $f$ begin new.updated_at := now(); return new; end; $f$;

create or replace function public.update_crm_opportunity_timestamp()
    returns trigger language plpgsql as $f$ begin new.updated_at := now(); return new; end; $f$;

create or replace function public.get_my_company_id()
    returns uuid language sql stable as $f$ select null::uuid $f$;

create or replace function public.get_my_role()
    returns text language sql stable as $f$ select 'field_worker'::text $f$;

create or replace function public.is_field_role()
    returns boolean language sql stable as $f$ select false $f$;

create or replace function public.is_manager_or_above()
    returns boolean language sql stable as $f$ select false $f$;

create or replace function public.create_invite(p_role text)
    returns text language sql as $f$ select ''::text $f$;
