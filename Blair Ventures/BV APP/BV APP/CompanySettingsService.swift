// CompanySettingsService.swift
// Aski IQ — Server-backed company settings.
//
// Replaces device-local UserDefaults persistence with one row per company
// in the `company_settings` table. RLS-scoped so values can never leak
// across tenants, and survives sign-out/sign-in/app-restart cleanly.
//
// CALLERS
//   - AppSettings.loadForCompany(_:) on login + restore
//   - AppSettings.save() on the explicit Save button
//   - AppSettings.clearForSignOut() on sign-out (in-memory only; the
//     server row stays untouched so it's there next time the user
//     signs back in)
//
// SCHEMA
// See SupabaseMigration_CompanySettings.sql.

import Foundation
import Supabase

// MARK: - Model

/// Decodable mirror of the `company_settings` table. Field names use
/// snake_case to match Postgres without needing CodingKeys.
struct CompanySettings: Codable, Equatable {
    var id:                          UUID?
    var company_id:                  UUID
    var name:                        String?
    var address:                     String?
    var phone:                       String?
    var email:                       String?
    var currency:                    String
    var tax_label:                   String
    var tax_rate:                    Decimal
    var default_contingency:         Decimal
    var default_payment_terms:       String
    var default_quote_validity_days: Int
    var job_prefix:                  String
    var next_job_number:             Int
    var annual_revenue_target:       Decimal

    /// Convenience: server returns string-form decimals via PostgREST.
    /// Construct an empty record for a freshly-loaded tenant whose row
    /// somehow doesn't exist yet (auto-create trigger should prevent
    /// this, but defensive).
    static func empty(for companyID: UUID) -> CompanySettings {
        CompanySettings(
            id: nil,
            company_id: companyID,
            name: nil, address: nil, phone: nil, email: nil,
            currency: "CAD",
            tax_label: "GST",
            tax_rate: 0.05,
            default_contingency: 0.05,
            default_payment_terms: "Net 30",
            default_quote_validity_days: 30,
            job_prefix: "AKI",
            next_job_number: 1,
            annual_revenue_target: 0
        )
    }
}

// MARK: - Service

@MainActor
enum CompanySettingsService {

    /// Load the settings row for the given company. Two-phase:
    ///
    /// 1. Fast path — direct SELECT. The auto-create trigger should
    ///    have already inserted a row when the company was created.
    /// 2. Defensive fallback — if no row exists (older tenant, missing
    ///    trigger, or environment without the migration applied yet),
    ///    call the SECURITY DEFINER `ensure_company_settings` RPC which
    ///    creates the row with defaults and returns it. RLS blocks
    ///    direct INSERT from end users, so this RPC is the only
    ///    legitimate fallback path.
    ///
    /// This double-layer means the iOS client never has to fail-soft
    /// to in-memory defaults that won't persist — there's always a
    /// real server row backing the cache.
    static func load(companyID: UUID) async throws -> CompanySettings {
        print("📥 SETTINGS LOAD → company_id=\(companyID)")

        // Phase 1 — direct SELECT
        let rows: [CompanySettings] = try await supabase
            .from("company_settings")
            .select()
            .eq("company_id", value: companyID.uuidString)
            .limit(1)
            .execute()
            .value
        if let first = rows.first { return first }

        // Phase 2 — fallback create via SECURITY DEFINER RPC
        print("⚠️  SETTINGS LOAD → no row for company_id=\(companyID), creating defaults via ensure_company_settings RPC")
        struct Params: Encodable { let p_company_id: String }
        let row: CompanySettings = try await supabase
            .rpc("ensure_company_settings",
                 params: Params(p_company_id: companyID.uuidString))
            .execute()
            .value
        return row
    }

    /// Persist the editable fields for the company. RLS on the
    /// company_settings table restricts UPDATE to admins; if the user
    /// isn't admin, this throws and the UI surfaces the error.
    static func save(_ settings: CompanySettings) async throws {
        print("📤 SETTINGS SAVE → company_id=\(settings.company_id)")
        // Build a patch payload. PostgREST UPDATE will only touch the
        // fields we send; we don't include id or company_id to avoid
        // accidental row-key changes.
        struct Update: Encodable {
            let name:                        String?
            let address:                     String?
            let phone:                       String?
            let email:                       String?
            let currency:                    String
            let tax_label:                   String
            let tax_rate:                    Decimal
            let default_contingency:         Decimal
            let default_payment_terms:       String
            let default_quote_validity_days: Int
            let job_prefix:                  String
            let annual_revenue_target:       Decimal
        }
        let patch = Update(
            name:                        settings.name,
            address:                     settings.address,
            phone:                       settings.phone,
            email:                       settings.email,
            currency:                    settings.currency,
            tax_label:                   settings.tax_label,
            tax_rate:                    settings.tax_rate,
            default_contingency:         settings.default_contingency,
            default_payment_terms:       settings.default_payment_terms,
            default_quote_validity_days: settings.default_quote_validity_days,
            job_prefix:                  settings.job_prefix,
            annual_revenue_target:       settings.annual_revenue_target
        )
        try await supabase
            .from("company_settings")
            .update(patch)
            .eq("company_id", value: settings.company_id.uuidString)
            .execute()
    }

    /// Atomic server-side job-number generator. Replaces the
    /// UserDefaults-based counter that produced duplicates across
    /// devices. Returns a formatted string like "AKI-2026-0042".
    static func nextJobNumber(companyID: UUID) async throws -> String {
        struct Params: Encodable { let p_company_id: String }
        let result = try await supabase
            .rpc("next_job_number", params: Params(p_company_id: companyID.uuidString))
            .execute()
        let raw = String(data: result.data, encoding: .utf8) ?? ""
        // PostgREST returns scalar text wrapped in quotes — strip them.
        return raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}
