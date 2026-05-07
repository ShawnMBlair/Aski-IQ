// EmailSettingsView.swift
// Aski IQ — per-company email sender settings.
//
// Settings → Company Settings → Email Sending
//
// Lets an admin set the branded sender name, reply-to inbox, and
// signature. Custom domain verification is shown as info only for beta —
// every tenant uses the platform Resend domain until they go through
// DNS verification post-beta.

import SwiftUI

struct EmailSettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    @State private var settings:    CompanyEmailSettings? = nil
    @State private var loadError:   String? = nil
    @State private var isLoading:   Bool    = true
    @State private var isSaving:    Bool    = false
    @State private var saveError:   String? = nil
    @State private var saveSuccess: Bool    = false

    @State private var showTestSheet: Bool   = false
    @State private var testRecipient: String = ""
    @State private var isSendingTest: Bool   = false
    @State private var testResult:    String? = nil

    private var canEdit: Bool {
        let role = store.currentUserRole
        return role == .executive || role == .manager || role == .officeAdmin
    }

    var body: some View {
        Form {
            if isLoading {
                Section { ProgressView("Loading email settings…") }
            } else if let error = loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Button("Retry") { Task { await load() } }
                }
            } else if var s = settings {
                senderIdentitySection(s: Binding(
                    get: { settings ?? s },
                    set: { settings = $0 }
                ))
                signatureSection(s: Binding(
                    get: { settings ?? s },
                    set: { settings = $0 }
                ))
                statusSection(s: s)
                testSection(s: s)
                customDomainInfoSection()

                if !canEdit {
                    Section {
                        Label("Only admins can edit these settings.",
                              systemImage: "lock.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Email Sending")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isSaving {
                    ProgressView()
                } else if canEdit {
                    Button("Save") { Task { await save() } }
                        .bold()
                        .disabled(settings == nil)
                }
            }
        }
        .alert("Couldn't save", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: { Text(saveError ?? "") }
        .alert("Settings saved", isPresented: $saveSuccess) {
            Button("OK") {}
        }
        .sheet(isPresented: $showTestSheet) { testEmailSheet() }
        .task { await load() }
    }

    // MARK: - Sections

    @ViewBuilder
    private func senderIdentitySection(s: Binding<CompanyEmailSettings>) -> some View {
        Section("Sender Identity") {
            TextField("Sender display name", text: s.from_name)
                .disabled(!canEdit)
                .textContentType(.organizationName)
                .autocorrectionDisabled()

            TextField("Reply-to email", text: s.reply_to_email)
                .disabled(!canEdit)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocapitalization(.none)
                .autocorrectionDisabled()

            VStack(alignment: .leading, spacing: 4) {
                Text("Recipients will see")
                    .font(.caption).foregroundColor(.secondary)
                Text(s.wrappedValue.effectiveFromHint)
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private func signatureSection(s: Binding<CompanyEmailSettings>) -> some View {
        Section("Signature") {
            TextField("Default signature",
                      text: Binding(
                        get: { s.wrappedValue.default_signature ?? "" },
                        set: { s.wrappedValue.default_signature = $0.isEmpty ? nil : $0 }
                      ),
                      axis: .vertical)
                .lineLimit(3...6)
                .disabled(!canEdit)
                .autocorrectionDisabled()

            TextField("Footer text (small print)",
                      text: Binding(
                        get: { s.wrappedValue.footer_text ?? "" },
                        set: { s.wrappedValue.footer_text = $0.isEmpty ? nil : $0 }
                      ),
                      axis: .vertical)
                .lineLimit(2...4)
                .disabled(!canEdit)
        }
    }

    @ViewBuilder
    private func statusSection(s: CompanyEmailSettings) -> some View {
        Section("Sending Status") {
            HStack {
                Label("Email enabled", systemImage: "envelope.fill")
                Spacer()
                Text(s.is_enabled ? "Yes" : "No")
                    .foregroundColor(s.is_enabled ? .green : .red)
            }

            HStack {
                Label("Provider", systemImage: "network")
                Spacer()
                Text(s.provider.capitalized)
                    .foregroundColor(s.provider_status == "active" ? .green : .orange)
            }

            HStack {
                Label("Domain", systemImage: "checkmark.shield.fill")
                Spacer()
                Text(s.domainStatusLabel)
                    .multilineTextAlignment(.trailing)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func testSection(s: CompanyEmailSettings) -> some View {
        Section("Test Email") {
            Button {
                testRecipient = store.currentUser?.email ?? ""
                testResult = nil
                showTestSheet = true
            } label: {
                Label("Send test email", systemImage: "paperplane.fill")
            }
            .disabled(!s.is_enabled)
        }
    }

    @ViewBuilder
    private func customDomainInfoSection() -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Use your own domain", systemImage: "globe")
                    .font(.subheadline.weight(.semibold))
                Text("Send branded emails from your own domain (e.g. quotes@yourcompany.com). This requires DNS verification and is available after beta. Until then, emails are sent from the Aski IQ platform sender — replies still route to your reply-to address.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Custom Domain (Future)")
        }
    }

    // MARK: - Test Sheet

    @ViewBuilder
    private func testEmailSheet() -> some View {
        NavigationStack {
            Form {
                Section("Recipient") {
                    TextField("name@company.com", text: $testRecipient)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
                if let result = testResult {
                    Section { Label(result, systemImage: "info.circle") }
                }
            }
            .navigationTitle("Send Test Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { showTestSheet = false }.disabled(isSendingTest)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isSendingTest {
                        ProgressView()
                    } else {
                        Button("Send") { Task { await sendTest() } }
                            .bold()
                            .disabled(testRecipient.isEmpty || settings == nil)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    @MainActor
    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        guard let cid = store.currentCompanyID else {
            loadError = "Sign in to a company to manage email settings."
            return
        }
        do {
            settings = try await CompanyEmailSettingsService.load(companyID: cid)
        } catch {
            loadError = error.localizedDescription
        }
    }

    @MainActor
    private func save() async {
        guard let s = settings else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await CompanyEmailSettingsService.save(s)
            saveSuccess = true
        } catch {
            saveError = error.localizedDescription
        }
    }

    @MainActor
    private func sendTest() async {
        guard let cid = store.currentCompanyID else { return }
        isSendingTest = true
        testResult = nil
        defer { isSendingTest = false }

        let result = await CompanyEmailSettingsService.sendTestEmail(
            to:        testRecipient,
            companyID: cid
        )
        switch result {
        case .success:
            testResult = "Sent. Check the inbox in a moment (and the spam folder, just in case)."
        case .failure(let err):
            testResult = "Failed: \(err.userMessage)"
        }
    }
}
