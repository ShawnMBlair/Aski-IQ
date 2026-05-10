# Phase 4 — RLS, Security, and Permissions (drafts)

Per the [Aski IQ Major Issue Repair Plan](../../BV%20APP/DEVELOPER_ROADMAP.md), Phase 4 audits and tightens RLS policies, SECURITY DEFINER function privileges, function search_path hardening, and tenant isolation across the public schema.

## Item 1 — Terms-RLS push order (LANDED)

**Status:** ✅ Fixed in this PR (`SyncEngine.swift` reorder commit).

The `quote_terms`, `estimate_terms`, and `material_sale_terms` tables were intermittently RLS-rejecting valid pushes. The RLS policies themselves were correctly written (`WITH CHECK EXISTS (SELECT 1 FROM <parent_table> WHERE id = ... AND company_id = current_user_company_id)`), but the Swift `SyncEngine.pullAll/pushPending` cycle pushed `material_sale_terms` *before* `material_sales`, so the parent didn't yet exist on the server when its children tried to insert. Fixed by moving `pushPendingMaterialSales` up next to `pushPendingQuotes` in the push order, ahead of all three terms tables.

No DB migration needed — pure ordering fix in app code.

## Item 2 — SECURITY DEFINER project-wide lockdown

**Migrations:**
- `SEC1_security_definer_lockdown.sql` — revokes anon (and `PUBLIC`) EXECUTE on 30+ functions that shouldn't be reachable without authentication. Three groups: trigger-only, role-check helpers, admin/sensitive writes. Intentional anon-callable functions (token-acceptance flows, signup flows) are explicitly preserved.
- `SEC2_function_search_path_pin.sql` — pins `search_path = public` on the 34 functions flagged by Supabase advisor's `function_search_path_mutable` lint. Mostly the `fn_*_lock_sample_marker` family from prior sample-data work, plus a handful of stragglers.

**Apply order:** SEC1 then SEC2 (independent, but logical).

## Item 3 — Tenant isolation review

**Status:** ✅ Clean.

Project-wide query for tables with `company_id` that have RLS disabled OR no policy returned **only the 4 QBO objects** (`qbo_connections`, `qbo_entity_map`, plus the two `*_status` views). Per the schema comments on those tables, that's intentional design: OAuth tokens live there, service-role-only access via Edge Functions. The advisor's `rls_enabled_no_policy` finding on these is accepted design intent, not a bug.

Every other public table with `company_id` has RLS enabled and at least one policy. **No changes required.**

## Apply order

Migrations in this folder are independent of each other and can be applied in any order — but ordering by name (SEC1 before SEC2) keeps the audit trail readable.

## Phase 4 status — COMPLETE (pending prod-apply approval)

- Terms-RLS bug shipped on `claude/xenodochial-bhaskara-96bfe2` as a Swift-only fix (no migration).
- 2 SECURITY DEFINER hardening migrations sit ready in this folder.
- Tenant isolation verified clean.
- Documented design intent: QBO service-role-only access pattern.

## Operator notes

When applying SEC1, the procurement migration's existing revokes will overlap (procurement already revoked `auto_link_opportunity_for_commercial_record`, the three trigger funcs, and the three RLS helpers). The repeat revokes are harmless no-ops. Postgres `revoke ... from <role>` doesn't error if the privilege wasn't there.

After applying both migrations, re-run `get_advisors` and confirm only the documented design-intent WARNs remain (RLS helpers callable by authenticated; QBO service-role design).
