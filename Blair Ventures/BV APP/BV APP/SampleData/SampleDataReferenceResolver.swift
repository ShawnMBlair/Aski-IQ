// SampleDataReferenceResolver.swift
// Aski IQ — Maps spreadsheet __ref strings to runtime UUIDs.
//
// Each row in the workbook has a stable `__ref` text key. FK columns
// suffixed `_ref` carry that key (not a UUID), so the workbook can be
// edited safely by humans without juggling UUIDs.
//
// At load time the seeder generates a fresh UUID for each row and
// registers it with the resolver. Subsequent FK lookups go through
// `uuid(for:)` to map __ref → UUID.

import Foundation

@MainActor
final class SampleDataReferenceResolver {

    private var refToUUID: [String: UUID] = [:]
    /// Reverse map for diagnostics ("which __ref does this UUID belong to?").
    private var uuidToRef: [UUID: String] = [:]
    /// Track which tab a __ref was registered from. Used for FK type
    /// validation (e.g., a `clientID_ref` should resolve to a Clients row).
    private var refToTab: [String: String] = [:]

    /// Register a freshly-minted UUID for a row.
    func register(refKey: String, uuid: UUID, tab: String) {
        refToUUID[refKey] = uuid
        uuidToRef[uuid]   = refKey
        refToTab[refKey]  = tab
    }

    /// Look up the UUID for a __ref string. Returns nil if not registered
    /// — callers should treat that as `unresolvedReference` error.
    func uuid(for refKey: String?) -> UUID? {
        guard let key = refKey, !key.isEmpty else { return nil }
        return refToUUID[key]
    }

    /// Same as `uuid(for:)` but throws when missing — the common case
    /// in seeders that assert FK integrity.
    func requireUUID(for refKey: String, sourceTab: String) throws -> UUID {
        guard let id = refToUUID[refKey] else {
            throw SampleDataError.unresolvedReference(refKey: refKey, sourceTab: sourceTab)
        }
        return id
    }

    /// Resolve a list of __refs (used for `memberIDs_refs` and similar).
    func uuids(for refKeys: [String]) -> [UUID] {
        refKeys.compactMap { refToUUID[$0] }
    }

    /// Diagnostic: which tab did this __ref come from?
    func tab(for refKey: String) -> String? { refToTab[refKey] }

    /// Total registered count — used by post-load assertions.
    var registeredCount: Int { refToUUID.count }
}
