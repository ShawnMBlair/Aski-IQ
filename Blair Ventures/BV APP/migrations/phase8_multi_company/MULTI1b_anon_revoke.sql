-- MULTI1 follow-up: revoke anon EXECUTE on the new SECURITY DEFINER
-- helpers introduced by MULTI1_company_memberships. Matches the SEC3
-- pattern that closed the anon-callable function audit.
--
-- Applied to prod 2026-05-10 immediately after MULTI1 merge.
--
-- - current_user_company_ids() — RLS-side helper, no anon use case.
-- - fn_ensure_company_membership() — trigger-only fn, no REST callers.
-- - set_active_company() — already restricted to authenticated in the
--   parent migration; included here for explicit completeness on every
--   future deploy.

REVOKE EXECUTE ON FUNCTION public.current_user_company_ids() FROM anon, public;
REVOKE EXECUTE ON FUNCTION public.fn_ensure_company_membership() FROM anon, authenticated, public;
REVOKE EXECUTE ON FUNCTION public.set_active_company(uuid) FROM anon, public;
