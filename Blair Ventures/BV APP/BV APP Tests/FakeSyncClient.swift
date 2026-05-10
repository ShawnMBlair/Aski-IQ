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
    /// The original Encodable payload is captured both as the source
    /// `Any` and as a normalized JSON-decoded `[String: Any]` so tests
    /// can do dict-style assertions regardless of whether the caller
    /// passed a typed struct or a dictionary.
    struct UpsertCall {
        let table: String
        let original: Any
        let dict: [String: Any]
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

    func upsert<T: Encodable>(_ payload: T, into table: String) async throws {
        if let err = nextUpsertError {
            nextUpsertError = nil
            throw err
        }
        // Encode → decode round-trip so tests can dict-inspect any
        // typed Row struct uniformly. This is fast for the small
        // payload shapes SyncEngine pushes (a few dozen keys).
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let json = try JSONSerialization.jsonObject(with: data)
        let dict = (json as? [String: Any]) ?? [:]
        upserts.append(.init(table: table, original: payload, dict: dict))
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
