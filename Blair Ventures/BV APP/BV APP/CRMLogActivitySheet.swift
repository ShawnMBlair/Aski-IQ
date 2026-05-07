// CRMLogActivitySheet.swift
// BV APP – Log a call or email against a CRM contact
// Sprint 10: Tap-to-call / tap-to-email with automatic activity logging

import SwiftUI

// MARK: - CRM Log Activity Sheet

struct CRMLogActivitySheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let contact: CRMContact
    let activityType: CRMActivityType   // .callMade or .emailSent
    var opportunityID: UUID? = nil      // pre-linked opportunity (from opp detail)

    @State private var notes:          String   = ""
    @State private var selectedOppID:  UUID?    = nil

    // ── Derived ──────────────────────────────────────────────────────────────

    private var isCall: Bool { activityType == .callMade }

    private var contactDetail: String {
        isCall ? contact.phone : contact.email
    }

    private var actionURL: URL? {
        if isCall {
            let digits = contact.phone.filter { $0.isNumber }
            guard !digits.isEmpty else { return nil }
            return URL(string: "tel://\(digits)")
        } else {
            guard !contact.email.isEmpty else { return nil }
            let encoded = contact.email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? contact.email
            return URL(string: "mailto:\(encoded)")
        }
    }

    private var clientOpportunities: [CRMOpportunity] {
        store.crmOpportunities
            .filter { $0.clientID == contact.clientID && $0.stage.isActive }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // ── Body ─────────────────────────────────────────────────────────────────

    var body: some View {
        NavigationStack {
            Form {

                // ── Contact banner ───────────────────────────────────────────
                Section {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.teal.opacity(0.15))
                                .frame(width: 44, height: 44)
                            Text(contact.initials)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.teal)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(contact.fullName)
                                .font(.subheadline.weight(.semibold))
                            if !contact.title.isEmpty {
                                Text(contact.title)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if !contactDetail.isEmpty {
                                Text(contactDetail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    // Action link — opens phone / mail app
                    if let url = actionURL {
                        Link(destination: url) {
                            HStack(spacing: 8) {
                                Image(systemName: isCall ? "phone.fill" : "envelope.fill")
                                    .font(.subheadline)
                                    .foregroundColor(isCall ? .green : .blue)
                                Text(isCall ? "Dial \(contact.phone)" : "Open in Mail")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(isCall ? .green : .blue)
                            }
                        }
                    }
                }

                // ── Notes ─────────────────────────────────────────────────────
                Section(isCall ? "Call Summary" : "Email Notes") {
                    ZStack(alignment: .topLeading) {
                        if notes.isEmpty {
                            Text(isCall
                                 ? "What was discussed?"
                                 : "What was the email about?")
                                .foregroundColor(.secondary)
                                .font(.body)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $notes)
                            .frame(minHeight: 100)
                    }
                }

                // ── Opportunity link ──────────────────────────────────────────
                if !clientOpportunities.isEmpty {
                    Section("Link to Opportunity") {
                        Picker("Opportunity", selection: $selectedOppID) {
                            Text("None").tag(UUID?.none)
                            ForEach(clientOpportunities) { opp in
                                Label(opp.title, systemImage: opp.stage.icon)
                                    .tag(Optional(opp.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
            .navigationTitle(isCall ? "Log Call" : "Log Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                selectedOppID = opportunityID
            }
        }
    }

    // ── Save ──────────────────────────────────────────────────────────────────

    private func save() {
        store.logCRMActivity(
            type:          activityType,
            title:         isCall
                ? "Call with \(contact.fullName)"
                : "Email to \(contact.fullName)",
            notes:         notes,
            clientID:      contact.clientID,
            contactID:     contact.id,
            opportunityID: selectedOppID,
            quoteID:       nil,
            projectID:     nil
        )
        dismiss()
    }
}
