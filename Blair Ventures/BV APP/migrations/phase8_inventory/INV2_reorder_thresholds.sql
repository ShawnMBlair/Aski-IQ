-- INV2 — Inventory v2 / reorder thresholds + suggested reorder quantity
--
-- Adds per-item reorder configuration columns to inventory_items.
-- These replace v1's "qty on hand ≤ 0" out-of-stock heuristic with
-- a real threshold per item. The AI assistant + dashboard widgets
-- read this to surface low-stock alerts before stock hits zero.
--
-- Backward compatible:
--   - Both columns are NULL-able with no default value.
--   - Items with reorder_point = NULL fall back to the v1 heuristic
--     in iOS (qty <= 0). Existing rows aren't touched on apply.
--   - The iOS InventoryItem Codable struct decodes these as Decimal?
--     so pre-INV2 pulls (from a stale branch) still parse cleanly.
--
-- Apply order:
--   1. Apply this migration on a staging branch first.
--   2. Verify pull works against branch (no schema-cache 42703 errors).
--   3. Apply to prod.
--   4. Deploy iOS build that uses the new columns.
--
-- Rollback: DROP COLUMN reorder_point, reorder_quantity. Safe because
-- the columns are nullable and have no FK / index dependencies.

ALTER TABLE public.inventory_items
    ADD COLUMN IF NOT EXISTS reorder_point     numeric(14, 4) NULL,
    ADD COLUMN IF NOT EXISTS reorder_quantity  numeric(14, 4) NULL;

-- Documentation comments — surfaced in Postgres' schema browser and
-- Supabase Studio so admins know what these fields mean without
-- guessing from the column name.
COMMENT ON COLUMN public.inventory_items.reorder_point IS
'When total on-hand qty across all locations drops below this value the item is flagged as low-stock. NULL = no threshold configured (falls back to qty ≤ 0).';

COMMENT ON COLUMN public.inventory_items.reorder_quantity IS
'Suggested quantity to reorder when an item hits its reorder_point. Drives the suggested-PO dialog in v2.1. NULL = no suggestion.';

-- Constraint: thresholds must be non-negative when set. Defense in
-- depth — iOS already gates the editor, but a misconfigured admin
-- script shouldn't poison the data.
ALTER TABLE public.inventory_items
    ADD CONSTRAINT inventory_items_reorder_point_nonneg
        CHECK (reorder_point IS NULL OR reorder_point >= 0),
    ADD CONSTRAINT inventory_items_reorder_quantity_nonneg
        CHECK (reorder_quantity IS NULL OR reorder_quantity >= 0);

-- Partial index on items configured with a reorder point. Lets the
-- low-stock dashboard widget run an efficient query against just
-- the configured set rather than scanning every item.
CREATE INDEX IF NOT EXISTS inventory_items_reorder_configured_idx
    ON public.inventory_items (company_id, reorder_point)
    WHERE reorder_point IS NOT NULL AND is_deleted = false;
