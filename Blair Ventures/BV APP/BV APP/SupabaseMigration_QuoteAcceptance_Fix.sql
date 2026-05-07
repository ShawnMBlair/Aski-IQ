-- Aski IQ — accept_quote_via_token bug fix.
--
-- Two surgical changes vs the previously-deployed function:
--
--   1) `#variable_conflict use_column` directive at the top of the
--      function body. The function's OUT parameter `client_name`
--      collided with `quotes.client_name` inside the RETURNING clause,
--      and Postgres' default plpgsql conflict mode (`error`) refused
--      to disambiguate. Reported in production as:
--          column reference "client_name" is ambiguous
--      The directive forces every unqualified identifier in SQL
--      sub-statements to resolve to a column, which is the desired
--      behavior throughout this function (verified by inspection —
--      every place that uses an OUT-param name without qualification
--      means the column).
--
--   2) `COALESCE(subtotal, 0) AS subtotal` in the RETURNING list.
--      Without the alias, the resulting record field would be named
--      `coalesce` and the later `v_quote_row.subtotal` reference would
--      return NULL — a latent bug masked by the ambiguity error above.
--
-- Body is otherwise byte-identical to the deployed version.

CREATE OR REPLACE FUNCTION public.accept_quote_via_token(
  p_token               text,
  p_acceptor_name       text,
  p_acceptor_email      text,
  p_acceptor_ip         inet,
  p_acceptor_user_agent text,
  p_signature_data_url  text
)
RETURNS TABLE(
  quote_id     uuid,
  company_id   uuid,
  quote_number text,
  client_name  text,
  grand_total  numeric,
  ok           boolean,
  reason       text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  v_token_row record;
  v_quote_row record;
BEGIN
  -- Look up the token. Service role bypasses RLS.
  SELECT * INTO v_token_row
  FROM public.quote_acceptance_tokens
  WHERE token = p_token
  LIMIT 1;

  IF v_token_row.id IS NULL THEN
    RETURN QUERY SELECT NULL::uuid, NULL::uuid, NULL::text, NULL::text, 0::numeric, false, 'Invalid token';
    RETURN;
  END IF;
  IF v_token_row.revoked_at IS NOT NULL THEN
    RETURN QUERY SELECT v_token_row.quote_id, v_token_row.company_id, NULL::text, NULL::text, 0::numeric, false, 'Token has been revoked';
    RETURN;
  END IF;
  IF v_token_row.accepted_at IS NOT NULL THEN
    RETURN QUERY SELECT v_token_row.quote_id, v_token_row.company_id, NULL::text, NULL::text, 0::numeric, false, 'Quote was already accepted';
    RETURN;
  END IF;
  IF v_token_row.expires_at < now() THEN
    RETURN QUERY SELECT v_token_row.quote_id, v_token_row.company_id, NULL::text, NULL::text, 0::numeric, false, 'Token has expired';
    RETURN;
  END IF;

  -- Stamp acceptance fields on the token.
  UPDATE public.quote_acceptance_tokens
     SET accepted_at         = now(),
         accepted_by_name    = btrim(coalesce(p_acceptor_name, '')),
         accepted_by_email   = btrim(coalesce(p_acceptor_email, '')),
         accepted_ip         = p_acceptor_ip,
         accepted_user_agent = p_acceptor_user_agent,
         signature_data_url  = p_signature_data_url
   WHERE id = v_token_row.id;

  -- Quote → accepted.
  UPDATE public.quotes
     SET status       = 'accepted',
         accepted_at  = now(),
         updated_at   = now(),
         sync_status  = 'pending'
   WHERE id = v_token_row.quote_id
   RETURNING id, job_number, client_name, COALESCE(subtotal, 0) AS subtotal
        INTO v_quote_row;

  -- Linked opportunity → won.
  -- crm_opportunities has no sync_status column in this schema, so we
  -- skip stamping it here. The iOS sync engine reconciles via updated_at.
  UPDATE public.crm_opportunities
     SET stage       = 'won',
         won_at      = now(),
         lost_at     = NULL,
         probability = 100,
         updated_at  = now()
   WHERE quote_id = v_token_row.quote_id;

  -- Linked estimate → awarded (sourced via the quote's estimate_id).
  UPDATE public.estimates
     SET status      = 'awarded',
         updated_at  = now(),
         sync_status = 'pending'
   WHERE id IN (
     SELECT estimate_id FROM public.quotes WHERE id = v_token_row.quote_id AND estimate_id IS NOT NULL
   );

  -- CRM activity log.
  INSERT INTO public.crm_activities (
    id, company_id, type, title, notes, date, user_name,
    quote_id, opportunity_id
  )
  SELECT
    gen_random_uuid(),
    v_token_row.company_id,
    'quoteAccepted',
    'Quote ' || v_quote_row.job_number || ' accepted via magic link',
    'Accepted by ' || coalesce(p_acceptor_name, p_acceptor_email, 'customer'),
    now(),
    coalesce(p_acceptor_name, p_acceptor_email, 'Customer'),
    v_token_row.quote_id,
    o.id
  FROM public.crm_opportunities o
  WHERE o.quote_id = v_token_row.quote_id
  LIMIT 1;

  -- Return the surface info the Edge Function needs for the email.
  RETURN QUERY
  SELECT
    v_quote_row.id,
    v_token_row.company_id,
    v_quote_row.job_number,
    v_quote_row.client_name,
    v_quote_row.subtotal,
    true,
    NULL::text;
END
$function$;
