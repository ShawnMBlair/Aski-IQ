-- Aski IQ — Stabilization fix: client sites were not persisting.
--
-- ROOT CAUSE: ClientSite is a nested Swift-only struct. The clients
-- table had no column for it, the push payload omitted it, the pull
-- decoder didn't know about it. Every site a rep added (e.g. inside
-- the EstimateCreateView site picker) lived only in the in-memory
-- @Published clients array until the next pull from server, which
-- returned clients without sites and overwrote the local cache —
-- silent data loss.
--
-- FIX: store the entire ClientSite[] as JSON on the clients row.
-- Same pattern already used by estimates.line_items_json + quotes.line_items_json
-- so the iOS encode/decode plumbing is familiar. Future migration to
-- a proper relational `client_sites` table is possible but not
-- blocking this fix.
--
-- iOS changes:
--   • SyncEngineCommercial.pushPendingClients: Row.sites_json
--     serialized from client.sites
--   • SyncEngine.pullClients: ClientRow.sites_json optional, decoded
--     and assigned to client.sites
--   • SitePickerSheet.AddSiteAndSelectSheet: re-fetches live client
--     before mutating, awaits push completion before dismissing,
--     surfaces failed-push errors instead of silently dropping.

ALTER TABLE public.clients
  ADD COLUMN IF NOT EXISTS sites_json text NOT NULL DEFAULT '[]';
