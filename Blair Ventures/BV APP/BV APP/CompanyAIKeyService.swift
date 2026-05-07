// CompanyAIKeyService.swift
// Aski IQ — Per-company Anthropic API key management.
//
// WHY THIS EXISTS
// Each company brings their own Anthropic API key. The key lives in
// `companies.anthropic_api_key` (server-side), with column-level GRANTs
// preventing direct SELECT from any client. Reads/writes go through
// SECURITY DEFINER RPCs that enforce admin role + tenant scope.
//
// SHAPE
// We never read the raw key on the client. Instead the status RPC
// returns metadata only — `is_set`, when, by whom — which is enough for
// the Settings UI to show "Configured" / "Not configured" without ever
// exposing the value.
//
// The setter accepts the raw key, validates it server-side (must start
// with `sk-ant-`), and updates the row. Passing an empty string clears
// the key (handy for revocation).
//
// USAGE
//   let status = try await CompanyAIKeyService.shared.fetchStatus()
//   if status.isSet { /* "✓ Configured by Alice on 2026-04-29" */ }
//
//   try await CompanyAIKeyService.shared.set(key: pastedKey)
//   try await CompanyAIKeyService.shared.clear()

import Foundation
import Supabase

@MainActor
final class CompanyAIKeyService {

    static let shared = CompanyAIKeyService()
    private init() {}

    /// Status snapshot returned by the RPC. The raw key is intentionally
    /// absent — there is no Swift code path that reads it.
    struct Status: Decodable {
        let isSet: Bool
        let updatedAt: Date?
        let updatedByName: String?

        enum CodingKeys: String, CodingKey {
            case isSet           = "is_set"
            case updatedAt       = "updated_at"
            case updatedByName   = "updated_by_name"
        }

        /// Display-friendly summary like "Configured by Alice · 2 days ago"
        /// or "Not configured — using shared trial key".
        func summary(globalFallbackAvailable: Bool) -> String {
            if isSet {
                let by = (updatedByName?.isEmpty == false ? "by \(updatedByName!) " : "")
                if let when = updatedAt {
                    return "Configured \(by)· \(Self.relativeFormatter.localizedString(for: when, relativeTo: Date()))"
                }
                return "Configured \(by)".trimmingCharacters(in: .whitespaces)
            }
            return globalFallbackAvailable
                ? "Not set — using the shared trial key"
                : "Not set — AI features unavailable for your company"
        }

        private static let relativeFormatter: RelativeDateTimeFormatter = {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .abbreviated
            return f
        }()
    }

    enum KeyError: Error, LocalizedError {
        case notAdmin
        case invalidShape
        case notSignedIn
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .notAdmin:        return "Only company admins can change the AI key."
            case .invalidShape:    return "That doesn't look like an Anthropic key (expected to start with sk-ant-)."
            case .notSignedIn:     return "Sign in before changing the AI key."
            case .underlying(let e): return e.localizedDescription
            }
        }
    }

    /// Returns `(is_set, updated_at, updated_by_name)` for the caller's
    /// company. Any signed-in tenant member can call this; only admins
    /// can change the value.
    func fetchStatus() async throws -> Status {
        do {
            // Postgres `RETURNS TABLE(...)` round-trips as an array of
            // single-row objects, so decode as `[Status]` and take first.
            let rows: [Status] = try await supabase
                .rpc("get_company_ai_key_status")
                .execute()
                .value
            return rows.first ?? Status(isSet: false, updatedAt: nil, updatedByName: nil)
        } catch {
            throw KeyError.underlying(error)
        }
    }

    /// Updates the company's Anthropic API key. Caller must be owner /
    /// executive / manager / officeAdmin (enforced server-side). Passing
    /// an empty / whitespace-only string clears the key — handy for
    /// revocation when the upstream key is rotated.
    func set(key rawKey: String) async throws {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // Quick client-side sanity gate before round-tripping. The server
        // re-validates so this isn't security, just UX.
        if !trimmed.isEmpty && !trimmed.hasPrefix("sk-ant-") {
            throw KeyError.invalidShape
        }

        struct Params: Encodable { let p_key: String }
        do {
            try await supabase
                .rpc("set_company_ai_key", params: Params(p_key: trimmed))
                .execute()
        } catch {
            // Map the server's ERRCODE 42501 to a typed error so the UI
            // can show "Only admins can change the key" cleanly.
            let msg = error.localizedDescription.lowercased()
            if msg.contains("only company admins") || msg.contains("42501") {
                throw KeyError.notAdmin
            }
            if msg.contains("does not look like an anthropic api key") {
                throw KeyError.invalidShape
            }
            throw KeyError.underlying(error)
        }
    }

    /// Convenience: clear the key (same as `set(key:"")`).
    func clear() async throws {
        try await set(key: "")
    }
}
