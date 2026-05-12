// SupabaseService.swift
// AskiCommand – Supabase Connection
// NEW FILE — do not replace anything existing

import Foundation
import Supabase

// MARK: - Credentials
// supabaseAnonKey is the Supabase *public* anon key — it is intentionally embedded
// in the client binary (Supabase's documented pattern). It grants only the access
// that Row Level Security policies allow. Real data security is enforced by RLS,
// not by keeping this key secret.
//
// Resolution order (defense-in-depth + override path for CI / open-sourcing):
//   1. Info.plist key SUPABASE_URL / SUPABASE_ANON_KEY (set via xcconfig build setting)
//   2. Process environment variable (handy for tests and CI)
//   3. Hardcoded fallback below (existing behaviour — keeps current builds working)
//
// To override without code changes, set Xcode build settings SUPABASE_URL and
// SUPABASE_ANON_KEY (or supply them via a Secrets.xcconfig referenced by the project)
// and add matching $(SUPABASE_URL) / $(SUPABASE_ANON_KEY) entries to Info.plist.

private let fallbackSupabaseURL = "https://uiwjvkutaezyismkjwxj.supabase.co"
private let fallbackSupabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVpd2p2a3V0YWV6eWlzbWtqd3hqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY2MzI3MjIsImV4cCI6MjA5MjIwODcyMn0.TAAfJJ5H_O6OKMhlCJ-TSwtji8mvti8xneChjdq_z6o"

private func resolveSupabaseConfigValue(_ key: String, fallback: String) -> String {
    if let plist = Bundle.main.object(forInfoDictionaryKey: key) as? String,
       !plist.isEmpty, !plist.hasPrefix("$(") {
        return plist
    }
    if let env = ProcessInfo.processInfo.environment[key], !env.isEmpty {
        return env
    }
    return fallback
}

private let supabaseURL: URL = {
    let raw = resolveSupabaseConfigValue("SUPABASE_URL", fallback: fallbackSupabaseURL)
    guard let url = URL(string: raw) else {
        fatalError("Invalid SUPABASE_URL: \(raw)")
    }
    return url
}()

/// Base URL for Edge Functions ("https://<ref>.supabase.co/functions/v1").
/// Exposed for services that need to construct full public URLs — e.g.
/// the quote-acceptance magic link that gets emailed to customers and
/// must be clickable from any browser, not just inside the app.
let supabaseFunctionsBaseURL: URL = supabaseURL.appendingPathComponent("/functions/v1")

private let supabaseAnonKey: String = resolveSupabaseConfigValue(
    "SUPABASE_ANON_KEY",
    fallback: fallbackSupabaseAnonKey
)

/// Same value as the private `supabaseAnonKey` above, re-exported at
/// file scope so direct-URLSession callers (e.g. SSE streaming in
/// `AIProxyClient.streamText`) can attach the `apikey` header without
/// reaching into the SDK's request pipeline. The anon key is public —
/// it ships in every iOS bundle anyway and is not a secret.
let supabasePublicAnonKey: String = supabaseAnonKey

// MARK: - Shared Client
// One instance used by the entire app

let supabase = SupabaseClient(
    supabaseURL: supabaseURL,
    supabaseKey: supabaseAnonKey,
    options: .init(
        auth: .init(
            autoRefreshToken: true,
            emitLocalSessionAsInitialSession: true
        )
    )
)

// MARK: - Table Names

enum SupabaseTable {
    static let companies          = "companies"
    static let profiles           = "profiles"
    static let projects           = "projects"
    static let projectAssignments = "project_assignments"
    static let employees          = "employees"
    static let crews              = "crews"
    static let crewMembers        = "crew_members"
    static let scheduleEntries    = "schedule_entries"
    static let scheduleAuditLog        = "schedule_audit_log"
    static let scheduleRecommendations = "schedule_recommendations"
    static let timesheetEntries   = "timesheet_entries"
    static let exceptionLogs      = "exception_logs"
    static let formTemplates      = "form_templates"
    static let formSubmissions    = "form_submissions"
    static let estimates          = "estimates"
    static let estimateLineItems  = "estimate_line_items"
    static let estimateRevisions  = "estimate_revisions"
    static let quoteRevisions     = "quote_revisions"
    static let auditSnapshots     = "audit_snapshots"
    // Extended tables
    static let incidents          = "incidents"
    static let certificates       = "certificates"
    static let clients            = "clients"
    static let quotes             = "quotes"
    static let dailyJobReports    = "daily_job_reports"
    static let equipment          = "equipment"
    // Commercial modules
    static let changeOrders       = "change_orders"
    static let rfis               = "rfis"
    static let projectBudgets     = "project_budgets"
    static let subcontractors     = "subcontractors"
    static let subContracts       = "sub_contracts"
    static let invoices           = "invoices"
    static let purchaseOrders     = "purchase_orders"
    static let materialRequests   = "material_requests"
    static let suppliers          = "suppliers"
    // Product & Service Library
    static let productServices    = "product_services"
    static let clientPricings     = "client_pricings"
    // Material Sales
    static let materialSales      = "material_sales"
    // Contracts module
    static let contracts            = "contracts"
    static let contractClauses      = "contract_clauses"
    static let contractMilestones   = "contract_milestones"
    static let complianceDocuments  = "compliance_documents"
    static let lienWaivers          = "lien_waivers"
    // CRM tables
    static let crmContacts        = "crm_contacts"
    static let crmOpportunities   = "crm_opportunities"
    static let crmTasks           = "crm_tasks"
    static let crmActivities      = "crm_activities"
    static let crmChecklists      = "crm_checklists"
    // Settings / admin tables
    static let companyCostCodes   = "company_cost_codes"
    static let importBatches      = "import_batches"
    static let termsTemplates     = "terms_templates"
    static let quoteTerms         = "quote_terms"
    /// Path-A clones of quote_terms — see SupabaseMigration_EstimateTerms_MaterialSaleTerms.sql
    static let estimateTerms      = "estimate_terms"
    static let materialSaleTerms  = "material_sale_terms"
    static let quoteApprovals     = "quote_approvals"
    // Workflow automation (added 2026-04 audit — previously UserDefaults-only)
    static let workflowRules      = "workflow_rules"
    static let workflowLog        = "workflow_log"
    // Material Request workflow (SupabaseMigration_MaterialRequestWorkflow.sql)
    static let workflowSettings   = "workflow_settings"
    static let materialRequestAudit = "material_request_audit"
    // Phase 8 / Inventory v1
    static let inventoryItems        = "inventory_items"
    static let stockLocations        = "stock_locations"
    static let inventoryStockLevels  = "inventory_stock_levels"
    static let inventoryTransfers    = "inventory_transfers"
    // Phase 9 / Expenses v1.1
    static let expenses              = "expenses"
    static let expenseAttachments    = "expense_attachments"
}

// MARK: - App User Profile
// Matches the profiles table in Supabase

struct AppUserProfile: Codable, Identifiable {
    let id: UUID
    let email: String
    let fullName: String
    let role: UserRole
    let isActive: Bool
    let createdAt: Date
    let companyID: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case fullName  = "full_name"
        case role
        case isActive  = "is_active"
        case createdAt = "created_at"
        case companyID = "company_id"
    }
}

// MARK: - MFA Helpers

struct MFAEnrollResult {
    let factorId:  String
    let qrDataURI: String
    let secret:    String
}

// MARK: - Auth Service

struct AuthService {

    /// Sign in — returns the user's profile including their role
    static func signIn(email: String, password: String) async throws -> AppUserProfile {
        let session = try await supabase.auth.signIn(email: email, password: password)
        return try await fetchProfile(userID: session.user.id)
    }

    /// Sign up a new user and provision their company + profile via SECURITY DEFINER RPC
    static func signUp(email: String, password: String, fullName: String, companyName: String) async throws -> AppUserProfile {
        let session = try await supabase.auth.signUp(email: email, password: password)
        struct SetupParams: Encodable { let p_full_name: String; let p_company_name: String }
        try await supabase.rpc("setup_new_user", params: SetupParams(p_full_name: fullName, p_company_name: companyName)).execute()
        return try await fetchProfile(userID: session.user.id)
    }

    /// Sign up via invite code — joins an existing company with a pre-assigned role
    static func signUpWithInvite(email: String, password: String, fullName: String, code: String) async throws -> AppUserProfile {
        let session = try await supabase.auth.signUp(email: email, password: password)
        struct UseParams: Encodable { let p_code: String; let p_full_name: String }
        try await supabase.rpc("use_invite", params: UseParams(p_code: code, p_full_name: fullName)).execute()
        return try await fetchProfile(userID: session.user.id)
    }

    /// Generate an invite code for a given role (managers and above only)
    static func createInvite(role: UserRole) async throws -> String {
        struct Params: Encodable { let p_role: String }
        let result = try await supabase.rpc("create_invite", params: Params(p_role: role.rawValue)).execute()
        guard let code = try? JSONDecoder().decode(String.self, from: result.data) else {
            throw NSError(domain: "Invite", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate invite code."])
        }
        return code
    }

    /// Sign out
    static func signOut() async throws {
        try await supabase.auth.signOut()
    }

    // MARK: - Profile

    /// Update the signed-in user's display name in both auth metadata and the profiles table.
    static func updateDisplayName(_ name: String) async throws {
        let userID = try await supabase.auth.session.user.id

        // Update auth user metadata
        try await supabase.auth.update(user: .init(data: ["full_name": AnyJSON.string(name)]))

        // Update profiles table row
        struct NameUpdate: Encodable { let full_name: String }
        try await supabase
            .from(SupabaseTable.profiles)
            .update(NameUpdate(full_name: name))
            .eq("id", value: userID.uuidString)
            .execute()
    }

    /// Update the signed-in user's role on their profile row.
    /// Server-side RLS controls whether self-promotion is allowed; if your
    /// policy blocks it, this call will fail and the caller surfaces the
    /// error. Callers SHOULD warn the user before demoting themselves —
    /// dropping below the admin tier locks them out of Settings sections
    /// gated on `currentUserRole.isAdmin`.
    static func updateRole(_ role: UserRole) async throws {
        let userID = try await supabase.auth.session.user.id
        struct RoleUpdate: Encodable { let role: String }
        try await supabase
            .from(SupabaseTable.profiles)
            .update(RoleUpdate(role: role.rawValue))
            .eq("id", value: userID.uuidString)
            .execute()
    }

    /// Update the name of the signed-in user's company.
    /// RLS should restrict this to admins of that company; callers should
    /// also gate the UI on `currentUserRole.isAdmin` to avoid surfacing a
    /// failing button to non-admins.
    static func updateCompanyName(_ name: String, companyID: UUID) async throws {
        struct NameUpdate: Encodable { let name: String }
        try await supabase
            .from(SupabaseTable.companies)
            .update(NameUpdate(name: name))
            .eq("id", value: companyID.uuidString)
            .execute()
    }

    // MARK: - MFA

    /// Returns the factor ID if the signed-in user has a verified TOTP factor, else nil.
    static func mfaFactorID() async -> String? {
        let factors = try? await supabase.auth.mfa.listFactors()
        return factors?.totp.first(where: { $0.status == .verified })?.id
    }

    /// Returns true if MFA challenge is required to reach AAL2.
    /// AuthenticatorAssuranceLevels is a String typealias in supabase-swift.
    static func mfaChallengeRequired() async -> Bool {
        guard let aal = try? await supabase.auth.mfa.getAuthenticatorAssuranceLevel() else {
            return false
        }
        return aal.nextLevel == "aal2" && aal.currentLevel != "aal2"
    }

    /// Start TOTP enrollment — returns QR data URI, secret, and factor ID.
    static func enrollMFA() async throws -> MFAEnrollResult {
        let response = try await supabase.auth.mfa.enroll(
            params: .totp(issuer: "Aski IQ", friendlyName: "Authenticator")
        )
        guard let totp = response.totp else {
            throw NSError(domain: "MFA", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "TOTP enrollment data missing."])
        }
        return MFAEnrollResult(
            factorId:  response.id,
            qrDataURI: totp.qrCode,
            secret:    totp.secret
        )
    }

    /// Complete enrollment by verifying the first TOTP code.
    static func confirmMFAEnrollment(factorId: String, code: String) async throws {
        try await supabase.auth.mfa.challengeAndVerify(
            params: .init(factorId: factorId, code: code)
        )
    }

    /// Verify a TOTP code for an existing factor (post-login challenge).
    static func verifyMFA(factorId: String, code: String) async throws {
        let challenge = try await supabase.auth.mfa.challenge(params: .init(factorId: factorId))
        try await supabase.auth.mfa.verify(
            params: .init(factorId: factorId, challengeId: challenge.id, code: code)
        )
    }

    /// Remove an enrolled MFA factor.
    static func unenrollMFA(factorId: String) async throws {
        try await supabase.auth.mfa.unenroll(params: .init(factorId: factorId))
    }

    /// Restore session on app launch
    static func restoreSession() async -> AppUserProfile? {
        do {
            let session = try await supabase.auth.session
            return try await fetchProfile(userID: session.user.id)
        } catch {
            return nil
        }
    }

    /// Fetch profile row from Supabase; auto-creates via RPC if missing
    static func fetchProfile(userID: UUID) async throws -> AppUserProfile {
        let rows: [AppUserProfile] = try await supabase
            .from(SupabaseTable.profiles)
            .select()
            .eq("id", value: userID.uuidString)
            .limit(1)
            .execute()
            .value

        if let profile = rows.first { return profile }

        // No profile — use SECURITY DEFINER RPC to bypass RLS circular dependency
        let user = try await supabase.auth.user()
        var fullName = ""
        if case .string(let name) = user.userMetadata["full_name"] { fullName = name }

        struct SetupParams: Encodable { let p_full_name: String; let p_company_name: String }
        try await supabase.rpc("setup_new_user",
            params: SetupParams(p_full_name: fullName, p_company_name: "My Company")).execute()

        let created: [AppUserProfile] = try await supabase
            .from(SupabaseTable.profiles)
            .select()
            .eq("id", value: userID.uuidString)
            .limit(1)
            .execute()
            .value
        guard let profile = created.first else {
            throw NSError(domain: "AuthService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Account setup failed. Contact your administrator."])
        }
        return profile
    }

    /// Returns the current JWT access token for direct API calls (e.g. Edge Functions).
    static func currentAccessToken() async throws -> String {
        let session = try await supabase.auth.session
        return session.accessToken
    }
}
