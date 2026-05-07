-- ─────────────────────────────────────────────────────────────────────
-- Aski IQ — FK index hardening
--
-- Surfaced during a defensive pass on missing indexes. Postgres
-- doesn't auto-index the referencing column on a foreign key — only
-- the referenced primary key is indexed. Bare FK columns hit a
-- sequential scan on every JOIN, every cascade-delete probe, and
-- every "show me records linked to X" query the iOS app makes.
--
-- 56 unindexed FKs were found total. This migration covers the
-- ~16 HOT-PATH ones — the FKs that participate in queries the app
-- runs on every screen. The remaining ~40 are mostly:
--   • `sample_data_created_by` — cleanup-only, hit by the admin
--     `clear_sample_data` function once during onboarding wipe.
--     Index would add insert overhead with negligible read benefit.
--   • Audit / one-shot columns (qbo connections, import batches,
--     terms_templates.{created_by,updated_by}) — accessed from
--     occasional admin views; sub-second sequential scan is fine
--     until those tables grow past 100k rows.
--
-- THE HOT-PATH SET
-- These FKs are dereferenced on every render of the relevant
-- screen. Without indexes, query time grows linearly with table
-- size; with indexes, it's O(log n) constant-feel. Worth adding
-- while data is still small (current row counts are double-digits)
-- so the CREATE INDEX runs in milliseconds and there's no
-- production lock contention.
--
-- DEPLOYMENT
-- Safe at any time — `CREATE INDEX IF NOT EXISTS` is idempotent
-- and won't fail on a re-run. No CONCURRENTLY needed at current
-- table sizes; the locks are sub-millisecond. If applied later
-- when tables have grown into the millions, switch to
-- `CREATE INDEX CONCURRENTLY` to avoid blocking writes.
-- ─────────────────────────────────────────────────────────────────────


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Quote / estimate workflow (highest read frequency)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Used by every "quotes for this project" lookup + PM dashboard.
CREATE INDEX IF NOT EXISTS idx_quotes_project_id
  ON public.quotes (project_id);

-- Used by PM filter on QuoteListView + the assigned-to-me dashboard.
CREATE INDEX IF NOT EXISTS idx_quotes_assigned_pm_id
  ON public.quotes (assigned_pm_id);

-- Used by every "estimates for this project" lookup + lock-on-promote
-- detection (project view shows "linked estimate" cross-link).
CREATE INDEX IF NOT EXISTS idx_estimates_project_id
  ON public.estimates (project_id);


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- CRM (activity feed, contact pages, task list filters)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Powers the "activities for this contact" timeline.
CREATE INDEX IF NOT EXISTS idx_crm_activities_contact_id
  ON public.crm_activities (contact_id);

-- Powers the "opportunities for this contact" cross-link panel.
CREATE INDEX IF NOT EXISTS idx_crm_opportunities_contact_id
  ON public.crm_opportunities (contact_id);

-- CRM Tasks list filters by client and by contact — both columns hit
-- on every Hub render that shows "tasks for this client / contact".
CREATE INDEX IF NOT EXISTS idx_crm_tasks_client_id
  ON public.crm_tasks (client_id);
CREATE INDEX IF NOT EXISTS idx_crm_tasks_contact_id
  ON public.crm_tasks (contact_id);


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Procurement (MR → PO chain, equipment-by-project)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- PO detail view shows "this PO fulfills MR-XXX". Without this
-- index every PO render does a seq-scan against material_requests.
CREATE INDEX IF NOT EXISTS idx_purchase_orders_material_request_id
  ON public.purchase_orders (material_request_id);

-- Equipment list filtered by project assignment — used on
-- ProjectDetailView's "equipment on site" section.
CREATE INDEX IF NOT EXISTS idx_equipment_assigned_project_id
  ON public.equipment (assigned_project_id);


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Operations (scheduling, approvals, signatures)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Schedule view filters by crew on every render of the crew calendar.
CREATE INDEX IF NOT EXISTS idx_schedule_entries_crew_id
  ON public.schedule_entries (crew_id);

-- Approval queue ("approvals I requested" + "approvals I decided")
-- filters by the current user on these two columns. Hot path during
-- approval workflow.
CREATE INDEX IF NOT EXISTS idx_quote_approvals_requested_by
  ON public.quote_approvals (requested_by);
CREATE INDEX IF NOT EXISTS idx_quote_approvals_decided_by
  ON public.quote_approvals (decided_by);


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Contracts (chain navigation: parent / supersede / signature)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Contract detail view walks the chain (parent_contract_id) to
-- show version history. The supersedes link is dereferenced on
-- every detail render.
CREATE INDEX IF NOT EXISTS idx_contracts_parent_contract_id
  ON public.contracts (parent_contract_id);
CREATE INDEX IF NOT EXISTS idx_contracts_supersedes_contract_id
  ON public.contracts (supersedes_contract_id);

-- Latest signature request — joined on every contract row in the
-- list view to display "Pending signature" / "Signed" status.
CREATE INDEX IF NOT EXISTS idx_contracts_latest_signature_request_id
  ON public.contracts (latest_signature_request_id);


-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Pricing (used per-line-item during quote build)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Client-specific pricing lookup runs once per line item during
-- quote build. With 5 quotes × 20 line items it's already 100
-- joins; without the index that's 100 seq scans on the pricing
-- table.
CREATE INDEX IF NOT EXISTS idx_client_pricings_product_service_id
  ON public.client_pricings (product_service_id);


-- ─────────────────────────────────────────────────────────────────────
-- VERIFICATION
-- After applying, re-run the original audit query and confirm the
-- 16 hot-path FKs no longer appear in the unindexed list. The
-- ~40 cold-path FKs (mostly sample_data_created_by) will remain
-- and that's by design — see header.
-- ─────────────────────────────────────────────────────────────────────
