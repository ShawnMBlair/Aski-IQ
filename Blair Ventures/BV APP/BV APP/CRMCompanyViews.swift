// CRMCompanyViews.swift
// BV APP – CRM Company List, Detail, Contact, and Activity Views

import SwiftUI
import Foundation

// MARK: - Currency Formatter

private func currency(_ d: Decimal) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.locale = .current
    return f.string(from: d as NSDecimalNumber) ?? "$0"
}

// MARK: - Relative Date Formatter

private func relativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

// MARK: - CRMCompanyListView

struct CRMCompanyListView: View {
    @EnvironmentObject var store: AppStore
    @State private var searchText: String = ""
    @State private var showLeadIntake: Bool = false
    @State private var showAddCompany: Bool = false
    @StateObject private var pagination = PaginationState(pageSize: 25)

    private var filtered: [Client] {
        store.clients
            .filter {
                searchText.isEmpty ||
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                ($0.contactName ?? "").localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        Group {
            if filtered.isEmpty {
                CompanyEmptyState(
                    hasSearch: !searchText.isEmpty,
                    onAdd: { showAddCompany = true }
                )
            } else {
                List {
                    ForEach(Array(filtered.prefix(pagination.displayLimit))) { client in
                        NavigationLink(destination: CRMCompanyDetailView(client: client)) {
                            CompanyListRow(client: client, store: store)
                        }
                    }
                    LoadMoreFooter(
                        showing: min(pagination.displayLimit, filtered.count),
                        total: filtered.count,
                        onLoad: { pagination.loadMore() }
                    )
                }
                .listStyle(.plain)
                .onChange(of: searchText) { pagination.reset() }
            }
        }
        .searchable(text: $searchText, prompt: "Search companies or contacts")
        .navigationTitle("Companies")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showLeadIntake = true
                } label: {
                    Label("New Lead", systemImage: "plus.circle.fill")
                }
            }
            if store.currentUserRole.canEditCRM {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAddCompany = true } label: {
                        Label("Add Company", systemImage: "building.2.badge.plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showLeadIntake) {
            LeadIntakeView()
                .environmentObject(store)
        }
        .sheet(isPresented: $showAddCompany) {
            ClientCreateEditView()
                .environmentObject(store)
        }
    }
}

// MARK: - Company List Row

private struct CompanyListRow: View {
    let client: Client
    let store: AppStore

    private var openOpps: [CRMOpportunity] {
        store.opportunities(for: client.id).filter { $0.isActive }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Avatar circle
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 44, height: 44)
                Text(client.initials)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.blue)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(client.name)
                        .font(.body.weight(.semibold))
                        .foregroundColor(.primary)
                    if !client.isActive {
                        Text("Inactive")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2))
                            .foregroundColor(.secondary)
                            .cornerRadius(4)
                    }
                }

                if let contactName = client.contactName, !contactName.isEmpty {
                    Text(contactName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                if let phone = client.contactPhone, !phone.isEmpty {
                    Text(phone)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if !openOpps.isEmpty {
                ZStack {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 26, height: 26)
                    Text("\(openOpps.count)")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.white)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Company Empty State

private struct CompanyEmptyState: View {
    let hasSearch: Bool
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: hasSearch ? "magnifyingglass" : "building.2")
                .font(.system(size: 52))
                .foregroundColor(.secondary)
            Text(hasSearch ? "No companies found" : "No companies yet")
                .font(.headline)
            Text(hasSearch ? "Try a different search term." : "Add your first company to start tracking your pipeline.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if !hasSearch {
                Button("Add Company", action: onAdd)
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
    }
}

// MARK: - CRMCompanyDetailView

struct CRMCompanyDetailView: View {
    @EnvironmentObject var store: AppStore
    let client: Client

    @State private var showNewOpportunity: Bool = false
    @State private var showAddContact: Bool = false
    @State private var showAddTask: Bool = false
    @State private var selectedContact: CRMContact? = nil

    private var openOpportunities: [CRMOpportunity] {
        store.opportunities(for: client.id).filter { $0.isActive }
    }

    private var allOpportunities: [CRMOpportunity] {
        store.opportunities(for: client.id)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var contacts: [CRMContact] {
        store.contacts(for: client.id)
    }

    private var recentActivities: [CRMActivity] {
        Array(store.crmActivities(forClient: client.id).prefix(8))
    }

    private var openTasks: [CRMTask] {
        store.crmTasks(forClient: client.id).filter { $0.status != .done }
    }

    // Most advanced active stage's next action
    private var nextBestAction: String {
        let orderedStages = OpportunityStage.allCases
        let activeOpps = openOpportunities
        guard !activeOpps.isEmpty else { return "Create first opportunity" }
        let mostAdvanced = activeOpps.max {
            let aIdx = orderedStages.firstIndex(of: $0.stage) ?? 0
            let bIdx = orderedStages.firstIndex(of: $1.stage) ?? 0
            return aIdx < bIdx
        }
        return mostAdvanced?.stage.nextAction ?? "Create first opportunity"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {

                // MARK: Header Card
                CompanyHeaderCard(client: client)

                VStack(spacing: 16) {

                    // MARK: Next Best Action Banner
                    NextBestActionBanner(
                        message: nextBestAction,
                        hasOpportunities: !openOpportunities.isEmpty
                    )
                    .padding(.horizontal, 16)

                    // MARK: Quick Actions
                    CompanyQuickActionsRow(
                        client: client,
                        onNewOpportunity: { showNewOpportunity = true }
                    )
                    .padding(.horizontal, 16)

                    // MARK: Contacts Section
                    CompanyContactsSection(
                        contacts: contacts,
                        onTapContact: { selectedContact = $0 },
                        onAddContact: { showAddContact = true }
                    )

                    // MARK: Win/Loss Stats
                    CompanyWinLossStatsCard(clientID: client.id)

                    // MARK: Opportunities Section
                    CompanyOpportunitiesSection(
                        opportunities: allOpportunities,
                        onNewOpportunity: { showNewOpportunity = true }
                    )

                    // MARK: Recent Activity Section
                    CompanyActivitySection(
                        activities: recentActivities,
                        clientID: client.id
                    )

                    // MARK: Material Sales (CRM-to-cash visibility)
                    CompanyMaterialSalesSection(client: client)
                        .environmentObject(store)

                    // MARK: Tasks Section
                    CompanyTasksSection(
                        tasks: openTasks,
                        onAddTask: { showAddTask = true }
                    )

                    // MARK: Attachments Section
                    CRMAttachmentSection(entityID: client.id, entityType: .company)
                        .environmentObject(store)
                        .padding(.vertical, 16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(12)
                        .padding(.horizontal, 16)

                    Spacer(minLength: 32)
                }
                .padding(.top, 16)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(client.name)
        .navigationBarTitleDisplayMode(.inline)
        // Sheets
        .sheet(isPresented: $showNewOpportunity) {
            CRMOpportunityCreateSheet(clientID: client.id)
                .environmentObject(store)
        }
        .sheet(isPresented: $showAddContact) {
            CRMContactCreateSheet(clientID: client.id)
                .environmentObject(store)
        }
        .sheet(isPresented: $showAddTask) {
            CRMTaskCreateSheet(clientID: client.id, opportunityID: nil)
                .environmentObject(store)
        }
        .sheet(item: $selectedContact) { contact in
            CRMContactDetailSheet(contact: contact)
                .environmentObject(store)
        }
    }
}

// MARK: - Company Header Card

private struct CompanyHeaderCard: View {
    let client: Client

    var body: some View {
        VStack(spacing: 0) {
            // Background accent
            LinearGradient(
                colors: [Color.blue.opacity(0.7), Color.blue.opacity(0.4)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(height: 80)

            VStack(spacing: 12) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 68, height: 68)
                        .shadow(radius: 4)
                    Text(client.initials)
                        .font(.title2.weight(.bold))
                        .foregroundColor(.blue)
                }
                .offset(y: -34)

                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Text(client.name)
                            .font(.title3.weight(.bold))
                            .multilineTextAlignment(.center)

                        if let code = client.code, !code.isEmpty {
                            Text(code)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.15))
                                .foregroundColor(.secondary)
                                .cornerRadius(6)
                        }
                    }

                    // Status badge
                    Text(client.isActive ? "Active" : "Inactive")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(client.isActive ? Color.green.opacity(0.15) : Color.secondary.opacity(0.15))
                        .foregroundColor(client.isActive ? .green : .secondary)
                        .cornerRadius(8)

                    // Address
                    let addr = client.fullBillingAddress
                    if !addr.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "mappin.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(addr)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }

                    // Phone
                    if let phone = client.contactPhone, !phone.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "phone")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(phone)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Email
                    if let email = client.contactEmail, !email.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "envelope")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(email)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .offset(y: -28)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

// MARK: - Next Best Action Banner

private struct NextBestActionBanner: View {
    let message: String
    let hasOpportunities: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: hasOpportunities ? "arrow.right.circle.fill" : "plus.circle.fill")
                .font(.title3)
                .foregroundColor(hasOpportunities ? .orange : .blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Next Best Action")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
            }

            Spacer()
        }
        .padding(14)
        .background(
            (hasOpportunities ? Color.orange : Color.blue).opacity(0.1)
        )
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    (hasOpportunities ? Color.orange : Color.blue).opacity(0.25),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Company Quick Actions Row

private struct CompanyQuickActionsRow: View {
    let client: Client
    let onNewOpportunity: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Call button
            if let phone = client.contactPhone, !phone.isEmpty,
               let url = URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") {
                Link(destination: url) {
                    QuickActionButton(
                        icon: "phone.fill",
                        label: "Call",
                        color: .green
                    )
                }
            } else {
                QuickActionButton(icon: "phone.fill", label: "Call", color: .green)
                    .opacity(0.4)
                    .disabled(true)
            }

            // Email button
            if let email = client.contactEmail, !email.isEmpty,
               let url = URL(string: "mailto:\(email)") {
                Link(destination: url) {
                    QuickActionButton(
                        icon: "envelope.fill",
                        label: "Email",
                        color: .indigo
                    )
                }
            } else {
                QuickActionButton(icon: "envelope.fill", label: "Email", color: .indigo)
                    .opacity(0.4)
                    .disabled(true)
            }

            // New Opportunity button
            Button(action: onNewOpportunity) {
                QuickActionButton(
                    icon: "chart.bar.fill",
                    label: "New Opp",
                    color: .orange
                )
            }
        }
    }
}

private struct QuickActionButton: View {
    let icon: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(color.opacity(0.12))
                    .frame(height: 48)
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)
            }
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Company Contacts Section

private struct CompanyContactsSection: View {
    @EnvironmentObject var store: AppStore
    let contacts: [CRMContact]
    let onTapContact: (CRMContact) -> Void
    let onAddContact: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader2(title: "Contacts", buttonLabel: "Add",
                           showButton: store.currentUserRole.canEditCRM,
                           action: onAddContact)
                .padding(.horizontal, 16)

            if contacts.isEmpty {
                EmptyRowPlaceholder(message: "No contacts yet")
                    .padding(.horizontal, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(contacts) { contact in
                        ContactRow(contact: contact, onTap: { onTapContact(contact) })
                        if contact.id != contacts.last?.id {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)
                .padding(.horizontal, 16)
            }
        }
    }
}

private struct ContactRow: View {
    @EnvironmentObject var store: AppStore
    let contact: CRMContact
    let onTap: () -> Void

    @State private var showLogCall:  Bool = false
    @State private var showLogEmail: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.teal.opacity(0.15))
                    .frame(width: 40, height: 40)
                Text(contact.initials)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.teal)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(contact.fullName)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                    if contact.isPrimary {
                        Text("Primary")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                }
                if !contact.title.isEmpty {
                    Text(contact.title).font(.caption).foregroundColor(.secondary)
                }
                if !contact.phone.isEmpty {
                    Text(contact.phone).font(.caption).foregroundColor(.secondary)
                }
            }

            Spacer()

            // Quick-action buttons
            HStack(spacing: 14) {
                if !contact.phone.isEmpty {
                    Button { showLogCall = true } label: {
                        Image(systemName: "phone.fill")
                            .font(.subheadline)
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
                }
                if !contact.email.isEmpty {
                    Button { showLogEmail = true } label: {
                        Image(systemName: "envelope.fill")
                            .font(.subheadline)
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                }
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .sheet(isPresented: $showLogCall) {
            CRMLogActivitySheet(contact: contact, activityType: .callMade)
                .environmentObject(store)
        }
        .sheet(isPresented: $showLogEmail) {
            CRMLogActivitySheet(contact: contact, activityType: .emailSent)
                .environmentObject(store)
        }
    }
}

// MARK: - Company Win/Loss Stats Card

private struct CompanyWinLossStatsCard: View {
    @EnvironmentObject var store: AppStore
    let clientID: UUID

    // 2026-04 audit fix (Phase 9 cleanup): the inline win/loss
    // computations on this card used to drift from the canonical
    // values in CRMDashboardView. They now route through the
    // shared helpers (`wonValue(in:)`, `lostValue(in:)`,
    // `winRate(in:)`, `wonLostCounts(in:)`) so per-company stats
    // and tenant-wide stats use the same math.
    private var allOpps: [CRMOpportunity] {
        store.crmOpportunities.filter { $0.clientID == clientID && !$0.isDeleted }
    }
    private var openOpps:   [CRMOpportunity] { allOpps.filter { $0.isActive } }
    private var wonOpps:    [CRMOpportunity] {
        allOpps.filter { $0.stage == .won && !$0.isDeleted }
    }
    private var lostOpps:   [CRMOpportunity] {
        allOpps.filter { $0.stage == .lost && !$0.isDeleted }
    }
    private var wonRevenue: Decimal { store.wonValue(in: allOpps) }
    private var lostQuoted: Decimal { store.lostValue(in: allOpps) }
    private var winRate: Double { store.winRate(in: allOpps) }
    private var avgDealSize: Decimal {
        let counts = store.wonLostCounts(in: allOpps)
        guard counts.won > 0 else { return 0 }
        return wonRevenue / Decimal(counts.won)
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader2(title: "Commercial Summary", buttonLabel: "",
                           showButton: false, action: {})
                .padding(.horizontal, 16)

            VStack(spacing: 12) {
                // Top row — pipeline + win rate
                HStack(spacing: 12) {
                    StatPill(label: "Open",   value: "\(openOpps.count)",
                             sub: store.pipelineValue(for: clientID).currencyString,
                             color: .blue)
                    StatPill(label: "Won",    value: "\(wonOpps.count)",
                             sub: wonRevenue.currencyString,   color: .green)
                    StatPill(label: "Lost",   value: "\(lostOpps.count)",
                             sub: lostQuoted.currencyString,   color: .red)
                }

                // Bottom row — win rate + avg deal
                HStack(spacing: 12) {
                    StatPill(label: "Win Rate",
                             value: String(format: "%.0f%%", winRate * 100),
                             sub: "\(wonOpps.count + lostOpps.count) closed",
                             color: winRate >= 0.5 ? .green : .orange)
                    StatPill(label: "Avg Deal",
                             value: avgDealSize.currencyString,
                             sub: "per won opp", color: .purple)
                    StatPill(label: "Total",
                             value: "\(allOpps.count)",
                             sub: "all time", color: .secondary)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct StatPill: View {
    let label: String
    let value: String
    let sub:   String
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.caption2).foregroundColor(.secondary)
            Text(value)
                .font(.subheadline.bold()).foregroundColor(color)
            Text(sub)
                .font(.caption2).foregroundColor(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.08))
        .cornerRadius(10)
    }
}

// MARK: - Company Opportunities Section

private struct CompanyOpportunitiesSection: View {
    @EnvironmentObject var store: AppStore
    let opportunities: [CRMOpportunity]
    let onNewOpportunity: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader2(title: "Opportunities", buttonLabel: "New",
                           showButton: store.currentUserRole.canEditCRM,
                           action: onNewOpportunity)
                .padding(.horizontal, 16)

            if opportunities.isEmpty {
                EmptyRowPlaceholder(message: "No opportunities yet")
                    .padding(.horizontal, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(opportunities) { opp in
                        NavigationLink(destination: CRMOpportunityDetailView(opportunity: opp)) {
                            OpportunityRow(opportunity: opp)
                        }
                        .buttonStyle(.plain)

                        if opp.id != opportunities.last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)
                .padding(.horizontal, 16)
            }
        }
    }
}

private struct OpportunityRow: View {
    let opportunity: CRMOpportunity

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: opportunity.stage.icon)
                .font(.body)
                .foregroundColor(opportunity.stage.color)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(opportunity.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(opportunity.stage.rawValue)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(opportunity.stage.color.opacity(0.15))
                    .foregroundColor(opportunity.stage.color)
                    .cornerRadius(6)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(currency(opportunity.value))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Company Activity Section

private struct CompanyActivitySection: View {
    let activities: [CRMActivity]
    let clientID: UUID
    @State private var showAllActivities: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent Activity")
                    .font(.headline)
                Spacer()
                Button("View All") {
                    showAllActivities = true
                }
                .font(.subheadline)
                .foregroundColor(.blue)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if activities.isEmpty {
                EmptyRowPlaceholder(message: "No activity recorded")
                    .padding(.horizontal, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(activities) { activity in
                        ActivityLogRow(activity: activity)

                        if activity.id != activities.last?.id {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)
                .padding(.horizontal, 16)
            }
        }
        .sheet(isPresented: $showAllActivities) {
            NavigationStack {
                // Placeholder: CRMActivityLogView(clientID: clientID)
                Text("Activity Log")
                    .font(.headline)
                    .foregroundColor(.secondary)
                    .navigationTitle("Activity")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

private struct ActivityLogRow: View {
    let activity: CRMActivity

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(activity.type.color.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: activity.type.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(activity.type.color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                Text(relativeDate(activity.date))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Company Tasks Section

private struct CompanyTasksSection: View {
    @EnvironmentObject var store: AppStore
    let tasks: [CRMTask]
    let onAddTask: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader2(title: "Open Tasks", buttonLabel: "Add",
                           showButton: store.currentUserRole.canEditCRM,
                           action: onAddTask)
                .padding(.horizontal, 16)

            if tasks.isEmpty {
                EmptyRowPlaceholder(message: "No open tasks")
                    .padding(.horizontal, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(tasks) { task in
                        TaskRow(task: task)

                        if task.id != tasks.last?.id {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)
                .padding(.horizontal, 16)
            }
        }
    }
}

private struct TaskRow: View {
    let task: CRMTask

    private var dueDateText: String {
        guard let date = task.dueDate else { return "No due date" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(task.priority.color.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: task.priority.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(task.priority.color)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(2)

                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.caption2)
                    Text(dueDateText)
                        .font(.caption)
                }
                .foregroundColor(task.isOverdue ? .red : .secondary)
            }

            Spacer()

            if task.isOverdue {
                Text("Overdue")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.12))
                    .foregroundColor(.red)
                    .cornerRadius(6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(task.isOverdue ? Color.red.opacity(0.04) : Color.clear)
    }
}

// MARK: - CRMContactDetailSheet

struct CRMContactDetailSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let contact: CRMContact

    @State private var isEditing: Bool = false
    @State private var firstName: String = ""
    @State private var lastName: String = ""
    @State private var title: String = ""
    @State private var phone: String = ""
    @State private var email: String = ""
    @State private var notes: String = ""
    @State private var isPrimary: Bool = false

    private var displayContact: CRMContact {
        // Reflect live edits during edit mode
        var c = contact
        c.firstName = firstName
        c.lastName = lastName
        c.title = title
        c.phone = phone
        c.email = email
        c.notes = notes
        c.isPrimary = isPrimary
        return c
    }

    var body: some View {
        NavigationStack {
            Form {
                // Header section
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(Color.teal.opacity(0.15))
                                    .frame(width: 68, height: 68)
                                Text(contact.initials)
                                    .font(.title2.weight(.bold))
                                    .foregroundColor(.teal)
                            }
                            if !isEditing {
                                Text(contact.fullName)
                                    .font(.title3.weight(.semibold))
                                if !contact.title.isEmpty {
                                    Text(contact.title)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                if contact.isPrimary {
                                    Text("Primary Contact")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.blue.opacity(0.15))
                                        .foregroundColor(.blue)
                                        .cornerRadius(8)
                                }
                            }
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                if isEditing {
                    // MARK: Edit Mode
                    Section("Name") {
                        TextField("First Name", text: $firstName)
                            .textContentType(.givenName)
                        TextField("Last Name", text: $lastName)
                            .textContentType(.familyName)
                    }

                    Section("Role") {
                        TextField("Title / Role", text: $title)
                            .textContentType(.jobTitle)
                        Toggle("Primary Contact", isOn: $isPrimary)
                    }

                    Section("Contact Info") {
                        HStack {
                            Image(systemName: "phone.fill")
                                .foregroundColor(.green)
                                .frame(width: 20)
                            TextField("Phone", text: $phone)
                                .textContentType(.telephoneNumber)
                                .keyboardType(.phonePad)
                        }
                        HStack {
                            Image(systemName: "envelope.fill")
                                .foregroundColor(.indigo)
                                .frame(width: 20)
                            TextField("Email", text: $email)
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .autocapitalization(.none)
                        }
                    }

                    Section("Notes") {
                        TextEditor(text: $notes)
                            .frame(minHeight: 80)
                    }

                } else {
                    // MARK: View Mode
                    if !phone.isEmpty {
                        Section("Phone") {
                            if let url = URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") {
                                Link(destination: url) {
                                    Label(phone, systemImage: "phone.fill")
                                        .foregroundColor(.green)
                                }
                            } else {
                                Label(phone, systemImage: "phone.fill")
                            }
                        }
                    }

                    if !email.isEmpty {
                        Section("Email") {
                            if let url = URL(string: "mailto:\(email)") {
                                Link(destination: url) {
                                    Label(email, systemImage: "envelope.fill")
                                        .foregroundColor(.indigo)
                                }
                            } else {
                                Label(email, systemImage: "envelope.fill")
                            }
                        }
                    }

                    if !notes.isEmpty {
                        Section("Notes") {
                            Text(notes)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Contact" : "Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isEditing {
                        Button("Cancel") {
                            populateFields()
                            isEditing = false
                        }
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isEditing {
                        Button("Save") { saveContact() }
                            .disabled(firstName.trimmingCharacters(in: .whitespaces).isEmpty)
                    } else if store.currentUserRole.canEditCRM {
                        Button("Edit") { isEditing = true }
                    }
                }
            }
        }
        .onAppear { populateFields() }
    }

    private func populateFields() {
        firstName = contact.firstName
        lastName = contact.lastName
        title = contact.title
        phone = contact.phone
        email = contact.email
        notes = contact.notes
        isPrimary = contact.isPrimary
    }

    private func saveContact() {
        var updated = contact
        updated.firstName = firstName.trimmingCharacters(in: .whitespaces)
        updated.lastName = lastName.trimmingCharacters(in: .whitespaces)
        updated.title = title.trimmingCharacters(in: .whitespaces)
        updated.phone = phone.trimmingCharacters(in: .whitespaces)
        updated.email = email.trimmingCharacters(in: .whitespaces)
        updated.notes = notes.trimmingCharacters(in: .whitespaces)
        updated.isPrimary = isPrimary
        store.upsertCRMContact(updated)
        isEditing = false
    }
}

// MARK: - CRMContactCreateSheet

struct CRMContactCreateSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let clientID: UUID

    @State private var firstName: String = ""
    @State private var lastName: String = ""
    @State private var title: String = ""
    @State private var phone: String = ""
    @State private var email: String = ""
    @State private var isPrimary: Bool = false
    @State private var notes: String = ""

    @State private var duplicates: [CRMContact] = []
    @State private var showDuplicateWarning: Bool = false

    private var isSaveDisabled: Bool {
        firstName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("First Name", text: $firstName)
                        .textContentType(.givenName)
                    TextField("Last Name", text: $lastName)
                        .textContentType(.familyName)
                }

                Section("Role") {
                    TextField("Title / Role", text: $title)
                        .textContentType(.jobTitle)
                    Toggle("Primary Contact", isOn: $isPrimary)
                }

                Section("Contact Info") {
                    HStack {
                        Image(systemName: "phone.fill")
                            .foregroundColor(.green)
                            .frame(width: 20)
                        TextField("Phone", text: $phone)
                            .textContentType(.telephoneNumber)
                            .keyboardType(.phonePad)
                            .onChange(of: phone) { checkDuplicates() }
                    }
                    HStack {
                        Image(systemName: "envelope.fill")
                            .foregroundColor(.indigo)
                            .frame(width: 20)
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                            .onChange(of: email) { checkDuplicates() }
                    }
                }

                if showDuplicateWarning {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Possible Duplicate Contact")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.orange)
                                ForEach(duplicates) { dup in
                                    Text("\(dup.fullName) — \(dup.email.isEmpty ? dup.phone : dup.email)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                }
            }
            .navigationTitle("New Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveContact() }
                        .disabled(isSaveDisabled)
                }
            }
        }
    }

    private func checkDuplicates() {
        let found = store.detectDuplicateContacts(email: email, phone: phone)
        duplicates = found
        showDuplicateWarning = !found.isEmpty && (!email.isEmpty || !phone.isEmpty)
    }

    private func saveContact() {
        var contact = CRMContact(clientID: clientID)
        contact.firstName = firstName.trimmingCharacters(in: .whitespaces)
        contact.lastName = lastName.trimmingCharacters(in: .whitespaces)
        contact.title = title.trimmingCharacters(in: .whitespaces)
        contact.phone = phone.trimmingCharacters(in: .whitespaces)
        contact.email = email.trimmingCharacters(in: .whitespaces)
        contact.isPrimary = isPrimary
        contact.notes = notes.trimmingCharacters(in: .whitespaces)

        store.upsertCRMContact(contact)
        store.logCRMActivity(
            type: .contactAdded,
            title: "Contact added: \(contact.fullName)",
            notes: contact.title,
            clientID: clientID,
            contactID: contact.id,
            opportunityID: nil,
            quoteID: nil,
            projectID: nil
        )
        dismiss()
    }
}

// MARK: - Shared Sub-components

private struct SectionHeader2: View {
    let title: String
    let buttonLabel: String
    var showButton: Bool = true
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            if showButton {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.caption.weight(.semibold))
                        Text(buttonLabel)
                            .font(.subheadline)
                    }
                    .foregroundColor(.blue)
                }
            }
        }
        .padding(.bottom, 8)
    }
}

private struct EmptyRowPlaceholder: View {
    let message: String

    var body: some View {
        HStack {
            Spacer()
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.vertical, 16)
            Spacer()
        }
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
}

// MARK: - Company Material Sales Section
//
// Surfaces every active material sale for this client on the CRM company
// detail screen — the canonical CRM-to-cash bridge. Counterpart to
// `OpportunityMaterialSalesSection` in CRMOpportunityViews.swift; same
// visual pattern (orange shippingbox, AskiSpacing tokens, secondarySystemGroupedBackground).
//
// Rolls up total revenue across non-deleted sales so AMs can answer
// "how much have we sold this account?" at a glance, and provides a
// "New" button that pre-fills the create sheet via `CommercialContext.from(client:)`.

struct CompanyMaterialSalesSection: View {
    let client: Client
    @EnvironmentObject var store: AppStore
    @State private var showCreate = false

    /// All non-deleted material sales for this client, newest first.
    private var sales: [MaterialSale] {
        store.materialSales
            .filter { !$0.isDeleted && $0.clientID == client.id }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Sum of grand totals across the visible sales — quick "lifetime
    /// material revenue" hint for the AM. `grandTotal` is `Decimal` so we
    /// keep the running total in `Decimal` to avoid float-precision drift
    /// and so we can use the existing `Decimal.currencyString` extension.
    private var totalRevenue: Decimal {
        sales.reduce(Decimal(0)) { $0 + $1.grandTotal }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AskiSpacing.md) {
            HStack {
                Image(systemName: "shippingbox.fill")
                    .foregroundColor(.orange)
                Text("Material Sales")
                    .font(.headline)
                if !sales.isEmpty {
                    Text("(\(sales.count))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if store.currentUserRole.canAccessCommercial {
                    Button { showCreate = true } label: {
                        Label("New", systemImage: "plus")
                            .font(.subheadline)
                    }
                    .accessibilityLabel("New material sale for this company")
                }
            }

            if sales.isEmpty {
                Text("No material sales yet for this company.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                // Lifetime revenue summary
                HStack {
                    Text("Lifetime revenue")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(totalRevenue.currencyString)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                }
                .padding(.bottom, AskiSpacing.xs)

                ForEach(sales) { sale in
                    NavigationLink {
                        MaterialSaleDetailView(sale: sale)
                    } label: {
                        CompanyMaterialSaleRow(sale: sale)
                    }
                }
            }
        }
        .padding(AskiSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: AskiRadius.card, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .padding(.horizontal, AskiSpacing.lg)
        .sheet(isPresented: $showCreate) {
            // Pre-fill the create sheet with this client's context.
            let prefill = CommercialContext.from(client: client, workType: .materialSale)
            MaterialSaleCreateEditView(context: prefill)
                .environmentObject(store)
        }
    }
}

/// Compact row for a material sale on the company detail screen.
/// Mirrors `OpportunityMaterialSaleRow` but without the linked/unlinked
/// distinction since on a company screen all sales by definition belong
/// to this client.
private struct CompanyMaterialSaleRow: View {
    let sale: MaterialSale

    var body: some View {
        HStack(spacing: AskiSpacing.md) {
            Image(systemName: "shippingbox")
                .foregroundColor(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(sale.saleNumber.isEmpty ? "Material sale" : sale.saleNumber)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                HStack(spacing: AskiSpacing.sm) {
                    Text(sale.status.rawValue.capitalized)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.16)))
                        .foregroundColor(.orange)
                    if let due = sale.requestedDeliveryDate {
                        Label(due.shortDate, systemImage: "calendar")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            Text(sale.grandTotal.currencyString)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, AskiSpacing.xs)
    }
}
