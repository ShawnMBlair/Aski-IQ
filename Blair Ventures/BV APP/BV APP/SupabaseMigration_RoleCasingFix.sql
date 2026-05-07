-- ─────────────────────────────────────────────────────────────────────
-- Aski IQ — Role-name casing fix (defensive)
--
-- Surfaced during the comprehensive RPC snapshot pass
-- (SupabaseRPCs_Snapshot_Comprehensive.sql, KNOWN ISSUES header).
--
-- THE BUG
-- iOS writes role values in snake_case (UserRole enum raw values:
-- 'office_admin', 'project_manager', 'safety_advisor'). Six SQL
-- helpers shipped with camelCase comparisons ('officeAdmin',
-- 'projectManager', 'safetyAdvisor'), so they silently return false
-- for every user with one of those roles. Any RLS policy or admin
-- gate built on top of these helpers fails for the very users it's
-- supposed to admit.
--
-- WHY NOTHING'S BROKEN IN PROD YET
-- The Executive role IS spelled correctly ('executive') and is the
-- only role currently exercising admin-gated paths (you, the
-- founder). The defect would surface the first time you onboarded
-- an Office Admin teammate.
--
-- FIX
-- Six functions, snake_case alignment, no schema change. 'owner'
-- references kept (vestigial — not in iOS UserRole, but harmless;
-- if it's ever re-introduced server-side it'll Just Work). The
-- non-broken `is_estimating_admin`, `is_field_role`, and
-- `is_manager_or_above` helpers already use snake_case correctly
-- and are NOT touched by this migration.
--
-- DEPLOYMENT
-- Safe to apply at any time — `CREATE OR REPLACE` rewrites the
-- function bodies; signatures are unchanged so dependent RLS
-- policies don't need to be rebuilt.
-- ─────────────────────────────────────────────────────────────────────


-- 1. Admin gate used by token-mint + AI-config functions.
--    Was: role IN ('owner', 'executive', 'manager', 'officeAdmin')
--    Now: role IN ('owner', 'executive', 'manager', 'office_admin')
CREATE OR REPLACE FUNCTION public._require_company_admin()
RETURNS TABLE(user_id uuid, company_id uuid, role text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id    uuid := auth.uid();
  v_company_id uuid;
  v_role       text;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT p.company_id, p.role INTO v_company_id, v_role
  FROM public.profiles p
  WHERE p.id = v_user_id;
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'No profile / company for caller' USING ERRCODE = '42501';
  END IF;
  IF v_role NOT IN ('owner', 'executive', 'manager', 'office_admin') THEN
    RAISE EXCEPTION 'Admin role required' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT v_user_id, v_company_id, v_role;
END $function$;


-- 2. Returns admin emails for a company. Used by EmailService bridge
--    code on the server (approval notifier fallback target).
--    Was: role IN ('owner', 'executive', 'manager', 'officeAdmin')
--    Now: role IN ('owner', 'executive', 'manager', 'office_admin')
CREATE OR REPLACE FUNCTION public.get_company_admin_emails(p_company_id uuid)
RETURNS TABLE(email text, full_name text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  SELECT p.email, p.full_name
  FROM public.profiles p
  WHERE p.company_id = p_company_id
    AND p.role IN ('owner', 'executive', 'manager', 'office_admin')
    AND p.is_active = true
    AND p.deleted_at IS NULL;
END $function$;


-- 3. Financial-admin gate (used by RLS on financial tables).
--    Was: role IN ('officeAdmin', 'manager', 'executive', 'owner')
--    Now: role IN ('office_admin', 'manager', 'executive', 'owner')
CREATE OR REPLACE FUNCTION public.is_financial_admin()
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  select coalesce(
    (select role in ('office_admin', 'manager', 'executive', 'owner')
     from profiles where id = auth.uid()),
    false
  );
$function$;


-- 4. Foreman-or-above gate (used by RLS on field-ops tables).
--    Was: role IN ('foreman', 'projectManager', 'officeAdmin',
--                  'manager', 'executive', 'owner')
--    Now: role IN ('foreman', 'project_manager', 'office_admin',
--                  'manager', 'executive', 'owner')
CREATE OR REPLACE FUNCTION public.is_foreman_or_above()
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  select coalesce(
    (select role in ('foreman', 'project_manager', 'office_admin',
                     'manager', 'executive', 'owner')
     from profiles where id = auth.uid()),
    false
  );
$function$;


-- 5. Safety-admin gate (used by RLS on safety/incident tables).
--    Was: role IN ('safetyAdvisor', 'officeAdmin', 'manager',
--                  'executive', 'owner')
--    Now: role IN ('safety_advisor', 'office_admin', 'manager',
--                  'executive', 'owner')
CREATE OR REPLACE FUNCTION public.is_safety_admin()
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  select coalesce(
    (select role in ('safety_advisor', 'office_admin', 'manager',
                     'executive', 'owner')
     from profiles where id = auth.uid()),
    false
  );
$function$;


-- 6. Company AI prompt setter (admin-only).
--    Was: role IN ('officeAdmin', 'manager', 'executive', 'owner')
--    Now: role IN ('office_admin', 'manager', 'executive', 'owner')
CREATE OR REPLACE FUNCTION public.set_company_ai_prompt(p_surface text, p_prompt text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_company uuid;
  v_role    text;
begin
  select p.company_id, p.role
    into v_company, v_role
    from profiles p
   where p.id = auth.uid();

  if v_company is null then
    raise exception 'No tenant for caller';
  end if;
  if v_role not in ('office_admin', 'manager', 'executive', 'owner') then
    raise exception 'Admin role required to change AI prompts'
      using errcode = '42501';
  end if;
  if p_surface not in ('chat', 'contract_review', 'contract_diff', 'crm_brief') then
    raise exception 'Unknown AI surface: %', p_surface;
  end if;

  if coalesce(trim(p_prompt), '') = '' then
    update companies
       set ai_prompt_overrides = ai_prompt_overrides - p_surface,
           updated_at          = now()
     where id = v_company;
  else
    update companies
       set ai_prompt_overrides = ai_prompt_overrides
                                  || jsonb_build_object(p_surface, p_prompt),
           updated_at          = now()
     where id = v_company;
  end if;
end;
$function$;


-- ─────────────────────────────────────────────────────────────────────
-- VERIFICATION (read-only — run as the affected user from psql or
-- the SQL editor to confirm the helpers now return TRUE for them).
--
--   select public.is_financial_admin();   -- expect: true for office_admin
--   select public.is_foreman_or_above();  -- expect: true for project_manager
--   select public.is_safety_admin();      -- expect: true for safety_advisor
--   select * from public._require_company_admin();  -- expect: row, no exception
--
-- The failure mode pre-fix was a silent `false` (RLS denial) or the
-- 'Admin role required' exception. Post-fix, the snake_case roles
-- pass cleanly.
-- ─────────────────────────────────────────────────────────────────────
