-- ─────────────────────────────────────────────────────────────────────
-- Aski IQ — Material Sale digital acceptance (Path-A clone of Quote acceptance)
--
-- Mirrors the quote_acceptance_tokens / mint / revoke / accept /
-- lookup / status / signed-details pipeline already in production
-- for quotes. NO existing quote tables or functions are touched.
--
-- LIFECYCLE MAPPING (decision recorded here so future readers know
-- why MaterialSaleStatus didn't grow new cases):
--   Quote:        draft → sent → accepted/declined
--   MaterialSale: draft → quoted → ordered (= accepted) / cancelled (= declined)
--                                 → invoiced → paid
-- accept_material_sale_via_token flips status='ordered' on accept.
-- No status change for declines yet (would need a separate decline
-- flow; for now only accept goes through magic link).
--
-- DEPLOYMENT
-- Safe to apply at any time — additive only. No existing rows
-- touched. The companion iOS service (MaterialSaleAcceptanceService)
-- + Cloudflare Pages page changes (see handoff doc) round out the
-- feature; this migration is the DB-side prerequisite.
-- ─────────────────────────────────────────────────────────────────────


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- material_sale_acceptance_tokens — exact mirror of quote_acceptance_tokens
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CREATE TABLE IF NOT EXISTS public.material_sale_acceptance_tokens (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  material_sale_id         uuid NOT NULL REFERENCES public.material_sales(id) ON DELETE CASCADE,
  company_id               uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  token                    text NOT NULL UNIQUE,
  expires_at               timestamptz NOT NULL,
  created_at               timestamptz NOT NULL DEFAULT now(),
  created_by               uuid REFERENCES auth.users(id),

  accepted_at              timestamptz,
  accepted_by_name         text,
  accepted_by_email        text,
  accepted_ip              inet,
  accepted_user_agent      text,
  signature_data_url       text,

  revoked_at               timestamptz,
  revoked_by               uuid REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS idx_material_sale_acceptance_tokens_sale
  ON public.material_sale_acceptance_tokens(material_sale_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_material_sale_acceptance_tokens_token
  ON public.material_sale_acceptance_tokens(token);

-- Acceptance audit field on the parent sale row
ALTER TABLE public.material_sales
  ADD COLUMN IF NOT EXISTS accepted_at timestamptz;

-- RLS — same EXISTS-on-parent pattern used elsewhere
ALTER TABLE public.material_sale_acceptance_tokens ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS material_sale_acceptance_tokens_company ON public.material_sale_acceptance_tokens;
CREATE POLICY material_sale_acceptance_tokens_company
  ON public.material_sale_acceptance_tokens
  FOR ALL TO authenticated
  USING (company_id = (SELECT company_id FROM public.profiles WHERE id = auth.uid()))
  WITH CHECK (company_id = (SELECT company_id FROM public.profiles WHERE id = auth.uid()));

GRANT SELECT, INSERT, UPDATE, DELETE
  ON public.material_sale_acceptance_tokens TO authenticated;


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- mint_material_sale_acceptance_token
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CREATE OR REPLACE FUNCTION public.mint_material_sale_acceptance_token(
  p_material_sale_id uuid,
  p_validity_days integer DEFAULT 30
)
RETURNS TABLE(token text, expires_at timestamp with time zone)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_admin       record;
  v_sale_row    record;
  v_token       text;
  v_expires_at  timestamptz;
BEGIN
  SELECT * INTO v_admin FROM public._require_company_admin();

  SELECT id, company_id INTO v_sale_row
  FROM public.material_sales
  WHERE id = p_material_sale_id AND COALESCE(is_deleted, false) = false;
  IF v_sale_row.id IS NULL THEN
    RAISE EXCEPTION 'Material sale not found' USING ERRCODE = '42501';
  END IF;
  IF v_sale_row.company_id <> v_admin.company_id THEN
    RAISE EXCEPTION 'Material sale does not belong to your company' USING ERRCODE = '42501';
  END IF;

  -- Auto-revoke any prior live token so only the latest URL works.
  UPDATE public.material_sale_acceptance_tokens
     SET revoked_at = now(),
         revoked_by = v_admin.user_id
   WHERE material_sale_id = p_material_sale_id
     AND revoked_at IS NULL
     AND accepted_at IS NULL;

  v_token := translate(
    encode(extensions.gen_random_bytes(24), 'base64'),
    '+/=', '-_'
  );
  v_expires_at := now() + make_interval(days => p_validity_days);

  INSERT INTO public.material_sale_acceptance_tokens(
    material_sale_id, company_id, token, expires_at, created_by
  ) VALUES (
    p_material_sale_id, v_admin.company_id, v_token, v_expires_at, v_admin.user_id
  );

  RETURN QUERY SELECT v_token, v_expires_at;
END $function$;

GRANT EXECUTE ON FUNCTION public.mint_material_sale_acceptance_token(uuid, integer) TO authenticated;


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- revoke_material_sale_acceptance_token
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CREATE OR REPLACE FUNCTION public.revoke_material_sale_acceptance_token(
  p_material_sale_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_admin record;
BEGIN
  SELECT * INTO v_admin FROM public._require_company_admin();
  UPDATE public.material_sale_acceptance_tokens
     SET revoked_at = now(),
         revoked_by = v_admin.user_id
   WHERE material_sale_id = p_material_sale_id
     AND company_id = v_admin.company_id
     AND revoked_at IS NULL
     AND accepted_at IS NULL;
END $function$;

GRANT EXECUTE ON FUNCTION public.revoke_material_sale_acceptance_token(uuid) TO authenticated;


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- lookup_material_sale_by_token — public lookup for the Edge Function
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CREATE OR REPLACE FUNCTION public.lookup_material_sale_by_token(p_token text)
RETURNS TABLE(
  material_sale_id  uuid,
  company_id        uuid,
  company_name      text,
  sale_number       text,
  sale_type         text,
  client_name       text,
  delivery_address  text,
  grand_total       numeric,
  expires_at        timestamp with time zone,
  accepted_at       timestamp with time zone,
  revoked_at        timestamp with time zone
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  SELECT
    s.id,
    t.company_id,
    co.name,
    s.sale_number,
    s.sale_type,
    cl.name,
    s.delivery_address,
    -- Total = subtotal + tax. Computed inline because material_sales
    -- doesn't store a denormalized grand_total column.
    (
      COALESCE((
        SELECT SUM((li->>'quantity')::numeric * (li->>'unitPrice')::numeric)
        FROM jsonb_array_elements(COALESCE(s.line_items_json::jsonb, '[]'::jsonb)) li
      ), 0)
      * (1 + COALESCE(s.tax_rate, 0) / 100.0)
    )::numeric,
    t.expires_at,
    t.accepted_at,
    t.revoked_at
  FROM public.material_sale_acceptance_tokens t
  JOIN public.material_sales s ON s.id = t.material_sale_id
  JOIN public.companies      co ON co.id = t.company_id
  LEFT JOIN public.clients   cl ON cl.id = s.client_id
  WHERE t.token = p_token
  LIMIT 1;
END $function$;

GRANT EXECUTE ON FUNCTION public.lookup_material_sale_by_token(text) TO anon, authenticated;


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- accept_material_sale_via_token — atomic accept
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Mirror of accept_quote_via_token. Differences:
--   • Status target: 'ordered' (not 'accepted' — see lifecycle map)
--   • Linked opportunity flips to 'won' (same as quote accept)
--   • No estimate update path (sales aren't sourced from estimates)
--   • CRM activity type: 'salesAccepted' — must exist as enum/constraint
--     value (CRMActivityType has it via the iOS-side enum; server-side
--     activity table treats the column as text so any value works)
CREATE OR REPLACE FUNCTION public.accept_material_sale_via_token(
  p_token               text,
  p_acceptor_name       text,
  p_acceptor_email      text,
  p_acceptor_ip         inet,
  p_acceptor_user_agent text,
  p_signature_data_url  text
)
RETURNS TABLE(
  material_sale_id uuid,
  company_id       uuid,
  sale_number      text,
  client_name      text,
  grand_total      numeric,
  ok               boolean,
  reason           text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  v_token_row record;
  v_sale_row  record;
BEGIN
  SELECT * INTO v_token_row
  FROM public.material_sale_acceptance_tokens
  WHERE token = p_token
  LIMIT 1;

  IF v_token_row.id IS NULL THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, NULL::text, NULL::text, 0::numeric, false, 'Invalid token';
    RETURN;
  END IF;
  IF v_token_row.revoked_at IS NOT NULL THEN
    RETURN QUERY SELECT v_token_row.material_sale_id, v_token_row.company_id, NULL::text, NULL::text, 0::numeric, false, 'Token has been revoked';
    RETURN;
  END IF;
  IF v_token_row.accepted_at IS NOT NULL THEN
    RETURN QUERY SELECT v_token_row.material_sale_id, v_token_row.company_id, NULL::text, NULL::text, 0::numeric, false, 'Sale was already accepted';
    RETURN;
  END IF;
  IF v_token_row.expires_at < now() THEN
    RETURN QUERY SELECT v_token_row.material_sale_id, v_token_row.company_id, NULL::text, NULL::text, 0::numeric, false, 'Token has expired';
    RETURN;
  END IF;

  -- Stamp the token.
  UPDATE public.material_sale_acceptance_tokens
     SET accepted_at         = now(),
         accepted_by_name    = btrim(coalesce(p_acceptor_name, '')),
         accepted_by_email   = btrim(coalesce(p_acceptor_email, '')),
         accepted_ip         = p_acceptor_ip,
         accepted_user_agent = p_acceptor_user_agent,
         signature_data_url  = p_signature_data_url
   WHERE id = v_token_row.id;

  -- Sale → ordered (= accepted in MaterialSale lifecycle terms).
  -- material_sales has no sync_status column (iOS reconciles via
  -- updated_at), so we don't stamp one here. Same pattern as the
  -- crm_opportunities update below.
  UPDATE public.material_sales
     SET status       = 'ordered',
         accepted_at  = now(),
         updated_at   = now()
   WHERE id = v_token_row.material_sale_id
   RETURNING id, sale_number,
             (SELECT name FROM public.clients WHERE id = client_id) AS client_name,
             (
               COALESCE((
                 SELECT SUM((li->>'quantity')::numeric * (li->>'unitPrice')::numeric)
                 FROM jsonb_array_elements(COALESCE(line_items_json::jsonb, '[]'::jsonb)) li
               ), 0)
               * (1 + COALESCE(tax_rate, 0) / 100.0)
             )::numeric AS grand_total
        INTO v_sale_row;

  -- Linked opportunity → Won (TitleCase per crm_opportunities_stage_chk
  -- enforced by SupabaseMigration_StageNormalization.sql). Same
  -- downstream effect as accept_quote_via_token.
  UPDATE public.crm_opportunities
     SET stage       = 'Won',
         won_at      = now(),
         lost_at     = NULL,
         probability = 100,
         updated_at  = now()
   WHERE id IN (
     SELECT opportunity_id FROM public.material_sales
     WHERE id = v_token_row.material_sale_id AND opportunity_id IS NOT NULL
   );

  -- CRM activity log.
  INSERT INTO public.crm_activities (
    id, company_id, type, title, notes, date, user_name,
    opportunity_id
  )
  SELECT
    gen_random_uuid(),
    v_token_row.company_id,
    'salesAccepted',
    'Material sale ' || v_sale_row.sale_number || ' accepted via magic link',
    'Accepted by ' || coalesce(p_acceptor_name, p_acceptor_email, 'customer'),
    now(),
    coalesce(p_acceptor_name, p_acceptor_email, 'Customer'),
    s.opportunity_id
  FROM public.material_sales s
  WHERE s.id = v_token_row.material_sale_id
  LIMIT 1;

  RETURN QUERY
  SELECT
    v_sale_row.id,
    v_token_row.company_id,
    v_sale_row.sale_number,
    v_sale_row.client_name,
    v_sale_row.grand_total,
    true,
    NULL::text;
END $function$;

GRANT EXECUTE ON FUNCTION public.accept_material_sale_via_token(text, text, text, inet, text, text) TO anon, authenticated;


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- get_material_sale_acceptance_status — for the iOS detail view pill
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CREATE OR REPLACE FUNCTION public.get_material_sale_acceptance_status(
  p_material_sale_id uuid
)
RETURNS TABLE(
  has_token         boolean,
  expires_at        timestamp with time zone,
  accepted_at       timestamp with time zone,
  accepted_by_name  text,
  accepted_by_email text,
  revoked_at        timestamp with time zone
)
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
  FROM public.material_sale_acceptance_tokens t
  JOIN public.material_sales s ON s.id = t.material_sale_id
  WHERE t.material_sale_id = p_material_sale_id
    AND s.company_id = v_company_id
  ORDER BY t.created_at DESC
  LIMIT 1;
END $function$;

GRANT EXECUTE ON FUNCTION public.get_material_sale_acceptance_status(uuid) TO authenticated;


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- get_material_sale_acceptance_signed_details — for SignedMaterialSalePDFGenerator
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CREATE OR REPLACE FUNCTION public.get_material_sale_acceptance_signed_details(
  p_material_sale_id uuid
)
RETURNS TABLE(
  accepted_at         timestamp with time zone,
  accepted_by_name    text,
  accepted_by_email   text,
  accepted_ip         text,
  signature_data_url  text,
  token_suffix        text
)
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
    t.accepted_at,
    t.accepted_by_name,
    t.accepted_by_email,
    host(t.accepted_ip)::text,
    t.signature_data_url,
    right(t.token, 6)
  FROM public.material_sale_acceptance_tokens t
  JOIN public.material_sales s ON s.id = t.material_sale_id
  WHERE t.material_sale_id = p_material_sale_id
    AND s.company_id = v_company_id
    AND t.accepted_at IS NOT NULL
  ORDER BY t.created_at DESC
  LIMIT 1;
END $function$;

GRANT EXECUTE ON FUNCTION public.get_material_sale_acceptance_signed_details(uuid) TO authenticated;


-- ─────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- After applying:
--   SELECT proname FROM pg_proc WHERE proname IN (
--     'mint_material_sale_acceptance_token',
--     'revoke_material_sale_acceptance_token',
--     'lookup_material_sale_by_token',
--     'accept_material_sale_via_token',
--     'get_material_sale_acceptance_status',
--     'get_material_sale_acceptance_signed_details'
--   );
--   SELECT 1 FROM information_schema.tables
--    WHERE table_schema='public' AND table_name='material_sale_acceptance_tokens';
--   SELECT 1 FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='material_sales' AND column_name='accepted_at';
-- ─────────────────────────────────────────────────────────────────────
