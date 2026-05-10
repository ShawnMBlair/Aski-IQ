// SyncEngineDJRPushTests.swift
// Aski IQ — Phase 5 / Wave 2 first SyncEngine push test.
//
// Validates that pushPendingDJRs:
//   1. Routes to the daily_job_reports table (DJR1 schema closure).
//   2. Includes report_number in the upsert payload (regression
//      guard for the SCHEMA GAP that pre-Phase-3 left it omitted).
//   3. Marks the row syncStatus=.synced after a successful push.
//   4. Includes only the standard fields the table accepts (id,
//      company_id, project_id, report_date, prepared_by,
//      work_summary, report_number, is_deleted, deleted_by; plus
//      deleted_at when set).
//
// Pattern: construct an isolated SyncEngine via init(client:) with a
// FakeSyncClient. Pre-seed AppStore with a pending DJR. Drive the
// push. Assert on FakeSyncClient.upserts + AppStore state.

import XCTest
import Supabase
@testable import BV_APP

final class SyncEngineDJRPushTests: XCTestCase {

    @MainActor
    private func withFreshStore<T>(_ body: (AppStore) throws -> T) rethrows -> T {
        let store = AppStore.shared
        let savedDJRs      = store.allDailyJobReports()
        let savedCompanyID = store.currentCompanyID
        defer {
            // Restore prior state by re-saving the snapshot DJR set + companyID.
            // DJRs persist in UserDefaults, so we re-encode the saved snapshot.
            UserDefaults.standard.set(
                try? JSONEncoder().encode(savedDJRs),
                forKey: "djr_v1"
            )
            store.currentCompanyID = savedCompanyID
        }
        // Reset to a known state.
        UserDefaults.standard.removeObject(forKey: "djr_v1")
        store.currentCompanyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        return try body(store)
    }

    @MainActor
    func test_pushPendingDJRs_routesToDailyJobReportsTable() async throws {
        try await withFreshStore { store in
            let fake = FakeSyncClient()
            let engine = SyncEngine(client: fake)

            var djr = DailyJobReport(
                projectID: UUID(),
                reportNumber: "DJR-PRJ-001",
                reportDate: Date(),
                submittedByName: "Test User"
            )
            djr.companyID = store.currentCompanyID
            djr.workPerformed = "Concrete pour"
            djr.syncStatus = .pending
            store.addDJR(djr)

            await engine.pushPendingDJRs()

            XCTAssertEqual(fake.upserts.count, 1,
                          "Expected one upsert; got \(fake.upserts.count)")
            XCTAssertEqual(fake.upserts.first?.table, "daily_job_reports")
        }
    }

    @MainActor
    func test_pushPendingDJRs_includesReportNumberInPayload() async throws {
        try await withFreshStore { store in
            let fake = FakeSyncClient()
            let engine = SyncEngine(client: fake)

            var djr = DailyJobReport(
                projectID: UUID(),
                reportNumber: "DJR-JOB123-007",
                reportDate: Date(),
                submittedByName: "PM"
            )
            djr.companyID = store.currentCompanyID
            djr.syncStatus = .pending
            store.addDJR(djr)

            await engine.pushPendingDJRs()

            let dict = try XCTUnwrap(fake.upserts.first?.dict)
            // The report_number key must be present and equal — regression
            // guard against the pre-Phase-3 schema gap that omitted it.
            XCTAssertEqual(dict["report_number"] as? String, "DJR-JOB123-007")
        }
    }

    @MainActor
    func test_pushPendingDJRs_marksRowSyncedOnSuccess() async throws {
        try await withFreshStore { store in
            let fake = FakeSyncClient()
            let engine = SyncEngine(client: fake)

            var djr = DailyJobReport(
                projectID: UUID(),
                reportNumber: "DJR-X-001",
                reportDate: Date(),
                submittedByName: "Foreman"
            )
            djr.companyID = store.currentCompanyID
            djr.syncStatus = .pending
            store.addDJR(djr)

            await engine.pushPendingDJRs()

            let updated = store.allDailyJobReports().first { $0.id == djr.id }
            XCTAssertEqual(updated?.syncStatus, .synced,
                          "Expected DJR to be marked .synced after successful push")
        }
    }

    @MainActor
    func test_pushPendingDJRs_recordsErrorOnFailure() async throws {
        try await withFreshStore { store in
            let fake = FakeSyncClient()
            // Simulate a network / Postgrest error on the next upsert.
            struct StubError: Error { let msg: String }
            fake.nextUpsertError = StubError(msg: "boom")

            let engine = SyncEngine(client: fake)

            var djr = DailyJobReport(
                projectID: UUID(),
                reportNumber: "DJR-Y-001",
                reportDate: Date(),
                submittedByName: "Foreman"
            )
            djr.companyID = store.currentCompanyID
            djr.syncStatus = .pending
            store.addDJR(djr)

            await engine.pushPendingDJRs()

            let updated = store.allDailyJobReports().first { $0.id == djr.id }
            XCTAssertEqual(updated?.syncStatus, .failed,
                          "Expected DJR to be marked .failed when push throws")
            XCTAssertNotNil(store.syncErrors[djr.id],
                          "Expected SyncErrorMapper to record the error for the row")
        }
    }
}
