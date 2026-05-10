// SyncErrorMapper.swift
// Aski IQ — Phase 2 stabilization: maps push-error exceptions into a
// user-facing reason so the Failed Syncs screen can show what actually
// went wrong instead of a generic "RLS or FK violation."
//
// CONTRACT
//   Static-only. Pure mapping. No network, no state, no logging side
//   effects (that's CrashReporter's job in the catch site that calls us).
//
// MAPPING APPROACH
//   Supabase Swift SDK's error type can vary (PostgrestError, URLError,
//   plain Error wrapped from the underlying transport). Rather than
//   pattern-match on concrete types — which couples this file to a
//   specific SDK version — we extract a SQLSTATE-shaped code and a
//   human-readable summary by inspecting the error's textual form.
//   PostgREST embeds the SQLSTATE in its JSON body which Supabase
//   surfaces via localizedDescription / String(describing:) on the
//   thrown error.
//
// COVERAGE
//   23502  null value in column ...                  → missing-required
//   23503  foreign key violation                     → linked-record-missing
//   23505  duplicate key value                       → duplicate-number
//   42501  insufficient privilege / RLS              → permission
//   42703  column does not exist                     → schema-cache
//   23514  check constraint                          → invalid-combo
//   "PGRST301" / "JWT"                              → auth
//   network / URLError                               → connectivity
//   anything else                                    → generic fallback
//
//   Special-cased substrings for common Aski IQ failures:
//   - opportunity_id null                            → unlinked-opportunity
//   - destination_type / single_destination_check    → invalid-destination

import Foundation

struct SyncErrorInfo: Equatable {
    /// SQLSTATE code or "" for non-Postgres errors. Show to users
    /// alongside the reason for support handoff.
    let code: String
    /// Plain-English explanation of what went wrong + recommended action.
    let reason: String
    /// Full error string. Hidden by default in the UI; surfaced via
    /// Copy Code so users can paste into support tickets.
    let rawMessage: String
    /// When the failure was captured. Used by the UI to show "failed
    /// 3 minutes ago" if multiple retries have happened.
    let timestamp: Date

    init(code: String, reason: String, rawMessage: String, timestamp: Date = Date()) {
        self.code        = code
        self.reason      = reason
        self.rawMessage  = rawMessage
        self.timestamp   = timestamp
    }
}

enum SyncErrorMapper {

    /// Map any thrown error from a sync push into a user-facing
    /// SyncErrorInfo. Designed to never throw or return nil — the
    /// Failed Syncs UI always gets *something* to show.
    static func info(for error: Error) -> SyncErrorInfo {
        let raw = String(describing: error)
        let localized = error.localizedDescription
        let combined = (raw + " " + localized).lowercased()

        // 1) Aski IQ–specific high-value patterns first (more specific
        // than the generic SQLSTATE map).

        if combined.contains("opportunity_id") && combined.contains("null") {
            return SyncErrorInfo(
                code: "23502",
                reason: "This record needs an opportunity link. Open it and pick or create one before retrying.",
                rawMessage: raw
            )
        }

        if combined.contains("material_requests_single_destination_check")
            || combined.contains("destination_type") && combined.contains("check") {
            return SyncErrorInfo(
                code: "23514",
                reason: "The destination doesn't match — pick exactly one of Project / Material Sale / Internal.",
                rawMessage: raw
            )
        }

        if combined.contains("material_requests_company_request_number_unique")
            || combined.contains("purchase_orders_company_po_number_unique") {
            return SyncErrorInfo(
                code: "23505",
                reason: "This number is already in use. The sync engine will retry with the next available number.",
                rawMessage: raw
            )
        }

        // 2) Generic SQLSTATE-shaped codes.

        if let code = extractSQLState(from: combined) {
            switch code {
            case "23502":
                return SyncErrorInfo(
                    code: code,
                    reason: "Missing required field. Open the record and check for blank required values.",
                    rawMessage: raw
                )
            case "23503":
                return SyncErrorInfo(
                    code: code,
                    reason: "A linked record hasn't synced to the server yet. Pull latest data and try again.",
                    rawMessage: raw
                )
            case "23505":
                return SyncErrorInfo(
                    code: code,
                    reason: "Duplicate value — this record conflicts with one already on the server.",
                    rawMessage: raw
                )
            case "23514":
                return SyncErrorInfo(
                    code: code,
                    reason: "A field combination isn't valid. Open the record and check the highlighted values.",
                    rawMessage: raw
                )
            case "42501":
                return SyncErrorInfo(
                    code: code,
                    reason: "You don't have permission for this action. Check with your admin.",
                    rawMessage: raw
                )
            case "42703":
                return SyncErrorInfo(
                    code: code,
                    reason: "The server's schema is out of sync. Wait 60 s and try again — the cache is refreshing.",
                    rawMessage: raw
                )
            default:
                return SyncErrorInfo(
                    code: code,
                    reason: "Sync failed (\(code)). Tap Copy Code and send to support.",
                    rawMessage: raw
                )
            }
        }

        // 3) Auth / token issues.
        if combined.contains("jwt") || combined.contains("pgrst301")
            || combined.contains("token") && combined.contains("expired") {
            return SyncErrorInfo(
                code: "AUTH",
                reason: "Your session expired. Sign out and back in, then retry.",
                rawMessage: raw
            )
        }

        // 4) Connectivity issues.
        if combined.contains("network") || combined.contains("offline")
            || combined.contains("could not connect") || combined.contains("timed out")
            || combined.contains("urlerror") {
            return SyncErrorInfo(
                code: "OFFLINE",
                reason: "Network issue — check connection and retry.",
                rawMessage: raw
            )
        }

        // 5) Final fallback. Surface localizedDescription as the reason
        // when it's reasonably short; otherwise generic copy. Operators
        // can always Copy Code for the full string.
        let trimmedLocalized = localized.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLocalized.isEmpty && trimmedLocalized.count < 160 {
            return SyncErrorInfo(
                code: "",
                reason: trimmedLocalized,
                rawMessage: raw
            )
        }

        return SyncErrorInfo(
            code: "",
            reason: "Sync failed. Tap Copy Code and send to support.",
            rawMessage: raw
        )
    }

    // MARK: - AppStore integration helpers
    //
    // Sync push catch blocks call `store.recordSyncError(id:error:)`
    // alongside the existing `syncStatus = .failed` assignment. Successful
    // retries call `store.clearSyncError(id:)`. The dictionary is the
    // source of truth that FailedSyncDetailView reads.

    /// Pull a 5-character SQLSTATE code (e.g. "23502") out of an error
    /// string. Postgres / PostgREST surface them in several forms:
    /// "code: 23502", "(SQLSTATE 23502)", "\"code\":\"23502\"".
    /// The regex tolerates all three.
    private static func extractSQLState(from text: String) -> String? {
        let patterns = [
            #""code"\s*:\s*"([0-9a-z]{5})""#,
            #"sqlstate\s+([0-9a-z]{5})"#,
            #"code:\s*([0-9a-z]{5})"#,
        ]
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression),
               let captured = text[range].range(of: "[0-9a-z]{5}", options: .regularExpression) {
                return String(text[captured]).uppercased()
            }
        }
        return nil
    }
}

// MARK: - AppStore convenience

extension AppStore {

    /// Record an error captured in a sync push catch block. Stores the
    /// mapped SyncErrorInfo against the entity's id so the Failed Syncs
    /// screen can show the per-row reason. The dictionary mutation
    /// fires the `@Published` change automatically — observing views
    /// re-render without an explicit objectWillChange.send().
    @MainActor
    func recordSyncError(id: UUID, error: Error) {
        syncErrors[id] = SyncErrorMapper.info(for: error)
    }

    /// Clear a previously-recorded error after a successful retry / discard.
    /// Idempotent — a no-op if no entry exists.
    @MainActor
    func clearSyncError(id: UUID) {
        syncErrors.removeValue(forKey: id)
    }
}

