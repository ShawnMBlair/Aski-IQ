-- =========================================================
-- SEC3 — Explicit anon revoke for SEC1 Group B+C functions
-- Phase 4 / follow-up after applying SEC1 to prod and seeing
-- the advisor still flag 34 anon-callable functions.
-- =========================================================
-- Why this is needed:
--   SEC1's pattern for Groups B+C was `revoke from public; grant to
--   authenticated`. That works for the PUBLIC inheritance path, but
--   Supabase's project-default privileges grant EXECUTE directly to
--   anon (not just via PUBLIC) — so the explicit anon grant survived
--   the `revoke from public` and the advisor still reports the
--   functions as anon-callable.
--
--   The fix is the same shape as SEC1's Group A trigger pattern:
--   explicitly `revoke from anon` in addition to `revoke from public`.
--   Group A already did this (belt-and-suspenders), so the trigger
--   functions are clean. Groups B+C missed it.
--
--   Caught by `get_advisors security` after SEC1+SEC2 prod-apply on
--   2026-05-10 — same kind of late-stage validation that caught the
--   procurement migration's default-privileges issue back in commit
--   0a39db1.
--
-- Idempotency: revoke is repeatable. authenticated grants from SEC1
-- are unaffected (we're not touching those).
--
-- Intentionally NOT touched (still anon-callable by design):
--   - accept_material_sale_via_token
--   - accept_purchase_order_via_token
--   - lookup_material_sale_by_token
--   - lookup_purchase_order_by_token
--   - get_contract_acceptance_status
--   - get_lien_waiver_sign_status
--   - get_material_sale_acceptance_signed_details
--   - get_material_sale_acceptance_status
--   - get_purchase_order_acceptance_signed_details
--   - get_purchase_order_acceptance_status
--   - get_quote_acceptance_signed_details
--   - get_quote_acceptance_status
--   - use_invite
--   - setup_new_user

-- GROUP B — Role-check helpers
revoke execute on function public._require_company_admin()                            from anon;
revoke execute on function public.can_decide_quote_approval(numeric, text, boolean)   from anon;
revoke execute on function public.is_commercial_decision_admin()                      from anon;
revoke execute on function public.is_estimating_admin()                               from anon;
revoke execute on function public.is_financial_admin()                                from anon;
revoke execute on function public.is_foreman_or_above()                               from anon;
revoke execute on function public.is_not_client()                                     from anon;
revoke execute on function public.is_quote_approval_admin()                           from anon;
revoke execute on function public.is_safety_admin()                                   from anon;
revoke execute on function public.get_my_company_ai_prompts()                         from anon;
revoke execute on function public.get_my_qbo_entity_ids(text)                         from anon;
revoke execute on function public.get_my_qbo_status()                                 from anon;

-- GROUP C — Admin / sensitive write operations
revoke execute on function public.clear_sample_data(uuid, uuid, text)                 from anon;
revoke execute on function public.ensure_company_email_settings(uuid)                 from anon;
revoke execute on function public.ensure_company_settings(uuid)                       from anon;
revoke execute on function public.get_company_ai_key_status()                         from anon;
revoke execute on function public.get_company_ai_limits()                             from anon;
revoke execute on function public.set_company_ai_key(text)                            from anon;
revoke execute on function public.set_company_ai_limits(bigint, bigint, bigint, bigint, boolean, boolean) from anon;
revoke execute on function public.set_company_ai_prompt(text, text)                   from anon;
revoke execute on function public.set_user_ai_limits(uuid, integer, bigint, timestamptz, text) from anon;
revoke execute on function public.purge_old_workflow_log(integer)                     from anon;
revoke execute on function public.next_job_number(uuid)                               from anon;
revoke execute on function public.mint_contract_acceptance_token(uuid, integer)       from anon;
revoke execute on function public.mint_lien_waiver_token(uuid, integer)               from anon;
revoke execute on function public.mint_material_sale_acceptance_token(uuid, integer)  from anon;
revoke execute on function public.mint_purchase_order_acceptance_token(uuid, integer) from anon;
revoke execute on function public.mint_quote_acceptance_token(uuid, integer)          from anon;
revoke execute on function public.revoke_contract_acceptance_token(uuid)              from anon;
revoke execute on function public.revoke_lien_waiver_token(uuid)                      from anon;
revoke execute on function public.revoke_material_sale_acceptance_token(uuid)         from anon;
revoke execute on function public.revoke_purchase_order_acceptance_token(uuid)        from anon;
revoke execute on function public.revoke_quote_acceptance_token(uuid)                 from anon;
revoke execute on function public.record_invoice_stripe_payment(uuid, text, numeric, text) from anon;
