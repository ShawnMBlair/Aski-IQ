// MaterialSaleAcceptanceService.swift
// Aski IQ — Mint + revoke + status for material-sale acceptance magic links.
//
// PAIRS WITH
// * Migration `material_sale_acceptance_tokens` (server-side table + RPCs)
// * Edge Function `material-sale-accept` (verify_jwt:false, public landing page)
//   — see CloudflareHandoff_MaterialSaleAcceptance.md for deployment notes
//
// FLOW
//   Admin presses "Send for digital acceptance" in MaterialSaleSendReviewSheet
//     → mintToken(saleID:) returns (token, expiresAt, fullURL)
//     → fullURL gets prepended into the email body composed by the
//       existing EmailComposeSheet
//     → customer clicks → public Edge Function shows acceptance page
//     → on signature, `accept_material_sale_via_token` RPC atomically flips
//       sale → ordered (= accepted), opportunity → won
//     → admins + customer get confirmation emails (server-side or via
//       SignedMaterialSalePDFGenerator on next pull)
//
// We never store the raw token client-side after minting — once it's
// pasted into the email body, the only durable record lives in the DB.
//
// IMPORTANT: this file is a deliberate clone of QuoteAcceptanceService.
// Do not refactor into a polymorphic acceptance pipeline without
// aligning with the master prompt — see migration header for rationale.

import Foundation
import Supabase

@MainActor
final class MaterialSaleAcceptanceService {

    static let shared = MaterialSaleAcceptanceService()
    private init() {}

    // MARK: - Models

    struct MintResult {
        let token:     String
        let expiresAt: Date
        let url:       URL          // full public link to the acceptance page
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

        /// User-facing summary for the MaterialSaleDetailView pill.
        var displaySummary: String {
            if let acceptedAt = acceptedAt {
                let by = acceptedByName ?? acceptedByEmail ?? "customer"
                let f = DateFormatter()
                f.dateStyle = .medium
                return "Accepted by \(by) · \(f.string(from: acceptedAt))"
            }
            if revokedAt != nil { return "Acceptance link revoked" }
            if let expiresAt = expiresAt {
                if expiresAt < Date() { return "Acceptance link expired" }
                let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
                return "Awaiting acceptance · expires \(f.localizedString(for: expiresAt, relativeTo: Date()))"
            }
            return "Awaiting acceptance"
        }
    }

    enum AcceptanceError: Error, LocalizedError {
        case notAdmin
        case saleNotFound
        case underlying(Error)
        var errorDescription: String? {
            switch self {
            case .notAdmin:        return "Only company admins can mint or revoke acceptance links."
            case .saleNotFound:    return "Material sale not found or not in your company."
            case .underlying(let e): return e.localizedDescription
            }
        }
    }

    // MARK: - Mint

    /// Mints a fresh acceptance token for the given material sale.
    /// Server-side auto-revokes any prior live token, so calling this
    /// twice in a row is safe — only the latest URL works.
    ///
    /// `validityDays` defaults to 30; admins can shorten it for tighter
    /// turnaround pressure.
    func mintToken(saleID: UUID, validityDays: Int = 30) async throws -> MintResult {
        struct MintParams: Encodable {
            let p_material_sale_id: UUID
            let p_validity_days:    Int
        }
        struct MintRow: Decodable {
            let token:      String
            let expires_at: Date
        }
        do {
            let rows: [MintRow] = try await supabase
                .rpc("mint_material_sale_acceptance_token",
                     params: MintParams(p_material_sale_id: saleID, p_validity_days: validityDays))
                .execute()
                .value
            guard let row = rows.first else {
                throw AcceptanceError.saleNotFound
            }
            // Build the public URL the customer will click. `/ms` is
            // the material-sale path on the same Cloudflare Pages site
            // that hosts the existing /q (quote) acceptance page —
            // keeps everything under accept.blairventures.ca.
            var comps = URLComponents(string: "https://accept.blairventures.ca/ms")
            comps?.queryItems = [URLQueryItem(name: "token", value: row.token)]
            guard let url = comps?.url else {
                throw AcceptanceError.underlying(NSError(
                    domain: "MaterialSaleAcceptance", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Couldn't construct acceptance URL"]
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
            if m.contains("material sale not found") {
                throw AcceptanceError.saleNotFound
            }
            throw AcceptanceError.underlying(error)
        }
    }

    // MARK: - Revoke

    /// Kills any live acceptance token for this sale. Used when the
    /// rep sent the wrong figures and wants the old link to stop working.
    func revoke(saleID: UUID) async throws {
        struct Params: Encodable { let p_material_sale_id: UUID }
        do {
            try await supabase
                .rpc("revoke_material_sale_acceptance_token", params: Params(p_material_sale_id: saleID))
                .execute()
        } catch {
            let m = error.localizedDescription.lowercased()
            if m.contains("admin role required") || m.contains("42501") {
                throw AcceptanceError.notAdmin
            }
            throw AcceptanceError.underlying(error)
        }
    }

    // MARK: - Status

    /// Most-recent token metadata for a sale. Returns nil when no
    /// token has ever been minted. Visible to any tenant member so the
    /// detail screen can show "Awaiting acceptance" without admin role.
    func fetchStatus(saleID: UUID) async throws -> AcceptanceStatus? {
        struct Params: Encodable { let p_material_sale_id: UUID }
        do {
            let rows: [AcceptanceStatus] = try await supabase
                .rpc("get_material_sale_acceptance_status", params: Params(p_material_sale_id: saleID))
                .execute()
                .value
            return rows.first
        } catch {
            throw AcceptanceError.underlying(error)
        }
    }

    // MARK: - Signed details (for PDF generation)

    /// Full set of acceptance fields needed to render a signed-sale
    /// PDF + acceptance certificate page. Returns nil when the sale
    /// has no accepted token row yet (server enforces accepted_at IS
    /// NOT NULL — unsigned tokens are filtered out so the PDF flow
    /// can't fire prematurely).
    struct SignedDetails: Decodable {
        let acceptedAt:      Date
        let acceptedByName:  String?
        let acceptedByEmail: String?
        let acceptedIP:      String?
        let signatureDataURL: String?
        let tokenSuffix:     String

        enum CodingKeys: String, CodingKey {
            case acceptedAt       = "accepted_at"
            case acceptedByName   = "accepted_by_name"
            case acceptedByEmail  = "accepted_by_email"
            case acceptedIP       = "accepted_ip"
            case signatureDataURL = "signature_data_url"
            case tokenSuffix      = "token_suffix"
        }

        /// Decodes the `data:image/png;base64,...` URL into raw PNG
        /// bytes the PDF renderer can draw. Returns nil if the
        /// signature wasn't captured or the URL is malformed.
        var signaturePNG: Data? {
            guard let url = signatureDataURL else { return nil }
            let base64: String
            if let comma = url.firstIndex(of: ","), url.hasPrefix("data:") {
                base64 = String(url[url.index(after: comma)...])
            } else {
                base64 = url
            }
            return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
        }
    }

    func fetchSignedDetails(saleID: UUID) async throws -> SignedDetails? {
        struct Params: Encodable { let p_material_sale_id: UUID }
        do {
            let rows: [SignedDetails] = try await supabase
                .rpc("get_material_sale_acceptance_signed_details",
                     params: Params(p_material_sale_id: saleID))
                .execute()
                .value
            return rows.first
        } catch {
            throw AcceptanceError.underlying(error)
        }
    }
}
