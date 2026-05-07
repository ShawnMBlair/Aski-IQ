// SiteDetailView.swift
// Aski IQ – Site Detail Screen
// Shows all context for a single client site: contacts, estimates, projects, notes.

import SwiftUI

// MARK: - Site Detail View

struct SiteDetailView: View {
    let site: ClientSite
    let client: Client

    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var showNewEstimate = false
    @State private var showEditSite    = false

    // Contacts assigned to this specific site
    private var siteContacts: [CRMContact] {
        store.crmContacts
            .filter { $0.clientID == client.id && $0.siteID == site.id }
            .sorted { ($0.isPrimary ? 0 : 1) < ($1.isPrimary ? 0 : 1) }
    }

    // All contacts for this client (for "other contacts" fallback display)
    private var allClientContacts: [CRMContact] {
        store.crmContacts.filter { $0.clientID == client.id && $0.siteID == nil && $0.isPrimary }
    }

    // Estimates for this site
    private var siteEstimates: [Estimate] {
        store.estimates
            .filter { $0.clientID == client.id && $0.siteID == site.id }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // Active projects for this client (by site address match or client match)
    private var siteProjects: [Project] {
        store.projects
            .filter { $0.clientName == client.name && $0.status == .active }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // ── Site Header ───────────────────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.orange.opacity(0.12))
                                    .frame(width: 52, height: 52)
                                Image(systemName: "mappin.circle.fill")
                                    .font(.title)
                                    .foregroundColor(.orange)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(site.name).font(.title3).bold()
                                Text(client.name).font(.subheadline).foregroundColor(.secondary)
                                if site.isDefault {
                                    Text("Default Site")
                                        .font(.caption2).bold()
                                        .padding(.horizontal, 6).padding(.vertical, 3)
                                        .background(Color.green.opacity(0.12))
                                        .foregroundColor(.green)
                                        .cornerRadius(5)
                                }
                            }
                        }

                        // Address
                        let addr = site.formattedAddress.isEmpty ? site.address : site.formattedAddress
                        if !addr.isEmpty {
                            Label(addr, systemImage: "location.fill")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)
                    .padding(.horizontal)

                    // ── Quick Stats ───────────────────────────────────
                    HStack(spacing: 12) {
                        MiniKPICard(value: "\(siteContacts.count)",  label: "Contacts",  icon: "person.2.fill")
                        MiniKPICard(value: "\(siteEstimates.count)", label: "Estimates", icon: "doc.text.fill")
                        MiniKPICard(value: "\(siteProjects.count)",  label: "Active Jobs", icon: "folder.fill")
                    }
                    .padding(.horizontal)

                    // ── New Estimate CTA ──────────────────────────────
                    Button { showNewEstimate = true } label: {
                        Label("New Estimate for \(site.name)", systemImage: "plus.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.purple)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .padding(.horizontal)

                    // ── Site Notes ────────────────────────────────────
                    let hasNotes = site.accessNotes != nil || site.safetyNotes != nil || site.logisticsNotes != nil
                    if hasNotes {
                        SectionHeader(title: "Site Notes")
                        VStack(spacing: 0) {
                            if let access = site.accessNotes, !access.isEmpty {
                                SiteNoteRow(icon: "key.fill", color: .blue,
                                            label: "Access", text: access)
                                Divider().padding(.leading, 44)
                            }
                            if let safety = site.safetyNotes, !safety.isEmpty {
                                SiteNoteRow(icon: "shield.lefthalf.filled", color: .red,
                                            label: "Safety", text: safety)
                                Divider().padding(.leading, 44)
                            }
                            if let logistics = site.logisticsNotes, !logistics.isEmpty {
                                SiteNoteRow(icon: "shippingbox.fill", color: .orange,
                                            label: "Logistics", text: logistics)
                            }
                        }
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                    }

                    // ── Assigned Contacts ─────────────────────────────
                    SectionHeader(title: "Site Contacts", count: siteContacts.count)
                    if siteContacts.isEmpty {
                        // Fall back to primary client contacts with an explanation
                        if allClientContacts.isEmpty {
                            EmptyCard(message: "No contacts assigned to this site. Assign contacts when creating or editing a contact.")
                        } else {
                            VStack(spacing: 0) {
                                ForEach(allClientContacts) { contact in
                                    ClientContactRow(contact: contact)
                                    if contact.id != allClientContacts.last?.id {
                                        Divider().padding(.leading, 56)
                                    }
                                }
                            }
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                            .padding(.horizontal)
                            Text("Showing company-level primary contacts. Assign contacts specifically to this site to refine.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal)
                        }
                    } else {
                        VStack(spacing: 0) {
                            ForEach(siteContacts) { contact in
                                ClientContactRow(contact: contact)
                                if contact.id != siteContacts.last?.id {
                                    Divider().padding(.leading, 56)
                                }
                            }
                        }
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                    }

                    // ── Estimates ─────────────────────────────────────
                    if !siteEstimates.isEmpty {
                        SectionHeader(title: "Estimates", count: siteEstimates.count)
                        VStack(spacing: 0) {
                            ForEach(siteEstimates) { estimate in
                                SiteEstimateRow(estimate: estimate)
                                if estimate.id != siteEstimates.last?.id {
                                    Divider().padding(.leading)
                                }
                            }
                        }
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                    }

                    // ── Active Projects ───────────────────────────────
                    if !siteProjects.isEmpty {
                        SectionHeader(title: "Active Projects", count: siteProjects.count)
                        ForEach(siteProjects) { project in
                            NavigationLink {
                                ProjectDetailView(project: project)
                            } label: {
                                ProjectSummaryRow(project: project).padding(.horizontal)
                            }
                        }
                    }

                    Spacer(minLength: 32)
                }
                .padding(.top)
            }
            .navigationTitle(site.name)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Edit") { showEditSite = true }
                }
            }
            .sheet(isPresented: $showNewEstimate) {
                EstimateCreateView(preselectedClientID: client.id, preselectedSiteID: site.id)
            }
        }
    }
}

// MARK: - Site Note Row

private struct SiteNoteRow: View {
    let icon:  String
    let color: Color
    let label: String
    let text:  String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundColor(color)
                .frame(width: 20)
                .padding(.leading, 16)
                .padding(.vertical, 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption).bold()
                    .foregroundColor(color)
                Text(text)
                    .font(.subheadline)
                    .foregroundColor(.primary)
            }
            .padding(.vertical, 12)

            Spacer()
        }
    }
}

// MARK: - Site Estimate Row

private struct SiteEstimateRow: View {
    let estimate: Estimate

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(estimate.jobNumber)
                    .font(.caption).foregroundColor(.secondary)
                Text(estimate.name)
                    .font(.subheadline).bold().lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                EstimateStatusBadge(status: estimate.status)
                Text(estimate.totalEstimated, format: .currency(code: "CAD"))
                    .font(.subheadline).bold()
            }
        }
        .padding()
    }
}
