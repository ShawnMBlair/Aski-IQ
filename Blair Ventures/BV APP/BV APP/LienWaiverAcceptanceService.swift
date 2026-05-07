// LienWaiverAcceptanceService.swift
// Aski IQ — Mint + revoke + status for lien waiver sign-off magic links.
//
// PAIRS WITH
// * Migration `contracts_phase2c_lien_waiver_signoff_rpcs` (server-
//   side RPCs that operate on the existing token columns on
//   `lien_waivers`).
// * Edge Function `lien-waiver-sign` (verify_jwt:false, public landing
//   page with prominent risk language).
//
// USE CASE
// Admin opens a lien waiver, picks "Send for digital signature" — we
// mint a token + URL, share via email/SMS. Sub clicks, sees the
// waiver terms with explicit explanation of what they're waiving,
// signs. The waiver atomically flips to status='received' with
// signature data captured for audit.
//
// MIRRORS QuoteAcceptanceService + ContractAcceptanceService — same
// surface area, third instance of the magic-link pattern. Each has
// different downstream effects:
//   Quote     → opportunity .won
//   Contract  → contract executed, status .active
//   Waiver    → waiver received, status .received

import Foundation
import Supabase

@MainActor
final class LienWaiverAcceptanceService {

    static let shared = LienWaiverAcceptanceService()
    private init() {}

    // MARK: - Models

    struct MintResult {
        let token:     String
        let expiresAt: Date
        let url:       URL
    }

    struct SignStatus: Decodable {
        let hasToken:        Bool
        let expiresAt:       Date?
        let sentAt:          Date?
        let signedAt:        Date?
        let signedByName:    String?
        let signedByEmail:   String?
        let revokedAt:       Date?

        enum CodingKeys: String, CodingKey {
            case hasToken          = "has_token"
            case expiresAt         = "expires_at"
            case sentAt            = "sent_at"
            case signedAt          = "signed_at"
            case signedByName      = "signed_by_name"
            case signedByEmail     = "signed_by_email"
            case revokedAt         = "revoked_at"
        }

        var displaySummary: String {
            if let signedAt {
                let by = signedByName ?? signedByEmail ?? "signer"
                let f = DateFormatter(); f.dateStyle = .medium
                return "Signed by \(by) · \(f.string(from: signedAt))"
            }
            if revokedAt != nil { return "Sign-off link revoked" }
            if let expiresAt {
                if expiresAt < Date() { return "Sign-off link expired" }
                let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
                return "Awaiting signature · expires \(f.localizedString(for: expiresAt, relativeTo: Date()))"
            }
            return "Awaiting signature"
        }
    }

    enum AcceptanceError: Error, LocalizedError {
        case notAdmin
        case waiverNotFound
        case alreadySigned
        case underlying(Error)
        var errorDescription: String? {
            switch self {
            case .notAdmin:        return "Only company admins can mint or revoke sign-off links."
            case .waiverNotFound:  return "Lien waiver not found in your company."
            case .alreadySigned:   return "This waiver has already been signed."
            case .underlying(let e): return e.localizedDescription
            }
        }
    }

    // MARK: - Mint

    /// Mints a fresh sign-off token for the waiver. Server-side already
    /// revokes any prior live token, so calling this twice in a row is
    /// safe — only the latest URL works.
    func mintToken(waiverID: UUID, validityDays: Int = 30) async throws -> MintResult {
        struct MintParams: Encodable {
            let p_waiver_id:     UUID
            let p_validity_days: Int
        }
        struct MintRow: Decodable {
            let token:      String
            let expires_at: Date
        }
        do {
            let rows: [MintRow] = try await supabase
                .rpc("mint_lien_waiver_token",
                     params: MintParams(p_waiver_id: waiverID, p_validity_days: validityDays))
                .execute()
                .value
            guard let row = rows.first else { throw AcceptanceError.waiverNotFound }

            // Build the public URL.
            var comps = URLComponents(
                url: supabaseFunctionsBaseURL.appendingPathComponent("lien-waiver-sign"),
                resolvingAgainstBaseURL: false
            )
            comps?.queryItems = [URLQueryItem(name: "token", value: row.token)]
            guard let url = comps?.url else {
                throw AcceptanceError.underlying(NSError(
                    domain: "LienWaiverAcceptance", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Couldn't build signing URL"]
                ))
            }
            return MintResult(token: row.token, expiresAt: row.expires_at, url: url)
        } catch let e as AcceptanceError {
            throw e
        } catch {
            let m = error.localizedDescription.lowercased()
            if m.contains("admin role required") || m.contains("42501") {
                throw AcceptanceError.notAdmin
            }
            if m.contains("already been signed") {
                throw AcceptanceError.alreadySigned
            }
            if m.contains("not found") {
                throw AcceptanceError.waiverNotFound
            }
            throw AcceptanceError.underlying(error)
        }
    }

    // MARK: - Revoke / status

    func revoke(waiverID: UUID) async throws {
        struct Params: Encodable { let p_waiver_id: UUID }
        do {
            try await supabase
                .rpc("revoke_lien_waiver_token", params: Params(p_waiver_id: waiverID))
                .execute()
        } catch {
            let m = error.localizedDescription.lowercased()
            if m.contains("admin role required") || m.contains("42501") {
                throw AcceptanceError.notAdmin
            }
            throw AcceptanceError.underlying(error)
        }
    }

    func fetchStatus(waiverID: UUID) async throws -> SignStatus? {
        struct Params: Encodable { let p_waiver_id: UUID }
        do {
            let rows: [SignStatus] = try await supabase
                .rpc("get_lien_waiver_sign_status", params: Params(p_waiver_id: waiverID))
                .execute()
                .value
            return rows.first
        } catch {
            throw AcceptanceError.underlying(error)
        }
    }
}
