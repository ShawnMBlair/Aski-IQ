// FakeSyncClient.swift
// Phase 5 / Wave 2 — In-memory test double for AskiSyncClient.
//
// Records every upsert call into an array tests can assert on, and
// serves canned select results from a table-keyed dictionary tests
// pre-populate. Methods are async-throwing to match the protocol.
// Tests can configure `nextUpsertError` / `nextSelectError` to drive
// failure-path coverage without spinning up a real Postgrest server.

#if canImport(XCTest)
import Foundation
@testable import BV_APP
import Supabase

final class FakeSyncClient: AskiSyncClient {

    // MARK: Recorded calls

    /// Every upsert call, in order. Tests inspect this to assert on
    /// payload shape (which keys + values pushed) and table routing.
    struct UpsertCall: Equatable {
        let table: String
        let payload: [String: AnyJSON]
    }
    private(set) var upserts: [UpsertCall] = []

    /// Every select call, in order. Tests inspect this when the
    /// behavior under test should issue particular queries.
    struct SelectCall: Equatable {
        let table: String
        let filters: [SyncFilter]
    }
    private(set) var selects: [SelectCall] = []

    // MARK: Canned responses + errors

    /// Pre-populated rows the next select on a given table will return.
    /// Tests set `cannedSelect[SupabaseTable.dailyJobReports] = [row1]`
    /// before exercising a pull path, and the fake hands them back.
    var cannedSelect: [String: [Any]] = [:]

    /// If non-nil, the next upsert call throws this error and clears
    /// the slot. Used to drive SyncErrorMapper coverage.
    var nextUpsertError: Error? = nil

    /// If non-nil, the next select call throws this error and clears
    /// the slot.
    var nextSelectError: Error? = nil

    // MARK: AskiSyncClient

    func upsert(_ payload: [String: AnyJSON], into table: String) async throws {
        if let err = nextUpsertError {
            nextUpsertError = nil
            throw err
        }
        upserts.append(.init(table: table, payload: payload))
    }

    func select<T: Decodable>(
        _ type: T.Type,
        from table: String,
        filters: [SyncFilter]
    ) async throws -> [T] {
        if let err = nextSelectError {
            nextSelectError = nil
            throw err
        }
        selects.append(.init(table: table, filters: filters))
        guard let canned = cannedSelect[table] else { return [] }
        return canned.compactMap { $0 as? T }
    }
}

// MARK: - SyncFilter Equatable

extension SyncFilter: Equatable {
    static func == (a: SyncFilter, b: SyncFilter) -> Bool {
        a.column == b.column && a.value == b.value && a.op == b.op
    }
}

extension SyncFilter.Op: Equatable {}

#endif
