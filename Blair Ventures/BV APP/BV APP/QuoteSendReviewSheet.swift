// QuoteSendReviewSheet.swift
// Aski IQ — Critical workflow fix: Review & Confirm before Send
//
// Pre-fix the "Save & Send Quote" button on QuoteCreateView fired the
// email pipeline immediately on save. There was no preview/confirm
// step, the rep never saw the recipient list or final wording, and
// the status flipped to .sent based on the email service's success
// callback — but a Terms picker auto-close (since fixed) could
// surface as "the quote sent without me confirming anything."
//
// THIS SHEET IS THE FIX
// Save & Send now saves the quote at .draft / .approved (no status
// flip), then opens this sheet. The user reviews:
//   • client + recipient
//   • quote number + version
//   • scope summary, line items, total
//   • attached terms (with re-edit shortcut)
//   • acceptance link toggle (admin only)
// Then taps Send. ONLY when EmailService.sendPDF succeeds does the
// quote flip to .sent — via CommercialWorkflowService.recordQuoteSent
// per the existing email-success-only contract.
//
// Cancel keeps the quote in its prior state (draft if new, whatever
// it was if editing). The sheet is non-dismissable while sending so
// the user doesn't accidentally lose state mid-send.

import SwiftUI

// MARK: - Send workflow state machine

enum QuoteSendWorkflowState: Equatable {
    case ready
    case sending
    case sent
    case failed(String)
}

// MARK: - Review sheet

struct QuoteSendReviewSheet: View {
    let quote: Quote

    /// Caller-provided send pipeline. The review sheet supplies the
    /// final recipient list + acceptance-link toggle, and this closure
    /// runs the actual mint + PDF + EmailService.sendPDF chain. Returns
    /// the result so the sheet can show error / dismiss on success.
    /// Async so the sheet can render a ProgressView while it runs.
    let performSend: (_ recipients: [String],
                       _ includeAcceptanceLink: Bool) async -> Result<Void, EmailService.EmailError>

    /// Fires after a successful send. Caller uses this to flip the
    /// quote status (via CommercialWorkflowService.recordQuoteSent)
    /// and dismiss the parent if appropriate.
    let onSendSucceeded: () -> Void

    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var workflowState: QuoteSendWorkflowState = .ready
    @State private var primaryRecipient: String = ""
    @State private var ccRecipients: [String] = []
    @State private var includeAcceptanceLink: Bool = true

    // MARK: Derived

    private var client: Client? { store.client(id: quote.clientID) }
    private var attachedTerms: [QuoteTerm] { store.quoteTerms(for: quote.id) }
    private var contactName: String? {
        store.crmContacts.first(where: { $0.clientID == quote.clientID && !$0.isDeleted })?.fullName
    }

    /// All known emails for this client — primary + CRM contacts.
    /// User picks the primary recipient via the form; the rest are
    /// CC'd unless the user removes them.
    private var availableRecipients: [String] {
        var seen = Set<String>()
        var out: [String] = []
        if let c = client, let e = c.contactEmail, !e.isEmpty,
           seen.insert(e.lowercased()).inserted {
            out.append(e)
        }
        for c in store.crmContacts
            where c.clientID == quote.clientID && !c.isDeleted && !c.email.isEmpty {
            if seen.insert(c.email.lowercased()).inserted {
                out.append(c.email)
            }
        }
        return out
    }

    private var canSend: Bool {
        if case .sending = workflowState { return false }
        if case .sent    = workflowState { return false }
        return !primaryRecipient.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                recipientSection
                quoteSummarySection
                lineItemsSection
                termsSection
                if case .failed(let msg) = workflowState {
                    Section {
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Review & Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(workflowState == .sending)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    sendButton
                }
            }
            .onAppear {
                // Pre-fill primary recipient from the client's first known email.
                if primaryRecipient.isEmpty,
                   let first = availableRecipients.first {
                    primaryRecipient = first
                }
                ccRecipients = Array(availableRecipients.dropFirst())
            }
            .interactiveDismissDisabled(workflowState == .sending)
        }
        .presentationDetents([.large])
    }

    // MARK: Sections

    @ViewBuilder
    private var recipientSection: some View {
        Section {
            if availableRecipients.isEmpty {
                TextField("recipient@example.com", text: $primaryRecipient)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .textInputAutocapitalization(.never)
            } else {
                Picker("To", selection: $primaryRecipient) {
                    ForEach(availableRecipients, id: \.self) { email in
                        Text(email).tag(email)
                    }
                }
                .pickerStyle(.menu)
            }
            if !ccRecipients.isEmpty {
                ForEach(ccRecipients, id: \.self) { email in
                    HStack {
                        Image(systemName: "envelope")
                            .foregroundColor(.secondary)
                        Text(email)
                            .font(.subheadline)
                        Spacer()
                        Button {
                            ccRecipients.removeAll { $0 == email }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if store.currentUserRole.isAdmin {
                Toggle("Include digital acceptance link", isOn: $includeAcceptanceLink)
            }
        } header: {
            Text("Recipients")
        } footer: {
            Text(includeAcceptanceLink && store.currentUserRole.isAdmin
                 ? "A magic-link will be minted and embedded in the email body so the customer can sign in one tap."
                 : "Plain PDF attachment — no acceptance link.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var quoteSummarySection: some View {
        Section("Quote") {
            LabeledContent("Number")  { Text(quote.jobNumber).fontDesign(.monospaced) }
            LabeledContent("Revision", value: "v\(quote.revision)")
            LabeledContent("Client",   value: quote.clientName)
            if let cn = contactName { LabeledContent("Contact", value: cn) }
            if let s = quote.siteAddress, !s.isEmpty {
                LabeledContent("Site",     value: s)
            }
            LabeledContent("Total",    value: quote.grandTotal.currencyString)
            LabeledContent("Expires",  value: quote.expiryDate.formatted(date: .abbreviated, time: .omitted))
        }
    }

    @ViewBuilder
    private var lineItemsSection: some View {
        Section("Line Items") {
            if quote.lineItems.isEmpty {
                Text("No line items.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(quote.lineItems) { item in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.description).font(.subheadline)
                            HStack(spacing: 6) {
                                Text(item.code)
                                    .font(.caption2.monospaced())
                                    .foregroundColor(.blue)
                                Text("\(NSDecimalNumber(decimal: item.estimatedQuantity).stringValue) \(item.unit) @ \(item.unitRate.currencyString)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Text(item.estimatedTotal.currencyString)
                            .font(.subheadline.bold())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var termsSection: some View {
        Section {
            if attachedTerms.isEmpty {
                Label("No Terms & Conditions attached", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else {
                ForEach(attachedTerms) { t in
                    HStack(spacing: 8) {
                        Image(systemName: t.isCustom ? "doc.text" : "doc.richtext")
                            .foregroundColor(t.isCustom ? .orange : .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.titleSnapshot).font(.subheadline)
                            if let v = t.versionSnapshot {
                                Text("v\(v)").font(.caption2.monospaced()).foregroundColor(.secondary)
                            } else if t.isCustom {
                                Text("Custom").font(.caption2).foregroundColor(.orange)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Terms & Conditions (\(attachedTerms.count))")
        } footer: {
            Text("Attached terms will be rendered as part of the PDF after Payment Terms.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        switch workflowState {
        case .ready, .failed:
            Button { Task { await runSend() } } label: {
                Label("Send", systemImage: "paperplane.fill").bold()
            }
            .disabled(!canSend)
        case .sending:
            HStack(spacing: 6) {
                ProgressView()
                Text("Sending…").font(.caption)
            }
        case .sent:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        }
    }

    // MARK: Send

    @MainActor
    private func runSend() async {
        let recipientsList: [String] = {
            var out: [String] = []
            let primary = primaryRecipient.trimmingCharacters(in: .whitespaces)
            if !primary.isEmpty { out.append(primary) }
            for cc in ccRecipients where !cc.isEmpty {
                if !out.contains(where: { $0.lowercased() == cc.lowercased() }) {
                    out.append(cc)
                }
            }
            return out
        }()

        guard !recipientsList.isEmpty else {
            workflowState = .failed("Add at least one recipient before sending.")
            return
        }

        workflowState = .sending
        let result = await performSend(recipientsList, includeAcceptanceLink)
        switch result {
        case .success:
            workflowState = .sent
            onSendSucceeded()
            // Brief pause so the user sees the green check, then dismiss.
            try? await Task.sleep(nanoseconds: 500_000_000)
            dismiss()
        case .failure(let err):
            workflowState = .failed(err.userMessage)
        }
    }
}
