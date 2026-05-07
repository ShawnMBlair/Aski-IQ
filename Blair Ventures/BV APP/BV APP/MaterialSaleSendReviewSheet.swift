// MaterialSaleSendReviewSheet.swift
// Aski IQ — Path-A clone of QuoteSendReviewSheet.
//
// Sits between the "Email to Client" button and the actual email send.
// Pre-fix the Material Sale detail view fired the email pipeline as
// soon as PDF generation finished — there was no review/confirm step,
// no recipient editing, no acceptance-link toggle.
//
// THIS SHEET IS THE FIX
// Tapping "Email Quote to Client" opens this review sheet. The user:
//   • picks the primary recipient + sees CC list
//   • sees the sale summary (number, client, total, delivery date)
//   • sees attached terms (with summary count)
//   • toggles "Include digital acceptance link" (admin only)
// Then taps Send. ONLY when EmailService.sendPDF succeeds does the
// sale flip from .draft → .quoted (handled by EmailComposeSheet's
// material_sale branch — this sheet doesn't manipulate status itself).
//
// Cancel keeps the sale in its prior state. The sheet is non-dismissable
// while sending so the user doesn't accidentally lose state mid-send.

import SwiftUI

// MARK: - Send workflow state machine

enum MaterialSaleSendWorkflowState: Equatable {
    case ready
    case sending
    case sent
    case failed(String)
}

// MARK: - Review sheet

struct MaterialSaleSendReviewSheet: View {
    let sale: MaterialSale

    /// Caller-provided send pipeline. The review sheet supplies the
    /// final recipient list + acceptance-link toggle, and this closure
    /// runs the actual mint + PDF + EmailService.sendPDF chain.
    let performSend: (_ recipients: [String],
                       _ includeAcceptanceLink: Bool) async -> Result<Void, EmailService.EmailError>

    /// Fires after a successful send. Caller uses this to refresh
    /// localSale / dismiss the parent if appropriate.
    let onSendSucceeded: () -> Void

    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var workflowState: MaterialSaleSendWorkflowState = .ready
    @State private var primaryRecipient: String = ""
    @State private var ccRecipients: [String] = []
    @State private var includeAcceptanceLink: Bool = true

    // MARK: Derived

    private var client: Client? { store.client(id: sale.clientID) }
    private var attachedTerms: [MaterialSaleTerm] { store.materialSaleTerms(for: sale.id) }
    private var contactName: String? {
        guard let cid = sale.contactID else { return nil }
        return store.crmContacts.first { $0.id == cid }?.fullName
    }

    /// All known emails for this client — primary + CRM contacts.
    private var availableRecipients: [String] {
        var seen = Set<String>()
        var out: [String] = []
        if let c = client, let e = c.contactEmail, !e.isEmpty,
           seen.insert(e.lowercased()).inserted {
            out.append(e)
        }
        for c in store.crmContacts
            where c.clientID == sale.clientID && !c.isDeleted && !c.email.isEmpty {
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

    private var docLabel: String {
        switch sale.saleType {
        case .rental:        return "Rental"
        case .directInvoice: return "Invoice"
        default:             return "Sale"
        }
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                recipientSection
                saleSummarySection
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
    private var saleSummarySection: some View {
        Section(docLabel) {
            LabeledContent("Number")  { Text(sale.saleNumber).fontDesign(.monospaced) }
            LabeledContent("Type",     value: sale.saleType.displayName)
            LabeledContent("Client",   value: client?.name ?? "—")
            if let cn = contactName { LabeledContent("Contact", value: cn) }
            if let addr = sale.deliveryAddress, !addr.isEmpty {
                LabeledContent("Delivery", value: addr)
            }
            if let req = sale.requestedDeliveryDate {
                LabeledContent("Requested",
                               value: req.formatted(date: .abbreviated, time: .omitted))
            }
            LabeledContent("Total",   value: sale.grandTotal.currencyString)
        }
    }

    @ViewBuilder
    private var lineItemsSection: some View {
        Section("Line Items") {
            if sale.lineItems.isEmpty {
                Text("No line items.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(sale.lineItems) { item in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.description).font(.subheadline)
                            HStack(spacing: 6) {
                                let qtyStr = NSDecimalNumber(decimal: item.quantity).stringValue
                                Text("\(qtyStr) \(item.unit) @ \(item.unitPrice.currencyString)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Text(item.lineTotal.currencyString)
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
            Text("Attached terms will be rendered as part of the PDF.")
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
            try? await Task.sleep(nanoseconds: 500_000_000)
            dismiss()
        case .failure(let err):
            workflowState = .failed(err.userMessage)
        }
    }
}
