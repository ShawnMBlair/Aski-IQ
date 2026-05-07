-- Aski IQ — get_quote_acceptance_signed_details
--
-- Returns the full set of fields the iOS app needs to render a "signed
-- quote" PDF + acceptance certificate page after a customer accepts a
-- quote via the magic link. Tenant-gated by company_id (same pattern as
-- get_quote_acceptance_status).
--
-- Returned columns are intentionally limited to what the PDF needs:
-- accepted_at, accepted_by_name, accepted_by_email, accepted_ip (cast
-- to text via host() for inet→text), signature_data_url (full base64
-- PNG), and token_suffix (last 6 chars of the token — never the full
-- token, so a leaked PDF can't be replayed against the acceptance
-- endpoint).

CREATE OR REPLACE FUNCTION public.get_quote_acceptance_signed_details(p_quote_id uuid)
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
  FROM public.quote_acceptance_tokens t
  JOIN public.quotes q ON q.id = t.quote_id
  WHERE t.quote_id = p_quote_id
    AND q.company_id = v_company_id
    AND t.accepted_at IS NOT NULL
  ORDER BY t.created_at DESC
  LIMIT 1;
END $function$;

GRANT EXECUTE ON FUNCTION public.get_quote_acceptance_signed_details(uuid) TO authenticated;
