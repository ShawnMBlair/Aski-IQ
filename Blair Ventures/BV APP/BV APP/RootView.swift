// RootView.swift
// AskiCommand – Root Navigation
// Session 4: Settings and Clients added to navigation
// Sprint 19B: .sidebarAdaptable tab style for iPad split-view

import SwiftUI
import CoreSpotlight

struct RootView: View {
    @EnvironmentObject var store: AppStore

    // Persist the selected tab across cold launches per scene. Each role's
    // TabView gets its own storage key so a field worker who flipped to "Hours"
    // doesn't end up on a non-existent tab after a role switch.
    @SceneStorage("aski_full_tab")  private var fullTab: Int = 0
    @SceneStorage("aski_field_tab") private var fieldTab: Int = 0
    @SceneStorage("aski_client_tab") private var clientTab: Int = 0

    /// Drives "More" presentation for routes that live behind the More tab.
    @State private var showMoreSheet: Bool = false

    var body: some View {
        Group {
            switch store.currentUserRole {
            case .fieldWorker:
                fieldWorkerTabView
            case .client:
                clientTabView
            default:
                fullTabView
            }
        }
        .onChange(of: store.pendingDeepLink) { _, route in
            guard let route else { return }
            handleDeepLink(route)
            store.pendingDeepLink = nil
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            handleSpotlightActivity(activity)
        }
        .onContinueUserActivity(SpotlightService.openActivityType) { activity in
            handleSpotlightActivity(activity)
        }
        .onChange(of: store.pendingSpotlightTarget) { _, target in
            guard let target else { return }
            handleSpotlightTarget(target)
            store.pendingSpotlightTarget = nil
        }
        .onChange(of: store.pendingOpenRecord) { _, intent in
            guard let intent else { return }
            handleOpenRecord(intent)
            store.pendingOpenRecord = nil
        }
    }

    /// Routes a universal-search hit to the right tab. Detail navigation is
    /// intentionally minimal in v1 — we land on the entity's hub list and the
    /// user taps through. Pushing a specific detail screen requires a
    /// programmable navigation path, which we'll layer on in a future pass.
    private func handleOpenRecord(_ intent: OpenRecordIntent) {
        switch store.currentUserRole {
        case .fieldWorker:
            switch intent.kind {
            case .project, .formSubmission, .incident: fieldTab = 1   // Projects
            default:                                   fieldTab = 0   // Today
            }
        case .client:
            clientTab = 0
        default:
            switch intent.kind {
            case .crmContact, .crmOpportunity:                    fullTab = 2   // CRM
            case .project:                                        fullTab = 1   // Projects
            case .quote, .estimate, .invoice, .formSubmission,
                 .incident, .client, .employee:                   fullTab = 4   // More
            }
        }
    }

    /// Pulls a target out of the inbound NSUserActivity (Spotlight tap or
    /// custom open URL) and stashes it on AppStore so the active scene
    /// reacts on the next render cycle.
    private func handleSpotlightActivity(_ activity: NSUserActivity) {
        guard var target = SpotlightService.target(from: activity) else { return }
        // Spotlight's CSSearchableItemActionType collapses both projects
        // and clients to the bare UUID. Disambiguate by looking up which
        // store actually has the ID.
        if case let .project(id) = target {
            if store.client(id: id) != nil { target = .client(id) }
        }
        store.pendingSpotlightTarget = target
    }

    /// Switches the active tab toward the Spotlight target. Detail navigation
    /// (push the actual record) is intentionally minimal here — the user
    /// lands on the relevant list and can tap through.
    private func handleSpotlightTarget(_ target: SpotlightTarget) {
        switch target {
        case .project:
            switch store.currentUserRole {
            case .fieldWorker: fieldTab = 1   // Projects
            case .client:      clientTab = 0  // My Project
            default:           fullTab = 1    // Projects
            }
        case .client:
            switch store.currentUserRole {
            case .fieldWorker: fieldTab = 1
            case .client:      clientTab = 0
            default:           fullTab = 4    // More — Clients lives there
            }
        // Week 4 audit closeout: Spotlight now indexes opportunities,
        // quotes, and invoices too. They all live under More for
        // full-tab roles; field/client roles land on their primary
        // list since they shouldn't normally be searching commercial
        // records (RLS would reject access anyway).
        case .opportunity, .quote, .invoice:
            switch store.currentUserRole {
            case .fieldWorker: fieldTab = 1
            case .client:      clientTab = 0
            default:           fullTab = 4    // More
            }
        }
    }

    /// Maps an incoming deep-link route to a tab change. Routes whose
    /// destination lives under "More" (Approval queue, invoices, etc.) flip
    /// to that tab — the More section is the canonical hub for them.
    private func handleDeepLink(_ route: NotifRoute) {
        switch route {
        case .approvalQueue, .djrApprovalQueue,
             .incidentList, .certificationList, .equipmentList,
             .estimateList, .invoiceList:
            // All live under More; switch full tab to More (4) or field-tab Hours (3) as fallback.
            switch store.currentUserRole {
            case .fieldWorker: fieldTab = 0      // Today landing for field
            case .client:      clientTab = 0
            default:           fullTab = 4       // More
            }
        case .crmTasks, .crmHub:
            switch store.currentUserRole {
            case .fieldWorker: fieldTab = 0
            case .client:      clientTab = 0
            default:           fullTab = 2       // CRM
            }
        }
    }

    // MARK: - Full Tab Bar

    private var fullTabView: some View {
        TabView(selection: $fullTab) {
            WidgetDashboardView()
                .tabItem { Label("Dashboard", systemImage: "house.fill") }
                .tag(0)

            ProjectListView()
                .tabItem { Label("Projects", systemImage: "folder.fill") }
                .tag(1)

            CRMHubView()
                .tabItem { Label("CRM", systemImage: "person.crop.rectangle.stack.fill") }
                .tag(2)

            ScheduleCalendarView()
                .tabItem { Label("Schedule", systemImage: "calendar") }
                .tag(3)

            MoreView()
                .tabItem { Label("More", systemImage: "ellipsis") }
                .tag(4)
        }
        // On iPad this becomes a sidebar; on iPhone it stays a tab bar.
        .tabViewStyle(.sidebarAdaptable)
    }

    // MARK: - Field Worker Tab Bar

    private var fieldWorkerTabView: some View {
        TabView(selection: $fieldTab) {
            ForemanDashboardView()
                .tabItem { Label("Today", systemImage: "house.fill") }
                .tag(0)

            ProjectListView()
                .tabItem { Label("Projects", systemImage: "folder.fill") }
                .tag(1)

            FormsHubView()
                .tabItem { Label("Forms", systemImage: "doc.text.fill") }
                .tag(2)

            NavigationStack { TimesheetDailyEntryView() }
                .tabItem { Label("Hours", systemImage: "clock.fill") }
                .tag(3)
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    // MARK: - Client Tab Bar

    private var clientTabView: some View {
        TabView(selection: $clientTab) {
            ProjectListView()
                .tabItem { Label("My Project", systemImage: "folder.fill") }
                .tag(0)

            ClientDocumentsView()
                .tabItem { Label("Documents", systemImage: "doc.fill") }
                .tag(1)
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    // MARK: - Dashboard Router

    @ViewBuilder
    private var dashboardView: some View {
        switch store.currentUserRole {
        case .fieldWorker:      ForemanDashboardView()
        case .foreman:          ForemanDashboardView()
        case .safetyAdvisor:    OfficeDashboardView()
        case .projectManager:   OfficeDashboardView()
        case .estimator:        EstimateListView()
        case .officeAdmin:      OfficeDashboardView()
        case .manager:          ManagementDashboardView()
        case .executive:        ManagementDashboardView()
        // Owner is a peer of executive for dashboard routing — same surface.
        case .owner:            ManagementDashboardView()
        case .client:           ProjectListView()
        }
    }
}

// MARK: - More View
// Each section is its own struct so the List TupleView stays short for the linker.

struct MoreView: View {
    var body: some View {
        NavigationStack {
            List {
                MoreFieldOpsSection()
                MoreEquipmentSection()
                MoreSafetySection()
                MoreCommercialSection()
                MorePeopleSection()
                MoreAdminSection()
                MoreAccountSection()
                AppStatusSection()
            }
            .navigationTitle("More")
        }
    }
}

// MARK: Field Operations

private struct MoreFieldOpsSection: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        Section("Field Operations") {
            NavigationLink(destination: TimesheetDailyEntryView()) {
                Label("Log Hours", systemImage: "clock.fill")
            }
            if store.currentUserRole.canApproveTimesheets {
                NavigationLink(destination: TimesheetApprovalQueueView()) {
                    MoreBadgeRow(label: "Approval Queue", icon: "checkmark.circle.fill",
                                 count: store.pendingTimesheets().count, color: .orange)
                }
            }
            NavigationLink(destination: RFIListView()) {
                MoreBadgeRow(label: "RFIs", icon: "questionmark.bubble.fill",
                             count: store.openRFIs.count, color: .orange)
            }
            NavigationLink(destination: FormsHubView()) {
                Label("Forms", systemImage: "doc.text.fill")
            }
            NavigationLink(destination: ReportsHubView()) {
                Label("Reports", systemImage: "chart.bar.fill")
            }
        }
    }
}

// MARK: Equipment

private struct MoreEquipmentSection: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        Section("Equipment & Assets") {
            NavigationLink(destination: EquipmentListView()) {
                MoreBadgeRow(label: "Equipment", icon: "truck.box.fill",
                             count: store.equipmentNeedingService.count + store.equipmentWithExpiringInspections.count,
                             color: .orange)
            }
        }
    }
}

// MARK: Safety

private struct MoreSafetySection: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        Section("Safety") {
            NavigationLink(destination: IncidentListView()) {
                MoreBadgeRow(label: "Incidents", icon: "exclamationmark.shield.fill",
                             count: store.openIncidents.count, color: .red)
            }
        }
    }
}

// MARK: Commercial

private struct MoreCommercialSection: View {
    @EnvironmentObject var store: AppStore
    @State private var showCommercialIntake = false

    var body: some View {
        let role = store.currentUserRole
        let show = role.canEstimate || role == .manager || role == .executive || role == .officeAdmin
        if show {
            Section("Commercial") {
                // ── New Commercial Work entry point ──────────────────────────
                Button {
                    showCommercialIntake = true
                } label: {
                    Label("New Commercial Work", systemImage: "plus.circle.fill")
                        .foregroundColor(.blue)
                }
                .sheet(isPresented: $showCommercialIntake) {
                    CommercialIntakeView()
                        .environmentObject(store)
                }

                // ── Material Sales ───────────────────────────────────────────
                NavigationLink(destination: MaterialSaleListView()) {
                    MoreBadgeRow(label: "Material Sales", icon: "shippingbox.fill",
                                 count: store.openMaterialSales.count, color: .purple)
                }

                NavigationLink(destination: ClientListView()) {
                    Label("Clients", systemImage: "building.2.fill")
                }
                if role.canEstimate || role == .manager || role == .executive {
                    NavigationLink(destination: EstimateListView()) {
                        MoreBadgeRow(label: "Estimates / Bids", icon: "doc.text.magnifyingglass",
                                     count: store.estimates.filter { $0.status.isActive }.count, color: .purple)
                    }
                    NavigationLink(destination: QuoteListView()) {
                        Label("Quotes", systemImage: "doc.richtext")
                    }
                }
                NavigationLink(destination: ChangeOrderListView()) {
                    MoreBadgeRow(label: "Change Orders", icon: "arrow.left.arrow.right.circle.fill",
                                 count: store.openChangeOrders.count, color: .orange)
                }
                NavigationLink(destination: SubcontractorListView()) {
                    MoreBadgeRow(label: "Subcontractors", icon: "building.2.fill",
                                 count: store.subcontractorsWithComplianceAlerts.count, color: .red)
                }
                NavigationLink(destination: InvoiceListView()) {
                    MoreBadgeRow(label: "Invoices", icon: "doc.plaintext.fill",
                                 count: store.overdueInvoices.count, color: .red)
                }
                NavigationLink(destination: ProcurementHubView()) {
                    MoreBadgeRow(label: "Procurement", icon: "shippingbox.fill",
                                 count: store.pendingMaterialApprovals.count, color: .orange)
                }
            }
        }
    }
}

// MARK: People

private struct MorePeopleSection: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        if store.currentUserRole.canManageUsers || store.currentUserRole == .officeAdmin {
            Section("People") {
                NavigationLink(destination: EmployeeListView()) {
                    Label("Employees", systemImage: "person.fill")
                }
                NavigationLink(destination: CertificateListView()) {
                    MoreBadgeRow(label: "Certifications", icon: "checkmark.seal.fill",
                                 count: store.complianceAlerts.count, color: .orange)
                }
            }
        }
    }
}

// MARK: Administration

private struct MoreAdminSection: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        if store.currentUserRole == .manager || store.currentUserRole == .executive || store.currentUserRole == .officeAdmin {
            Section("Administration") {
                NavigationLink(destination: AdminPanelView()) {
                    MoreBadgeRow(label: "Admin Panel", icon: "shield.lefthalf.filled",
                                 count: store.pendingWorkflowAlerts.count, color: .blue)
                }
                NavigationLink(destination: WorkflowLogView()) {
                    Label("Workflow Log", systemImage: "gearshape.2.fill")
                }
            }
        }
    }
}

// MARK: Account

private struct MoreAccountSection: View {
    @EnvironmentObject var store: AppStore
    @State private var showRoleSelector = false
    @State private var showSettings     = false

    var body: some View {
        Section("Account") {
            HStack {
                Label("Signed in as", systemImage: "person.circle"); Spacer()
                Text(store.currentUser?.fullName ?? "Unknown").foregroundColor(.secondary).font(.subheadline)
            }
            HStack {
                Label("Role", systemImage: "person.badge.key.fill"); Spacer()
                Text(store.currentUserRole.displayName).foregroundColor(.secondary).font(.subheadline)
            }
            Button { showRoleSelector = true } label: {
                Label("Switch Role", systemImage: "arrow.left.arrow.right").foregroundColor(.blue)
            }
            .sheet(isPresented: $showRoleSelector) { RoleSelectorView() }
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape.fill").foregroundColor(.blue)
            }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store) }
            Button(role: .destructive) {
                Task {
                    // Sign out via Supabase first so the auth-state listener
                    // in BV_APPApp doesn't fire `clearAllData()` mid-flight
                    // and race with the manual reset below.
                    try? await AuthService.signOut()
                    // Hard reset — wipes memory + tenant scope + UserDefaults
                    // + SyncEngine state. The previous partial reset let the
                    // prior user's currentCompanyID leak into the next sign-in.
                    store.fullSignOutReset()
                }
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }
}

// MARK: App Status

private struct AppStatusSection: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Section("App Status") {
            conflictsRow
            HStack {
                Label("Active Projects", systemImage: "folder"); Spacer()
                Text("\(store.projects.filter { $0.status == .active }.count) active")
                    .foregroundColor(.secondary).font(.subheadline)
            }
            HStack {
                Label("Clients", systemImage: "building.2"); Spacer()
                Text("\(store.clients.count) total").foregroundColor(.secondary).font(.subheadline)
            }
            pendingRow
            certRow
            syncRows
        }
    }

    @ViewBuilder
    private var conflictsRow: some View {
        let conflicts = store.criticalScheduleConflicts.count
        if conflicts > 0 {
            NavigationLink(destination: ScheduleConflictListView(date: nil).environmentObject(store)) {
                MoreBadgeRow(label: "Schedule Conflicts", icon: "exclamationmark.triangle.fill",
                             count: conflicts, color: .red, alwaysShowBadge: true)
            }
        }
    }

    private var pendingRow: some View {
        let count = store.pendingTimesheets().count
        return HStack {
            Label("Pending Approvals", systemImage: "clock.badge.exclamationmark"); Spacer()
            Text("\(count)").foregroundColor(count > 0 ? .orange : .secondary).font(.subheadline)
        }
    }

    private var certRow: some View {
        let count = store.complianceAlerts.count
        return HStack {
            Label("Cert Alerts", systemImage: "checkmark.seal.fill"); Spacer()
            Text("\(count)").foregroundColor(count > 0 ? .orange : .secondary).font(.subheadline)
        }
    }

    private var syncRows: some View {
        Group {
            HStack {
                Label("Sync", systemImage: "icloud"); Spacer()
                Text(SyncEngine.shared.isSyncing ? "Syncing…" : "Up to date")
                    .foregroundColor(.secondary).font(.subheadline)
            }
            if let last = SyncEngine.shared.lastSyncAt {
                HStack {
                    Label("Last sync", systemImage: "clock"); Spacer()
                    Text(last.shortDate).foregroundColor(.secondary).font(.subheadline)
                }
            }
        }
    }
}

// MARK: - More Badge Row helper

private struct MoreBadgeRow: View {
    let label:           String
    let icon:            String
    let count:           Int
    let color:           Color
    var alwaysShowBadge: Bool = false

    var body: some View {
        HStack {
            Label(label, systemImage: icon)
            Spacer()
            if count > 0 || alwaysShowBadge {
                Text("\(count)")
                    .font(.caption).bold()
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(color.opacity(0.15))
                    .foregroundColor(color)
                    .cornerRadius(10)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count > 0
            ? "\(label), \(count) item\(count == 1 ? "" : "s")"
            : label)
    }
}

// MARK: - Role Selector

struct RoleSelectorView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Select Your Role") {
                    ForEach(UserRole.allCases, id: \.self) { role in
                        Button {
                            store.currentUserRole = role
                            dismiss()
                        } label: {
                            HStack(spacing: 16) {
                                ZStack {
                                    Circle()
                                        .fill(roleColor(role).opacity(0.15))
                                        .frame(width: 44, height: 44)
                                    Image(systemName: role.icon)
                                        .foregroundColor(roleColor(role))
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(role.displayName)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text(role.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if store.currentUserRole == role {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Select Role")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.bold()
                }
            }
        }
        .presentationDetents([.large])
    }

    private func roleColor(_ role: UserRole) -> Color {
        switch role {
        case .fieldWorker:    return .green
        case .foreman:        return .orange
        case .safetyAdvisor:  return .mint
        case .projectManager: return .blue
        case .estimator:      return .purple
        case .officeAdmin:    return .teal
        case .manager:        return .indigo
        case .executive:      return .red
        case .owner:          return .pink   // distinguishable from executive red
        case .client:         return .gray
        }
    }
}
