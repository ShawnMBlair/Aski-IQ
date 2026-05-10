// SyncEngineInventoryPushTests.swift
// Aski IQ — Phase 8 / Inventory v1 push tests via AskiSyncClient seam.
//
// Covers the 4 inventory push functions:
//   - pushPendingInventoryItems
//   - pushPendingStockLocations
//   - pushPendingStockLevels
//   - pushPendingInventoryTransfers
//
// Each gets a routing assertion (table name) + a payload-shape regression
// guard for one critical field. The full-row payload coverage matches
// the pattern from SyncEngineDJRPushTests + SyncEngineMRPushTests.

import XCTest
@testable import BV_APP

final class SyncEngineInventoryPushTests: XCTestCase {

    @MainActor
    private func withFreshStore<T>(_ body: (AppStore) async throws -> T) async rethrows -> T {
        let store = AppStore.shared
        let savedItems     = store.inventoryItems
        let savedLocations = store.stockLocations
        let savedLevels    = store.inventoryStockLevels
        let savedTransfers = store.inventoryTransfers
        let savedCompanyID = store.currentCompanyID
        defer {
            store.inventoryItems         = savedItems
            store.stockLocations         = savedLocations
            store.inventoryStockLevels   = savedLevels
            store.inventoryTransfers     = savedTransfers
            store.currentCompanyID       = savedCompanyID
        }
        store.inventoryItems       = []
        store.stockLocations       = []
        store.inventoryStockLevels = []
        store.inventoryTransfers   = []
        store.currentCompanyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        return try await body(store)
    }

    // MARK: - InventoryItem

    @MainActor
    func test_pushPendingInventoryItems_routesToInventoryItemsTable() async throws {
        try await withFreshStore { store in
            let fake = FakeSyncClient()
            let engine = SyncEngine(client: fake)

            var item = InventoryItem(sku: "TEST-001", name: "Test Widget")
            item.companyID = store.currentCompanyID
            item.syncStatus = .pending
            store.inventoryItems.append(item)

            await engine.pushPendingInventoryItems()

            XCTAssertEqual(fake.upserts.count, 1)
            XCTAssertEqual(fake.upserts.first?.table, "inventory_items")
        }
    }

    @MainActor
    func test_pushPendingInventoryItems_includesSkuAndName() async throws {
        try await withFreshStore { store in
            let fake = FakeSyncClient()
            let engine = SyncEngine(client: fake)

            var item = InventoryItem(sku: "BOLT-1/2", name: "1/2 inch carriage bolt")
            item.companyID = store.currentCompanyID
            item.unit = "ea"
            item.costCode = "MAT-FAST"
            item.syncStatus = .pending
            store.inventoryItems.append(item)

            await engine.pushPendingInventoryItems()

            let dict = try XCTUnwrap(fake.upserts.first?.dict)
            XCTAssertEqual(dict["sku"] as? String, "BOLT-1/2")
            XCTAssertEqual(dict["name"] as? String, "1/2 inch carriage bolt")
            XCTAssertEqual(dict["unit"] as? String, "ea")
            XCTAssertEqual(dict["cost_code"] as? String, "MAT-FAST")
        }
    }

    @MainActor
    func test_pushPendingInventoryItems_marksSyncedOnSuccess() async throws {
        try await withFreshStore { store in
            let fake = FakeSyncClient()
            let engine = SyncEngine(client: fake)

            var item = InventoryItem(sku: "X", name: "Y")
            item.companyID = store.currentCompanyID
            item.syncStatus = .pending
            store.inventoryItems.append(item)

            await engine.pushPendingInventoryItems()

            let updated = store.inventoryItems.first { $0.id == item.id }
            XCTAssertEqual(updated?.syncStatus, .synced)
        }
    }

    // MARK: - StockLocation

    @MainActor
    func test_pushPendingStockLocations_routesToStockLocationsTable() async throws {
        try await withFreshStore { store in
            let fake = FakeSyncClient()
            let engine = SyncEngine(client: fake)

            var loc = StockLocation()
            loc.companyID = store.currentCompanyID
            loc.name = "Yard South"
            loc.code = "YARD-S"
            loc.syncStatus = .pending
            store.stockLocations.append(loc)

            await engine.pushPendingStockLocations()

            XCTAssertEqual(fake.upserts.count, 1)
            XCTAssertEqual(fake.upserts.first?.table, "stock_locations")
        }
    }

    @MainActor
    func test_pushPendingStockLocations_includesNameCodeIsDefault() async throws {
        try await withFreshStore { store in
            let fake = FakeSyncClient()
            let engine = SyncEngine(client: fake)

            var loc = StockLocation()
            loc.companyID = store.currentCompanyID
            loc.name = "Main Yard"
            loc.code = "MAIN"
            loc.locationType = "yard"
            loc.isDefault = true
            loc.syncStatus = .pending
            store.stockLocations.append(loc)

            await engine.pushPendingStockLocations()

            let dict = try XCTUnwrap(fake.upserts.first?.dict)
            XCTAssertEqual(dict["name"] as? String, "Main Yard")
            XCTAssertEqual(dict["code"] as? String, "MAIN")
            XCTAssertEqual(dict["location_type"] as? String, "yard")
            XCTAssertEqual(dict["is_default"] as? Bool, true)
        }
    }

    // MARK: - InventoryStockLevel

    @MainActor
    func test_pushPendingStockLevels_routesToStockLevelsTable() async throws {
        try await withFreshStore { store in
            let fake = FakeSyncClient()
            let engine = SyncEngine(client: fake)

            var level = InventoryStockLevel(itemID: UUID(), locationID: UUID())
            level.companyID = store.currentCompanyID
            level.quantityOnHand = 42
            level.syncStatus = .pending
            store.inventoryStockLevels.append(level)

            await engine.pushPendingStockLevels()

            XCTAssertEqual(fake.upserts.count, 1)
            XCTAssertEqual(fake.upserts.first?.table, "inventory_stock_levels")
        }
    }

    @MainActor
    func test_pushPendingStockLevels_includesQuantityOnHand() async throws {
        try await withFreshStore { store in
            let fake = FakeSyncClient()
            let engine = SyncEngine(client: fake)

            var level = InventoryStockLevel(itemID: UUID(), locationID: UUID())
            level.companyID = store.currentCompanyID
            level.quantityOnHand = 17
            level.avgUnitCost = 2.50
            level.syncStatus = .pending
            store.inventoryStockLevels.append(level)

            await engine.pushPendingStockLevels()

            let dict = try XCTUnwrap(fake.upserts.first?.dict)
            // JSON encodes Decimal as a Number; round-tripping through
            // dict gives a numeric. Compare via stringification to avoid
            // Double-vs-Decimal precision flakiness.
            XCTAssertEqual("\(dict["quantity_on_hand"] ?? "")", "17")
            XCTAssertEqual("\(dict["avg_unit_cost"] ?? "")", "2.5")
        }
    }

    // MARK: - InventoryTransfer

    @MainActor
    func test_pushPendingInventoryTransfers_routesToTransfersTable() async throws {
        try await withFreshStore { store in
            let fake = FakeSyncClient()
            let engine = SyncEngine(client: fake)

            var transfer = InventoryTransfer(itemID: UUID(), fromLocationID: UUID())
            transfer.companyID = store.currentCompanyID
            transfer.transferNumber = "BV-XFR-2026-0001"
            transfer.toLocationID = UUID()
            transfer.quantity = 5
            transfer.syncStatus = .pending
            store.inventoryTransfers.append(transfer)

            await engine.pushPendingInventoryTransfers()

            XCTAssertEqual(fake.upserts.count, 1)
            XCTAssertEqual(fake.upserts.first?.table, "inventory_transfers")
        }
    }

    @MainActor
    func test_pushPendingInventoryTransfers_includesTransferNumberAndDestination() async throws {
        try await withFreshStore { store in
            let fake = FakeSyncClient()
            let engine = SyncEngine(client: fake)

            let toProj = UUID()
            var transfer = InventoryTransfer(itemID: UUID(), fromLocationID: UUID())
            transfer.companyID = store.currentCompanyID
            transfer.transferNumber = "BV-XFR-2026-0042"
            transfer.toProjectID = toProj   // Project destination, not location
            transfer.quantity = 3
            transfer.syncStatus = .pending
            store.inventoryTransfers.append(transfer)

            await engine.pushPendingInventoryTransfers()

            let dict = try XCTUnwrap(fake.upserts.first?.dict)
            XCTAssertEqual(dict["transfer_number"] as? String, "BV-XFR-2026-0042")
            XCTAssertEqual(dict["to_project_id"] as? String, toProj.uuidString)
            XCTAssertNil(dict["to_location_id"] as? String,
                         "Project destination should not also set to_location_id")
        }
    }

    @MainActor
    func test_pushPendingInventoryTransfers_recordsErrorOnFailure() async throws {
        try await withFreshStore { store in
            let fake = FakeSyncClient()
            struct StubError: Error {}
            fake.nextUpsertError = StubError()

            let engine = SyncEngine(client: fake)

            var transfer = InventoryTransfer(itemID: UUID(), fromLocationID: UUID())
            transfer.companyID = store.currentCompanyID
            transfer.transferNumber = "BV-XFR-2026-9999"
            transfer.toLocationID = UUID()
            transfer.quantity = 1
            transfer.syncStatus = .pending
            store.inventoryTransfers.append(transfer)

            await engine.pushPendingInventoryTransfers()

            let updated = store.inventoryTransfers.first { $0.id == transfer.id }
            XCTAssertEqual(updated?.syncStatus, .failed)
            XCTAssertNotNil(store.syncErrors[transfer.id])
        }
    }
}
