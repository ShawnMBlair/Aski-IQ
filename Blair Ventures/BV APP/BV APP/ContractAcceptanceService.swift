// ContractAcceptanceService.swift
// Aski IQ — Mint + revoke + status for contract sign-off magic links.
//
// PAIRS WITH
// * Migration `contract_acceptance_tokens` (server-side table + RPCs)
// * Edge Function `contract-accept` (verify_jwt:false, public landing)
//
// USE CASE
// Sub or supplier needs to digitally sign their contract. Admin opens
// the contract, picks "Send for digital signature" — we mint a token,
// embed the URL in the email, sub clicks → public HTML page with the
// contract summary + signature pad. On submit, the contract flips to
// `executed_date = today, status = active` atomically.
//
// MIRRORS QuoteAcceptanceService — same surface area, different
// downstream effects (contract execution vs opportunity won).

import Foundation
import Supabase

@MainActor
final class ContractAcceptanceService {

    static let shared = ContractAcceptanceService()
    private init() {}

    // MARK: - Models

    struct MintResult {
        let token:     String
        let expiresAt: Date
        let url:       URL
    }

    struct AcceptanceStatus: Decodable {
        let hasToken:        Bool
        let expiresAt:       Date?
        let acceptedAt:      Date?
        let acceptedByName:  String?
        let acceptedByEmail: String?
        let revokedAt:       Date?

        enum CodingKeys: String, CodingKey {
            case hasToken          = "has_token"
            case expiresAt         = "expires_at"
            case acceptedAt        = "accepted_at"
            case acceptedByName    = "accepted_by_name"
            case acceptedByEmail   = "accepted_by_email"
            case revokedAt         = "revoked_at"
        }

        var displaySummary: String {
            if let acceptedAt = acceptedAt {
                let by = acceptedByName ?? acceptedByEmail ?? "counterparty"
                let f = DateFormatter(); f.dateStyle = .medium
                return "Signed by \(by) · \(f.string(from: acceptedAt))"
            }
            if revokedAt != nil { return "Sign-off link revoked" }
            if let expiresAt = expiresAt {
                if expiresAt < Date() { return "Sign-off link expired" }
                let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
                return "Awaiting signature · expires \(f.localizedString(for: expiresAt, relativeTo: Date()))"
            }
            return "Awaiting signature"
        }
    }

    enum AcceptanceError: Error, LocalizedError {
        case notAdmin
        case contractNotFound
        case underlying(Error)
        var errorDescription: String? {
            switch self {
            case .notAdmin:           return "Only company admins can mint or revoke sign-off links."
            case .contractNotFound:   return "Contract not found in your company."
            case .underlying(let e):  return e.localizedDescription
            }
        }
    }

    // MARK: - Mint

    func mintToken(contractID: UUID, validityDays: Int = 30) async throws -> MintResult {
        struct MintParams: Encodable {
            let p_contract_id:   UUID
            let p_validity_days: Int
        }
        struct MintRow: Decodable {
            let token:      String
            let expires_at: Date
        }
        do {
            let rows: [MintRow] = try await supabase
                .rpc("mint_contract_acceptance_token",
                     params: MintParams(p_contract_id: contractID, p_validity_days: validityDays))
                .execute()
                .value
            guard let row = rows.first else { throw AcceptanceError.contractNotFound }
            var comps = URLComponents(
                url: supabaseFunctionsBaseURL.appendingPathComponent("contract-accept"),
                resolvingAgainstBaseURL: false
            )
            comps?.queryItems = [URLQueryItem(name: "token", value: row.token)]
            guard let url = comps?.url else {
                throw AcceptanceError.underlying(NSError(
                    domain: "ContractAcceptance", code: 1,
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
            if m.contains("contract not found") {
                throw AcceptanceError.contractNotFound
            }
            throw AcceptanceError.underlying(error)
        }
    }

    // MARK: - Revoke / status

    func revoke(contractID: UUID) async throws {
        struct Params: Encodable { let p_contract_id: UUID }
        do {
            try await supabase
                .rpc("revoke_contract_acceptance_token", params: Params(p_contract_id: contractID))
                .execute()
        } catch {
            let m = error.localizedDescription.lowercased()
            if m.contains("admin role required") || m.contains("42501") {
                throw AcceptanceError.notAdmin
            }
            throw AcceptanceError.underlying(error)
        }
    }

    func fetchStatus(contractID: UUID) async throws -> AcceptanceStatus? {
        struct Params: Encodable { let p_contract_id: UUID }
        do {
            let rows: [AcceptanceStatus] = try await supabase
                .rpc("get_contract_acceptance_status", params: Params(p_contract_id: contractID))
                .execute()
                .value
            return rows.first
        } catch {
            throw AcceptanceError.underlying(error)
        }
    }
}
