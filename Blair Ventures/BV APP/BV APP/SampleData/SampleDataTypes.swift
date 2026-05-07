// SampleDataTypes.swift
// Aski IQ — Sample Data infrastructure types.
//
// Defines:
//   - `SampleDataTrackable` protocol every operational struct conforms to
//     (matches the 5 sample_data_* columns added by the migration).
//   - `SampleDataBatch` — metadata for a single load.
//   - `SampleDataLoadResult` — structured return from the seeder.
//   - `SampleDataError` — failure modes.
//
// The protocol is opt-in. To make a struct trackable:
//   1. Add the 5 stored properties (see comment at top of protocol).
//   2. Declare conformance: `extension Client: SampleDataTrackable {}`.
// The seeder requires conformance; the rest of the app does not.

import Foundation

// MARK: - SampleDataTrackable

/// Conformed-to by every struct that can be loaded as sample data.
///
/// Required stored properties (add to each conforming struct):
/// ```
/// var isSampleData:           Bool      = false
/// var sampleDataBatchID:      UUID?     = nil
/// var sampleDataSeedVersion:  String?   = nil
/// var sampleDataCreatedAt:    Date?     = nil
/// var sampleDataCreatedBy:    UUID?     = nil
/// ```
///
/// The seeder calls `stamp(batch:)` before persisting to populate all
/// five fields atomically. Production code never sets these.
protocol SampleDataTrackable {
    var isSampleData:           Bool    { get set }
    var sampleDataBatchID:      UUID?   { get set }
    var sampleDataSeedVersion:  String? { get set }
    var sampleDataCreatedAt:    Date?   { get set }
    var sampleDataCreatedBy:    UUID?   { get set }
}

extension SampleDataTrackable {
    /// Apply a load batch's metadata. Idempotent.
    mutating func stamp(batch: SampleDataBatch) {
        isSampleData          = true
        sampleDataBatchID     = batch.id
        sampleDataSeedVersion = batch.seedVersion
        sampleDataCreatedAt   = batch.createdAt
        sampleDataCreatedBy   = batch.createdBy
    }
}

// MARK: - SampleDataBatch

/// Metadata for a single load operation. Generated at the start of
/// `SampleDataSeeder.load()` and stamped on every record persisted
/// during that load.
struct SampleDataBatch: Hashable {
    let id:           UUID
    let seedVersion:  String
    let datasetName:  String
    let companyID:    UUID
    let createdAt:    Date
    let createdBy:    UUID
}

// MARK: - SampleDataLoadResult

/// Return value of the orchestrator. Surfaces per-module counts so the
/// admin UI can show "Loaded N clients, M projects, …" and post-load
/// QA assertions can compare against `_Manifest.expected_counts`.
struct SampleDataLoadResult {
    let batch:           SampleDataBatch
    let perModuleCounts: [String: Int]  // tab name → loaded count
    let durationSeconds: TimeInterval

    var totalRecords: Int {
        perModuleCounts.values.reduce(0, +)
    }
}

// MARK: - SampleDataError

enum SampleDataError: LocalizedError {
    case notAuthenticated
    case notAuthorized(role: String, allowed: [String])
    case datasetMissing
    case datasetUnreadable(underlying: Error)
    case manifestMissingField(String)
    case incompatibleAppVersion(required: String, current: String)
    case batchAlreadyActive(existing: UUID)
    case unresolvedReference(refKey: String, sourceTab: String)
    case foreignKeyMismatch(expectedTab: String, refKey: String)
    case relativeDateMalformed(token: String)
    case enumMismatch(field: String, value: String, allowed: [String])
    case persistenceFailed(tab: String, recordRef: String, underlying: Error)
    case resetRpcFailed(underlying: Error)
    case confirmationPhraseMismatch
    case clearedNothing  // batch_id not found in this company

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You must be signed in to load sample data."
        case let .notAuthorized(role, allowed):
            return "Role \(role) cannot load sample data. Required: \(allowed.joined(separator: " or "))."
        case .datasetMissing:
            return "Sample dataset bundle resource not found."
        case let .datasetUnreadable(e):
            return "Couldn't read sample dataset: \(e.localizedDescription)"
        case let .manifestMissingField(name):
            return "Manifest is missing required field '\(name)'."
        case let .incompatibleAppVersion(req, cur):
            return "Dataset requires app version \(req); current is \(cur)."
        case let .batchAlreadyActive(id):
            return "A sample-data batch is already loaded (id: \(id.uuidString.prefix(8)))."
        case let .unresolvedReference(key, tab):
            return "Reference '\(key)' in tab '\(tab)' did not resolve to any other row's __ref."
        case let .foreignKeyMismatch(tab, key):
            return "FK '\(key)' should resolve to a row in tab '\(tab)'."
        case let .relativeDateMalformed(token):
            return "Date token '\(token)' is malformed. Expected T-N, T+N, T0, or ISO 8601."
        case let .enumMismatch(field, value, allowed):
            return "Field '\(field)' value '\(value)' not in allowed set: \(allowed.joined(separator: ", "))."
        case let .persistenceFailed(tab, ref, e):
            return "Failed to persist '\(ref)' in '\(tab)': \(e.localizedDescription)"
        case let .resetRpcFailed(e):
            return "Reset RPC failed: \(e.localizedDescription)"
        case .confirmationPhraseMismatch:
            return "Confirmation phrase must be exactly 'DELETE SAMPLE DATA'."
        case .clearedNothing:
            return "No sample data found for this batch in the current company."
        }
    }
}

// MARK: - Active batch tracking

/// Where the currently-loaded batch ID is persisted on the device.
/// Stored per (companyID) so switching tenants doesn't conflate state.
/// Lives in UserDefaults for now — graduates to a database column when
/// multi-device tracking matters.
enum SampleDataActiveBatch {

    private static func key(for companyID: UUID) -> String {
        "aski.sample_active_batch.\(companyID.uuidString)"
    }

    static func get(companyID: UUID) -> UUID? {
        guard let s = UserDefaults.standard.string(forKey: key(for: companyID)) else { return nil }
        return UUID(uuidString: s)
    }

    static func set(_ batchID: UUID, companyID: UUID) {
        UserDefaults.standard.set(batchID.uuidString, forKey: key(for: companyID))
    }

    static func clear(companyID: UUID) {
        UserDefaults.standard.removeObject(forKey: key(for: companyID))
    }
}
