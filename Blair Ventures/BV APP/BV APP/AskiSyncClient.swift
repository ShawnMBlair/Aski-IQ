// AskiSyncClient.swift
// Phase 5 / Wave 2 — Sync push/pull abstraction.
//
// Why this exists:
//   SyncEngine references a single global `supabase` SupabaseClient
//   through a fluent chain: supabase.from(t).select().eq().execute().
//   The chain is fine for production but impossible to drive from
//   tests — there's no seam to swap out network IO. Phase 5 / Wave 1
//   shipped pure-Swift unit tests for SyncErrorMapper + number
//   generation; sync push/pull stayed untestable.
//
// What this is:
//   A narrow intent-shaped protocol that describes the surface
//   SyncEngine actually needs from a backing data store: upsert one
//   payload into a table, fetch decoded rows from a table with a small
//   set of filters. Everything else (delete, update, rpc, range, in,
//   realtime) can grow onto the protocol when a migrating push/pull
//   function needs it — no need to model it preemptively.
//
//   Two implementations:
//     - LiveSyncClient        wraps the real supabase global so prod
//                             behavior is byte-identical to today.
//     - (test only) FakeSyncClient lives in BV APP Tests and records
//                             calls / serves canned rows for assertions.
//
// Migration strategy (from SyncEngine direct supabase.from(...) calls):
//   1. SyncEngine gains an injectable `client: AskiSyncClient` that
//      defaults to LiveSyncClient(supabase). Production constructs it
//      with no args and gets the live impl.
//   2. Push/pull functions migrate one at a time from the fluent chain
//      to the intent-shaped methods. Each migration is a small commit
//      so behavior changes are easy to bisect.
//   3. Tests inject a FakeSyncClient and assert on the recorded calls.
//
// This file ships ONLY the protocol + the live wrapper. The first
// migrated function (pushPendingDJRs) lands in the same commit as
// proof; the rest follow incrementally.

import Foundation
import Supabase

// MARK: - Protocol

/// Narrow data-client abstraction Aski's SyncEngine speaks to. All
/// methods are async-throwing — failure cases match the underlying
/// Postgrest error shape so SyncErrorMapper continues to work
/// unchanged across both impls.
protocol AskiSyncClient: Sendable {

    /// Upsert one payload into a table. Equivalent to:
    ///   supabase.from(table).upsert(payload).execute()
    /// Accepts any Encodable so both dict-style payloads
    /// ([String: AnyJSON]) and typed Codable Row structs work without
    /// per-call-site conversion. Sendable is intentionally NOT required
    /// — many push functions construct their Row struct inside a
    /// @MainActor-isolated function, which makes the conformance
    /// MainActor-isolated rather than Sendable. The payload is consumed
    /// inside the same task that creates it, so cross-actor transfer
    /// concerns don't apply.
    func upsert<T: Encodable>(_ payload: T, into table: String) async throws

    /// Select rows from a table with optional column projection +
    /// filters + ordering + limit, decoding into T. Equivalent to:
    ///   supabase.from(table).select(columns).eq(...).in(...)
    ///     .order(orderBy, ascending: ...).limit(limit).execute().value
    /// Pass `columns = "*"` for the default full-row select; provide a
    /// comma-separated subset (e.g. "id,company_id,exception_type") to
    /// reduce row size on large tables. `orderBy = nil` for unordered;
    /// `limit = nil` for no explicit cap.
    func select<T: Decodable>(
        _ type: T.Type,
        from table: String,
        columns: String,
        filters: [SyncFilter],
        orderBy: String?,
        ascending: Bool,
        limit: Int?
    ) async throws -> [T]
}

extension AskiSyncClient {
    /// Convenience overload — full-row, filters only.
    func select<T: Decodable>(
        _ type: T.Type,
        from table: String,
        filters: [SyncFilter]
    ) async throws -> [T] {
        try await select(type, from: table, columns: "*", filters: filters,
                         orderBy: nil, ascending: true, limit: nil)
    }

    /// Convenience overload — full-row, filters + ordering.
    func select<T: Decodable>(
        _ type: T.Type,
        from table: String,
        filters: [SyncFilter],
        orderBy: String,
        ascending: Bool = true
    ) async throws -> [T] {
        try await select(type, from: table, columns: "*", filters: filters,
                         orderBy: orderBy, ascending: ascending, limit: nil)
    }

    /// Convenience overload — full-row, filters + limit.
    func select<T: Decodable>(
        _ type: T.Type,
        from table: String,
        filters: [SyncFilter],
        limit: Int
    ) async throws -> [T] {
        try await select(type, from: table, columns: "*", filters: filters,
                         orderBy: nil, ascending: true, limit: limit)
    }

    /// Convenience overload — full-row, filters + ordering + limit.
    func select<T: Decodable>(
        _ type: T.Type,
        from table: String,
        filters: [SyncFilter],
        orderBy: String?,
        ascending: Bool,
        limit: Int?
    ) async throws -> [T] {
        try await select(type, from: table, columns: "*", filters: filters,
                         orderBy: orderBy, ascending: ascending, limit: limit)
    }
}

// MARK: - Filter shape

/// A single column predicate. Mirrors the subset of Postgrest filter
/// operators SyncEngine uses today; grow as needed.
struct SyncFilter: Sendable, Equatable {
    let column: String
    let op: Op
    /// Single-value carrier (eq, neq). Empty for multi-value ops.
    let value: String
    /// Multi-value carrier (in_). Empty for single-value ops.
    let values: [String]

    enum Op: Sendable {
        case eq
        case neq
        case in_
    }

    static func eq(_ column: String, _ value: String) -> SyncFilter {
        .init(column: column, op: .eq, value: value, values: [])
    }
    static func eq(_ column: String, _ value: Bool) -> SyncFilter {
        .init(column: column, op: .eq, value: value ? "true" : "false", values: [])
    }
    static func neq(_ column: String, _ value: String) -> SyncFilter {
        .init(column: column, op: .neq, value: value, values: [])
    }
    /// Match where `column` is in the provided value list. Maps to
    /// Postgrest's `.in("col", values: [...])` call.
    static func in_(_ column: String, _ values: [String]) -> SyncFilter {
        .init(column: column, op: .in_, value: "", values: values)
    }
}

// MARK: - Live (production) impl

/// Production implementation that delegates straight to the existing
/// global `supabase` SupabaseClient. Behavior is byte-identical to the
/// pre-Phase-5 fluent calls.
struct LiveSyncClient: AskiSyncClient {

    let client: SupabaseClient

    init(_ client: SupabaseClient = supabase) {
        self.client = client
    }

    func upsert<T: Encodable>(_ payload: T, into table: String) async throws {
        try await client.from(table).upsert(payload).execute()
    }

    func select<T: Decodable>(
        _ type: T.Type,
        from table: String,
        columns: String,
        filters: [SyncFilter],
        orderBy: String?,
        ascending: Bool,
        limit: Int?
    ) async throws -> [T] {
        var query = client.from(table).select(columns)
        for filter in filters {
            switch filter.op {
            case .eq:  query = query.eq(filter.column, value: filter.value)
            case .neq: query = query.neq(filter.column, value: filter.value)
            case .in_: query = query.in(filter.column, values: filter.values)
            }
        }
        // Postgrest's fluent chain returns different transformed-builder
        // types from .order / .limit, so we narrow via local var rebinds.
        if let orderBy {
            let ordered = query.order(orderBy, ascending: ascending)
            if let limit {
                return try await ordered.limit(limit).execute().value
            }
            return try await ordered.execute().value
        }
        if let limit {
            return try await query.limit(limit).execute().value
        }
        return try await query.execute().value
    }
}
