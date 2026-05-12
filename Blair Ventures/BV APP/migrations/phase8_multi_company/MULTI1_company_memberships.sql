-- MULTI1 — Multi-tenant company memberships
-- Phase 8 / Track 3 server-side enablement.
-- Applied to prod 2026-05-10 via `phase8-v2-supabase` branch merge.
--
-- Today: profiles.company_id is a single FK; get_my_company_id() returns it.
-- Goal:  preserve current single-active-company semantics while introducing
--        a many-to-many memberships table so a user can BELONG to multiple
--        companies and the iOS switcher can flip the active one.
--
-- Design notes:
--   - profiles.company_id becomes the "active" company for the session.
--   - company_memberships is the durable many-to-many.
--   - get_my_company_id() unchanged — still reads profiles.company_id, so
--     EVERY existing tenant-scoped RLS policy keeps working with no rewrite.
--   - companies RLS relaxed so the user can READ any company they have a
--     membership for (drives the switcher list).
--   - set_active_company(uuid) is the only way to flip the active company:
--     verifies the user has a membership for that company, then updates
--     profiles.company_id atomically.
--   - Backfill creates is_primary=true memberships for every existing
--     profile, so no user loses access mid-deploy.

-- 1. Membership table
CREATE TABLE IF NOT EXISTS public.company_memberships (
    user_id          uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    company_id       uuid        NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    role_in_company  text        NOT NULL DEFAULT 'member',
    is_primary       boolean     NOT NULL DEFAULT false,
    is_active        boolean     NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, company_id)
);

CREATE INDEX IF NOT EXISTS company_memberships_company_idx
    ON public.company_memberships (company_id) WHERE is_active = true;

-- One primary company per user — enforced via partial unique index so
-- inactive memberships don't pollute the constraint.
CREATE UNIQUE INDEX IF NOT EXISTS company_memberships_one_primary_idx
    ON public.company_memberships (user_id)
    WHERE is_primary = true AND is_active = true;

COMMENT ON TABLE public.company_memberships IS
'Many-to-many between auth.users and companies. Each user has 1+ memberships; exactly one is is_primary. The currently-ACTIVE company is held on profiles.company_id and changed via set_active_company().';

-- 2. Backfill from existing profiles. Each profile becomes a primary,
--    active membership for the user's current company. No-op if a row
--    already exists (idempotent re-apply).
INSERT INTO public.company_memberships (user_id, company_id, role_in_company, is_primary, is_active)
SELECT p.id, p.company_id, p.role, true, true
FROM public.profiles p
WHERE p.deleted_at IS NULL
ON CONFLICT (user_id, company_id) DO NOTHING;

-- 3. RLS — users see their own memberships; admins of a company see
--    memberships scoped to that company.
ALTER TABLE public.company_memberships ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS company_memberships_self_read ON public.company_memberships;
CREATE POLICY company_memberships_self_read
    ON public.company_memberships
    FOR SELECT
    TO authenticated
    USING (user_id = auth.uid());

-- 4. Helper: returns the set of company IDs the current user belongs to.
CREATE OR REPLACE FUNCTION public.current_user_company_ids()
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
    SELECT company_id
    FROM public.company_memberships
    WHERE user_id = auth.uid() AND is_active = true
$$;

COMMENT ON FUNCTION public.current_user_company_ids() IS
'All companies the authed user has an active membership for. Used by relaxed companies RLS + (future) cross-company aggregations.';

-- 5. Relax companies RLS: previously locked to profiles.company_id; now
--    allows any membership row. Drop and recreate so the new USING expr
--    takes effect cleanly.
DROP POLICY IF EXISTS companies_read ON public.companies;
CREATE POLICY companies_read
    ON public.companies
    FOR SELECT
    TO authenticated
    USING (id IN (SELECT public.current_user_company_ids()));

-- 6. Active-company swap helper. Verifies membership before flipping
--    profiles.company_id. Safe to call from iOS — the function lives
--    server-side and returns a boolean indicating whether the swap
--    succeeded (false = caller has no membership for that company).
CREATE OR REPLACE FUNCTION public.set_active_company(p_company_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
    v_has_membership boolean;
BEGIN
    -- Must be authenticated.
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'set_active_company: not authenticated'
            USING ERRCODE = '28000';
    END IF;

    -- Verify the caller actually has an active membership for the
    -- target company. Refuse the swap otherwise — RLS would block
    -- the new tenant's reads anyway, but failing here gives a clean
    -- error rather than a silent empty data set on iOS.
    SELECT EXISTS (
        SELECT 1 FROM public.company_memberships
        WHERE user_id = auth.uid() AND company_id = p_company_id AND is_active = true
    ) INTO v_has_membership;

    IF NOT v_has_membership THEN
        RETURN false;
    END IF;

    UPDATE public.profiles
       SET company_id = p_company_id
     WHERE id = auth.uid();

    RETURN true;
END;
$$;

COMMENT ON FUNCTION public.set_active_company(uuid) IS
'Swaps the active company for the authed user. Verifies membership first; returns false if the user has no active membership for the target company.';

GRANT EXECUTE ON FUNCTION public.set_active_company(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.set_active_company(uuid) FROM anon, public;

-- 7. Trigger: when a profile's company_id changes (signup or via
--    set_active_company side-channel), auto-ensure a membership row
--    exists for that (user, company) pair. Prevents drift if a profile
--    is updated via direct SQL without going through set_active_company.
CREATE OR REPLACE FUNCTION public.fn_ensure_company_membership()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
    IF NEW.company_id IS NULL THEN
        RETURN NEW;
    END IF;
    INSERT INTO public.company_memberships (user_id, company_id, role_in_company, is_primary, is_active)
    VALUES (NEW.id, NEW.company_id, NEW.role, false, true)
    ON CONFLICT (user_id, company_id) DO UPDATE
        SET is_active = true;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_profile_company_membership ON public.profiles;
CREATE TRIGGER trg_profile_company_membership
    AFTER INSERT OR UPDATE OF company_id ON public.profiles
    FOR EACH ROW
    EXECUTE FUNCTION public.fn_ensure_company_membership();
