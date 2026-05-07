// AccountDeletionView.swift
// Aski IQ — Multi-step in-app account-deletion flow.
//
// Apple App Store guideline 5.1.1(v) requires this flow be reachable from
// inside the app; Settings → Privacy is where it lives.
//
// STEPS
//   .warning   — what gets deleted vs anonymized, offer to download data
//   .reauth    — confirm password + optional reason
//   .deleting  — spinner while the Edge Function does its work
//   .done      — final confirmation before sign-out flips back to login
//
// VOICE
// We do NOT use scary capitalized red copy here, but we are honest about
// what's irreversible. The button label says "Delete my account" — no
// euphemism — and the password gate makes the user explicitly confirm.

import SwiftUI

struct AccountDeletionView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable {
        case warning
        case reauth
        case deleting
        case done
        case failed(String)
    }

    @State private var step: Step = .warning
    @State private var password: String = ""
    @State private var reason: String = ""
    @State private var didExport: Bool = false
    @State private var isExporting: Bool = false
    @State private var exportFileURL: URL? = nil
    @State private var showExportShareSheet = false
    @State private var showFinalConfirm = false

    /// Hide the Close button while the Edge Function is mid-flight, so the
    /// user can't accidentally back out during the irreversible step.
    private var showCloseButton: Bool {
        if case .deleting = step { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .warning:           warningStep
                case .reauth:            reauthStep
                case .deleting:          deletingStep
                case .done:              doneStep
                case .failed(let msg):   failedStep(msg)
                }
            }
            .padding(.horizontal, AskiSpacing.lg)
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // ToolbarContentBuilder doesn't accept `if case` patterns,
                // so we route the visibility through a plain Bool.
                if showCloseButton {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $showExportShareSheet) {
                if let url = exportFileURL {
                    ShareSheet(items: [url])
                }
            }
            .alert("Delete account permanently?",
                   isPresented: $showFinalConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete my account", role: .destructive) {
                    Task { await runDeletion() }
                }
            } message: {
                Text("This will permanently delete your sign-in. Business records (timesheets, incidents, invoices) stay with the company; your name and email are scrubbed. This can't be undone.")
            }
        }
    }

    // MARK: - Step views

    private var warningStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AskiSpacing.lg) {
                bullet("You won't be able to sign back in with this email.",
                       icon: "lock.slash.fill", color: .red)
                bullet("Your name and email will be scrubbed from your profile.",
                       icon: "person.crop.circle.badge.minus", color: .orange)
                bullet("Business records (timesheets, incidents, invoices, change orders) stay with the company. They legally must be retained.",
                       icon: "doc.text.fill", color: .blue)
                bullet("If you're the company owner, your team will lose access. Transfer ownership first if that matters.",
                       icon: "exclamationmark.triangle.fill", color: .yellow)

                Divider().padding(.vertical, AskiSpacing.sm)

                Text("Download your data first?")
                    .font(.headline)
                Text("PIPEDA / GDPR right of access. We strongly recommend keeping a copy before you delete.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button {
                    Task { await runExport() }
                } label: {
                    HStack {
                        if isExporting {
                            ProgressView().scaleEffect(0.85)
                            Text("Preparing your data…")
                        } else if didExport {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text("Data downloaded — share it again")
                        } else {
                            Image(systemName: "square.and.arrow.down")
                            Text("Download my data")
                        }
                        Spacer()
                    }
                    .padding(AskiSpacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: AskiRadius.card)
                            .fill(Color(.secondarySystemBackground))
                    )
                }
                .disabled(isExporting)
                .buttonStyle(.plain)

                Spacer(minLength: AskiSpacing.lg)

                Button {
                    step = .reauth
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AskiSpacing.md)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.vertical, AskiSpacing.md)
        }
    }

    private var reauthStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AskiSpacing.lg) {
                Text("Confirm your password")
                    .font(.headline)
                Text("Re-entering your password proves you're the account holder, in case your phone is unlocked and out of your hands.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .padding(AskiSpacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: AskiRadius.card)
                            .fill(Color(.secondarySystemBackground))
                    )

                Text("Reason (optional)")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, AskiSpacing.sm)
                Text("Helps us improve. Not shared with your company.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $reason)
                    .frame(minHeight: 80)
                    .padding(AskiSpacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: AskiRadius.card)
                            .fill(Color(.secondarySystemBackground))
                    )

                Spacer(minLength: AskiSpacing.lg)

                Button(role: .destructive) {
                    showFinalConfirm = true
                } label: {
                    Text("Delete my account")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AskiSpacing.md)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(password.isEmpty)
            }
            .padding(.vertical, AskiSpacing.md)
        }
    }

    private var deletingStep: some View {
        VStack(spacing: AskiSpacing.lg) {
            Spacer()
            ProgressView().scaleEffect(1.3)
            Text("Deleting your account…")
                .font(.headline)
            Text("This usually takes a few seconds. Don't close the app.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var doneStep: some View {
        VStack(spacing: AskiSpacing.lg) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)
            Text("Account deleted")
                .font(.title2.weight(.semibold))
            Text("You'll be returned to the sign-in screen.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Button("Sign out") {
                Task {
                    store.clearAllData()
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, AskiSpacing.lg)
        }
        .frame(maxWidth: .infinity)
    }

    private func failedStep(_ msg: String) -> some View {
        VStack(spacing: AskiSpacing.lg) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundColor(.red)
            Text("Couldn't delete account")
                .font(.title3.weight(.semibold))
            Text(msg)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            Button("Try again") { step = .reauth }
                .buttonStyle(.borderedProminent)
            Button("Close") { dismiss() }
                .padding(.bottom, AskiSpacing.lg)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func bullet(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: AskiSpacing.md) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runExport() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let url = try DataExportService.shared.exportAll(from: store)
            exportFileURL = url
            didExport = true
            showExportShareSheet = true
        } catch {
            ToastService.shared.error("Export failed: \(error.localizedDescription)")
        }
    }

    private func runDeletion() async {
        step = .deleting
        let result = await AccountDeletionService.shared.deleteAccount(
            store:         store,
            password:      password,
            reason:        reason.trimmingCharacters(in: .whitespacesAndNewlines),
            exportedFirst: didExport
        )
        switch result {
        case .success:
            step = .done
        case .failure(let err):
            step = .failed(err.userMessage)
        }
    }
}
