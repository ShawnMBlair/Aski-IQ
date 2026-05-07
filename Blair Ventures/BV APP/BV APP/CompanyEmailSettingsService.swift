// CompanyEmailSettingsService.swift
// Aski IQ — per-company email sender settings (multi-tenant).
//
// Each tenant has one row in `company_email_settings`. The send-email
// Edge Function reads it on every send to determine FROM identity and
// reply_to. This service is the iOS-side mirror — load on Settings open,
// save on the explicit Save button.
//
// Mirrors the CompanySettingsService pattern: SECURITY DEFINER RPC for
// the load-or-create fast path, RLS-scoped UPDATE for save.

import Foundation
import Supabase

// MARK: - Model

struct CompanyEmailSettings: Codable, Equatable {
    var id:                  UUID?
    var company_id:          UUID
    var from_name:           String
    var reply_to_email:      String
    var default_signature:   String?
    var footer_text:         String?
    var logo_url:            String?
    var domain_status:       String       // 'platform' | 'verifying' | 'verified' | 'failed'
    var custom_from_email:   String?
    var provider:            String       // 'resend' | 'sendgrid' | ...
    var provider_status:     String       // 'active' | 'suspended' | 'error'
    var is_enabled:          Bool

    /// Human-readable summary for the Settings UI status block.
    var domainStatusLabel: String {
        switch domain_status {
        case "verified":  return "Custom domain verified"
        case "verifying": return "Custom domain — verification pending"
        case "failed":    return "Custom domain — verification failed"
        default:          return "Platform sender (no DNS setup needed)"
        }
    }

    /// What the recipient will actually see as From, given current state.
    /// Note: the actual FROM is resolved server-side; this is a UI hint only.
    var effectiveFromHint: String {
        if domain_status == "verified",
           let custom = custom_from_email, !custom.isEmpty {
            return "\(from_name) <\(custom)>"
        }
        let safeName = from_name.isEmpty ? "Aski IQ" : from_name
        return "\(safeName) <send@askiiq.app>" // visual placeholder; real value held in PLATFORM_FROM_EMAIL secret
    }
}

// MARK: - Service

@MainActor
enum CompanyEmailSettingsService {

    /// Load (or auto-create) the email settings row for a company.
    /// Two-phase: SELECT first; if missing, fall back to the SECURITY
    /// DEFINER `ensure_company_email_settings` RPC.
    static func load(companyID: UUID) async throws -> CompanyEmailSettings {
        print("📥 EMAIL SETTINGS LOAD → company_id=\(companyID)")
        let rows: [CompanyEmailSettings] = try await supabase
            .from("company_email_settings")
            .select()
            .eq("company_id", value: companyID.uuidString)
            .limit(1)
            .execute()
            .value
        if let first = rows.first { return first }

        print("⚠️  EMAIL SETTINGS LOAD → no row, creating defaults via RPC")
        struct Params: Encodable { let p_company_id: String }
        let row: CompanyEmailSettings = try await supabase
            .rpc("ensure_company_email_settings",
                 params: Params(p_company_id: companyID.uuidString))
            .execute()
            .value
        return row
    }

    /// Persist the editable fields. RLS on the table restricts UPDATE to
    /// admins; non-admins get a permission error here.
    static func save(_ s: CompanyEmailSettings) async throws {
        print("📤 EMAIL SETTINGS SAVE → company_id=\(s.company_id)")
        struct Update: Encodable {
            let from_name:         String
            let reply_to_email:    String
            let default_signature: String?
            let footer_text:       String?
            let is_enabled:        Bool
        }
        let patch = Update(
            from_name:         s.from_name,
            reply_to_email:    s.reply_to_email,
            default_signature: s.default_signature,
            footer_text:       s.footer_text,
            is_enabled:        s.is_enabled
        )
        try await supabase
            .from("company_email_settings")
            .update(patch)
            .eq("company_id", value: s.company_id.uuidString)
            .execute()
    }

    /// Sends a small test email to the caller's own auth.users.email so the
    /// admin can confirm the wired path: Edge Function → Resend → inbox.
    /// Returns the EmailService Result so the UI can surface the same
    /// errors as production sends.
    static func sendTestEmail(to recipient: String,
                              companyID:    UUID) async -> Result<Void, EmailService.EmailError> {
        let body = """
        This is a test email from Aski IQ.

        If you received this, your company email settings are working correctly.

        Company: \(companyID)
        Sent at: \(ISO8601DateFormatter().string(from: Date()))
        """
        return await EmailService.shared.sendText(
            to:         [recipient],
            subject:    "Aski IQ — email settings test",
            bodyText:   body,
            entityType: "test",
            entityID:   UUID()
        )
    }
}
