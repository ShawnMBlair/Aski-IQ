-- ─────────────────────────────────────────────────────────────────────
-- Aski IQ — Supabase RPC snapshot, 2026-05-04
--
-- This file is a version-controlled mirror of every magic-link /
-- acceptance-token / job-number RPC currently deployed in the
-- production Supabase database (project uiwjvkutaezyismkjwxj).
--
-- WHY THIS FILE EXISTS
--   We discovered three latent bugs in `accept_quote_via_token` over a
--   single session because the function only existed in the Supabase
--   dashboard — there was no version-controlled source of truth. This
--   snapshot closes that gap for the high-risk RPCs (the ones bugs in
--   are most likely to ship straight to production).
--
-- WHAT'S COVERED
--   • Quote magic-link mint/revoke/accept/lookup/status/signed-details
--   • Contract magic-link mint/revoke/accept/lookup/status
--   • Lien waiver magic-link mint/revoke/accept/lookup/status
--   • next_job_number — used by every job-numbering call site
--
-- WHAT'S NOT COVERED (yet)
--   • The 30+ trigger functions (`fn_*_lock_sample_marker`, `set_*_at`)
--     — they're auto-generated guards, low risk, dump in a follow-up
--   • AI utilities (`set_company_ai_*`, `get_company_ai_*`, `record_ai_usage`)
--   • User onboarding (`handle_new_user`, `setup_new_user`, `use_invite`)
--   • Sample-data utilities (`clear_sample_data`)
--   • QBO integration (`get_my_qbo_*`, `record_invoice_stripe_payment`)
--
-- HOW TO USE
--   • If a bug is reported in any of these RPCs, fix it HERE FIRST,
--     then `apply_migration` to deploy. That keeps git as the source
--     of truth.
--   • To re-snapshot: SELECT pg_get_functiondef(oid) FROM pg_proc
--     WHERE proname IN (...) — replace the contents of this file.
--
-- Already version-controlled separately (DO NOT duplicate here):
--   • accept_quote_via_token            → SupabaseMigration_QuoteAcceptance_Fix.sql
--   • get_quote_acceptance_signed_details → SupabaseMigration_QuoteAcceptance_SignedDetails.sql
--   • get_quote_acceptance_status       → snapshot below
-- ─────────────────────────────────────────────────────────────────────


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- QUOTE ACCEPTANCE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

CREATE OR REPLACE FUNCTION public.mint_quote_acceptance_token(p_quote_id uuid, p_validity_days integer DEFAULT 30)
 RETURNS TABLE(token text, expires_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_admin       record;
  v_quote_row   record;
  v_token       text;
  v_expires_at  timestamptz;
BEGIN
  SELECT * INTO v_admin FROM public._require_company_admin();

  SELECT id, company_id INTO v_quote_row
  FROM public.quotes
  WHERE id = p_quote_id AND is_deleted = false;
  IF v_quote_row.id IS NULL THEN
    RAISE EXCEPTION 'Quote not found' USING ERRCODE = '42501';
  END IF;
  IF v_quote_row.company_id <> v_admin.company_id THEN
    RAISE EXCEPTION 'Quote does not belong to your company' USING ERRCODE = '42501';
  END IF;

  UPDATE public.quote_acceptance_tokens
     SET revoked_at = now(),
         revoked_by = v_admin.user_id
   WHERE quote_id = p_quote_id
     AND revoked_at IS NULL
     AND accepted_at IS NULL;

  v_token := translate(
    encode(extensions.gen_random_bytes(24), 'base64'),
    '+/=', '-_'
  );
  v_expires_at := now() + make_interval(days => p_validity_days);

  INSERT INTO public.quote_acceptance_tokens(
    quote_id, company_id, token, expires_at, created_by
  ) VALUES (
    p_quote_id, v_admin.company_id, v_token, v_expires_at, v_admin.user_id
  );

  RETURN QUERY SELECT v_token, v_expires_at;
END $function$;


CREATE OR REPLACE FUNCTION public.revoke_quote_acceptance_token(p_quote_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_admin record;
BEGIN
  SELECT * INTO v_admin FROM public._require_company_admin();
  UPDATE public.quote_acceptance_tokens
     SET revoked_at = now(),
         revoked_by = v_admin.user_id
   WHERE quote_id = p_quote_id
     AND company_id = v_admin.company_id
     AND revoked_at IS NULL
     AND accepted_at IS NULL;
END $function$;


CREATE OR REPLACE FUNCTION public.lookup_quote_by_token(p_token text)
 RETURNS TABLE(quote_id uuid, company_id uuid, company_name text, quote_number text, client_name text, scope_summary text, subtotal numeric, expires_at timestamp with time zone, accepted_at timestamp with time zone, revoked_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  SELECT
    q.id,
    t.company_id,
    c.name,
    q.job_number,
    q.client_name,
    q.scope_summary,
    coalesce(q.subtotal, 0)::numeric,
    t.expires_at,
    t.accepted_at,
    t.revoked_at
  FROM public.quote_acceptance_tokens t
  JOIN public.quotes q     ON q.id = t.quote_id
  JOIN public.companies c  ON c.id = t.company_id
  WHERE t.token = p_token
  LIMIT 1;
END $function$;


CREATE OR REPLACE FUNCTION public.get_quote_acceptance_status(p_quote_id uuid)
 RETURNS TABLE(has_token boolean, expires_at timestamp with time zone, accepted_at timestamp with time zone, accepted_by_name text, accepted_by_email text, revoked_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id    uuid := auth.uid();
  v_company_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT company_id INTO v_company_id FROM public.profiles WHERE id = v_user_id;

  RETURN QUERY
  SELECT
    true,
    t.expires_at,
    t.accepted_at,
    t.accepted_by_name,
    t.accepted_by_email,
    t.revoked_at
  FROM public.quote_acceptance_tokens t
  JOIN public.quotes q ON q.id = t.quote_id
  WHERE t.quote_id = p_quote_id
    AND q.company_id = v_company_id
  ORDER BY t.created_at DESC
  LIMIT 1;
END $function$;


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- CONTRACT ACCEPTANCE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

CREATE OR REPLACE FUNCTION public.mint_contract_acceptance_token(p_contract_id uuid, p_validity_days integer DEFAULT 30)
 RETURNS TABLE(token text, expires_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_admin       record;
  v_contract    record;
  v_token       text;
  v_expires_at  timestamptz;
BEGIN
  SELECT * INTO v_admin FROM public._require_company_admin();

  SELECT id, company_id INTO v_contract
  FROM public.contracts
  WHERE id = p_contract_id AND is_deleted = false;
  IF v_contract.id IS NULL THEN
    RAISE EXCEPTION 'Contract not found' USING ERRCODE = '42501';
  END IF;
  IF v_contract.company_id <> v_admin.company_id THEN
    RAISE EXCEPTION 'Contract does not belong to your company' USING ERRCODE = '42501';
  END IF;

  UPDATE public.contract_acceptance_tokens
     SET revoked_at = now(),
         revoked_by = v_admin.user_id
   WHERE contract_id = p_contract_id
     AND revoked_at IS NULL
     AND accepted_at IS NULL;

  v_token := translate(
    encode(extensions.gen_random_bytes(24), 'base64'),
    '+/=', '-_'
  );
  v_expires_at := now() + make_interval(days => p_validity_days);

  INSERT INTO public.contract_acceptance_tokens(
    contract_id, company_id, token, expires_at, created_by
  ) VALUES (
    p_contract_id, v_admin.company_id, v_token, v_expires_at, v_admin.user_id
  );

  RETURN QUERY SELECT v_token, v_expires_at;
END $function$;


CREATE OR REPLACE FUNCTION public.revoke_contract_acceptance_token(p_contract_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_admin record;
BEGIN
  SELECT * INTO v_admin FROM public._require_company_admin();
  UPDATE public.contract_acceptance_tokens
     SET revoked_at = now(),
         revoked_by = v_admin.user_id
   WHERE contract_id = p_contract_id
     AND company_id = v_admin.company_id
     AND revoked_at IS NULL
     AND accepted_at IS NULL;
END $function$;


CREATE OR REPLACE FUNCTION public.accept_contract_via_token(p_token text, p_acceptor_name text, p_acceptor_email text, p_acceptor_ip inet, p_acceptor_user_agent text, p_signature_data_url text)
 RETURNS TABLE(contract_id uuid, company_id uuid, contract_number text, contract_title text, counterparty text, ok boolean, reason text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_token_row record;
  v_contract  record;
BEGIN
  SELECT * INTO v_token_row
  FROM public.contract_acceptance_tokens
  WHERE token = p_token
  LIMIT 1;

  IF v_token_row.id IS NULL THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, NULL::text, NULL::text, NULL::text, false, 'Invalid token';
    RETURN;
  END IF;
  IF v_token_row.revoked_at IS NOT NULL THEN
    RETURN QUERY SELECT v_token_row.contract_id, v_token_row.company_id, NULL::text, NULL::text, NULL::text, false, 'Token has been revoked';
    RETURN;
  END IF;
  IF v_token_row.accepted_at IS NOT NULL THEN
    RETURN QUERY SELECT v_token_row.contract_id, v_token_row.company_id, NULL::text, NULL::text, NULL::text, false, 'Contract was already signed';
    RETURN;
  END IF;
  IF v_token_row.expires_at < now() THEN
    RETURN QUERY SELECT v_token_row.contract_id, v_token_row.company_id, NULL::text, NULL::text, NULL::text, false, 'Token has expired';
    RETURN;
  END IF;

  UPDATE public.contract_acceptance_tokens
     SET accepted_at         = now(),
         accepted_by_name    = btrim(coalesce(p_acceptor_name, '')),
         accepted_by_email   = btrim(coalesce(p_acceptor_email, '')),
         accepted_ip         = p_acceptor_ip,
         accepted_user_agent = p_acceptor_user_agent,
         signature_data_url  = p_signature_data_url
   WHERE id = v_token_row.id;

  UPDATE public.contracts
     SET executed_date = current_date,
         status        = 'active',
         updated_at    = now(),
         sync_status   = 'pending'
   WHERE id = v_token_row.contract_id
   RETURNING id, contract_number, title, counterparty_name INTO v_contract;

  RETURN QUERY
  SELECT
    v_contract.id,
    v_token_row.company_id,
    v_contract.contract_number,
    v_contract.title,
    v_contract.counterparty_name,
    true,
    NULL::text;
END $function$;


CREATE OR REPLACE FUNCTION public.lookup_contract_by_token(p_token text)
 RETURNS TABLE(contract_id uuid, company_id uuid, company_name text, contract_number text, contract_title text, contract_type text, counterparty text, counterparty_role text, contract_value numeric, currency text, expires_at timestamp with time zone, accepted_at timestamp with time zone, revoked_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  SELECT
    c.id,
    t.company_id,
    co.name,
    c.contract_number,
    c.title,
    c.contract_type,
    c.counterparty_name,
    c.counterparty_type,
    coalesce(c.contract_value, 0)::numeric,
    c.currency,
    t.expires_at,
    t.accepted_at,
    t.revoked_at
  FROM public.contract_acceptance_tokens t
  JOIN public.contracts  c  ON c.id  = t.contract_id
  JOIN public.companies  co ON co.id = t.company_id
  WHERE t.token = p_token
  LIMIT 1;
END $function$;


CREATE OR REPLACE FUNCTION public.get_contract_acceptance_status(p_contract_id uuid)
 RETURNS TABLE(has_token boolean, expires_at timestamp with time zone, accepted_at timestamp with time zone, accepted_by_name text, accepted_by_email text, revoked_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id    uuid := auth.uid();
  v_company_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT company_id INTO v_company_id FROM public.profiles WHERE id = v_user_id;

  RETURN QUERY
  SELECT
    true,
    t.expires_at,
    t.accepted_at,
    t.accepted_by_name,
    t.accepted_by_email,
    t.revoked_at
  FROM public.contract_acceptance_tokens t
  JOIN public.contracts c ON c.id = t.contract_id
  WHERE t.contract_id = p_contract_id
    AND c.company_id = v_company_id
  ORDER BY t.created_at DESC
  LIMIT 1;
END $function$;


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- LIEN WAIVER ACCEPTANCE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

CREATE OR REPLACE FUNCTION public.mint_lien_waiver_token(p_waiver_id uuid, p_validity_days integer DEFAULT 30)
 RETURNS TABLE(token text, expires_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_admin       record;
  v_waiver      record;
  v_token       text;
  v_expires_at  timestamptz;
BEGIN
  SELECT * INTO v_admin FROM public._require_company_admin();

  SELECT id, company_id, signed_at INTO v_waiver
  FROM public.lien_waivers
  WHERE id = p_waiver_id AND is_deleted = false;
  IF v_waiver.id IS NULL THEN
    RAISE EXCEPTION 'Lien waiver not found' USING ERRCODE = '42501';
  END IF;
  IF v_waiver.company_id <> v_admin.company_id THEN
    RAISE EXCEPTION 'Lien waiver does not belong to your company' USING ERRCODE = '42501';
  END IF;
  IF v_waiver.signed_at IS NOT NULL THEN
    RAISE EXCEPTION 'Lien waiver has already been signed' USING ERRCODE = '22023';
  END IF;

  v_token      := translate(encode(extensions.gen_random_bytes(24), 'base64'), '+/=', '-_');
  v_expires_at := now() + make_interval(days => p_validity_days);

  UPDATE public.lien_waivers
     SET magic_link_token       = v_token,
         magic_link_expires_at  = v_expires_at,
         magic_link_sent_at     = now(),
         magic_link_revoked_at  = NULL,
         status                 = CASE
                                    WHEN status = 'requested' THEN 'sent'
                                    ELSE status
                                  END,
         updated_at             = now(),
         sync_status            = 'pending'
   WHERE id = p_waiver_id;

  RETURN QUERY SELECT v_token, v_expires_at;
END $function$;


CREATE OR REPLACE FUNCTION public.revoke_lien_waiver_token(p_waiver_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_admin record;
BEGIN
  SELECT * INTO v_admin FROM public._require_company_admin();
  UPDATE public.lien_waivers
     SET magic_link_revoked_at = now(),
         updated_at            = now(),
         sync_status           = 'pending'
   WHERE id = p_waiver_id
     AND company_id = v_admin.company_id
     AND magic_link_token IS NOT NULL
     AND magic_link_revoked_at IS NULL
     AND signed_at IS NULL;
END $function$;


CREATE OR REPLACE FUNCTION public.accept_lien_waiver_via_token(p_token text, p_acceptor_name text, p_acceptor_email text, p_acceptor_ip inet, p_acceptor_user_agent text, p_signature_data_url text)
 RETURNS TABLE(waiver_id uuid, company_id uuid, waiver_type text, waiver_from_name text, amount numeric, currency text, ok boolean, reason text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row record;
BEGIN
  SELECT * INTO v_row
  FROM public.lien_waivers
  WHERE magic_link_token = p_token
  LIMIT 1;

  IF v_row.id IS NULL THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, NULL::text, NULL::text, NULL::numeric, NULL::text, false, 'Invalid token';
    RETURN;
  END IF;
  IF v_row.magic_link_revoked_at IS NOT NULL THEN
    RETURN QUERY SELECT v_row.id, v_row.company_id, NULL::text, NULL::text, NULL::numeric, NULL::text, false, 'Link has been revoked';
    RETURN;
  END IF;
  IF v_row.signed_at IS NOT NULL THEN
    RETURN QUERY SELECT v_row.id, v_row.company_id, NULL::text, NULL::text, NULL::numeric, NULL::text, false, 'Waiver has already been signed';
    RETURN;
  END IF;
  IF v_row.magic_link_expires_at IS NOT NULL AND v_row.magic_link_expires_at < now() THEN
    RETURN QUERY SELECT v_row.id, v_row.company_id, NULL::text, NULL::text, NULL::numeric, NULL::text, false, 'Link has expired';
    RETURN;
  END IF;

  UPDATE public.lien_waivers
     SET signed_at            = now(),
         received_at          = now(),
         signed_by_name       = btrim(coalesce(p_acceptor_name, '')),
         signed_by_email      = btrim(coalesce(p_acceptor_email, '')),
         signed_by_ip         = p_acceptor_ip,
         signed_user_agent    = p_acceptor_user_agent,
         signature_data_url   = p_signature_data_url,
         status               = 'received',
         updated_at           = now(),
         sync_status          = 'pending'
   WHERE id = v_row.id;

  RETURN QUERY
  SELECT
    v_row.id,
    v_row.company_id,
    v_row.waiver_type,
    v_row.waiver_from_name,
    v_row.amount,
    v_row.currency,
    true,
    NULL::text;
END $function$;


CREATE OR REPLACE FUNCTION public.lookup_lien_waiver_by_token(p_token text)
 RETURNS TABLE(waiver_id uuid, company_id uuid, company_name text, contract_number text, contract_title text, waiver_type text, waiver_from_name text, amount numeric, retainage_excluded numeric, currency text, through_date date, payment_reference text, expires_at timestamp with time zone, signed_at timestamp with time zone, revoked_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  SELECT
    w.id,
    w.company_id,
    co.name,
    c.contract_number,
    c.title,
    w.waiver_type,
    w.waiver_from_name,
    coalesce(w.amount, 0)::numeric,
    coalesce(w.retainage_excluded, 0)::numeric,
    w.currency,
    w.through_date,
    w.payment_reference,
    w.magic_link_expires_at,
    w.signed_at,
    w.magic_link_revoked_at
  FROM public.lien_waivers w
  JOIN public.companies co ON co.id = w.company_id
  LEFT JOIN public.contracts c ON c.id = w.contract_id
  WHERE w.magic_link_token = p_token
  LIMIT 1;
END $function$;


CREATE OR REPLACE FUNCTION public.get_lien_waiver_sign_status(p_waiver_id uuid)
 RETURNS TABLE(has_token boolean, expires_at timestamp with time zone, sent_at timestamp with time zone, signed_at timestamp with time zone, signed_by_name text, signed_by_email text, revoked_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id    uuid := auth.uid();
  v_company_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT company_id INTO v_company_id FROM public.profiles WHERE id = v_user_id;

  RETURN QUERY
  SELECT
    (w.magic_link_token IS NOT NULL),
    w.magic_link_expires_at,
    w.magic_link_sent_at,
    w.signed_at,
    w.signed_by_name,
    w.signed_by_email,
    w.magic_link_revoked_at
  FROM public.lien_waivers w
  WHERE w.id = p_waiver_id
    AND w.company_id = v_company_id;
END $function$;


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- JOB NUMBERING
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

CREATE OR REPLACE FUNCTION public.next_job_number(p_company_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_prefix text;
    v_number integer;
    v_year   integer := EXTRACT(year FROM now())::int;
BEGIN
    -- Caller must be a member of this company. RLS doesn't apply to
    -- SECURITY DEFINER functions, so we enforce it manually.
    IF NOT EXISTS (
        SELECT 1 FROM public.profiles
        WHERE id = auth.uid() AND company_id = p_company_id
    ) THEN
        RAISE EXCEPTION 'caller is not a member of company %', p_company_id;
    END IF;

    UPDATE public.company_settings
    SET next_job_number = next_job_number + 1
    WHERE company_id = p_company_id
    RETURNING job_prefix, (next_job_number - 1) INTO v_prefix, v_number;

    IF v_prefix IS NULL THEN
        RAISE EXCEPTION 'company_settings row missing for %', p_company_id;
    END IF;

    RETURN format('%s-%s-%s', v_prefix, v_year, lpad(v_number::text, 4, '0'));
END;
$function$;
