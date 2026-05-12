// EmailComposeSheet.swift
// Aski IQ — Reusable in-app email composer for sending PDFs to clients.
//
// Used by Quote / Invoice / Change Order detail views. Renders the PDF on
// open, lets the user edit recipient/subject/body, then ships through the
// `send-email` Edge Function via EmailService. Logs a CRMActivity of type
// .emailSent on success.
//
// USAGE
//   .sheet(isPresented: $showEmail) {
//       EmailComposeSheet(
//           recipientSuggestions: client?.contactEmails ?? [],
//           defaultSubject: "Quote \(quote.jobNumber)",
//           defaultBody: "Hi \(clientName),\n\nPlease find your quote attached.",
//           pdfData: pdfBytes,
//           pdfFilename: "Quote_\(quote.jobNumber).pdf",
//           entityType: "quote",
//           entityID: quote.id,
//           clientID: quote.clientID,
//           contactID: nil,
//           opportunityID: opp?.id,
//           quoteID: quote.id,
//           projectID: nil
//       )
//       .environmentObject(store)
//   }

import SwiftUI

struct EmailComposeSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    // Composition state
    let recipientSuggestions: [String]
    let defaultSubject: String
    let defaultBody:    String
    let pdfData:        Data
    let pdfFilename:    String

    // Audit / CRM linkage
    let entityType:     String
    let entityID:       UUID
    let clientID:       UUID?
    let contactID:      UUID?
    let opportunityID:  UUID?
    let quoteID:        UUID?
    let projectID:      UUID?

    @State private var toRaw:   String = ""
    @State private var subject: String = ""
    @State private var bodyText: String = ""

    @State private var isSending: Bool = false
    @State private var errorMessage: String? = nil
    // (Success state previously shown as an alert; replaced by ToastService.)

    private var attachmentSizeKB: Int {
        max(1, pdfData.count / 1024)
    }

    /// Recipient list — comma- or semicolon-separated emails entered by the user.
    private var recipientList: [String] {
        toRaw
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var canSend: Bool {
        !isSending
        && !recipientList.isEmpty
        && recipientList.allSatisfy(isValidEmail(_:))
        && !subject.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("To") {
                    TextField("client@example.com, …", text: $toRaw, axis: .vertical)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .lineLimit(1...3)
                    if !recipientSuggestions.isEmpty && toRaw.isEmpty {
                        ForEach(recipientSuggestions, id: \.self) { suggestion in
                            Button {
                                toRaw = suggestion
                            } label: {
                                HStack {
                                    Image(systemName: "envelope")
                                    Text(suggestion).foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "plus.circle.fill").foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }

                Section("Subject") {
                    TextField("Subject", text: $subject)
                }

                Section("Message") {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 140)
                }

                Section("Attachment") {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.fill")
                            .foregroundColor(.red)
                        VStack(alignment: .leading) {
                            Text(pdfFilename).font(.subheadline)
                            Text("\(attachmentSizeKB) KB · PDF")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Send Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSending)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Send") { Task { await send() } }
                            .disabled(!canSend)
                            .accessibilityLabel("Send email")
                    }
                }
            }
            .onAppear {
                if subject.isEmpty { subject = defaultSubject }
                if bodyText.isEmpty { bodyText = defaultBody }
                if toRaw.isEmpty,
                   let first = recipientSuggestions.first {
                    toRaw = first
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Send

    private func send() async {
        guard canSend else { return }
        errorMessage = nil
        isSending = true

        // Wrap the user-composed plain text in branded HTML chrome so
        // the recipient sees a polished email instead of raw lines.
        // The plain-text body is preserved verbatim as the fallback
        // for clients that strip HTML.
        let html = EmailHTMLTemplate.wrap(
            plainText:   bodyText,
            companyName: AppSettings.shared.companyName,
            subject:     subject
        )

        let result = await EmailService.shared.sendPDF(
            to:          recipientList,
            subject:     subject,
            bodyText:    bodyText,
            bodyHTML:    html,
            pdfData:     pdfData,
            pdfFilename: pdfFilename,
            entityType:  entityType,
            entityID:    entityID
        )

        switch result {
        case .success:
            // Mirror the send to the CRM activity timeline so it shows up
            // alongside calls / notes / stage changes for this opportunity.
            store.logCRMActivity(
                type:          .emailSent,
                title:         subject,
                notes:         "Sent to \(recipientList.joined(separator: ", ")) with attachment \(pdfFilename).",
                clientID:      clientID,
                contactID:     contactID,
                opportunityID: opportunityID,
                quoteID:       quoteID,
                projectID:     projectID
            )

            // Quote-specific: stamp sentAt + advance status. Fires for any
            // pre-terminal status (draft, approved) so a user who skipped
            // the Approve step still gets sent_at recorded. Idempotent —
            // skips quotes already in .accepted / .declined / .sent so a
            // record-keeping resend doesn't demote state.
            if entityType == "quote",
               let qid = quoteID,
               let idx = store.quotes.firstIndex(where: { $0.id == qid }) {
                let s = store.quotes[idx].status
                if s == .draft || s == .approved {
                    store.quotes[idx].status = .sent
                }
                if store.quotes[idx].sentAt == nil {
                    store.quotes[idx].sentAt = Date()
                }
                store.quotes[idx].syncStatus = .pending
                store.upsertQuote(store.quotes[idx])
            }

            // Material-sale-specific: advance .draft → .quoted on
            // confirmed email-success so the lifecycle states stay
            // truthful. Idempotent — sales already past .quoted
            // (.ordered / .invoiced / .paid / .cancelled) don't get
            // demoted by a record-keeping resend.
            if entityType == "material_sale",
               let idx = store.materialSales.firstIndex(where: { $0.id == entityID }) {
                if store.materialSales[idx].status == .draft {
                    store.materialSales[idx].status = .quoted
                    store.materialSales[idx].syncStatus = .pending
                    store.upsertMaterialSale(store.materialSales[idx])
                }
            }

            Haptics.success()
            ToastService.shared.success("Email sent",
                                        body: "To \(recipientList.joined(separator: ", "))")
            dismiss()  // close the compose sheet straight away — toast is the receipt
        case .failure(let err):
            errorMessage = err.userMessage
            Haptics.error()
        }
        isSending = false
    }

    // MARK: - Validation

    private func isValidEmail(_ s: String) -> Bool {
        let regex = #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return s.range(of: regex, options: .regularExpression) != nil
    }
}
