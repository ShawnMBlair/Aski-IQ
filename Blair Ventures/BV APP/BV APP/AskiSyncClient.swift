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

    /// Select rows from a table with optional filters + ordering, decoding
    /// into T. Equivalent to:
    ///   supabase.from(table).select().eq(...).eq(...).order(orderBy)
    ///     .execute().value
    /// Pass `orderBy = nil` for unordered queries.
    func select<T: Decodable>(
        _ type: T.Type,
        from table: String,
        filters: [SyncFilter],
        orderBy: String?,
        ascending: Bool
    ) async throws -> [T]
}

extension AskiSyncClient {
    /// Convenience overload for the most common case — filters only,
    /// no explicit ordering.
    func select<T: Decodable>(
        _ type: T.Type,
        from table: String,
        filters: [SyncFilter]
    ) async throws -> [T] {
        try await select(type, from: table, filters: filters, orderBy: nil, ascending: true)
    }
}

// MARK: - Filter shape

/// A single column predicate. Mirrors the subset of Postgrest filter
/// operators SyncEngine uses today; grow as needed.
struct SyncFilter: Sendable {
    let column: String
    let op: Op
    let value: String

    enum Op: Sendable {
        case eq
        case neq
    }

    static func eq(_ column: String, _ value: String) -> SyncFilter {
        .init(column: column, op: .eq, value: value)
    }
    static func eq(_ column: String, _ value: Bool) -> SyncFilter {
        .init(column: column, op: .eq, value: value ? "true" : "false")
    }
    static func neq(_ column: String, _ value: String) -> SyncFilter {
        .init(column: column, op: .neq, value: value)
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
        filters: [SyncFilter],
        orderBy: String?,
        ascending: Bool
    ) async throws -> [T] {
        var query = client.from(table).select()
        for filter in filters {
            switch filter.op {
            case .eq:  query = query.eq(filter.column, value: filter.value)
            case .neq: query = query.neq(filter.column, value: filter.value)
            }
        }
        if let orderBy {
            return try await query.order(orderBy, ascending: ascending).execute().value
        }
        return try await query.execute().value
    }
}
