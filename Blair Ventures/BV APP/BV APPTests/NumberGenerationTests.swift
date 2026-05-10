// NumberGenerationTests.swift
// Aski IQ — Phase 5 / Wave 1 unit tests for the Phase 3 number-generation
// hardening. Validates the parsed-max+1 + soft-delete + multi-tenant
// behavior that landed across 8 modules.
//
// Pattern: spin up an in-memory AppStore-like fixture for each scenario,
// seed it with shaped MaterialRequests / Invoices / etc., call the
// nextXNumber() helper, assert the output. Pure Swift — no Supabase.
//
// What's NOT tested here: the DB-side partial unique index. That requires
// an integration target running against a real Supabase branch and is
// tracked under Phase 5 / Wave 2.

import XCTest
@testable import BV_APP

final class NumberGenerationTests: XCTestCase {

    // Convenience: a real AppStore with a known company_id seeded. We
    // can't easily mock AppStore (it's a singleton + ObservableObject),
    // but we can mutate its arrays and currentCompanyID for the test
    // duration, then restore.
    @MainActor
    private func withFreshStore<T>(_ body: (AppStore) throws -> T) rethrows -> T {
        let store = AppStore.shared
        let savedMRs           = store.materialRequests
        let savedPOs           = store.purchaseOrders
        let savedInvoices      = store.invoices
        let savedQuotes        = store.quotes
        let savedMaterialSales = store.materialSales
        let savedCompanyID     = store.currentCompanyID
        defer {
            store.materialRequests = savedMRs
            store.purchaseOrders   = savedPOs
            store.invoices         = savedInvoices
            store.quotes           = savedQuotes
            store.materialSales    = savedMaterialSales
            store.currentCompanyID = savedCompanyID
        }
        // Reset to known state.
        store.materialRequests = []
        store.purchaseOrders   = []
        store.invoices         = []
        store.quotes           = []
        store.materialSales    = []
        store.currentCompanyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        return try body(store)
    }

    // MARK: - Material Requests

    @MainActor
    func test_nextMaterialRequestNumber_emptyStore_returnsFirst() {
        withFreshStore { store in
            let number = store.nextMaterialRequestNumber()
            XCTAssertTrue(number.hasSuffix("-0001"),
                          "Expected first MR to be 0001; got \(number)")
        }
    }

    @MainActor
    func test_nextMaterialRequestNumber_skipsSoftDeleted() {
        withFreshStore { store in
            let year = Calendar.current.component(.year, from: Date())
            let yearPrefix = (AppSettings.shared.companyPrefix.isEmpty ? "BV" : AppSettings.shared.companyPrefix)
                + "-MR-\(year)-"
            // Seed: live MR with 0001, soft-deleted MR with 0002, live with 0003.
            // Expected: next = 0004 (max+1, NOT count+1 which would be 0004
            // anyway with 3 rows; the failure case is when soft-deleted
            // is the highest).
            var mr1 = MaterialRequest(requestNumber: "\(yearPrefix)0001")
            mr1.companyID = store.currentCompanyID
            mr1.isDeleted = false
            store.materialRequests.append(mr1)

            var mr2 = MaterialRequest(requestNumber: "\(yearPrefix)0002")
            mr2.companyID = store.currentCompanyID
            mr2.isDeleted = true   // soft-deleted
            store.materialRequests.append(mr2)

            var mr3 = MaterialRequest(requestNumber: "\(yearPrefix)0003")
            mr3.companyID = store.currentCompanyID
            mr3.isDeleted = false
            store.materialRequests.append(mr3)

            let next = store.nextMaterialRequestNumber()
            XCTAssertEqual(next, "\(yearPrefix)0004",
                           "Soft-deleted highest should NOT inflate the max; got \(next)")
        }
    }

    @MainActor
    func test_nextMaterialRequestNumber_softDeletedHighest_doesNotInflate() {
        withFreshStore { store in
            let year = Calendar.current.component(.year, from: Date())
            let yearPrefix = (AppSettings.shared.companyPrefix.isEmpty ? "BV" : AppSettings.shared.companyPrefix)
                + "-MR-\(year)-"
            // Live 0001, soft-deleted 0099 (the bug scenario).
            var mr1 = MaterialRequest(requestNumber: "\(yearPrefix)0001")
            mr1.companyID = store.currentCompanyID
            mr1.isDeleted = false
            store.materialRequests.append(mr1)

            var mr99 = MaterialRequest(requestNumber: "\(yearPrefix)0099")
            mr99.companyID = store.currentCompanyID
            mr99.isDeleted = true
            store.materialRequests.append(mr99)

            let next = store.nextMaterialRequestNumber()
            // The soft-deleted 0099 is filtered out, so max-of-live = 1, next = 2.
            // (count+1 would have given 3 — wrong.)
            XCTAssertEqual(next, "\(yearPrefix)0002")
        }
    }

    @MainActor
    func test_nextMaterialRequestNumber_excludesOtherCompanies() {
        withFreshStore { store in
            let year = Calendar.current.component(.year, from: Date())
            let yearPrefix = (AppSettings.shared.companyPrefix.isEmpty ? "BV" : AppSettings.shared.companyPrefix)
                + "-MR-\(year)-"
            // Same number from a DIFFERENT company shouldn't influence
            // this company's max.
            let otherCompany = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
            var mrOther = MaterialRequest(requestNumber: "\(yearPrefix)0050")
            mrOther.companyID = otherCompany
            mrOther.isDeleted = false
            store.materialRequests.append(mrOther)

            let next = store.nextMaterialRequestNumber()
            XCTAssertEqual(next, "\(yearPrefix)0001",
                           "Cross-tenant number should not inflate this tenant's max; got \(next)")
        }
    }

    @MainActor
    func test_nextMaterialRequestNumber_yearPrefixIgnored_acrossYears() {
        withFreshStore { store in
            // A number from a previous year shouldn't influence this year's max.
            let prevYearPrefix = (AppSettings.shared.companyPrefix.isEmpty ? "BV" : AppSettings.shared.companyPrefix)
                + "-MR-2025-"
            var mrPrev = MaterialRequest(requestNumber: "\(prevYearPrefix)0500")
            mrPrev.companyID = store.currentCompanyID
            mrPrev.isDeleted = false
            store.materialRequests.append(mrPrev)

            let next = store.nextMaterialRequestNumber()
            XCTAssertTrue(next.hasSuffix("-0001"),
                          "Previous year's number should not inflate current year; got \(next)")
        }
    }

    // MARK: - Purchase Orders (same shape, different prefix)

    @MainActor
    func test_nextPONumber_emptyStore_returnsFirst() {
        withFreshStore { store in
            let number = store.nextPONumber()
            XCTAssertTrue(number.hasSuffix("-0001"))
        }
    }

    @MainActor
    func test_nextPONumber_skipsSoftDeleted() {
        withFreshStore { store in
            let year = Calendar.current.component(.year, from: Date())
            let yearPrefix = (AppSettings.shared.companyPrefix.isEmpty ? "BV" : AppSettings.shared.companyPrefix)
                + "-PO-\(year)-"

            var po1 = PurchaseOrder(poNumber: "\(yearPrefix)0001")
            po1.companyID = store.currentCompanyID
            po1.isDeleted = false
            store.purchaseOrders.append(po1)

            var po99 = PurchaseOrder(poNumber: "\(yearPrefix)0099")
            po99.companyID = store.currentCompanyID
            po99.isDeleted = true
            store.purchaseOrders.append(po99)

            let next = store.nextPONumber()
            XCTAssertEqual(next, "\(yearPrefix)0002")
        }
    }

    // MARK: - Invoices

    @MainActor
    func test_nextInvoiceNumber_emptyStore_returnsFirst() {
        withFreshStore { store in
            let number = store.nextInvoiceNumber()
            XCTAssertTrue(number.hasSuffix("-0001"))
        }
    }

    @MainActor
    func test_nextInvoiceNumber_skipsSoftDeleted() {
        withFreshStore { store in
            let year = Calendar.current.component(.year, from: Date())
            let yearPrefix = (AppSettings.shared.companyPrefix.isEmpty ? "BV" : AppSettings.shared.companyPrefix)
                + "-INV-\(year)-"

            var inv = Invoice(invoiceNumber: "\(yearPrefix)0010")
            inv.companyID = store.currentCompanyID
            inv.isDeleted = true
            store.invoices.append(inv)

            let next = store.nextInvoiceNumber()
            // Only soft-deleted exists → next is 0001.
            XCTAssertTrue(next.hasSuffix("-0001"),
                          "Soft-deleted invoice should not block first issue; got \(next)")
        }
    }

    // MARK: - Quotes (job_number field, not quoteNumber)

    @MainActor
    func test_nextQuoteNumber_emptyStore_returnsFirst() {
        withFreshStore { store in
            let number = store.nextQuoteNumber()
            XCTAssertTrue(number.hasSuffix("-0001"))
            XCTAssertTrue(number.hasPrefix("Q-"))
        }
    }

    @MainActor
    func test_nextQuoteNumber_skipsSoftDeleted_andOtherCompanies() {
        withFreshStore { store in
            let year = Calendar.current.component(.year, from: Date())
            let prefix = "Q-\(year)-"

            // Same-tenant soft-deleted high number.
            var q1 = Quote.testFixture()
            q1.companyID = store.currentCompanyID
            q1.jobNumber = "\(prefix)0050"
            q1.isDeleted = true
            store.quotes.append(q1)

            // Other-tenant live high number.
            var q2 = Quote.testFixture()
            q2.companyID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
            q2.jobNumber = "\(prefix)0080"
            q2.isDeleted = false
            store.quotes.append(q2)

            let next = store.nextQuoteNumber()
            XCTAssertEqual(next, "\(prefix)0001",
                           "Soft-deleted + cross-tenant should both be excluded; got \(next)")
        }
    }
}

// MARK: - Test fixtures

private extension Quote {
    /// Minimum-viable Quote for tests where the only fields we care about
    /// are companyID + jobNumber + isDeleted. Real production code paths
    /// validate more, but the number generator only reads those three.
    static func testFixture() -> Quote {
        var q = Quote(
            jobNumber:  "Q-2026-0000",
            estimateID: UUID(),
            clientID:   UUID(),
            clientName: "Test Client",
            preparedBy: "Test"
        )
        q.id = UUID()
        return q
    }
}
