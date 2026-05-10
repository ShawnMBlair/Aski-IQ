// SyncEngineInventory.swift
// Phase 8 / Inventory v1 — push/pull functions for the four inventory
// tables. Follows the AskiSyncClient seam from Phase 5 / Wave 2 so
// these are testable from day one.

import Foundation
import Combine
import Supabase

// Local ISO8601 formatter — `isoFull` on SyncEngine is private. Mirroring
// its exact configuration so timestamps round-trip identically.
private let _invIsoFull: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

extension SyncEngine {

    // ─────────────────────────────────────────────────────────────────
    // MARK: Inventory Items
    // ─────────────────────────────────────────────────────────────────

    func pullInventoryItems() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, company_id, sku, name, unit, cost_code: String
                let description, notes: String?
                let product_service_id: String?
                let default_location_id: String?
                let standard_cost: Decimal?
                /// Phase 8 / Inventory v2 — both fields optional so pulls
                /// against pre-INV2 branches (or projects where the
                /// migration hasn't applied yet) still decode cleanly.
                /// Postgrest omits absent columns from the JSON payload,
                /// which Decodable maps to `nil` for Optional types.
                let reorder_point: Decimal?
                let reorder_quantity: Decimal?
                let is_active: Bool
                let created_at, updated_at: String?
                let last_modified_by: String?
                let last_modified_at: String?
                let sync_status: String?
                let is_deleted: Bool?
                let deleted_at: String?
                let deleted_by: String?
            }
            let rows: [Row] = try await client.select(
                Row.self,
                from: SupabaseTable.inventoryItems,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ],
                orderBy: "name",
                ascending: true
            )

            let parsed: [InventoryItem] = rows.compactMap { row in
                guard let id = UUID(uuidString: row.id),
                      let cid = UUID(uuidString: row.company_id) else { return nil }
                var item = InventoryItem(sku: row.sku, name: row.name, unit: row.unit)
                item.id              = id
                item.companyID       = cid
                item.description     = row.description ?? ""
                item.costCode        = row.cost_code
                item.notes           = row.notes ?? ""
                item.productServiceID  = row.product_service_id.flatMap(UUID.init(uuidString:))
                item.defaultLocationID = row.default_location_id.flatMap(UUID.init(uuidString:))
                item.standardCost    = row.standard_cost
                item.reorderPoint    = row.reorder_point
                item.reorderQuantity = row.reorder_quantity
                item.isActive        = row.is_active
                item.syncStatus      = .synced
                return item
            }

            await MainActor.run {
                store.inventoryItems = parsed
                store.objectWillChange.send()
            }
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushPendingInventoryItems() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.inventoryItems.filter { $0.syncStatus == .pending }
        for item in pending {
            do {
                struct Row: Codable {
                    let id, company_id, sku, name, unit, cost_code: String
                    let description, notes: String?
                    let product_service_id, default_location_id: String?
                    let standard_cost: Decimal?
                    /// Phase 8 / Inventory v2 — pushed alongside the other
                    /// item fields. INV2 migration must be applied to
                    /// prod before this build ships, or the upsert
                    /// returns 42703 ("column does not exist"). Both
                    /// fields are nullable on the server side so we can
                    /// emit `null` for items without a configured
                    /// threshold (the common case for v1-imported rows).
                    let reorder_point: Decimal?
                    let reorder_quantity: Decimal?
                    let is_active, is_deleted: Bool
                    let deleted_at, deleted_by: String?
                }
                let row = Row(
                    id:                 item.id.uuidString,
                    company_id:         (item.companyID ?? companyID).uuidString,
                    sku:                item.sku,
                    name:               item.name,
                    unit:               item.unit,
                    cost_code:          item.costCode,
                    description:        item.description.isEmpty ? nil : item.description,
                    notes:              item.notes.isEmpty ? nil : item.notes,
                    product_service_id: item.productServiceID?.uuidString,
                    default_location_id: item.defaultLocationID?.uuidString,
                    standard_cost:      item.standardCost,
                    reorder_point:      item.reorderPoint,
                    reorder_quantity:   item.reorderQuantity,
                    is_active:          item.isActive,
                    is_deleted:         item.isDeleted,
                    deleted_at:         item.deletedAt.map { _invIsoFull.string(from: $0) },
                    deleted_by:         item.deletedBy
                )
                try await client.upsert(row, into: SupabaseTable.inventoryItems)
                if let i = store.inventoryItems.firstIndex(where: { $0.id == item.id }) {
                    store.inventoryItems[i].syncStatus = .synced
                }
                await MainActor.run { store.clearSyncError(id: item.id) }
            } catch {
                if let i = store.inventoryItems.firstIndex(where: { $0.id == item.id }) {
                    store.inventoryItems[i].syncStatus = .failed
                }
                await MainActor.run { store.recordSyncError(id: item.id, error: error) }
                CrashReporter.capture(error: error, context: [
                    "operation": "\(#function)",
                    "item_id": item.id.uuidString,
                    "sku": item.sku
                ])
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: Stock Locations
    // ─────────────────────────────────────────────────────────────────

    func pullStockLocations() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, company_id, name, code, location_type: String
                let description, address: String?
                let is_active, is_default: Bool
                let is_deleted: Bool?
            }
            let rows: [Row] = try await client.select(
                Row.self,
                from: SupabaseTable.stockLocations,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ],
                orderBy: "name",
                ascending: true
            )
            let parsed: [StockLocation] = rows.compactMap { row in
                guard let id = UUID(uuidString: row.id),
                      let cid = UUID(uuidString: row.company_id) else { return nil }
                var loc = StockLocation()
                loc.id            = id
                loc.companyID     = cid
                loc.name          = row.name
                loc.code          = row.code
                loc.description   = row.description ?? ""
                loc.locationType  = row.location_type
                loc.address       = row.address ?? ""
                loc.isActive      = row.is_active
                loc.isDefault     = row.is_default
                loc.syncStatus    = .synced
                return loc
            }
            await MainActor.run {
                store.stockLocations = parsed
                store.objectWillChange.send()
            }
        } catch {
            print("⚠️ \(#function) failed: \(error)")
        }
    }

    func pushPendingStockLocations() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.stockLocations.filter { $0.syncStatus == .pending }
        for loc in pending {
            do {
                struct Row: Codable {
                    let id, company_id, name, code, location_type: String
                    let description, address: String?
                    let is_active, is_default, is_deleted: Bool
                }
                let row = Row(
                    id:            loc.id.uuidString,
                    company_id:    (loc.companyID ?? companyID).uuidString,
                    name:          loc.name,
                    code:          loc.code,
                    location_type: loc.locationType,
                    description:   loc.description.isEmpty ? nil : loc.description,
                    address:       loc.address.isEmpty ? nil : loc.address,
                    is_active:     loc.isActive,
                    is_default:    loc.isDefault,
                    is_deleted:    loc.isDeleted
                )
                try await client.upsert(row, into: SupabaseTable.stockLocations)
                if let i = store.stockLocations.firstIndex(where: { $0.id == loc.id }) {
                    store.stockLocations[i].syncStatus = .synced
                }
                await MainActor.run { store.clearSyncError(id: loc.id) }
            } catch {
                if let i = store.stockLocations.firstIndex(where: { $0.id == loc.id }) {
                    store.stockLocations[i].syncStatus = .failed
                }
                await MainActor.run { store.recordSyncError(id: loc.id, error: error) }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: Stock Levels
    // ─────────────────────────────────────────────────────────────────

    func pullStockLevels() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, company_id, item_id, location_id: String
                let quantity_on_hand: Decimal
                let avg_unit_cost: Decimal?
                let last_counted_at: String?
                let last_counted_by: String?
                let notes: String?
                let is_deleted: Bool?
            }
            let rows: [Row] = try await client.select(
                Row.self,
                from: SupabaseTable.inventoryStockLevels,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ]
            )
            let parsed: [InventoryStockLevel] = rows.compactMap { row in
                guard let id = UUID(uuidString: row.id),
                      let cid = UUID(uuidString: row.company_id),
                      let itemID = UUID(uuidString: row.item_id),
                      let locID = UUID(uuidString: row.location_id) else { return nil }
                var level = InventoryStockLevel(itemID: itemID, locationID: locID)
                level.id              = id
                level.companyID       = cid
                level.quantityOnHand  = row.quantity_on_hand
                level.avgUnitCost     = row.avg_unit_cost
                level.lastCountedBy   = row.last_counted_by ?? ""
                level.notes           = row.notes ?? ""
                level.syncStatus      = .synced
                return level
            }
            await MainActor.run {
                store.inventoryStockLevels = parsed
                store.objectWillChange.send()
            }
        } catch {
            print("⚠️ \(#function) failed: \(error)")
        }
    }

    func pushPendingStockLevels() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.inventoryStockLevels.filter { $0.syncStatus == .pending }
        for level in pending {
            do {
                struct Row: Codable {
                    let id, company_id, item_id, location_id: String
                    let quantity_on_hand: Decimal
                    let avg_unit_cost: Decimal?
                    let last_counted_at: String?
                    let last_counted_by: String?
                    let notes: String?
                    let is_deleted: Bool
                }
                let row = Row(
                    id:               level.id.uuidString,
                    company_id:       (level.companyID ?? companyID).uuidString,
                    item_id:          level.itemID.uuidString,
                    location_id:      level.locationID.uuidString,
                    quantity_on_hand: level.quantityOnHand,
                    avg_unit_cost:    level.avgUnitCost,
                    last_counted_at:  level.lastCountedAt.map { _invIsoFull.string(from: $0) },
                    last_counted_by:  level.lastCountedBy.isEmpty ? nil : level.lastCountedBy,
                    notes:            level.notes.isEmpty ? nil : level.notes,
                    is_deleted:       level.isDeleted
                )
                try await client.upsert(row, into: SupabaseTable.inventoryStockLevels)
                if let i = store.inventoryStockLevels.firstIndex(where: { $0.id == level.id }) {
                    store.inventoryStockLevels[i].syncStatus = .synced
                }
                await MainActor.run { store.clearSyncError(id: level.id) }
            } catch {
                if let i = store.inventoryStockLevels.firstIndex(where: { $0.id == level.id }) {
                    store.inventoryStockLevels[i].syncStatus = .failed
                }
                await MainActor.run { store.recordSyncError(id: level.id, error: error) }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: Inventory Transfers
    // ─────────────────────────────────────────────────────────────────

    func pullInventoryTransfers() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, company_id, transfer_number, item_id: String
                let from_location_id: String
                let to_location_id, to_project_id, to_material_request_id: String?
                let quantity: Decimal
                let unit_cost: Decimal?
                let notes: String?
                let transferred_by_name: String?
                let transferred_at: String
                let is_deleted: Bool?
            }
            let rows: [Row] = try await client.select(
                Row.self,
                from: SupabaseTable.inventoryTransfers,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ],
                orderBy: "transferred_at",
                ascending: false,
                limit: 500
            )
            let parsed: [InventoryTransfer] = rows.compactMap { row in
                guard let id = UUID(uuidString: row.id),
                      let cid = UUID(uuidString: row.company_id),
                      let itemID = UUID(uuidString: row.item_id),
                      let fromLoc = UUID(uuidString: row.from_location_id) else { return nil }
                var t = InventoryTransfer(itemID: itemID, fromLocationID: fromLoc)
                t.id                   = id
                t.companyID            = cid
                t.transferNumber       = row.transfer_number
                t.toLocationID         = row.to_location_id.flatMap(UUID.init(uuidString:))
                t.toProjectID          = row.to_project_id.flatMap(UUID.init(uuidString:))
                t.toMaterialRequestID  = row.to_material_request_id.flatMap(UUID.init(uuidString:))
                t.quantity             = row.quantity
                t.unitCost             = row.unit_cost
                t.notes                = row.notes ?? ""
                t.transferredByName    = row.transferred_by_name ?? ""
                if let parsed = SyncEngine.isoIn(row.transferred_at) {
                    t.transferredAt = parsed
                }
                t.syncStatus = .synced
                return t
            }
            await MainActor.run {
                store.inventoryTransfers = parsed
                store.objectWillChange.send()
            }
        } catch {
            print("⚠️ \(#function) failed: \(error)")
        }
    }

    func pushPendingInventoryTransfers() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.inventoryTransfers.filter { $0.syncStatus == .pending }
        for t in pending {
            do {
                struct Row: Codable {
                    let id, company_id, transfer_number, item_id, from_location_id: String
                    let to_location_id, to_project_id, to_material_request_id: String?
                    let quantity: Decimal
                    let unit_cost: Decimal?
                    let notes, transferred_by_name: String?
                    let transferred_at: String
                    let is_deleted: Bool
                }
                let row = Row(
                    id:                     t.id.uuidString,
                    company_id:             (t.companyID ?? companyID).uuidString,
                    transfer_number:        t.transferNumber,
                    item_id:                t.itemID.uuidString,
                    from_location_id:       t.fromLocationID.uuidString,
                    to_location_id:         t.toLocationID?.uuidString,
                    to_project_id:          t.toProjectID?.uuidString,
                    to_material_request_id: t.toMaterialRequestID?.uuidString,
                    quantity:               t.quantity,
                    unit_cost:              t.unitCost,
                    notes:                  t.notes.isEmpty ? nil : t.notes,
                    transferred_by_name:    t.transferredByName.isEmpty ? nil : t.transferredByName,
                    transferred_at:         _invIsoFull.string(from: t.transferredAt),
                    is_deleted:             t.isDeleted
                )
                try await client.upsert(row, into: SupabaseTable.inventoryTransfers)
                if let i = store.inventoryTransfers.firstIndex(where: { $0.id == t.id }) {
                    store.inventoryTransfers[i].syncStatus = .synced
                }
                await MainActor.run { store.clearSyncError(id: t.id) }
            } catch {
                if let i = store.inventoryTransfers.firstIndex(where: { $0.id == t.id }) {
                    store.inventoryTransfers[i].syncStatus = .failed
                }
                await MainActor.run { store.recordSyncError(id: t.id, error: error) }
                CrashReporter.capture(error: error, context: [
                    "operation": "\(#function)",
                    "transfer_id": t.id.uuidString,
                    "transfer_number": t.transferNumber
                ])
            }
        }
    }
}
