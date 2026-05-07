// CRMSearchView.swift
// BV APP – Global CRM Search

import SwiftUI

// MARK: - CRM Search View

struct CRMSearchView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var query:   String = ""
    @State private var results: SearchResults = .empty
    @FocusState private var isSearchFocused: Bool

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private struct SearchResults {
        var contacts:     [CRMContact]    = []
        var companies:    [Client]        = []
        var opportunities: [CRMOpportunity] = []
        static let empty = SearchResults()
        var hasAny: Bool { !contacts.isEmpty || !companies.isEmpty || !opportunities.isEmpty }
    }

    private func runSearch(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { results = .empty; return }
        let lq = trimmed.lowercased()
        results = SearchResults(
            contacts: store.crmContacts.filter {
                $0.fullName.range(of: lq, options: .caseInsensitive) != nil ||
                $0.email.range(of: lq, options: .caseInsensitive) != nil ||
                $0.phone.range(of: lq, options: .caseInsensitive) != nil ||
                $0.title.range(of: lq, options: .caseInsensitive) != nil
            },
            companies: store.clients.filter {
                $0.name.range(of: lq, options: .caseInsensitive) != nil ||
                ($0.billingCity ?? "").range(of: lq, options: .caseInsensitive) != nil ||
                ($0.contactName ?? "").range(of: lq, options: .caseInsensitive) != nil
            },
            opportunities: store.crmOpportunities.filter {
                $0.title.range(of: lq, options: .caseInsensitive) != nil ||
                $0.stage.rawValue.range(of: lq, options: .caseInsensitive) != nil ||
                $0.serviceType.range(of: lq, options: .caseInsensitive) != nil ||
                $0.notes.range(of: lq, options: .caseInsensitive) != nil
            }
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search Bar
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search contacts, companies, deals…", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isSearchFocused)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                if trimmed.isEmpty {
                    SearchIdleView()
                } else if !results.hasAny {
                    SearchEmptyView(query: trimmed)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {

                            // MARK: Companies
                            if !results.companies.isEmpty {
                                SearchSectionHeader(title: "Companies", count: results.companies.count)
                                ForEach(results.companies) { company in
                                    NavigationLink(destination: CRMCompanyDetailView(client: company).environmentObject(store)) {
                                        CompanySearchRow(client: company)
                                    }
                                    .buttonStyle(.plain)
                                    Divider().padding(.leading, 52)
                                }
                            }

                            // MARK: Contacts
                            if !results.contacts.isEmpty {
                                SearchSectionHeader(title: "Contacts", count: results.contacts.count)
                                ForEach(results.contacts) { contact in
                                    ContactSearchRow(contact: contact, store: store)
                                    Divider().padding(.leading, 52)
                                }
                            }

                            // MARK: Opportunities
                            if !results.opportunities.isEmpty {
                                SearchSectionHeader(title: "Opportunities", count: results.opportunities.count)
                                ForEach(results.opportunities) { opp in
                                    NavigationLink(destination: CRMOpportunityDetailView(opportunity: opp).environmentObject(store)) {
                                        OpportunitySearchRow(opp: opp)
                                    }
                                    .buttonStyle(.plain)
                                    Divider().padding(.leading, 52)
                                }
                            }

                            Spacer(minLength: 32)
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Search CRM")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { isSearchFocused = true }
            .onChange(of: query) { newValue in
                // Debounce: run search 300ms after last keystroke
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard query == newValue else { return }
                    runSearch(newValue)
                }
            }
        }
    }
}

// MARK: - Section Header

private struct SearchSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Spacer()
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }
}

// MARK: - Company Row

private struct CompanySearchRow: View {
    let client: Client

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: "building.2.fill")
                    .font(.subheadline)
                    .foregroundColor(.blue)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(client.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                if let city = client.billingCity, !city.isEmpty {
                    Text(city)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Contact Row

private struct ContactSearchRow: View {
    let contact: CRMContact
    let store: AppStore

    private var companyName: String {
        store.clients.first(where: { $0.id == contact.clientID })?.name ?? ""
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.purple.opacity(0.12))
                    .frame(width: 36, height: 36)
                Text(contact.initials)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.purple)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.fullName)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                HStack(spacing: 4) {
                    if !contact.title.isEmpty {
                        Text(contact.title)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if !contact.title.isEmpty && !companyName.isEmpty {
                        Text("·").font(.caption).foregroundColor(.secondary)
                    }
                    if !companyName.isEmpty {
                        Text(companyName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Opportunity Row

private struct OpportunitySearchRow: View {
    let opp: CRMOpportunity

    private var valueString: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 0
        f.locale = .current
        return f.string(from: opp.value as NSDecimalNumber) ?? "$0"
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(opp.stage.color.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: opp.stage.icon)
                    .font(.subheadline)
                    .foregroundColor(opp.stage.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(opp.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(opp.stage.rawValue)
                        .font(.caption)
                        .foregroundColor(opp.stage.color)
                    Text("·").font(.caption).foregroundColor(.secondary)
                    Text(valueString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Idle / Empty States

private struct SearchIdleView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.4))
            Text("Search contacts, companies,\nand opportunities")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }
}

private struct SearchEmptyView: View {
    let query: String

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "xmark.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.4))
            Text("No results for \"\(query)\"")
                .font(.subheadline.weight(.medium))
                .foregroundColor(.primary)
            Text("Try a different name, company, or stage.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }
}
