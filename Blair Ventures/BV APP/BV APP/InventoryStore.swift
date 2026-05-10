// InventoryStore.swift
// Phase 8 / Inventory v1 — AppStore extension exposing CRUD + the
// MR availability hook.
//
// All mutations: role-gated through requireRole, mark .syncStatus =
// .pending, fire the appropriate SyncEngine push, and call
// objectWillChange. Mirrors the procurement pattern.

import Foundation
import Combine

// MARK: - AppStore: Inventory state

extension AppStore {

    // The collections themselves live alongside the other @Published
    // arrays in AppStore.swift. To keep this file focused, we declare
    // the storage there in a follow-up edit and only expose the CRUD
    // surface here.

    // MARK: - InventoryItem CRUD

    /// All inventory items for the current tenant, excluding soft-deleted.
    var activeInventoryItems: [InventoryItem] {
        inventoryItems.filter { !$0.isDeleted }
    }

    /// Inventory items the current user is allowed to see — same scope
    /// today (no per-role filter for inventory yet), but the helper
    /// makes future filtering trivial.
    var visibleInventoryItems: [InventoryItem] {
        activeInventoryItems
    }

    func addInventoryItem(_ item: InventoryItem) {
        guard requireRole(
            [.officeAdmin, .manager, .executive, .owner],
            action: "add_inventory_item"
        ) else { return }
        var new = item
        if new.companyID == nil { new.companyID = currentCompanyID }
        new.syncStatus = .pending
        new.updatedAt  = Date()
        inventoryItems.append(new)
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingInventoryItems() }
    }

    func updateInventoryItem(_ item: InventoryItem) {
        guard requireRole(
            [.officeAdmin, .manager, .executive, .owner],
            action: "update_inventory_item"
        ) else { return }
        guard let idx = inventoryItems.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = item
        if updated.companyID == nil { updated.companyID = currentCompanyID }
        updated.syncStatus = .pending
        updated.updatedAt  = Date()
        inventoryItems[idx] = updated
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingInventoryItems() }
    }

    func deleteInventoryItem(id: UUID) {
        guard requireRole(
            [.manager, .executive, .owner],
            action: "delete_inventory_item"
        ) else { return }
        guard let idx = inventoryItems.firstIndex(where: { $0.id == id }) else { return }
        var deleted = inventoryItems[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        inventoryItems[idx] = deleted
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingInventoryItems() }
    }

    // MARK: - StockLocation CRUD

    var activeStockLocations: [StockLocation] {
        stockLocations.filter { !$0.isDeleted && $0.isActive }
    }

    /// The default location for the current company. Created by the
    /// INV1 migration as "Main Yard / MAIN" when prod ran the seed.
    var defaultStockLocation: StockLocation? {
        activeStockLocations.first { $0.isDefault }
    }

    func addStockLocation(_ location: StockLocation) {
        guard requireRole(
            [.officeAdmin, .manager, .executive, .owner],
            action: "add_stock_location"
        ) else { return }
        var new = location
        if new.companyID == nil { new.companyID = currentCompanyID }
        new.syncStatus = .pending
        new.updatedAt  = Date()
        stockLocations.append(new)
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingStockLocations() }
    }

    func updateStockLocation(_ location: StockLocation) {
        guard requireRole(
            [.officeAdmin, .manager, .executive, .owner],
            action: "update_stock_location"
        ) else { return }
        guard let idx = stockLocations.firstIndex(where: { $0.id == location.id }) else { return }
        var updated = location
        if updated.companyID == nil { updated.companyID = currentCompanyID }
        updated.syncStatus = .pending
        updated.updatedAt  = Date()
        stockLocations[idx] = updated
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingStockLocations() }
    }

    // MARK: - InventoryStockLevel — read helpers

    /// Quantity-on-hand for an item at a specific location.
    /// Returns 0 when the item has never been at that location (no row
    /// exists yet) — caller should treat 0 as "none in stock".
    func quantityOnHand(itemID: UUID, locationID: UUID) -> Decimal {
        inventoryStockLevels
            .first { !$0.isDeleted && $0.itemID == itemID && $0.locationID == locationID }
            .map { $0.quantityOnHand } ?? 0
    }

    /// Total qty across every active location for an item.
    func totalQuantityOnHand(itemID: UUID) -> Decimal {
        inventoryStockLevels
            .filter { !$0.isDeleted && $0.itemID == itemID }
            .reduce(0) { $0 + $1.quantityOnHand }
    }

    /// Locations where an item has stock > 0 (active rows only). Useful
    /// for the transfer source picker.
    func locationsWithStock(itemID: UUID) -> [StockLocation] {
        let levels = inventoryStockLevels.filter {
            !$0.isDeleted && $0.itemID == itemID && $0.quantityOnHand > 0
        }
        let locIDs = Set(levels.map { $0.locationID })
        return activeStockLocations.filter { locIDs.contains($0.id) }
    }

    // MARK: - InventoryTransfer CRUD

    /// All transfers for the current tenant, excluding soft-deleted.
    /// Sorted newest-first so the activity log feels live.
    var recentInventoryTransfers: [InventoryTransfer] {
        inventoryTransfers
            .filter { !$0.isDeleted }
            .sorted { $0.transferredAt > $1.transferredAt }
    }

    /// Auto-generates the next transfer number scoped to (company, year).
    /// Format: BV-XFR-YYYY-NNNN. Mirrors the Phase 3 number-gen pattern
    /// (parsed-max+1, soft-delete excluded, multi-tenant scope).
    func nextTransferNumber() -> String {
        let prefix = (AppSettings.shared.companyPrefix.isEmpty
                      ? "BV" : AppSettings.shared.companyPrefix)
        let year   = Calendar.current.component(.year, from: Date())
        let yearPrefix = "\(prefix)-XFR-\(year)-"
        let highest = inventoryTransfers
            .filter { $0.companyID == currentCompanyID && !$0.isDeleted }
            .compactMap { t -> Int? in
                guard t.transferNumber.hasPrefix(yearPrefix) else { return nil }
                return Int(t.transferNumber.dropFirst(yearPrefix.count))
            }
            .max() ?? 0
        return "\(yearPrefix)\(String(format: "%04d", highest + 1))"
    }

    /// Record a transfer. Mutates local stock_levels immediately for
    /// optimistic UX, then pushes both the transfer row and the touched
    /// stock_level rows. Server-side replay should be idempotent because
    /// stock_levels are upserted by (item × location).
    ///
    /// Validation:
    ///   - quantity > 0
    ///   - source location has enough stock
    ///   - exactly one destination set
    /// Returns the persisted transfer or nil on validation failure.
    @discardableResult
    func recordInventoryTransfer(
        itemID: UUID,
        fromLocationID: UUID,
        destination: InventoryTransferDestination,
        quantity: Decimal,
        notes: String = ""
    ) -> InventoryTransfer? {
        guard requireRole(
            [.foreman, .projectManager, .officeAdmin, .manager, .executive, .owner],
            action: "record_inventory_transfer"
        ) else { return nil }
        guard quantity > 0 else { return nil }

        let onHand = quantityOnHand(itemID: itemID, locationID: fromLocationID)
        guard onHand >= quantity else {
            ToastService.shared.error(
                "Not enough stock at source — \(onHand) on hand, \(quantity) requested."
            )
            return nil
        }

        // Build the transfer row.
        var transfer = InventoryTransfer(
            itemID: itemID,
            fromLocationID: fromLocationID
        )
        transfer.companyID            = currentCompanyID
        transfer.transferNumber       = nextTransferNumber()
        transfer.toLocationID         = destination.locationID
        transfer.toProjectID          = destination.projectID
        transfer.toMaterialRequestID  = destination.materialRequestID
        transfer.quantity             = quantity
        transfer.notes                = notes
        transfer.transferredByName    = currentUser?.fullName ?? ""
        transfer.transferredAt        = Date()
        transfer.syncStatus           = .pending

        // Snapshot unit cost from source location so the transfer row
        // captures the cost-of-goods at time of move (immutable history).
        if let srcLevel = inventoryStockLevels.first(where: {
            !$0.isDeleted && $0.itemID == itemID && $0.locationID == fromLocationID
        }) {
            transfer.unitCost = srcLevel.avgUnitCost
        }

        inventoryTransfers.append(transfer)

        // Optimistic stock-level updates.
        // 1) Decrement source location.
        decrementStockLevel(itemID: itemID, locationID: fromLocationID, by: quantity)

        // 2) If destination is another location, increment it.
        if let toLocID = destination.locationID {
            incrementStockLevel(
                itemID: itemID,
                locationID: toLocID,
                by: quantity,
                avgUnitCost: transfer.unitCost
            )
        }
        // (Project / MR destinations remove qty from inventory entirely;
        // no destination stock-level row to bump.)

        objectWillChange.send()
        Task {
            await SyncEngine.shared.pushPendingInventoryTransfers()
            await SyncEngine.shared.pushPendingStockLevels()
        }
        return transfer
    }

    private func decrementStockLevel(itemID: UUID, locationID: UUID, by qty: Decimal) {
        if let idx = inventoryStockLevels.firstIndex(where: {
            !$0.isDeleted && $0.itemID == itemID && $0.locationID == locationID
        }) {
            inventoryStockLevels[idx].quantityOnHand -= qty
            inventoryStockLevels[idx].syncStatus     = .pending
            inventoryStockLevels[idx].updatedAt      = Date()
        }
    }

    private func incrementStockLevel(
        itemID: UUID,
        locationID: UUID,
        by qty: Decimal,
        avgUnitCost: Decimal? = nil
    ) {
        if let idx = inventoryStockLevels.firstIndex(where: {
            !$0.isDeleted && $0.itemID == itemID && $0.locationID == locationID
        }) {
            // Existing row — add to qty and update weighted-avg cost.
            let prevQty  = inventoryStockLevels[idx].quantityOnHand
            let prevCost = inventoryStockLevels[idx].avgUnitCost ?? avgUnitCost ?? 0
            let newQty   = prevQty + qty
            // Weighted average. Avoid divide-by-zero when prevQty was 0.
            if let incomingCost = avgUnitCost, prevQty > 0 {
                let totalValue = (prevQty * prevCost) + (qty * incomingCost)
                inventoryStockLevels[idx].avgUnitCost = totalValue / newQty
            } else if let incomingCost = avgUnitCost {
                inventoryStockLevels[idx].avgUnitCost = incomingCost
            }
            inventoryStockLevels[idx].quantityOnHand = newQty
            inventoryStockLevels[idx].syncStatus     = .pending
            inventoryStockLevels[idx].updatedAt      = Date()
        } else {
            // No row yet — create one.
            var level = InventoryStockLevel(itemID: itemID, locationID: locationID)
            level.companyID        = currentCompanyID
            level.quantityOnHand   = qty
            level.avgUnitCost      = avgUnitCost
            level.syncStatus       = .pending
            inventoryStockLevels.append(level)
        }
    }

    // MARK: - InventoryService.checkAvailability — the MR hook

    /// Returns inventory items that satisfy a Material Request line item,
    /// keyed by the item's name (the same key the MR line uses).
    /// Empty result = nothing in stock; non-empty = "consider an
    /// inventory transfer instead of buying".
    ///
    /// Today we match by case-insensitive name. v2 will switch to
    /// product_service_id lookup once the picker carries that ID.
    func availableInventoryFor(materialRequest mr: MaterialRequest) -> [String: [InventoryItem]] {
        guard !inventoryItems.isEmpty else { return [:] }
        var result: [String: [InventoryItem]] = [:]
        for line in mr.lineItems {
            let needle = line.description.lowercased().trimmingCharacters(in: .whitespaces)
            guard !needle.isEmpty else { continue }
            let matches = activeInventoryItems.filter {
                let candidate = $0.name.lowercased().trimmingCharacters(in: .whitespaces)
                return candidate == needle
            }.filter {
                totalQuantityOnHand(itemID: $0.id) > 0
            }
            if !matches.isEmpty {
                result[line.description] = matches
            }
        }
        return result
    }
}
