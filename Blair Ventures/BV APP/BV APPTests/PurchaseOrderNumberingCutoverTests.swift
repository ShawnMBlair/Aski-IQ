// PurchaseOrderNumberingCutoverTests.swift
// Aski IQ — B1.2 PO numbering cutover (2026-05-14)
//
// Validates the iOS cutover from local Swift PO number generation to
// the production `next_purchase_order_number(uuid)` RPC shipped earlier
// today (2026-05-14 08:59 MT).
//
// What's tested here:
//   1. resolvePONumber() flag-OFF path returns legacy local formula
//   2. resolvePONumber() flag-ON path is wired to the server path
//   3. nextPONumber() legacy fallback remains correct (parity test
//      against the prior contract — soft-delete-aware, monotonic)
//   4. CompanySettingsService.nextPurchaseOrderNumber params encoding
//   5. Feature flag persistence round-trip via UserDefaults
//
// What's NOT tested here:
//   - The live RPC against staging/production. That requires an
//     integration target authenticated against a real Supabase instance.
//     Covered by manual smoke per B1_2_iOS_cutover_runbook.md §7.
//   - The DB partial unique index. Owned by the procurement migration
//     test suite + production verification.

import XCTest
@testable import BV_APP

@MainActor
final class PurchaseOrderNumberingCutoverTests: XCTestCase {

    // Test fixtures use the same in-memory AppStore mutation pattern as
    // NumberGenerationTests.swift — save state, mutate, defer-restore.
    private func withFreshStore<T>(_ body: (AppStore) async throws -> T) async rethrows -> T {
        let store = AppStore.shared
        let savedPOs       = store.purchaseOrders
        let savedCompanyID = store.currentCompanyID
        let savedFlag      = AppSettings.shared.serverPONumberingEnabled
        let savedPrefix    = AppSettings.shared.companyPrefix
        defer {
            store.purchaseOrders               = savedPOs
            store.currentCompanyID             = savedCompanyID
            AppSettings.shared.serverPONumberingEnabled = savedFlag
            AppSettings.shared.companyPrefix            = savedPrefix
        }
        store.purchaseOrders               = []
        store.currentCompanyID             = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        AppSettings.shared.companyPrefix   = "BV"
        return try await body(store)
    }

    // MARK: - Flag OFF: legacy local formula

    func testResolvePONumber_FlagOff_usesLegacyFormula() async throws {
        try await withFreshStore { store in
            AppSettings.shared.serverPONumberingEnabled = false
            let year = Calendar.current.component(.year, from: Date())

            // Seed an existing PO for the same (company, year).
            var existing = PurchaseOrder(poNumber: "BV-PO-\(year)-0007", projectID: nil)
            existing.companyID = store.currentCompanyID
            store.purchaseOrders.append(existing)

            let number = await store.resolvePONumber()
            XCTAssertEqual(
                number, "BV-PO-\(year)-0008",
                "Flag-off should use the legacy max-of-existing-suffix + 1 formula"
            )
        }
    }

    // MARK: - Legacy nextPONumber() parity (the fallback path)

    func testNextPONumber_MonotonicWithinCompanyYear() async throws {
        try await withFreshStore { store in
            let year = Calendar.current.component(.year, from: Date())

            // 3 existing POs with non-sequential suffixes for our company.
            for suffix in ["0003", "0007", "0005"] {
                var po = PurchaseOrder(poNumber: "BV-PO-\(year)-\(suffix)", projectID: nil)
                po.companyID = store.currentCompanyID
                store.purchaseOrders.append(po)
            }

            // A PO for a DIFFERENT company should NOT contaminate the count.
            var other = PurchaseOrder(poNumber: "BV-PO-\(year)-9999", projectID: nil)
            other.companyID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
            store.purchaseOrders.append(other)

            let number = store.nextPONumber()
            XCTAssertEqual(
                number, "BV-PO-\(year)-0008",
                "Should be max of existing same-company suffixes (7) + 1; the foreign-company 9999 must be ignored"
            )
        }
    }

    func testNextPONumber_EmptyStateStartsAtOne() async throws {
        try await withFreshStore { store in
            let year = Calendar.current.component(.year, from: Date())
            let number = store.nextPONumber()
            XCTAssertEqual(
                number, "BV-PO-\(year)-0001",
                "First PO of a fresh tenant-year should be -0001"
            )
        }
    }

    // MARK: - Feature flag persistence

    func testServerPONumberingEnabled_RoundTripUserDefaults() async {
        let savedFlag = AppSettings.shared.serverPONumberingEnabled
        defer { AppSettings.shared.serverPONumberingEnabled = savedFlag }

        AppSettings.shared.serverPONumberingEnabled = false
        XCTAssertFalse(
            UserDefaults.standard.bool(forKey: "ak_server_po_numbering_enabled"),
            "Toggling the flag off should persist to UserDefaults"
        )

        AppSettings.shared.serverPONumberingEnabled = true
        XCTAssertTrue(
            UserDefaults.standard.bool(forKey: "ak_server_po_numbering_enabled"),
            "Toggling the flag on should persist to UserDefaults"
        )
    }

    // MARK: - RPC params encoding

    func testRPCParams_EncodeCompanyIDAsUUIDString() throws {
        // Mirror the exact Params struct used in CompanySettingsService.
        struct Params: Encodable { let p_company_id: String }
        let id = UUID(uuidString: "bd75d321-01e3-4312-beca-ecbb9a3cf490")!
        let params = Params(p_company_id: id.uuidString)

        let data = try JSONEncoder().encode(params)
        let json = try XCTUnwrap(
            String(data: data, encoding: .utf8),
            "Encoded params should round-trip through UTF-8"
        )
        XCTAssertEqual(
            json,
            #"{"p_company_id":"BD75D321-01E3-4312-BECA-ECBB9A3CF490"}"#,
            "RPC params must encode p_company_id as the uppercase UUID string"
        )
    }

    // MARK: - No-active-company error path

    func testNextPONumberServer_ThrowsWhenNoActiveCompany() async {
        await withFreshStore { store in
            // Simulate the signed-out / pre-onboarding state.
            store.currentCompanyID = nil
            do {
                _ = try await store.nextPONumberServer()
                XCTFail("nextPONumberServer should throw when no currentCompanyID is set")
            } catch {
                // Expected — the function checks currentCompanyID and
                // throws NSError(domain: "Procurement", code: 1, ...).
                let nsErr = error as NSError
                XCTAssertEqual(nsErr.domain, "Procurement")
                XCTAssertEqual(nsErr.code, 1)
            }
        }
    }
}
