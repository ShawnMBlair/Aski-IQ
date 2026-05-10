# Phase 8 / Inventory v1 ✅ shipped 2026-05-10

The originally-deferred Inventory module (per the FUTURE marker in `Procurement.swift::submitMaterialRequest`) is now live end-to-end.

## What's included in v1

### Database (applied to prod 2026-05-10)
- `inventory_items` — stockable SKUs (`(company_id, sku)` partial UNIQUE)
- `stock_locations` — yards / warehouses / mobile units (one default per company; 5 "Main Yard" rows seeded)
- `inventory_stock_levels` — qty-on-hand per `(item × location)` (partial UNIQUE)
- `inventory_transfers` — movement audit trail with single-destination CHECK constraint
- RLS via `get_my_company_id()`, `set_updated_at` triggers, all the standard hardening
- Migration: `INV1_inventory_module_v1_schema.sql`

### Swift
- `InventoryModels.swift` — model structs (BaseModel-conforming)
- `InventoryStore.swift` — AppStore extension: CRUD, `recordInventoryTransfer` with optimistic local updates + weighted-avg cost, `nextTransferNumber()` (Phase 3 parsed-max+1 pattern)
- `SyncEngineInventory.swift` — push + pull for all 4 tables via the `AskiSyncClient` seam (Phase 5 / Wave 2). Each push wires through `SyncErrorMapper`.
- `InventoryViews.swift` — 7 SwiftUI views: List, Detail, ItemEditor, LocationList, LocationEditor, TransferCreate, TransfersHistory

### UX
- More-tab navigation: 3 entries in "Equipment & Assets" — Inventory, Stock Locations, Inventory Movements
- First-launch sync gate banner on every list view
- Role gating: managers/officeAdmin/executive/owner can manage items + locations; foremen/PMs+ can record transfers
- Transfer form validates: quantity > 0, source has enough stock, source ≠ destination

### Hooks
- `Procurement.swift::submitMaterialRequest` now calls `availableInventoryFor(materialRequest:)` before transitioning the MR to `.submitted`. If any line items are in stock, surfaces a non-blocking toast: "Consider an inventory transfer instead of buying new."

### Tests
- `SyncEngineInventoryPushTests.swift` — 9 cases covering push routing + payload shape + syncStatus transitions + error path for all 4 push functions

## What's deferred to v2

| Item | Why |
|---|---|
| Reservations (hold-for-planned-project) | Needs design — what does "reserve until" mean? Per project? Per quote? UX flow? |
| Low-stock alerts + reorder automation | Needs threshold model + notification routing |
| Supplier reorder logic | Depends on low-stock alerts + integration with supplier workflow |
| Multi-unit conversions (kg vs tonne, ea vs case) | Schema change to add `conversion_factor` table; needs picker UX |
| Barcode scanning + lookup | VisionKit integration + UX for camera-based item lookup |
| Item picker integration with Estimate/Quote line items | Today the MR availability check matches by name; should match via `product_service_id` once the picker carries that ID |
| Physical-count UI | Adjustment screen for end-of-period inventory counts (data model already supports `last_counted_at`) |

## Key call-sites (for v2 author)

- Add new push/pull → mirror the 4 functions in `SyncEngineInventory.swift`
- Add new view → `InventoryViews.swift` + entry point in `RootView.swift::MoreEquipmentSection`
- Modify availability check → `InventoryStore.swift::availableInventoryFor(materialRequest:)`
- Modify transfer mechanics → `InventoryStore.swift::recordInventoryTransfer`
- Add new test → mirror `SyncEngineInventoryPushTests.swift`
