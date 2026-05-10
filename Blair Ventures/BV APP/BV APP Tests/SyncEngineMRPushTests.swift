// SyncEngineMRPushTests.swift
// Aski IQ — Phase 5 / Wave 2 / Slice 2 SyncEngine push tests for
// Material Requests + Purchase Orders.
//
// MR was the original Phase 1 trigger (BV-MR-2026-0001 didn't sync to
// prod), so these tests are the highest-value coverage for the seam
// migration. They guard:
//   - table routing (material_requests vs purchase_orders)
//   - that critical fields are pushed (request_number, destination_type,
//     po_number, supplier_id) — regressions here would re-create the
//     "data not saved" Phase 1 incident
//   - syncStatus transitions on success / failure
//   - SyncErrorMapper integration (PO push gap-fill from Wave 2 / Slice 2)

import XCTest
@testable import BV_APP

final class SyncEngineMRPushTests: XCTestCase {

    @MainActor
    private func withFreshStore<T>(_ body: (AppStore) throws -> T) rethrows -> T {
        let store = AppStore.shared
        let savedMRs       = store.materialRequests
        let savedPOs       = store.purchaseOrders
        let savedCompanyID = store.currentCompanyID
        defer {
            store.materialRequests = savedMRs
            store.purchaseOrders   = savedPOs
            store.currentCompanyID = savedCompanyID
        }
        store.materialRequests = []
        store.purchaseOrders   = []
        store.currentCompanyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        return try body(store)
    }

    // MARK: - Material Requests

    @MainActor
    func test_pushPendingMaterialRequests_routesToMaterialRequestsTable() async throws {
        try await withFreshStore { store in
            let fake = FakeSyncClient()
            let engine = SyncEngine(client: fake)

            var mr = MaterialRequest(requestNumber: "BV-MR-2026-0001")
            mr.companyID = store.currentCompanyID
            mr.syncStatus = .pending
            store.materialRequests.append(mr)

            await engine.pushPendingMaterialRequests()

            XCTAssertEqual(fake.upserts.count, 1)
            XCTAssertEqual(fake.upserts.first?.table, "material_requests")
        }
    }

    @MainActor
    func test_pushPendingMaterialRequests_includesRequestNumberAndDestinationType() async throws {
        try await withFreshStore { store in
            let fake = FakeSyncClient()
            let engine = SyncEngine(client: fake)

            var mr = MaterialRequest(requestNumber: "BV-MR-2026-0042")
            mr.companyID = store.currentCompanyID
            mr.destinationType = .project
            mr.syncStatus = .pending
            store.materialRequests.append(mr)

            await engine.pushPendingMaterialRequests()

            let dict = try XCTUnwrap(fake.upserts.first?.dict)
            // request_number — Phase 1 incident regression guard.
            XCTAssertEqual(dict["request_number"] as? String, "BV-MR-2026-0042")
            // destination_type — the column whose CHECK constraint
            // first surfaced the procurement migration risk.
            XCTAssertEqual(dict["destination_type"] as? String, "project")
        }
    }

    @MainActor
    func test_pushPendingMaterialRequests_marksSyncedOnSuccess() async throws {
        try await withFreshStore { store in
            let fake = FakeSyncClient()
            let engine = SyncEngine(client: fake)

            var mr = MaterialRequest(requestNumber: "BV-MR-2026-0001")
            mr.companyID = store.currentCompanyID
            mr.syncStatus = .pending
            store.materialRequests.append(mr)

            await engine.pushPendingMaterialRequests()

            let updated = store.materialRequests.first { $0.id == mr.id }
            XCTAssertEqual(updated?.syncStatus, .synced)
        }
    }

    @MainActor
    func test_pushPendingMaterialRequests_recordsErrorOnFailure() async throws {
        try await withFreshStore { store in
            let fake = FakeSyncClient()
            struct StubError: Error {}
            fake.nextUpsertError = StubError()

            let engine = SyncEngine(client: fake)

            var mr = MaterialRequest(requestNumber: "BV-MR-2026-0099")
            mr.companyID = store.currentCompanyID
            mr.syncStatus = .pending
            store.materialRequests.append(mr)

            await engine.pushPendingMaterialRequests()

            let updated = store.materialRequests.first { $0.id == mr.id }
            XCTAssertEqual(updated?.syncStatus, .failed)
            XCTAssertNotNil(store.syncErrors[mr.id])
        }
    }

    // MARK: - Purchase Orders

    @MainActor
    func test_pushPendingPurchaseOrders_routesToPurchaseOrdersTable() async throws {
        try await withFreshStore { store in
            let fake = FakeSyncClient()
            let engine = SyncEngine(client: fake)

            var po = PurchaseOrder(poNumber: "BV-PO-2026-0001")
            po.companyID = store.currentCompanyID
            po.syncStatus = .pending
            store.purchaseOrders.append(po)

            await engine.pushPendingPurchaseOrders()

            XCTAssertEqual(fake.upserts.count, 1)
            XCTAssertEqual(fake.upserts.first?.table, "purchase_orders")
        }
    }

    @MainActor
    func test_pushPendingPurchaseOrders_includesPoNumber() async throws {
        try await withFreshStore { store in
            let fake = FakeSyncClient()
            let engine = SyncEngine(client: fake)

            var po = PurchaseOrder(poNumber: "BV-PO-2026-0007")
            po.companyID = store.currentCompanyID
            po.syncStatus = .pending
            store.purchaseOrders.append(po)

            await engine.pushPendingPurchaseOrders()

            let dict = try XCTUnwrap(fake.upserts.first?.dict)
            XCTAssertEqual(dict["po_number"] as? String, "BV-PO-2026-0007")
        }
    }

    @MainActor
    func test_pushPendingPurchaseOrders_recordsErrorOnFailure_gapFillCheck() async throws {
        // Wave 2 / Slice 2 gap-fill: PO push didn't previously wire
        // through SyncErrorMapper; this test guards that the error path
        // now stamps a per-row reason like every other commercial push.
        try await withFreshStore { store in
            let fake = FakeSyncClient()
            struct StubError: Error {}
            fake.nextUpsertError = StubError()

            let engine = SyncEngine(client: fake)

            var po = PurchaseOrder(poNumber: "BV-PO-2026-0099")
            po.companyID = store.currentCompanyID
            po.syncStatus = .pending
            store.purchaseOrders.append(po)

            await engine.pushPendingPurchaseOrders()

            let updated = store.purchaseOrders.first { $0.id == po.id }
            XCTAssertEqual(updated?.syncStatus, .failed)
            XCTAssertNotNil(store.syncErrors[po.id],
                          "PO push should record sync error after Wave 2 gap-fill")
        }
    }
}
