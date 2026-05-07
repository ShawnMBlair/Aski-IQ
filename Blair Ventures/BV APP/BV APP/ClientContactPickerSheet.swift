// ClientContactPickerSheet.swift
// Aski IQ – Contact Picker for Estimate / Quote Creation
// Shows CRMContacts for a given client, optionally filtered by site.

import SwiftUI

// MARK: - Client Contact Picker Sheet

struct ClientContactPickerSheet: View {
    let clientID:    UUID
    var siteID:      UUID?           // Optional — used to surface site-specific contacts first
    @Binding var selectedContactID:  UUID?
    @EnvironmentObject var store:    AppStore
    @Environment(\.dismiss) var dismiss
    @State private var showAddContact = false

    private var client: Client? { store.client(id: clientID) }

    // All contacts for this client, site-assigned first
    private var contacts: [CRMContact] {
        let all = store.crmContacts.filter { $0.clientID == clientID }
        // Sort: primary first, then site-matched, then role order, then name
        return all.sorted {
            if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
            let aSite = ($0.siteID == siteID && siteID != nil)
            let bSite = ($1.siteID == siteID && siteID != nil)
            if aSite != bSite { return aSite }
            return $0.fullName < $1.fullName
        }
    }

    // Site-specific contacts (shown in first section if siteID is set)
    private var siteContacts: [CRMContact] {
        guard let sid = siteID else { return [] }
        return contacts.filter { $0.siteID == sid }
    }

    // General contacts (no site, or different site)
    private var generalContacts: [CRMContact] {
        if siteID == nil { return contacts }
        return contacts.filter { $0.siteID != siteID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if contacts.isEmpty {
                    VStack(spacing: 20) {
                        Spacer()
                        Image(systemName: "person.slash")
                            .font(.system(size: 52))
                            .foregroundColor(.secondary)
                        Text("No Contacts for \(client?.name ?? "this client")")
                            .font(.headline)
                        Text("Add at least one contact before creating an estimate.\nWho should this estimate be addressed to?")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button {
                            showAddContact = true
                        } label: {
                            Label("Add Contact", systemImage: "person.badge.plus")
                                .font(.headline)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                                .padding(.horizontal)
                        }
                        Spacer()
                    }
                } else {
                    List {
                        // Site-specific contacts (if a site is selected)
                        if !siteContacts.isEmpty {
                            Section("At this site") {
                                ForEach(siteContacts) { contact in
                                    contactRow(contact)
                                }
                            }
                        }

                        // General / company-level contacts
                        let general = generalContacts
                        if !general.isEmpty {
                            Section(siteContacts.isEmpty ? (client?.name ?? "Contacts") : "Company Contacts") {
                                ForEach(general) { contact in
                                    contactRow(contact)
                                }
                            }
                        }

                        // Add new contact
                        Section {
                            Button {
                                showAddContact = true
                            } label: {
                                Label("Add New Contact", systemImage: "person.badge.plus")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Select Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddContact) {
                AddCRMContactSheet(clientID: clientID)
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func contactRow(_ contact: CRMContact) -> some View {
        Button {
            selectedContactID = contact.id
            dismiss()
        } label: {
            HStack(spacing: 14) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(contact.role.color.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Text(contact.initials)
                        .font(.subheadline).bold()
                        .foregroundColor(contact.role.color)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(contact.fullName).font(.subheadline).bold()
                        if contact.isPrimary {
                            Text("Primary")
                                .font(.caption2).bold()
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.blue.opacity(0.12))
                                .foregroundColor(.blue)
                                .cornerRadius(4)
                        }
                    }
                    HStack(spacing: 4) {
                        Image(systemName: contact.role.icon)
                            .font(.caption2)
                            .foregroundColor(contact.role.color)
                        Text(contact.role.label)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if !contact.title.isEmpty {
                            Text("· \(contact.title)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    if !contact.email.isEmpty {
                        Text(contact.email)
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }

                Spacer()

                if selectedContactID == contact.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                }
            }
            .padding(.vertical, 4)
        }
        .foregroundColor(.primary)
    }
}
