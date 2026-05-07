-- Aski IQ — setup_new_user fix (May 2026)
--
-- WHAT THIS FIXES
-- Before: setup_new_user created a new company and assigned the calling
--         user the role 'manager' on the new profiles row.
-- After:  the calling user — i.e. the company creator, the FIRST user —
--         is assigned 'executive'.
--
-- WHY
-- 'manager' lacks several admin-tier capabilities (Clear Sample Data,
-- billing, member-role management). The first user IS the owner; they
-- need full admin access from sign-up.
--
-- USER EXPERIENCE IMPACT
-- New signups: the company creator lands as `executive` and can
-- immediately use admin-only features (Sample Data load/clear,
-- invites, billing, role management when the Team screen ships).
-- Existing users: see the one-time backfill block at the bottom — it
-- promotes the original owner of each existing company to executive
-- IF that company currently has zero executives. Comment it out if
-- you've already manually promoted yourselves.
--
-- ROLLBACK
-- Re-run the previous version (with 'manager') if you need to revert.

-- =============================================================================
-- 1. Replace the function
-- =============================================================================
CREATE OR REPLACE FUNCTION public.setup_new_user(
    p_full_name    text,
    p_company_name text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_user_id    uuid := auth.uid();
    v_company_id uuid;
BEGIN
    -- Sanity gate: bail out if there's no auth context. Without this,
    -- a rogue caller without auth could create orphan companies. The
    -- handle_new_user trigger has already created the profile row; we
    -- just need to attach company + role.
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'setup_new_user called without an auth.uid()';
    END IF;

    -- Always create a fresh company. Different signups with the same
    -- p_company_name produce different companies; tenant isolation
    -- comes from company_id (UUID), never from name.
    INSERT INTO companies (name, created_at)
    VALUES (p_company_name, now())
    RETURNING id INTO v_company_id;

    -- Upsert the profile. The handle_new_user trigger inserts a row
    -- with company_id = NULL when the auth user is created; we update
    -- it here. New owners always start as 'executive'.
    INSERT INTO profiles (id, email, full_name, role, is_active, company_id, created_at)
    SELECT v_user_id, email, p_full_name, 'executive', true, v_company_id, now()
    FROM auth.users
    WHERE id = v_user_id
    ON CONFLICT (id) DO UPDATE
    SET company_id = v_company_id,
        full_name  = p_full_name,
        role       = 'executive';
END;
$function$;

-- =============================================================================
-- 2. One-time backfill: promote single-user owners to executive
-- =============================================================================
-- For every existing company that has exactly one profile row and that
-- profile's role is currently 'manager', promote them to 'executive'.
--
-- Why "exactly one": multi-user companies need a deliberate owner
-- selection — we don't auto-promote in those because we'd be guessing.
-- Run this once after deploying the function above. SAFE TO RE-RUN
-- (the WHERE clause makes it idempotent).
--
-- COMMENT OUT IF: you've already manually fixed your test accounts.

UPDATE profiles p
SET role = 'executive'
WHERE p.role = 'manager'
  AND p.company_id IS NOT NULL
  AND (
    SELECT count(*)
    FROM profiles p2
    WHERE p2.company_id = p.company_id
      AND p2.is_active IS TRUE
  ) = 1;
