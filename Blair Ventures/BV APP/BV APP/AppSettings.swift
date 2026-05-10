// AppSettings.swift
// AskiCommand – Company Settings
// NEW FILE — company-wide settings that feed every module

import Foundation
import SwiftUI
import Combine
import Supabase

// MARK: - App Settings Store
//
// PERSISTENCE
// ============================================================================
// As of May 2026, all company-level settings live server-side in the
// `company_settings` table (one row per company, RLS-scoped). This class is
// an in-memory cache that:
//   * Loads from Supabase via `loadForCompany(_:)` on login + restoreSession
//   * Persists to Supabase via `save()` on the explicit Save button in
//     SettingsView
//   * Clears in-memory state via `clearForSignOut()` on sign-out
//
// What's NOT in `company_settings`:
//   * `anthropicAPIKey` — lives in Keychain (per-device, not tenant).
//     Phase 2 audit moved this server-side via CompanyAIKeyService for the
//     shared per-company key. The legacy field here is for the local-only
//     fallback path; not removed yet to avoid breaking older code paths.
//
// Pre-fix, every property's `didSet` wrote to `UserDefaults` keyed by
// `ak_*` (NOT keyed by company_id). Two consequences:
//   1. Two users on the same device shared the same UserDefaults keys —
//      values "leaked" between accounts.
//   2. After fullSignOutReset() shipped, every sign-out wiped UserDefaults
//      via removePersistentDomain — settings disappeared.
// Both bugs had one root cause: UserDefaults is the wrong store for
// tenant business data. Fix is server-side persistence, scoped by RLS.

final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // MARK: - Company Identity (tenant-scoped, server-backed)

    @Published var companyPrefix:  String = "AKI"
    @Published var companyName:    String = ""
    @Published var companyAddress: String = ""
    @Published var companyPhone:   String = ""
    @Published var companyEmail:   String = ""

    // MARK: - Commercial Defaults (tenant-scoped, server-backed)

    @Published var defaultPaymentTerms:       String = "Net 30"
    @Published var defaultQuoteValidityDays:  Int    = 30
    /// Percentage form (5.0 = 5%) for backwards compat with existing
    /// callers in QuoteViews, ProjectInvoiceGeneratorSheet, etc.
    /// Server-side stored as a fraction (0.05); conversion happens in
    /// CompanySettingsService load/save.
    @Published var defaultContingencyPercent: Double = 0.0
    @Published var taxRate:                   Double = 5.0
    @Published var taxLabel:                  String = "GST"

    /// Company-wide preferred currency. Inherited onto every new
    /// Quote / Invoice / Material Sale at creation. ISO 4217.
    @Published var preferredCurrency: String = "CAD" {
        didSet {
            // Defensive: force ISO 4217 shape so a typed-in 'usd'
            // doesn't reach the DB CHECK and bounce.
            let cleaned = preferredCurrency.uppercased().filter { $0.isLetter }
            if cleaned != preferredCurrency {
                preferredCurrency = cleaned
            }
        }
    }

    @Published var annualRevenueTarget: Double = 0

    // MARK: - Scheduling tunables (Phase 1)
    //
    // Drive the new conflict-detection rules surfaced by
    // ScheduleConflictService. Defaults are conservative — a new
    // tenant can ship without configuring either and still get the
    // upgraded conflict detection.
    //
    // travelBufferMinutes: Minimum gap (in minutes) between two
    //   back-to-back shifts for the same crew or employee. Set to 0
    //   to disable the back-to-back warning. 30 min covers typical
    //   urban site-to-site travel; bump higher for rural fleets.
    //
    // overtimeWeeklyThresholdHours: Hours-per-week target for an
    //   employee or crew before the conflict service flags overtime
    //   risk. Defaults to 40 (standard week). Set to 0 to disable.
    @Published var travelBufferMinutes:           Int    = 30
    @Published var overtimeWeeklyThresholdHours:  Double = 40

    // MARK: - Local-only (Keychain or device-scoped)
    //
    // anthropicAPIKey stays in Keychain — it's a credential, not tenant
    // settings, and the Keychain is per-device by design. CompanyAIKeyService
    // is the canonical per-tenant path; this is a legacy fallback.

    @Published var anthropicAPIKey: String = "" {
        didSet { KeychainHelper.set(anthropicAPIKey, for: "ak_anthropic_key") }
    }

    // MARK: - Tracking

    /// True when in-memory state has been mutated since the last load/save.
    /// Drives the Save button enabled state.
    @Published private(set) var hasUnsavedChanges: Bool = false

    /// The companyID this snapshot belongs to. Set in `loadForCompany(_:)`;
    /// cleared in `clearForSignOut()`. `save()` refuses if this is nil.
    private var loadedCompanyID: UUID?

    /// Snapshot of the last server state — used to compute hasUnsavedChanges.
    private var lastLoadedSnapshot: CompanySettings?

    private init() {
        // Wire change tracking: any @Published mutation flips the dirty flag.
        // Combine subscription set up after init so initial defaults don't
        // mark the cache as dirty.
        Task { @MainActor in self.bindChangeTracking() }
    }

    // MARK: - Lifecycle

    /// Pull settings from Supabase for the given company and populate
    /// the in-memory @Published fields. Called from LoginView and
    /// BV_APPApp.restoreSession after currentCompanyID is set.
    @MainActor
    func loadForCompany(_ companyID: UUID) async {
        do {
            let settings = try await CompanySettingsService.load(companyID: companyID)
            applySnapshot(settings)
            self.loadedCompanyID    = companyID
            self.lastLoadedSnapshot = settings
            self.hasUnsavedChanges  = false
            print("✅ SETTINGS LOAD OK — company_id=\(companyID)")
        } catch {
            print("⚠️ SETTINGS LOAD FAILED — company_id=\(companyID) — \(error.localizedDescription)")
        }
    }

    /// Push the current in-memory state to Supabase.
    /// Throws if not loaded for a company yet (caller should disable
    /// the Save button until load completes).
    ///
    /// OPTIMISTIC + ROLLBACK
    /// The @Published mutations already updated the UI the moment the
    /// user typed in the form — that's the optimistic side. On save
    /// failure we revert: re-apply the lastLoadedSnapshot so the form
    /// fields snap back to the server's authoritative state. Without
    /// this, a failed save would leave the user thinking their typed
    /// value persisted when it didn't.
    @MainActor
    func save() async throws {
        guard let companyID = loadedCompanyID else {
            throw NSError(
                domain: "AppSettings", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Settings not loaded for any company yet — sign in fully before saving."]
            )
        }
        let snapshot = currentSnapshot(companyID: companyID)
        do {
            try await CompanySettingsService.save(snapshot)
            // Commit — server accepted the write.
            self.lastLoadedSnapshot = snapshot
            self.hasUnsavedChanges  = false
        } catch {
            // Rollback — restore the last server state to the @Published
            // fields. The change-tracking publisher will re-flip
            // hasUnsavedChanges, but applySnapshot writes-then-resets so
            // by the end of this block the form mirrors the server.
            if let prior = self.lastLoadedSnapshot {
                applySnapshot(prior)
                self.hasUnsavedChanges = false
            }
            throw error
        }
    }

    /// Wipe the in-memory cache on sign-out. The server row stays
    /// untouched. Called from AppStore.fullSignOutReset().
    @MainActor
    func clearForSignOut() {
        companyPrefix             = "AKI"
        companyName               = ""
        companyAddress            = ""
        companyPhone              = ""
        companyEmail              = ""
        defaultPaymentTerms       = "Net 30"
        defaultQuoteValidityDays  = 30
        defaultContingencyPercent = 0.0
        taxRate                   = 5.0
        taxLabel                  = "GST"
        preferredCurrency         = "CAD"
        annualRevenueTarget       = 0
        loadedCompanyID           = nil
        lastLoadedSnapshot        = nil
        hasUnsavedChanges         = false
    }

    // MARK: - Job Number Generator
    //
    // Two APIs — keep the sync version stable for legacy callers
    // (CRMCommercialBridge, CRMOpportunityViews, EntityFactories), add
    // an async server-authoritative version for new code paths that
    // need cross-device atomic uniqueness.
    //
    // SYNC (`nextJobNumber()`): UserDefaults-backed local counter.
    //   Pros: works offline, no await, drop-in for existing callers.
    //   Cons: counter resets on `fullSignOutReset` (UserDefaults wipe);
    //         multiple devices can produce the same number under the
    //         same tenant. Acceptable for a single-PM workspace; will
    //         migrate to async when multi-device pressure surfaces.
    //
    // ASYNC (`nextJobNumberServer()`): calls the `next_job_number` RPC
    //   for atomic server-side increment. Use this from new code that
    //   creates records that must be globally unique within a tenant.
    //   Returns "AKI-2026-0042" formatted by the RPC.

    /// Local UserDefaults counter — legacy sync API. See note above.
    func nextJobNumber() -> String {
        let year = Calendar.current.component(.year, from: Date())
        let key  = "ak_job_seq_\(year)"
        let next = UserDefaults.standard.integer(forKey: key) + 1
        UserDefaults.standard.set(next, forKey: key)
        return String(format: "%@-%d-%04d", companyPrefix, year, next)
    }

    /// Server-side atomic generator. Use for new code that needs
    /// cross-device uniqueness (multi-PM workspaces, multiple devices).
    @MainActor
    func nextJobNumberServer() async throws -> String {
        guard let companyID = loadedCompanyID else {
            throw NSError(domain: "AppSettings", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No active company"])
        }
        return try await CompanySettingsService.nextJobNumber(companyID: companyID)
    }

    /// In-memory preview of the job-number format. Doesn't touch the
    /// counter; uses the local prefix + current year. Real number is
    /// resolved by `nextJobNumber()` at create time.
    func previewJobNumber() -> String {
        let year = Calendar.current.component(.year, from: Date())
        let key  = "ak_job_seq_\(year)"
        let next = UserDefaults.standard.integer(forKey: key) + 1
        return String(format: "%@-%d-%04d", companyPrefix, year, next)
    }

    // MARK: - Reset to Defaults
    // In-memory only. Does NOT push to server — caller must hit Save
    // afterwards if they want to persist.

    @MainActor
    func resetToDefaults() {
        companyPrefix             = "AKI"
        defaultPaymentTerms       = "Net 30"
        defaultQuoteValidityDays  = 30
        defaultContingencyPercent = 0.0
        taxRate                   = 5.0
        taxLabel                  = "GST"
        preferredCurrency         = "CAD"
    }

    // MARK: - Private

    /// Map a server snapshot into the @Published fields.
    /// Server stores tax_rate / default_contingency as fractions
    /// (0.05); iOS uses percent form (5.0) for back-compat with the
    /// many call-sites that already do `taxRate / 100`. Convert here
    /// at the boundary.
    private func applySnapshot(_ s: CompanySettings) {
        companyPrefix             = s.job_prefix
        companyName               = s.name ?? ""
        companyAddress            = s.address ?? ""
        companyPhone              = s.phone ?? ""
        companyEmail              = s.email ?? ""
        defaultPaymentTerms       = s.default_payment_terms
        defaultQuoteValidityDays  = s.default_quote_validity_days
        defaultContingencyPercent = decimalToPercent(s.default_contingency)
        taxRate                   = decimalToPercent(s.tax_rate)
        taxLabel                  = s.tax_label
        preferredCurrency         = s.currency
        annualRevenueTarget       = NSDecimalNumber(decimal: s.annual_revenue_target).doubleValue
    }

    /// Build a CompanySettings record from the current @Published state.
    private func currentSnapshot(companyID: UUID) -> CompanySettings {
        var s = lastLoadedSnapshot ?? CompanySettings.empty(for: companyID)
        s.company_id              = companyID
        s.name                    = companyName.isEmpty    ? nil : companyName
        s.address                 = companyAddress.isEmpty ? nil : companyAddress
        s.phone                   = companyPhone.isEmpty   ? nil : companyPhone
        s.email                   = companyEmail.isEmpty   ? nil : companyEmail
        s.currency                = preferredCurrency
        s.tax_label               = taxLabel
        s.tax_rate                = percentToDecimal(taxRate)
        s.default_contingency     = percentToDecimal(defaultContingencyPercent)
        s.default_payment_terms   = defaultPaymentTerms
        s.default_quote_validity_days = defaultQuoteValidityDays
        s.job_prefix              = companyPrefix
        s.annual_revenue_target   = Decimal(annualRevenueTarget)
        return s
    }

    private func decimalToPercent(_ d: Decimal) -> Double {
        NSDecimalNumber(decimal: d).doubleValue * 100
    }
    private func percentToDecimal(_ p: Double) -> Decimal {
        Decimal(p / 100)
    }

    /// Subscribe to every @Published var so any UI edit flips
    /// hasUnsavedChanges. The dropFirst skips the initial sink that
    /// fires immediately after subscription.
    private var changeCancellables: Set<AnyCancellable> = []

    @MainActor
    private func bindChangeTracking() {
        let triggers: [AnyPublisher<Void, Never>] = [
            $companyPrefix.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $companyName.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $companyAddress.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $companyPhone.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $companyEmail.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $defaultPaymentTerms.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $defaultQuoteValidityDays.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $defaultContingencyPercent.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $taxRate.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $taxLabel.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $preferredCurrency.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $annualRevenueTarget.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .sink { [weak self] _ in self?.hasUnsavedChanges = true }
            .store(in: &changeCancellables)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var store: AppStore
    @State private var showResetConfirm      = false
    @State private var showExportShareSheet  = false
    @State private var exportFileURL: URL?    = nil
    @State private var exportError: String?  = nil
    @State private var isExporting           = false
    /// PIPEDA / GDPR right-to-erasure entry point. Presents the multi-step
    /// AccountDeletionView modally so the user can confirm + re-auth.
    @State private var showDeleteAccount     = false
    @State private var showMFAEnroll         = false
    @State private var showDisableMFAConfirm = false   // now a sheet, not alert
    @State private var mfaEnabled            = false
    @State private var mfaFactorId: String?  = nil
    @State private var displayName           = ""
    @State private var isSavingName          = false
    // Company name editor (admin-only edit per RLS)
    @State private var companyNameDraft      = ""
    @State private var isSavingCompanyName   = false
    @State private var companyNameError: String? = nil
    /// Phase 8 / Multi-Company / Track 3 — controls the company
    /// switcher sheet presentation. Sheet itself lives in
    /// MultiCompany.swift and reads `store.companyMemberships`.
    @State private var showCompanySwitcher    = false
    // Settings save (toolbar button)
    @State private var isSavingSettings      = false
    @State private var settingsSaveError: String? = nil

    // MARK: - Per-company AI key state
    @State private var aiKeyStatus: CompanyAIKeyService.Status? = nil
    @State private var aiKeyDraft: String = ""
    @State private var isSavingAIKey      = false
    @State private var aiKeyError: String? = nil
    @State private var showAIKeyEditor    = false
    @State private var showAIKeyClearConfirm = false
    /// Spending caps + usage view. Visible to all members; only admins
    /// can change values from inside the screen.
    @State private var showAILimits        = false
    /// Phase 9 closeout: drill-in to per-call AI history. Reads
    /// audit_snapshots where record_type = 'ai_proxy_call'.
    @State private var showAIUsageHistory  = false
    /// Phase-2 deferred: per-surface AI system-prompt customization.
    @State private var showAIPromptEditor  = false
    @State private var showInviteSheet       = false
    @State private var showImportSheet       = false

    // MARK: - Integrations state
    @ObservedObject private var qbo = QBOService.shared
    @State private var showQBOConnect = false

    var body: some View {
        NavigationStack {
            Form {

                // MARK: - Job Numbers
                Section {
                    HStack {
                        Text("Next job number")
                        Spacer()
                        Text(settings.previewJobNumber())
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                            .fontDesign(.monospaced)
                    }
                    HStack {
                        Text("Company prefix")
                        Spacer()
                        TextField("e.g. AKI", text: $settings.companyPrefix)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.characters)
                            .frame(width: 80)
                    }
                } header: {
                    Text("Job Numbers")
                } footer: {
                    Text("Format: \(settings.companyPrefix.isEmpty ? "AKI" : settings.companyPrefix)-\(Calendar.current.component(.year, from: Date()))-0001. The prefix applies to all estimates, quotes, and projects.")
                }

                // MARK: - Company Info
                Section("Company Info") {
                    HStack {
                        Text("Company name")
                        Spacer()
                        TextField("Your company name", text: $settings.companyName)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Address")
                        Spacer()
                        TextField("Street, City, Province", text: $settings.companyAddress)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Phone")
                        Spacer()
                        TextField("(780) 000-0000", text: $settings.companyPhone)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.phonePad)
                    }
                    HStack {
                        Text("Email")
                        Spacer()
                        TextField("info@company.com", text: $settings.companyEmail)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                    }
                }

                // MARK: - Commercial Defaults
                Section {
                    HStack {
                        Text("Currency")
                        Spacer()
                        // 2026-04 re-audit fix: ISO 4217 picker. Common
                        // codes covered explicitly; everything else
                        // falls into "Other" which keeps whatever the
                        // user typed (still validated DB-side by the
                        // 3-uppercase-letter CHECK).
                        Picker("Currency", selection: $settings.preferredCurrency) {
                            Text("USD — US Dollar").tag("USD")
                            Text("CAD — Canadian Dollar").tag("CAD")
                            Text("EUR — Euro").tag("EUR")
                            Text("GBP — British Pound").tag("GBP")
                            Text("AUD — Australian Dollar").tag("AUD")
                            Text("MXN — Mexican Peso").tag("MXN")
                            // Fall-through tag so existing custom
                            // values don't disappear from the picker
                            // when they're outside the canonical list.
                            if !["USD","CAD","EUR","GBP","AUD","MXN"]
                                .contains(settings.preferredCurrency) {
                                Text("\(settings.preferredCurrency) — Other")
                                    .tag(settings.preferredCurrency)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220)
                    }
                    HStack {
                        Text("Tax label")
                        Spacer()
                        TextField("GST / HST / VAT", text: $settings.taxLabel)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    HStack {
                        Text("Tax rate")
                        Spacer()
                        TextField("5.0", value: $settings.taxRate, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .frame(width: 60)
                        Text("%").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Default contingency")
                        Spacer()
                        TextField("0", value: $settings.defaultContingencyPercent, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .frame(width: 60)
                        Text("%").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Quote validity")
                        Spacer()
                        Stepper("\(settings.defaultQuoteValidityDays) days",
                                value: $settings.defaultQuoteValidityDays,
                                in: 7...90, step: 7)
                    }
                } header: {
                    Text("Commercial Defaults")
                } footer: {
                    Text("These values pre-fill every new estimate and quote. You can override them on individual records.")
                }

                // MARK: - Payment Terms
                Section("Default Payment Terms") {
                    TextEditor(text: $settings.defaultPaymentTerms)
                        .frame(minHeight: 80)
                }

                // MARK: - AI Features (Bring Your Own Key)
                //
                // Each company holds their own Anthropic API key on the
                // server (`companies.anthropic_api_key`). All AI calls in
                // the app route through the `ai-proxy` Edge Function,
                // which reads the company's key, falls back to a global
                // trial key if none is set, and writes an audit log.
                //
                // This section shows status to all members (so they know
                // why AI may or may not be working) but only admins can
                // change the key.
                Section {
                    if let status = aiKeyStatus {
                        HStack(alignment: .top, spacing: AskiSpacing.md) {
                            Image(systemName: status.isSet ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(status.isSet ? .green : .orange)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(status.isSet ? "AI key configured" : "AI key not set")
                                    .font(.subheadline.weight(.semibold))
                                Text(status.summary(globalFallbackAvailable: true))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    } else {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text("Loading status…")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if store.currentUserRole.isAdmin {
                        Button {
                            aiKeyDraft = ""
                            aiKeyError = nil
                            showAIKeyEditor = true
                        } label: {
                            Label(aiKeyStatus?.isSet == true ? "Replace AI Key" : "Set AI Key",
                                  systemImage: "key.fill")
                        }
                        if aiKeyStatus?.isSet == true {
                            Button(role: .destructive) {
                                showAIKeyClearConfirm = true
                            } label: {
                                Label("Clear AI Key", systemImage: "trash")
                            }
                        }
                    }

                    // Visible to everyone — admins get an editor, members
                    // get a read-only usage view. Lives in the same
                    // screen so cost transparency is one tap away.
                    Button {
                        showAILimits = true
                    } label: {
                        Label("AI Usage & Spending Caps", systemImage: "gauge.with.dots.needle.50percent")
                    }

                    // Per-call drill-in (Week 4 closeout). Aggregate
                    // spend lives above; this is the breakdown of
                    // who/what/when. Admin-only because the response
                    // payloads can leak business context.
                    if store.currentUserRole.isAdmin {
                        Button {
                            showAIUsageHistory = true
                        } label: {
                            Label("AI Usage History", systemImage: "list.bullet.rectangle.portrait")
                        }
                        // Phase-2 deferred audit fix: tenant-customizable
                        // AI system prompts. Admin-only because changes
                        // affect every AI call across the whole company.
                        Button {
                            showAIPromptEditor = true
                        } label: {
                            Label("Customize AI Prompts", systemImage: "text.bubble.fill")
                        }
                    }
                } header: {
                    Text("AI Features")
                } footer: {
                    if store.currentUserRole.isAdmin {
                        Text("Each company brings their own Anthropic API key so usage and billing stay separate. Get a key at console.anthropic.com → API Keys. The key never leaves the server — even admins can't read it back, only replace or clear it.")
                    } else {
                        Text("AI calls (Aski Chat, document summaries, CRM insights) use your company's Anthropic API key. Contact your admin if AI features aren't working.")
                    }
                }

                // MARK: - Commercial Settings (T&C library)
                // Open to executive/manager/office_admin per spec —
                // broader than canManageUsers (which excludes
                // office_admin), so this needs its own gate.
                if [.executive, .manager, .officeAdmin].contains(store.currentUserRole) {
                    Section {
                        NavigationLink {
                            TermsTemplatesListView()
                                .environmentObject(store)
                        } label: {
                            Label("Terms & Conditions", systemImage: "doc.text.fill")
                        }
                    } header: {
                        Text("Commercial Settings")
                    } footer: {
                        Text("Manage reusable Terms & Conditions templates that can be attached to quotes.")
                    }
                }

                // MARK: - Approvals (Slice 5)
                // Manager + executive only — these are the roles that
                // can decide approvals. Office admins don't have the
                // authority per ApprovalThreshold.canApprove.
                if [.executive, .manager].contains(store.currentUserRole) {
                    Section {
                        NavigationLink {
                            PendingApprovalsListView()
                                .environmentObject(store)
                        } label: {
                            HStack {
                                Label("Pending Approvals", systemImage: "checkmark.seal")
                                Spacer()
                                if !store.pendingApprovals.isEmpty {
                                    Text("\(store.pendingApprovals.count)")
                                        .font(.caption.bold())
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.orange))
                                }
                            }
                        }
                    } footer: {
                        let salesK = Int(NSDecimalNumber(decimal: ApprovalThreshold.salesCeilingUSD / 1000).doubleValue)
                        let mgrK   = Int(NSDecimalNumber(decimal: ApprovalThreshold.managerCeilingUSD / 1000).doubleValue)
                        Text("Quotes above $\(salesK)K need manager sign-off; above $\(mgrK)K need executive sign-off, before they can be sent.")
                    }
                }

                // MARK: - Team Invites
                if store.currentUserRole.canManageUsers {
                    Section {
                        NavigationLink {
                            CostCodeSettingsView()
                                .environmentObject(store)
                        } label: {
                            Label("Cost Codes", systemImage: "tag.fill")
                        }

                        NavigationLink {
                            ProductServiceListView()
                                .environmentObject(store)
                        } label: {
                            Label("Products & Services", systemImage: "shippingbox.fill")
                        }

                        NavigationLink {
                            EmailSettingsView()
                                .environmentObject(store)
                        } label: {
                            Label("Email Sending", systemImage: "paperplane.fill")
                        }

                        Button {
                            showImportSheet = true
                        } label: {
                            Label("Import Data", systemImage: "arrow.up.doc.fill")
                                .foregroundColor(.blue)
                        }

                        NavigationLink {
                            ImportHistoryView()
                                .environmentObject(store)
                        } label: {
                            Label("Import History", systemImage: "clock.arrow.circlepath")
                        }

                        Button {
                            showInviteSheet = true
                        } label: {
                            Label("Generate Invite Code", systemImage: "person.badge.plus")
                                .foregroundColor(.blue)
                        }
                    } header: {
                        Text("Team")
                    } footer: {
                        Text("Invite codes let new users join your company with a pre-assigned role. Each code expires after 7 days.")
                    }
                }

                // MARK: - Integrations
                //
                // QuickBooks Online + (future) other accounting / e-sign
                // services live here. The status row reads the
                // server-side `qbo_connection_status` view via an RPC
                // so the company members see whether QBO is wired up
                // even if they aren't admins.
                Section {
                    HStack(alignment: .top, spacing: AskiSpacing.md) {
                        Image(systemName: qbo.status?.isConnected == true ? "checkmark.seal.fill" : "link.badge.plus")
                            .foregroundColor(qbo.status?.isConnected == true ? .green : .secondary)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("QuickBooks Online")
                                .font(.subheadline.weight(.semibold))
                            if let s = qbo.status, s.isConnected {
                                Text("Connected — realm \(s.realm_id ?? "?")")
                                    .font(.caption).foregroundColor(.secondary)
                                if let last = s.last_synced_at, !last.isEmpty {
                                    Text("Last sync \(last.prefix(10))")
                                        .font(.caption2).foregroundColor(.secondary)
                                }
                                if let err = s.last_error, !err.isEmpty {
                                    Text("⚠️ \(err)")
                                        .font(.caption2).foregroundColor(.red)
                                }
                            } else {
                                Text("Not connected")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }

                    if store.currentUserRole.isAdmin {
                        Button {
                            showQBOConnect = true
                        } label: {
                            Label(qbo.status?.isConnected == true ? "Reconnect QuickBooks" : "Connect to QuickBooks",
                                  systemImage: "link")
                        }
                    }
                } header: {
                    Text("Integrations")
                } footer: {
                    Text("Push invoices into QuickBooks Online with one tap. Set up Intuit OAuth credentials in Supabase secrets first (QBO_CLIENT_ID, QBO_CLIENT_SECRET, QBO_REDIRECT_URI).")
                }

                // MARK: - Security (MFA)
                Section {
                    HStack {
                        Label("Two-Factor Auth", systemImage: "lock.shield.fill")
                        Spacer()
                        if mfaEnabled {
                            Text("Enabled")
                                .font(.subheadline).foregroundColor(.green)
                        } else {
                            Text("Off")
                                .font(.subheadline).foregroundColor(.secondary)
                        }
                    }
                    if mfaEnabled {
                        Button(role: .destructive) {
                            showDisableMFAConfirm = true
                        } label: {
                            Label("Disable Authenticator", systemImage: "xmark.shield")
                        }
                    } else {
                        Button {
                            showMFAEnroll = true
                        } label: {
                            Label("Enable Authenticator App", systemImage: "plus.app")
                                .foregroundColor(.blue)
                        }
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text(mfaEnabled
                         ? "Your account requires a one-time code from your authenticator app each time you sign in."
                         : "Add an extra layer of protection. You'll need your authenticator app every time you sign in.")
                }

                // MARK: - Account
                Section("Account") {
                    HStack {
                        Label("Display Name", systemImage: "person.circle")
                        Spacer()
                        TextField("Your name", text: $displayName)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.primary)
                            .onSubmit { Task { await saveDisplayName() } }
                        if isSavingName {
                            ProgressView().scaleEffect(0.7)
                        }
                    }
                    HStack {
                        Label("Email", systemImage: "envelope")
                        Spacer()
                        Text(store.currentUser?.email ?? "")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                    // Role — READ-ONLY display.
                    //
                    // FUTURE WORK: role changes belong in a Team / Users
                    // admin screen, not personal Settings. The rules:
                    //   * Users can view their own role here
                    //   * Only `executive` can change another user's role
                    //   * Self-promotion is forbidden (security)
                    //   * Even an executive shouldn't accidentally change
                    //     their own role from this screen
                    // `AuthService.updateRole(_:)` exists for the future
                    // Team Management screen to call.
                    HStack {
                        Label("Role", systemImage: "person.badge.key.fill")
                        Spacer()
                        Text(store.currentUserRole.displayName)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                    // Tenant identity — visible at a glance, tap-to-copy
                    // for support tickets / debugging tenant isolation
                    // issues. Truncated middle so the full UUID fits on
                    // narrow phones; long-press for the full value.
                    if let cid = store.currentCompanyID {
                        Button {
                            UIPasteboard.general.string = cid.uuidString
                            ToastService.shared.success("Company ID copied")
                        } label: {
                            HStack {
                                Label("Company ID", systemImage: "building.2")
                                    .foregroundColor(.primary)
                                Spacer()
                                Text(cid.uuidString.prefix(8) + "…" + cid.uuidString.suffix(4))
                                    .foregroundColor(.secondary)
                                    .font(.subheadline.monospaced())
                                Image(systemName: "doc.on.doc")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Company ID \(cid.uuidString). Tap to copy.")
                    }
                    Button(role: .destructive) {
                        Task {
                            try? await AuthService.signOut()
                            store.fullSignOutReset()
                        }
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }

                // MARK: - Company (admin-only edit)
                // Visible to all members; editable only by admins per RLS.
                // Default name "My Company" comes from setup_new_user when
                // no company name is provided at signup — fix it here.
                if store.currentCompanyID != nil {
                    Section("Company") {
                        HStack {
                            Label("Name", systemImage: "building.2.fill")
                            Spacer()
                            TextField("Company name", text: $companyNameDraft)
                                .multilineTextAlignment(.trailing)
                                .foregroundColor(.primary)
                                .disabled(!store.currentUserRole.isAdmin || isSavingCompanyName)
                                .onSubmit { Task { await saveCompanyName() } }
                            if isSavingCompanyName {
                                ProgressView().scaleEffect(0.7)
                            }
                        }
                        if let err = companyNameError {
                            Text(err).font(.caption).foregroundColor(.red)
                        }
                        if !store.currentUserRole.isAdmin {
                            Text("Only admins can change the company name.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        // Phase 8 / Multi-Company / Track 3 — surface the
                        // company switcher. Single-membership users still
                        // see the row (confirms which tenant they're in);
                        // the sheet's footer explains that switching
                        // unlocks once multiple memberships exist.
                        Button {
                            showCompanySwitcher = true
                        } label: {
                            Label("Switch Company", systemImage: "rectangle.2.swap")
                        }
                    }
                }

                // MARK: - Privacy & Data
                Section {
                    Button {
                        Task { await runExport() }
                    } label: {
                        if isExporting {
                            HStack {
                                ProgressView().scaleEffect(0.85)
                                Text("Preparing your data…")
                            }
                        } else {
                            Label("Download My Data", systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(isExporting)
                    if let exportError {
                        Text(exportError)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    // PIPEDA / GDPR right-to-erasure pair to "Download My Data".
                    // Apple App Store guideline 5.1.1(v) requires this be
                    // reachable from inside the app for any account-creating
                    // app — without it, the app is rejected at review.
                    Button(role: .destructive) {
                        showDeleteAccount = true
                    } label: {
                        Label("Delete My Account", systemImage: "person.crop.circle.badge.xmark")
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Download your data: a JSON file with every record from this company. PIPEDA / GDPR right of access compliant.\n\nDelete your account: permanently removes your sign-in. Business records (timesheets, invoices, incidents) stay with the company; your name and email are scrubbed.")
                }

                // MARK: - App Info
                Section("App Info") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0 — Session 4")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                    HStack {
                        Text("Database")
                        Spacer()
                        Text("Supabase")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }

                // MARK: - Sample Data (admin-only — Load + Clear)
                if store.currentUserRole == .executive
                    || store.currentUserRole == .officeAdmin {
                    SampleDataSettingsView()
                }

                // MARK: - Reset / Setup
                if store.currentUserRole.isAdmin {
                    Section {
                        // Lets an admin re-walk the first-run wizard at any
                        // time. Useful when a new admin joins the company
                        // and wants the guided tour even though the tenant
                        // is no longer "fresh."
                        Button {
                            OnboardingPresenter.shared.forcePresent()
                        } label: {
                            Label("Re-run Setup Wizard", systemImage: "wand.and.stars")
                        }

                        Button(role: .destructive) {
                            showResetConfirm = true
                        } label: {
                            Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                // Explicit Save button — only enabled when the user has
                // unsaved changes. This is the canonical way to push
                // settings to Supabase; never relies on didSet writes.
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await saveSettings() }
                    } label: {
                        if isSavingSettings {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Text("Save").bold()
                        }
                    }
                    .disabled(!settings.hasUnsavedChanges || isSavingSettings)
                }
            }
            .alert(
                "Couldn't save settings",
                isPresented: Binding(
                    get: { settingsSaveError != nil },
                    set: { if !$0 { settingsSaveError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { settingsSaveError = nil }
            } message: {
                Text(settingsSaveError ?? "")
            }
            .alert("Reset to Defaults?", isPresented: $showResetConfirm) {
                Button("Reset", role: .destructive) { settings.resetToDefaults() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This resets all commercial defaults and company prefix. Your data is not affected.")
            }
            .sheet(isPresented: $showExportShareSheet) {
                if let url = exportFileURL {
                    ShareSheet(items: [url])
                }
            }
            .sheet(isPresented: $showDeleteAccount) {
                AccountDeletionView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showDisableMFAConfirm) {
                if let fid = mfaFactorId {
                    MFADisableConfirmView(factorId: fid) {
                        Task { await refreshMFAStatus() }
                    }
                }
            }
            .sheet(isPresented: $showMFAEnroll) {
                MFAEnrollView {
                    Task { await refreshMFAStatus() }
                }
            }
            .sheet(isPresented: $showInviteSheet) {
                InviteCodeGeneratorView()
            }
            // Phase 8 / Multi-Company / Track 3 — switcher.
            .sheet(isPresented: $showCompanySwitcher) {
                CompanySwitcherSheet()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showImportSheet) {
                MultiTabImportView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showAIKeyEditor) {
                AIKeyEditorSheet(
                    draft:    $aiKeyDraft,
                    isSaving: $isSavingAIKey,
                    error:    $aiKeyError,
                    onSave: { newKey in
                        await saveAIKey(newKey)
                    }
                )
            }
            .sheet(isPresented: $showAILimits) {
                AILimitsView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showAIUsageHistory) {
                AIUsageHistoryView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showAIPromptEditor) {
                CompanyAIPromptEditorView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showQBOConnect, onDismiss: {
                Task { await qbo.refreshStatus() }
            }) {
                QBOConnectSheet()
            }
            .alert("Clear AI key?", isPresented: $showAIKeyClearConfirm) {
                Button("Clear", role: .destructive) {
                    Task { await clearAIKey() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("AI features will stop working for everyone in your company until a new key is set. The shared trial key (if any) will not be used as a fallback.")
            }
            .task {
                displayName       = store.currentUser?.fullName ?? ""
                companyNameDraft  = await loadCompanyName()
                await refreshMFAStatus()
                await refreshAIKeyStatus()
                await qbo.refreshStatus()
            }
        }
    }

    // MARK: - AI key management

    private func refreshAIKeyStatus() async {
        do {
            aiKeyStatus = try await CompanyAIKeyService.shared.fetchStatus()
        } catch {
            // Don't toast — the section will just keep showing "Loading…"
            // which is fine; the user retries on a re-render.
            aiKeyStatus = .init(isSet: false, updatedAt: nil, updatedByName: nil)
        }
    }

    private func saveAIKey(_ rawKey: String) async {
        isSavingAIKey = true
        aiKeyError = nil
        defer { isSavingAIKey = false }
        do {
            try await CompanyAIKeyService.shared.set(key: rawKey)
            await refreshAIKeyStatus()
            showAIKeyEditor = false
            aiKeyDraft = ""
            ToastService.shared.success("AI key saved. Calls will use this key from now on.")
        } catch let err as CompanyAIKeyService.KeyError {
            aiKeyError = err.errorDescription
        } catch {
            aiKeyError = error.localizedDescription
        }
    }

    private func clearAIKey() async {
        do {
            try await CompanyAIKeyService.shared.clear()
            await refreshAIKeyStatus()
            ToastService.shared.warning("AI key cleared. AI features are now disabled for the company.")
        } catch {
            ToastService.shared.error("Couldn't clear key: \(error.localizedDescription)")
        }
    }

    /// Generates the JSON export and presents the share sheet so the user
    /// can save it to Files / email / send. PIPEDA right-of-access.
    @MainActor
    private func runExport() async {
        exportError = nil
        isExporting = true
        defer { isExporting = false }
        do {
            let url = try DataExportService.shared.exportAll(from: store)
            exportFileURL = url
            showExportShareSheet = true
        } catch let err as DataExportService.ExportError {
            exportError = err.errorDescription
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func saveDisplayName() async {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed != store.currentUser?.fullName else { return }
        isSavingName = true
        do {
            try await AuthService.updateDisplayName(trimmed)
            let parts = trimmed.components(separatedBy: " ")
            store.currentUser?.firstName = parts.first ?? trimmed
            store.currentUser?.lastName  = parts.dropFirst().joined(separator: " ")
        } catch {
            // Revert on failure
            displayName = store.currentUser?.fullName ?? ""
        }
        isSavingName = false
    }

    /// Push the in-memory settings cache to Supabase. Called by the
    /// toolbar Save button. Surfaces failures via an alert so the user
    /// knows whether the values they typed actually persisted.
    private func saveSettings() async {
        guard !isSavingSettings else { return }
        isSavingSettings = true
        defer { isSavingSettings = false }
        do {
            try await settings.save()
        } catch {
            settingsSaveError = error.localizedDescription
        }
    }

    /// Read the current company name fresh from Supabase — the name
    /// isn't mirrored in the local AppStore, so we round-trip on view
    /// appear. Returns "" if the lookup fails (lets the placeholder
    /// "Company name" show in the TextField).
    private func loadCompanyName() async -> String {
        guard let cid = store.currentCompanyID else { return "" }
        struct Row: Decodable { let name: String? }
        do {
            let rows: [Row] = try await supabase
                .from(SupabaseTable.companies)
                .select("name")
                .eq("id", value: cid.uuidString)
                .limit(1)
                .execute()
                .value
            return rows.first?.name ?? ""
        } catch {
            return ""
        }
    }

    /// Persist the company-name change. RLS on companies decides whether
    /// the caller is permitted to update; non-admins are also gated in
    /// the UI so the call shouldn't typically be reached.
    private func saveCompanyName() async {
        let trimmed = companyNameDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let companyID = store.currentCompanyID else { return }
        isSavingCompanyName = true
        companyNameError    = nil
        do {
            try await AuthService.updateCompanyName(trimmed, companyID: companyID)
            // No mirror in AppStore — the SyncEngine will pick up the
            // new name on next pull. Settings re-renders show the draft
            // value already.
        } catch {
            companyNameError = "Couldn't update company name: \(error.localizedDescription)"
        }
        isSavingCompanyName = false
    }

    private func refreshMFAStatus() async {
        let factorId   = await AuthService.mfaFactorID()
        mfaFactorId    = factorId
        mfaEnabled     = factorId != nil
    }
}

// MARK: - Invite Code Generator Sheet

struct InviteCodeGeneratorView: View {
    @Environment(\.dismiss) var dismiss

    private let invitableRoles: [UserRole] = [
        .fieldWorker, .foreman, .safetyAdvisor, .projectManager,
        .estimator, .officeAdmin, .manager
    ]

    @State private var selectedRole: UserRole = .fieldWorker
    @State private var generatedCode: String? = nil
    @State private var isLoading            = false
    @State private var errorMessage: String? = nil
    @State private var copied               = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Choose the role for the new team member. They'll have this role as soon as they use the code to create their account.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .listRowBackground(Color.clear)
                }

                Section("Role") {
                    Picker("Role", selection: $selectedRole) {
                        ForEach(invitableRoles, id: \.self) { role in
                            Text(role.displayName).tag(role)
                        }
                    }
                    .pickerStyle(.inline)
                    .onChange(of: selectedRole) { generatedCode = nil; errorMessage = nil }
                }

                if let code = generatedCode {
                    Section {
                        VStack(spacing: 16) {
                            Text(code)
                                .font(.system(size: 32, weight: .bold, design: .monospaced))
                                .tracking(6)
                                .foregroundColor(.orange)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)

                            Button {
                                UIPasteboard.general.string = code
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                            } label: {
                                Label(copied ? "Copied!" : "Copy Code", systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(copied ? .green : .orange)

                            ShareLink(item: "Your Aski IQ invite code: \(code)\n\nDownload the app and use this code when creating your account. It expires in 7 days.") {
                                Label("Share Code", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color.clear)
                    } header: {
                        Text("Invite Code — expires in 7 days")
                    }
                }

                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                if generatedCode == nil {
                    Section {
                        Button {
                            Task { await generate() }
                        } label: {
                            if isLoading {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                    Spacer()
                                }
                            } else {
                                Label("Generate Code", systemImage: "plus.circle.fill")
                                    .frame(maxWidth: .infinity)
                                    .foregroundColor(.white)
                            }
                        }
                        .listRowBackground(isLoading ? Color.gray.opacity(0.3) : Color.orange)
                        .disabled(isLoading)
                    }
                } else {
                    Section {
                        Button {
                            generatedCode = nil
                            errorMessage  = nil
                        } label: {
                            Label("Generate Another Code", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Invite Team Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func generate() async {
        isLoading    = true
        errorMessage = nil
        do {
            generatedCode = try await AuthService.createInvite(role: selectedRole)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - AI Key Editor Sheet
//
// Pasting an Anthropic key in plain view feels wrong, so we use SecureField
// + a non-trivial confirmation step. Once saved, the value is gone from
// the device — the server stores it, and the status RPC only returns
// metadata (is_set / when / by whom).

private struct AIKeyEditorSheet: View {
    @Binding var draft: String
    @Binding var isSaving: Bool
    @Binding var error: String?
    let onSave: (String) async -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-…", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Anthropic API Key")
                } footer: {
                    Text("Get a key at console.anthropic.com → API Keys. Once saved it's stored server-side and can't be read back — only replaced or cleared.")
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.subheadline)
                    }
                }

                Section {
                    Button {
                        Task { await onSave(draft) }
                    } label: {
                        if isSaving {
                            HStack {
                                ProgressView().scaleEffect(0.85)
                                Text("Saving…")
                            }
                        } else {
                            Label("Save AI Key", systemImage: "checkmark.seal.fill")
                        }
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .navigationTitle("Set AI Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
