-- =========================================================
-- SECURITY DEFINER project-wide lockdown
-- Phase 4 / Item 2 of the Aski IQ stabilization plan.
-- =========================================================
-- Purpose:
--   The procurement migration (commit 0a39db1) discovered a Supabase
--   default-privileges quirk: when CREATE FUNCTION runs in the public
--   schema, EXECUTE is granted to PUBLIC by default, AND additionally
--   to anon + authenticated by Supabase's project-default privileges.
--   `revoke from anon, authenticated` alone is a no-op because the
--   PUBLIC inheritance still applies. The pattern that actually works
--   is: `revoke from public` + (for trigger funcs) `revoke from anon,
--   authenticated` + (for auth-needed helpers) `grant to authenticated`.
--
--   The procurement migration applied this pattern to its 6 trigger
--   functions and RLS helpers. A project-wide audit on 2026-05-09
--   surfaced 30+ MORE functions with the same gap. This migration
--   closes them in three groups.
--
-- Categorization principles:
--   - Trigger functions  (only fired by trigger context):
--       anon=NO, authenticated=NO, service_role=YES
--   - Role-check helpers (called by RLS policies):
--       anon=NO, authenticated=YES, service_role=YES
--   - Admin / sensitive writes (config / financial / maintenance):
--       anon=NO, authenticated=YES (internal logic checks admin role)
--   - Intentional anon (token RPCs, signup flow):
--       no change — these are deliberately anon-callable
--
-- Idempotency: every revoke/grant is repeatable; safe to re-run.
--
-- Verification approach: after applying, run get_advisors and confirm
-- no procurement-introduced WARN remains beyond the documented design
-- intent (RLS helpers callable by authenticated).

-- =========================================================
-- GROUP A — Trigger-only functions
-- Should never be invoked via /rest/v1/rpc/<name>. Revoke from
-- both PUBLIC (kills the default-privileges path) and from anon /
-- authenticated explicitly (belt-and-suspenders).
-- =========================================================

revoke execute on function public.auto_link_opportunity_for_commercial_record() from public;
revoke execute on function public.auto_link_opportunity_for_commercial_record() from anon, authenticated;

revoke execute on function public.fn_block_client_hard_delete() from public;
revoke execute on function public.fn_block_client_hard_delete() from anon, authenticated;

revoke execute on function public.fn_create_company_email_settings() from public;
revoke execute on function public.fn_create_company_email_settings() from anon, authenticated;

revoke execute on function public.fn_create_company_settings() from public;
revoke execute on function public.fn_create_company_settings() from anon, authenticated;

revoke execute on function public.fn_sync_company_name() from public;
revoke execute on function public.fn_sync_company_name() from anon, authenticated;

-- =========================================================
-- GROUP B — Role-check helpers (callable by RLS policies)
-- Authenticated needs them to evaluate policies. Anon must not.
-- Pattern: revoke from PUBLIC, grant to authenticated.
-- =========================================================

revoke execute on function public._require_company_admin()                            from public;
grant  execute on function public._require_company_admin()                            to authenticated;

revoke execute on function public.can_decide_quote_approval(numeric, text, boolean)   from public;
grant  execute on function public.can_decide_quote_approval(numeric, text, boolean)   to authenticated;

revoke execute on function public.is_commercial_decision_admin()                      from public;
grant  execute on function public.is_commercial_decision_admin()                      to authenticated;

revoke execute on function public.is_estimating_admin()                               from public;
grant  execute on function public.is_estimating_admin()                               to authenticated;

revoke execute on function public.is_financial_admin()                                from public;
grant  execute on function public.is_financial_admin()                                to authenticated;

revoke execute on function public.is_foreman_or_above()                               from public;
grant  execute on function public.is_foreman_or_above()                               to authenticated;

revoke execute on function public.is_not_client()                                     from public;
grant  execute on function public.is_not_client()                                     to authenticated;

revoke execute on function public.is_quote_approval_admin()                           from public;
grant  execute on function public.is_quote_approval_admin()                           to authenticated;

revoke execute on function public.is_safety_admin()                                   from public;
grant  execute on function public.is_safety_admin()                                   to authenticated;

revoke execute on function public.get_my_company_ai_prompts()                         from public;
grant  execute on function public.get_my_company_ai_prompts()                         to authenticated;

revoke execute on function public.get_my_qbo_entity_ids(text)                         from public;
grant  execute on function public.get_my_qbo_entity_ids(text)                         to authenticated;

revoke execute on function public.get_my_qbo_status()                                 from public;
grant  execute on function public.get_my_qbo_status()                                 to authenticated;

-- =========================================================
-- GROUP C — Admin / sensitive write operations
-- Authenticated callers need access (internal logic checks role).
-- Anon must not be able to invoke any of these. Pattern: revoke
-- from PUBLIC, grant to authenticated.
-- =========================================================

revoke execute on function public.clear_sample_data(uuid, uuid, text)                 from public;
grant  execute on function public.clear_sample_data(uuid, uuid, text)                 to authenticated;

revoke execute on function public.ensure_company_email_settings(uuid)                 from public;
grant  execute on function public.ensure_company_email_settings(uuid)                 to authenticated;

revoke execute on function public.ensure_company_settings(uuid)                       from public;
grant  execute on function public.ensure_company_settings(uuid)                       to authenticated;

revoke execute on function public.get_company_ai_key_status()                         from public;
grant  execute on function public.get_company_ai_key_status()                         to authenticated;

revoke execute on function public.get_company_ai_limits()                             from public;
grant  execute on function public.get_company_ai_limits()                             to authenticated;

revoke execute on function public.set_company_ai_key(text)                            from public;
grant  execute on function public.set_company_ai_key(text)                            to authenticated;

revoke execute on function public.set_company_ai_limits(bigint, bigint, bigint, bigint, boolean, boolean) from public;
grant  execute on function public.set_company_ai_limits(bigint, bigint, bigint, bigint, boolean, boolean) to authenticated;

revoke execute on function public.set_company_ai_prompt(text, text)                   from public;
grant  execute on function public.set_company_ai_prompt(text, text)                   to authenticated;

revoke execute on function public.set_user_ai_limits(uuid, integer, bigint, timestamptz, text) from public;
grant  execute on function public.set_user_ai_limits(uuid, integer, bigint, timestamptz, text) to authenticated;

revoke execute on function public.purge_old_workflow_log(integer)                     from public;
grant  execute on function public.purge_old_workflow_log(integer)                     to authenticated;

revoke execute on function public.next_job_number(uuid)                               from public;
grant  execute on function public.next_job_number(uuid)                               to authenticated;

-- Token-mint / revoke functions: must be auth-only — no anonymous
-- session should be able to mint signing tokens. The acceptance flows
-- (anon-callable accept_*_via_token) are unaffected.
revoke execute on function public.mint_contract_acceptance_token(uuid, integer)       from public;
grant  execute on function public.mint_contract_acceptance_token(uuid, integer)       to authenticated;

revoke execute on function public.mint_lien_waiver_token(uuid, integer)               from public;
grant  execute on function public.mint_lien_waiver_token(uuid, integer)               to authenticated;

revoke execute on function public.mint_material_sale_acceptance_token(uuid, integer)  from public;
grant  execute on function public.mint_material_sale_acceptance_token(uuid, integer)  to authenticated;

revoke execute on function public.mint_purchase_order_acceptance_token(uuid, integer) from public;
grant  execute on function public.mint_purchase_order_acceptance_token(uuid, integer) to authenticated;

revoke execute on function public.mint_quote_acceptance_token(uuid, integer)          from public;
grant  execute on function public.mint_quote_acceptance_token(uuid, integer)          to authenticated;

revoke execute on function public.revoke_contract_acceptance_token(uuid)              from public;
grant  execute on function public.revoke_contract_acceptance_token(uuid)              to authenticated;

revoke execute on function public.revoke_lien_waiver_token(uuid)                      from public;
grant  execute on function public.revoke_lien_waiver_token(uuid)                      to authenticated;

revoke execute on function public.revoke_material_sale_acceptance_token(uuid)         from public;
grant  execute on function public.revoke_material_sale_acceptance_token(uuid)         to authenticated;

revoke execute on function public.revoke_purchase_order_acceptance_token(uuid)        from public;
grant  execute on function public.revoke_purchase_order_acceptance_token(uuid)        to authenticated;

revoke execute on function public.revoke_quote_acceptance_token(uuid)                 from public;
grant  execute on function public.revoke_quote_acceptance_token(uuid)                 to authenticated;

revoke execute on function public.record_invoice_stripe_payment(uuid, text, numeric, text) from public;
grant  execute on function public.record_invoice_stripe_payment(uuid, text, numeric, text) to authenticated;

-- =========================================================
-- INTENTIONAL ANON ACCESS — DO NOT TOUCH
-- =========================================================
-- The following are deliberately callable by anon and stay as-is:
--
--   - accept_material_sale_via_token
--   - accept_purchase_order_via_token
--     (Acceptance flows — customer / supplier doesn't have a login;
--      the signed token IS the auth.)
--
--   - lookup_material_sale_by_token
--   - lookup_purchase_order_by_token
--     (Customer / supplier portal needs to read by token before
--      acceptance.)
--
--   - get_contract_acceptance_status
--   - get_lien_waiver_sign_status
--   - get_material_sale_acceptance_signed_details
--   - get_material_sale_acceptance_status
--   - get_purchase_order_acceptance_signed_details
--   - get_purchase_order_acceptance_status
--   - get_quote_acceptance_signed_details
--   - get_quote_acceptance_status
--     (Customer-facing portals query these; they're meant to be
--      anon-readable for the acceptance flow UX.)
--
--   - use_invite
--   - setup_new_user
--     (Signup flow — user doesn't have an account yet.)
--
-- (The accept_/lookup_ functions for contract/lien_waiver/quote already
-- have anon=NO — those were locked down in earlier hardening. We're
-- not toggling them back on.)
