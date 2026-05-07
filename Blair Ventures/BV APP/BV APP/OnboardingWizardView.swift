// OnboardingWizardView.swift
// Aski IQ — First-run setup wizard for new company admins (Tier A).
//
// WHY THIS EXISTS
// A brand-new admin signing in to an empty Aski IQ tenant has to figure
// out, in order: where company info lives, where invite codes are
// generated, how to plug in their AI key, what spending caps mean,
// and how to make the first project. Each of those screens already
// exists in Settings — but burying them six taps deep means most
// founders abandon mid-setup and call back next week saying "AI
// doesn't work" or "I can't add my crew."
//
// This wizard is a single guided flow that touches each of those
// surfaces once, in a sane order, so a new admin can be up and running
// in 5–10 minutes. Each step writes to the same backend services the
// permanent Settings screens use — no duplicated state, no parallel
// universe to debug later.
//
// TRIGGER LOGIC
// `OnboardingPresenter` decides whether to show the wizard. It fires
// on the FIRST authenticated session for a given (admin, company)
// pair where the wizard has not yet been completed AND the company
// looks empty (no other projects). The "completed" flag persists in
// UserDefaults keyed by companyID so re-installs on the same tenant
// don't re-trigger.
//
// SKIPPABLE STEPS
// Every step has a Skip option. Skipping is logged (we set the
// completion flag either way) so an admin can run through it once,
// dismiss the parts they don't want, and never see it again. There's
// no "Re-open Wizard" button by design — Settings already exposes
// every individual surface so a power user can change anything later.
//
// ROLE GATING
// Only `currentUserRole.isAdmin` (executive in this codebase) sees
// the wizard at all. Non-admins land directly on RootView. Server
// RPCs would refuse the AI-key + caps writes anyway, but failing
// silently mid-wizard would be a worse UX than just not showing it.

import SwiftUI
import Combine

// MARK: - Presenter

/// Drives whether the wizard is shown. Wraps the UserDefaults flag,
/// the empty-tenant heuristic, and the role gate behind one published
/// boolean that BV_APPApp's RootView observes via `.sheet(isPresented:)`.
@MainActor
final class OnboardingPresenter: ObservableObject {

    static let shared = OnboardingPresenter()
    private init() {}

    /// True when we want the wizard sheet up. RootView binds this.
    @Published var isPresented: Bool = false

    /// UserDefaults key. Per-company so a user who switches tenants
    /// (edge case — most won't) sees the wizard once per fresh tenant.
    private func defaultsKey(for companyID: UUID) -> String {
        "aski.onboarding.completed.\(companyID.uuidString)"
    }

    /// True if the wizard has already been run (or skipped) for this
    /// tenant. We set the flag on Finish OR Skip so the wizard never
    /// nags a user who actively dismissed it.
    func hasCompleted(for companyID: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: defaultsKey(for: companyID))
    }

    func markCompleted(for companyID: UUID) {
        UserDefaults.standard.set(true, forKey: defaultsKey(for: companyID))
    }

    /// "Empty tenant" means there are no projects on file — by the time
    /// a real company has used the app for an hour they will have at
    /// least one. Avoids re-triggering on a returning user who just
    /// happens not to have completed the wizard.
    func looksEmpty(in store: AppStore) -> Bool {
        store.projects.isEmpty
    }

    /// Called from BV_APPApp once the initial pull is done. If the
    /// gate passes, flip `isPresented` so the sheet binding fires.
    func evaluate(in store: AppStore) {
        guard store.isAuthenticated,
              store.currentUserRole.isAdmin,
              let cid = store.currentCompanyID,
              !hasCompleted(for: cid),
              looksEmpty(in: store) else {
            return
        }
        // Defer one runloop so the sheet doesn't try to mount before
        // RootView's Tab transitions settle.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.isPresented = true
        }
    }

    /// Manual trigger for the Settings → "Re-run Setup" button (added
    /// in a follow-up session for any admin who wants the tour again).
    func forcePresent() {
        isPresented = true
    }
}

// MARK: - Wizard

/// Five-step setup wizard. Pages live as private subviews below so the
/// outer step controller stays small and obvious.
struct OnboardingWizardView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var presenter = OnboardingPresenter.shared
    @Environment(\.dismiss) var dismiss

    @State private var step: Step = .welcome

    enum Step: Int, CaseIterable {
        case welcome, company, team, aiKey, caps, project, finish
        var progress: Double {
            // First (welcome) = 0%, last (finish) = 100%; middle five
            // share the bar evenly.
            Double(rawValue) / Double(Step.allCases.count - 1)
        }
        var title: String {
            switch self {
            case .welcome: return "Welcome to Aski IQ"
            case .company: return "Company Info"
            case .team:    return "Invite Your Team"
            case .aiKey:   return "Connect AI"
            case .caps:    return "Spending Caps"
            case .project: return "First Project"
            case .finish:  return "You're Ready"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // MARK: Progress bar
                ProgressView(value: step.progress)
                    .tint(.purple)
                    .padding(.horizontal)
                    .padding(.top, 8)

                Divider().padding(.top, 8)

                // MARK: Active step
                Group {
                    switch step {
                    case .welcome: WelcomeStep(advance: advance)
                    case .company: CompanyInfoStep(settings: settings, advance: advance, skip: skip)
                    case .team:    TeamInviteStep(advance: advance, skip: skip)
                    case .aiKey:   AIKeyStep(advance: advance, skip: skip)
                    case .caps:    SpendingCapsStep(advance: advance, skip: skip)
                    case .project: FirstProjectStep(advance: advance, skip: skip)
                    case .finish:  FinishStep(close: finishWizard)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.25), value: step)
            }
            .navigationTitle(step.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if step != .welcome && step != .finish {
                        Button {
                            // Step backwards; never below welcome.
                            if let prev = Step(rawValue: step.rawValue - 1) {
                                step = prev
                            }
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Skip All") {
                        skipEverything()
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }
            }
            .interactiveDismissDisabled(step != .finish && step != .welcome)
        }
    }

    // MARK: - Step transitions

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    private func skip() {
        // Same as advance — we don't track "skipped this step" granularly.
        // Telemetry would be nice; not worth the schema cost yet.
        advance()
    }

    private func skipEverything() {
        // Mark complete and close. The user is choosing "I know what
        // I'm doing" — we respect that and don't pop back.
        if let cid = store.currentCompanyID {
            presenter.markCompleted(for: cid)
        }
        presenter.isPresented = false
        dismiss()
    }

    private func finishWizard() {
        if let cid = store.currentCompanyID {
            presenter.markCompleted(for: cid)
        }
        presenter.isPresented = false
        dismiss()
    }
}

// MARK: - Step 0: Welcome

private struct WelcomeStep: View {
    let advance: () -> Void
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "bolt.shield.fill")
                .font(.system(size: 72))
                .foregroundStyle(.linearGradient(colors: [.purple, .blue], startPoint: .top, endPoint: .bottom))

            VStack(spacing: 8) {
                Text("Welcome\(store.currentUser?.firstName.isEmpty == false ? ", \(store.currentUser!.firstName)" : "")")
                    .font(.largeTitle).bold()
                Text("Let's get your company set up. About 5 minutes.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            VStack(alignment: .leading, spacing: 12) {
                wizardChecklistItem("building.2", "Company info — what shows on quotes & invoices")
                wizardChecklistItem("person.2.badge.plus", "Invite your team")
                wizardChecklistItem("brain.head.profile", "Connect AI (optional)")
                wizardChecklistItem("gauge.with.dots.needle.50percent", "Set spending caps")
                wizardChecklistItem("hammer.fill", "Create your first project")
            }
            .padding(.top, 16)
            .padding(.horizontal, 24)

            Spacer()

            Button {
                advance()
            } label: {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func wizardChecklistItem(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundColor(.purple)
            Text(text)
                .font(.subheadline)
            Spacer()
        }
    }
}

// MARK: - Step 1: Company Info

private struct CompanyInfoStep: View {
    @ObservedObject var settings: AppSettings
    let advance: () -> Void
    let skip: () -> Void

    /// We don't BLOCK on company name (some users self-employ and
    /// just want their name on quotes), but we DO surface a warning
    /// because downstream documents look weird without it.
    private var hasMinInfo: Bool {
        !settings.companyName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section {
                Text("Shown on quotes, invoices, and contract signing pages. You can change any of this later in Settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .listRowBackground(Color.clear)
            }

            Section("Company") {
                LabeledTextField(label: "Name", placeholder: "Acme Construction Ltd.", text: $settings.companyName)
                LabeledTextField(label: "Address", placeholder: "Street, City, Province", text: $settings.companyAddress)
                LabeledTextField(label: "Phone", placeholder: "(780) 000-0000", text: $settings.companyPhone, keyboard: .phonePad)
                LabeledTextField(label: "Email", placeholder: "info@acme.com", text: $settings.companyEmail, keyboard: .emailAddress, autocapitalize: false)
            }

            // Section with both header + footer must use the
            // 3-trailing-closure form; the `Section("Title") { } footer: { }`
            // shorthand isn't valid SwiftUI syntax.
            Section {
                HStack {
                    Text("Prefix")
                    Spacer()
                    TextField("AKI", text: $settings.companyPrefix)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.characters)
                        .frame(width: 100)
                }
            } header: {
                Text("Job Number Prefix")
            } footer: {
                Text("Future job numbers will look like \(settings.companyPrefix.isEmpty ? "AKI" : settings.companyPrefix)-\(Calendar.current.component(.year, from: Date()))-0001.")
            }

            if !hasMinInfo {
                Section {
                    Label("Set the company name so quotes and invoices look right.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
            }

            Section {
                Button {
                    advance()
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                        .foregroundColor(.white)
                }
                .listRowBackground(Color.purple)

                Button("Skip") { skip() }
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Step 2: Team Invites

private struct TeamInviteStep: View {
    let advance: () -> Void
    let skip: () -> Void

    @State private var generatedCodes: [GeneratedCode] = []
    @State private var pickedRole: UserRole = .foreman
    @State private var isGenerating = false
    @State private var error: String?

    /// Roles a brand-new admin most likely needs first. Office-side
    /// roles (officeAdmin, manager) usually arrive later when the team
    /// grows past a single admin.
    private let priorityRoles: [UserRole] = [.foreman, .fieldWorker, .projectManager, .estimator]

    /// Stable display row so the list re-renders without re-fetching.
    private struct GeneratedCode: Identifiable {
        let id = UUID()
        let role: UserRole
        let code: String
    }

    var body: some View {
        Form {
            Section {
                Text("Generate a code per role. Share it (text, email, AirDrop) — the new user enters it on signup and lands with that role pre-assigned. Each code is good for 7 days.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .listRowBackground(Color.clear)
            }

            Section("Pick a role to invite") {
                Picker("Role", selection: $pickedRole) {
                    ForEach(priorityRoles, id: \.self) { r in
                        Text(r.displayName).tag(r)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    Task { await generate() }
                } label: {
                    HStack {
                        if isGenerating {
                            ProgressView().scaleEffect(0.85)
                            Text("Generating…")
                        } else {
                            Image(systemName: "plus.circle.fill")
                            Text("Generate \(pickedRole.displayName) Code")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundColor(.white)
                }
                .listRowBackground(isGenerating ? Color.gray : Color.blue)
                .disabled(isGenerating)

                if let err = error {
                    Text(err).font(.caption).foregroundColor(.red)
                }
            }

            if !generatedCodes.isEmpty {
                Section("Codes (tap to share)") {
                    ForEach(generatedCodes) { gc in
                        ShareLink(item: shareText(for: gc)) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(gc.role.displayName)
                                        .font(.subheadline)
                                    Text(gc.code)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundColor(.purple)
                                        .tracking(2)
                                }
                                Spacer()
                                Image(systemName: "square.and.arrow.up")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    advance()
                } label: {
                    Text(generatedCodes.isEmpty ? "Continue (invite later)" : "Continue")
                        .frame(maxWidth: .infinity)
                        .foregroundColor(.white)
                }
                .listRowBackground(Color.purple)

                Button("Skip") { skip() }
                    .foregroundColor(.secondary)
            }
        }
    }

    private func shareText(for gc: GeneratedCode) -> String {
        "Aski IQ invite code: \(gc.code) (\(gc.role.displayName)) — download the app and enter this code on signup. Expires in 7 days."
    }

    private func generate() async {
        isGenerating = true
        error = nil
        defer { isGenerating = false }
        do {
            let code = try await AuthService.createInvite(role: pickedRole)
            generatedCodes.append(GeneratedCode(role: pickedRole, code: code))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Step 3: AI Key

private struct AIKeyStep: View {
    let advance: () -> Void
    let skip: () -> Void

    @State private var draftKey: String = ""
    @State private var isSaving = false
    @State private var savedOK = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Optional — but unlocks Aski Chat, contract review, CRM auto-summaries, and more.", systemImage: "sparkles")
                        .font(.subheadline)
                        .foregroundColor(.purple)
                    Text("Aski IQ uses Anthropic's Claude. Bring your own API key so usage and billing stay on your account.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .listRowBackground(Color.clear)
            }

            Section {
                SecureField("sk-ant-…", text: $draftKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("Anthropic API Key")
            } footer: {
                Text("Get a key at console.anthropic.com → API Keys. The key is stored encrypted on the server and never leaves it — even admins can only replace it, not read it back.")
            }

            if savedOK {
                Section {
                    Label("AI key saved.", systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                }
            }

            if let err = error {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        if isSaving {
                            ProgressView().scaleEffect(0.85)
                            Text("Saving…")
                        } else {
                            Text(savedOK ? "Continue" : "Save & Continue")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundColor(.white)
                }
                .listRowBackground(Color.purple)
                .disabled(isSaving || (draftKey.trimmingCharacters(in: .whitespaces).isEmpty && !savedOK))

                Button("Skip — set up AI later") { skip() }
                    .foregroundColor(.secondary)
            }
        }
    }

    private func save() async {
        if savedOK { advance(); return }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            try await CompanyAIKeyService.shared.set(key: draftKey)
            savedOK = true
            // Brief beat to let the user see "saved", then advance.
            try? await Task.sleep(nanoseconds: 600_000_000)
            advance()
        } catch let err as CompanyAIKeyService.KeyError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Step 4: Spending Caps

private struct SpendingCapsStep: View {
    let advance: () -> Void
    let skip: () -> Void

    /// Whole-dollar inputs; we convert to cents on save (DB stores cents).
    @State private var dailyDollars: String = "10"
    @State private var monthlyDollars: String = "200"
    @State private var pauseWhenExceeded: Bool = true
    @State private var notifyAdmins: Bool = true
    @State private var isSaving = false
    @State private var savedOK = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text("Hard caps on AI spending. When the daily or monthly limit is reached, AI calls pause until the next window — protects you from a runaway bug or someone leaving a chat open overnight.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .listRowBackground(Color.clear)
            }

            Section("Daily cap") {
                HStack {
                    Text("$")
                    TextField("10", text: $dailyDollars)
                        .keyboardType(.decimalPad)
                    Text("USD / day").foregroundColor(.secondary)
                }
            }

            Section("Monthly cap") {
                HStack {
                    Text("$")
                    TextField("200", text: $monthlyDollars)
                        .keyboardType(.decimalPad)
                    Text("USD / month").foregroundColor(.secondary)
                }
            }

            Section {
                Toggle("Pause AI when cap is reached", isOn: $pauseWhenExceeded)
                Toggle("Notify admins on cap hit", isOn: $notifyAdmins)
            } header: {
                Text("Behavior")
            } footer: {
                Text("If you turn pause off, calls keep running and you'll get billed past the cap — only flip this if you really know what you're doing.")
            }

            if savedOK {
                Section {
                    Label("Caps saved.", systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                }
            }

            if let err = error {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        if isSaving {
                            ProgressView().scaleEffect(0.85)
                            Text("Saving…")
                        } else {
                            Text(savedOK ? "Continue" : "Save & Continue")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundColor(.white)
                }
                .listRowBackground(Color.purple)
                .disabled(isSaving)

                Button("Skip — accept defaults") { skip() }
                    .foregroundColor(.secondary)
            }
        }
    }

    private func save() async {
        if savedOK { advance(); return }
        isSaving = true
        error = nil
        defer { isSaving = false }

        // Parse dollar amounts to cents. Empty = no cap on that axis.
        let dailyCents: Int64? = dollarsToCents(dailyDollars)
        let monthlyCents: Int64? = dollarsToCents(monthlyDollars)

        do {
            try await CompanyAILimitsService.shared.setLimits(
                dailyTokenLimit:          nil,                  // not exposed in onboarding — too low-level
                monthlyTokenLimit:        nil,
                dailyCostLimitCents:      dailyCents,
                monthlyCostLimitCents:    monthlyCents,
                pauseWhenExceeded:        pauseWhenExceeded,
                adminNotificationEnabled: notifyAdmins
            )
            savedOK = true
            try? await Task.sleep(nanoseconds: 600_000_000)
            advance()
        } catch let err as CompanyAILimitsService.LimitsError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func dollarsToCents(_ s: String) -> Int64? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let d = Double(trimmed), d > 0 else { return nil }
        return Int64((d * 100).rounded())
    }
}

// MARK: - Step 5: First Project

private struct FirstProjectStep: View {
    let advance: () -> Void
    let skip: () -> Void

    @EnvironmentObject var store: AppStore
    @ObservedObject private var settings = AppSettings.shared

    @State private var name = ""
    @State private var clientName = ""
    @State private var address = ""
    @State private var startDate = Date()
    @State private var saved = false

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !clientName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section {
                Text("A starter project so the dashboard isn't empty. You can add real ones later from the Projects tab.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .listRowBackground(Color.clear)
            }

            Section("Project") {
                LabeledTextField(label: "Name", placeholder: "e.g. Smith Residence Re-roof", text: $name)
                LabeledTextField(label: "Client", placeholder: "e.g. Smith Family", text: $clientName)
                LabeledTextField(label: "Address", placeholder: "Street, City", text: $address)
                DatePicker("Start date", selection: $startDate, displayedComponents: .date)
            }

            if saved {
                Section {
                    Label("Project created.", systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                }
            }

            Section {
                Button {
                    saveAndAdvance()
                } label: {
                    Text(saved ? "Continue" : "Create & Continue")
                        .frame(maxWidth: .infinity)
                        .foregroundColor(.white)
                }
                .listRowBackground(canSave ? Color.purple : Color.gray)
                .disabled(!canSave && !saved)

                Button("Skip — add projects later") { skip() }
                    .foregroundColor(.secondary)
            }
        }
    }

    private func saveAndAdvance() {
        if saved { advance(); return }
        var p = Project(
            name: name.trimmingCharacters(in: .whitespaces),
            clientName: clientName.trimmingCharacters(in: .whitespaces)
        )
        p.siteAddress = address.trimmingCharacters(in: .whitespaces).isEmpty ? nil : address
        p.startDate = startDate
        p.status = .active
        p.jobNumber = settings.nextJobNumber()
        p.companyID = store.currentCompanyID
        store.upsertProject(p)
        saved = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            advance()
        }
    }
}

// MARK: - Step 6: Finish

private struct FinishStep: View {
    let close: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 96))
                .foregroundStyle(.linearGradient(colors: [.green, .mint], startPoint: .top, endPoint: .bottom))
            VStack(spacing: 8) {
                Text("You're all set")
                    .font(.largeTitle).bold()
                Text("Everything you set up here lives in Settings — change anything you need from there.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            VStack(alignment: .leading, spacing: 10) {
                bullet("Open the Schedule tab to plan your first crew shift.")
                bullet("Use the Projects tab to dig into your starter project.")
                bullet("Tap the chat bubble for Aski (your AI assistant).")
            }
            .padding(.horizontal, 32)
            .padding(.top, 8)

            Spacer()

            Button {
                close()
            } label: {
                Text("Open Aski IQ")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundColor(.purple)
                .padding(.top, 7)
            Text(s)
                .font(.subheadline)
            Spacer()
        }
    }
}

// MARK: - Reusable Field

/// Compact labeled-text-field row, used by Company Info and First
/// Project. We define our own (instead of plain TextField) so the
/// field labels visually line up the same way across both steps.
private struct LabeledTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var autocapitalize: Bool = true

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 80, alignment: .leading)
                .foregroundColor(.secondary)
                .font(.subheadline)
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(autocapitalize ? .sentences : .never)
                .autocorrectionDisabled(!autocapitalize)
        }
    }
}
