// AdminPanelView.swift
// Aski IQ – Admin Control Panel

import SwiftUI

// MARK: - Admin Panel Root

struct AdminPanelView: View {
    @EnvironmentObject var store: AppStore
    @State private var selectedTab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $selectedTab) {
                    Text("Overview").tag(0)
                    Text("Audit").tag(1)
                    Text("Auto").tag(2)
                    Text("Users").tag(3)
                    Text("Roles").tag(4)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                Divider()

                switch selectedTab {
                case 1:  AuditLogView()
                case 2:  WorkflowRulesView()
                case 3:  AdminUserListView()
                case 4:  PermissionMatrixView()
                default: SystemOverviewView()
                }
            }
            .navigationTitle("Admin")
        }
    }
}

// MARK: - System Overview

struct SystemOverviewView: View {
    @EnvironmentObject var store: AppStore
    @State private var showPurgeIncidentsAlert = false
    @State private var isPurgingIncidents      = false

    // Storage estimate (UserDefaults keys we know about)
    private var estimatedRecords: Int {
        store.projects.count + store.employees.count + store.timesheetEntries.count +
        store.formSubmissions.count + store.invoices.count + store.materialRequests.count +
        store.purchaseOrders.count + store.equipment.count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                healthBanner
                dataCountsSection
                openItemsSection
                syncSection
                workflowAlertsSection
                dangerZoneSection
            }
            .padding(.vertical)
        }
    }

    // MARK: Sections

    private var dataCountsSection: some View {
        GroupBox("Data Records") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                NavigationLink { ProjectListView() } label: {
                    StatTile(label: "Projects", value: "\(store.projects.count)", icon: "folder.fill", color: .blue)
                }.buttonStyle(.plain)
                NavigationLink { EmployeeListView() } label: {
                    StatTile(label: "Employees", value: "\(store.employees.count)", icon: "person.fill", color: .indigo)
                }.buttonStyle(.plain)
                NavigationLink { TimesheetApprovalQueueView() } label: {
                    StatTile(label: "Timesheets", value: "\(store.timesheetEntries.count)", icon: "clock.fill", color: .orange)
                }.buttonStyle(.plain)
                NavigationLink { FormSubmissionListView() } label: {
                    StatTile(label: "Forms", value: "\(store.formSubmissions.count)", icon: "doc.text.fill", color: .teal)
                }.buttonStyle(.plain)
                NavigationLink { InvoiceListView() } label: {
                    StatTile(label: "Invoices", value: "\(store.invoices.count)", icon: "doc.plaintext.fill", color: .green)
                }.buttonStyle(.plain)
                NavigationLink { IncidentListView() } label: {
                    StatTile(label: "Incidents", value: "\(store.incidents.count)", icon: "exclamationmark.shield", color: .red)
                }.buttonStyle(.plain)
                NavigationLink { EquipmentListView() } label: {
                    StatTile(label: "Equipment", value: "\(store.equipment.count)", icon: "truck.box.fill", color: .cyan)
                }.buttonStyle(.plain)
                NavigationLink { ProcurementHubView() } label: {
                    StatTile(label: "MR / POs",
                             value: "\(store.materialRequests.count) / \(store.purchaseOrders.count)",
                             icon: "shippingbox.fill", color: .purple)
                }.buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal)
    }

    private var openItemsSection: some View {
        GroupBox("Open Items") {
            VStack(spacing: 0) {
                openItemsTop
                openItemsBottom
            }
        }
        .padding(.horizontal)
    }

    // Split into two Groups to stay under the 10-element TupleView limit
    private var openItemsTop: some View {
        Group {
            // 2026-05: unified queue lives at the top of Open Items so
            // a manager can see EVERYTHING awaiting their approval
            // (estimates, schedule plans, timesheets) at a glance —
            // not just timesheets.
            adminNavRow("Approval Queue", value: store.approvalQueueCount, threshold: 1, color: .orange) { ApprovalQueueView() }
            Divider()
            adminNavRow("Pending Timesheets", value: store.pendingTimesheets().count, threshold: 1, color: .orange) { TimesheetApprovalQueueView() }
            Divider()
            adminNavRow("Overdue Invoices", value: store.overdueInvoices.count, threshold: 1, color: .red) { InvoiceListView() }
            Divider()
            adminNavRow("Open Incidents", value: store.openIncidents.count, threshold: 1, color: .red) { IncidentListView() }
            Divider()
            adminNavRow("Cert Alerts", value: store.complianceAlerts.count, threshold: 1, color: .orange) { CertificateListView() }
        }
    }

    private var openItemsBottom: some View {
        Group {
            adminNavRow("MR Pending Approval", value: store.pendingMaterialApprovals.count, threshold: 1, color: .orange) { ProcurementHubView() }
            Divider()
            adminNavRow("Schedule Conflicts", value: store.criticalScheduleConflicts.count, threshold: 1, color: .red) { ScheduleConflictListView(date: nil) }
            Divider()
            adminNavRow("Equipment Service Due", value: store.equipmentNeedingService.count, threshold: 1, color: .orange) { EquipmentListView() }
        }
    }

    private var dangerZoneSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Danger Zone", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.red)

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clear All Incidents from Server")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        Text("Permanently deletes all incident records from Supabase. Use to remove accumulated test/sample data.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if isPurgingIncidents {
                        ProgressView()
                    } else {
                        Button("Purge") {
                            showPurgeIncidentsAlert = true
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red)
                        .cornerRadius(8)
                    }
                }
            }
        }
        .padding(.horizontal)
        .alert("Delete All Incidents?", isPresented: $showPurgeIncidentsAlert) {
            Button("Delete All", role: .destructive) {
                isPurgingIncidents = true
                Task {
                    await SyncEngine.shared.purgeAllIncidentsFromServer()
                    await MainActor.run { isPurgingIncidents = false }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all \(store.incidents.count) incident records from the server and cannot be undone.")
        }
    }

    private var syncSection: some View {
        GroupBox("Sync & Storage") {
            VStack(spacing: 10) {
                SyncStatusRow(isSyncing: SyncEngine.shared.isSyncing, lastSync: SyncEngine.shared.lastSyncAt)
                HStack {
                    Label("Audit Log Entries", systemImage: "doc.text.magnifyingglass"); Spacer()
                    Text("\(store.auditSnapshots.count)").foregroundColor(.secondary).font(.subheadline)
                }
                HStack {
                    Label("Workflow Log Entries", systemImage: "gearshape.2"); Spacer()
                    Text("\(store.workflowLog.count)").foregroundColor(.secondary).font(.subheadline)
                }
                HStack {
                    Label("Total Records (est.)", systemImage: "cylinder.split.1x2"); Spacer()
                    Text("\(estimatedRecords)").foregroundColor(.secondary).font(.subheadline)
                }
                Divider()
                DiagnosticsNavRow()
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var workflowAlertsSection: some View {
        if !store.pendingWorkflowAlerts.isEmpty {
            GroupBox("Pending Workflow Alerts (\(store.pendingWorkflowAlerts.count))") {
                VStack(spacing: 8) {
                    ForEach(store.pendingWorkflowAlerts) { alert in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "bell.badge.fill").foregroundColor(.orange).font(.caption)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alert.title).font(.subheadline).bold()
                                Text(alert.body).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                    Button("Dismiss All") { store.pendingWorkflowAlerts.removeAll() }
                        .font(.caption).foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: Helpers

    private var healthBanner: some View {
        let issues = store.overdueInvoices.count + store.openIncidents.count +
                     store.criticalScheduleConflicts.count + store.complianceAlerts.count
        return HStack(spacing: 12) {
            Image(systemName: issues == 0 ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundColor(issues == 0 ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(issues == 0 ? "All Systems Healthy" : "\(issues) Item\(issues == 1 ? "" : "s") Need Attention")
                    .font(.headline)
                Text(issues == 0 ? "No open issues detected." : "Review open items below.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(issues == 0 ? Color.green.opacity(0.08) : Color.orange.opacity(0.08))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    private func adminNavRow<Dest: View>(_ label: String, value: Int, threshold: Int, color: Color, @ViewBuilder destination: () -> Dest) -> some View {
        NavigationLink(destination: destination) {
            HStack {
                Text(label).font(.subheadline).foregroundColor(.primary)
                Spacer()
                Text("\(value)")
                    .font(.subheadline).bold()
                    .foregroundColor(value >= threshold ? color : .secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value == 0
            ? "\(label), none"
            : "\(label), \(value) item\(value == 1 ? "" : "s")")
        .accessibilityHint("Tap to view")
    }
}

struct StatTile: View {
    let label: String
    let value: String
    let icon:  String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundColor(color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.subheadline).bold()
                Text(label).font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
        // VoiceOver: read as a single element — "Projects: 12"
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

private struct SyncStatusRow: View {
    let isSyncing: Bool
    let lastSync: Date?
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Sync Status", systemImage: "icloud"); Spacer()
                Text(isSyncing ? "Syncing…" : "Idle").foregroundColor(.secondary).font(.subheadline)
            }
            if let last = lastSync {
                HStack {
                    Label("Last Sync", systemImage: "clock"); Spacer()
                    Text(last.shortDate).foregroundColor(.secondary).font(.subheadline)
                }
            }
        }
    }
}

// MARK: - Audit Log View

struct AuditLogView: View {
    @EnvironmentObject var store: AppStore
    @State private var searchText   = ""
    @State private var filterType   = ""
    @StateObject private var pagination = PaginationState(pageSize: 40)
    @State private var isLoading    = false

    private var entityTypes: [String] {
        Array(Set(store.auditSnapshots.map { $0.entityType })).sorted()
    }

    private var filtered: [AuditSnapshot] {
        store.auditSnapshots
            .filter { snap in
                let matchType   = filterType.isEmpty || snap.entityType == filterType
                let matchSearch = searchText.isEmpty  ||
                    snap.entityType.localizedCaseInsensitiveContains(searchText) ||
                    snap.eventType.localizedCaseInsensitiveContains(searchText)  ||
                    snap.createdBy.localizedCaseInsensitiveContains(searchText)
                return matchType && matchSearch
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var displayed: [AuditSnapshot] { Array(filtered.prefix(pagination.displayLimit)) }

    var body: some View {
        auditBody
            .searchable(text: $searchText, prompt: "Entity type, event, user…")
            .onChange(of: searchText) { pagination.reset() }
            .refreshable { await reload() }
            .task { if store.auditSnapshots.isEmpty { await reload() } }
            .overlay(alignment: .top) {
                if isLoading && store.auditSnapshots.isEmpty {
                    ProgressView("Loading audit history…")
                        .padding(.top, 80)
                }
            }
    }

    private func reload() async {
        isLoading = true
        await SyncEngine.shared.pullAuditSnapshots()
        isLoading = false
    }

    private var auditBody: some View {
        VStack(spacing: 0) {
            // Entity type filter
            if !entityTypes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(label: "All Types", isSelected: filterType.isEmpty) {
                            filterType = ""; pagination.reset()
                        }
                        ForEach(entityTypes, id: \.self) { type in
                            FilterChip(label: type, isSelected: filterType == type) {
                                filterType = filterType == type ? "" : type
                                pagination.reset()
                            }
                        }
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                }
                Divider()
            }

            if filtered.isEmpty {
                Spacer()
                EmptyCard(message: "No audit entries found.")
                Spacer()
            } else {
                List {
                    ForEach(displayed, id: \.id) { snap in
                        NavigationLink {
                            AuditSnapshotDetailView(snapshot: snap)
                        } label: {
                            AuditSnapshotRow(snapshot: snap)
                        }
                    }
                    LoadMoreFooter(showing: displayed.count, total: filtered.count) { pagination.loadMore() }
                }
                .listStyle(.plain)
            }
        }
    }
}

struct AuditSnapshotRow: View {
    let snapshot: AuditSnapshot

    private var eventColor: Color {
        switch snapshot.eventType {
        case let e where e.contains("approved"): return .green
        case let e where e.contains("rejected"): return .red
        case let e where e.contains("deleted"):  return .red
        case let e where e.contains("payment"):  return .green
        case let e where e.contains("submit"):   return .orange
        default: return .blue
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(eventColor.opacity(0.15))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: eventIcon)
                        .font(.system(size: 13))
                        .foregroundColor(eventColor)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(snapshot.eventType.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.subheadline).bold()
                    Spacer()
                    Text(snapshot.createdAt.shortDate)
                        .font(.caption2).foregroundColor(.secondary)
                }
                Text(snapshot.entityType)
                    .font(.caption).foregroundColor(.secondary)
                    + Text(" · \(snapshot.entityID.uuidString.prefix(8))…")
                    .font(.caption).foregroundColor(.secondary)
                Label(snapshot.createdBy, systemImage: "person")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var eventIcon: String {
        switch snapshot.eventType {
        case let e where e.contains("approved"): return "checkmark"
        case let e where e.contains("rejected"): return "xmark"
        case let e where e.contains("deleted"):  return "trash"
        case let e where e.contains("payment"):  return "creditcard"
        case let e where e.contains("submit"):   return "paperplane"
        default: return "pencil"
        }
    }
}

// MARK: - Audit Snapshot Detail

/// Opens when an admin taps a row in the audit log. Renders the entity JSON
/// snapshot pretty-printed so compliance can see exactly what state the
/// record was in at the moment of the event.
struct AuditSnapshotDetailView: View {
    let snapshot: AuditSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(snapshot.eventType.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.title2).bold()
                        Spacer()
                    }
                    Text("\(snapshot.entityType) · \(snapshot.entityID.uuidString)")
                        .font(.caption).foregroundColor(.secondary)
                        .textSelection(.enabled)
                    Text("\(snapshot.createdAt.formatted(.dateTime)) by \(snapshot.createdBy.isEmpty ? "system" : snapshot.createdBy)")
                        .font(.caption).foregroundColor(.secondary)
                }

                Divider()

                Text("Snapshot at time of event").font(.caption).foregroundColor(.secondary)
                Text(prettyPrintedSnapshot)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                    .textSelection(.enabled)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .navigationTitle("Audit entry")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var prettyPrintedSnapshot: String {
        let raw = String(data: snapshot.snapshotData, encoding: .utf8) ?? ""
        guard let data = raw.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: obj,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let s = String(data: pretty, encoding: .utf8)
        else { return raw }
        return s
    }
}

// MARK: - Admin User List

struct AdminUserListView: View {
    @EnvironmentObject var store: AppStore
    @State private var searchText = ""

    private var filtered: [Employee] {
        store.employees
            .filter { emp in
                searchText.isEmpty ||
                emp.fullName.localizedCaseInsensitiveContains(searchText) ||
                emp.role.displayName.localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.lastName < $1.lastName }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Label("Total Employees", systemImage: "person.3.fill")
                    Spacer()
                    Text("\(store.employees.count)").foregroundColor(.secondary)
                }
                HStack {
                    Label("Active", systemImage: "checkmark.circle")
                    Spacer()
                    Text("\(store.employees.filter { $0.isActive }.count)").foregroundColor(.green)
                }
            } header: {
                Text("Workforce Summary")
            }

            Section("Roles") {
                ForEach(UserRole.allCases, id: \.self) { role in
                    let count = store.employees.filter { $0.role == role }.count
                    if count > 0 {
                        HStack {
                            Label(role.displayName, systemImage: role.icon)
                            Spacer()
                            Text("\(count)")
                                .font(.subheadline).bold()
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section("All Employees") {
                ForEach(filtered) { emp in
                    NavigationLink {
                        EmployeeDetailView(employee: emp)
                    } label: {
                        AdminUserRow(employee: emp)
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Name or role…")
    }
}

struct AdminUserRow: View {
    let employee: Employee
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack {
            ZStack {
                Circle()
                    .fill(roleColor(employee.role).opacity(0.15))
                    .frame(width: 40, height: 40)
                Text(employee.initials)
                    .font(.subheadline).bold()
                    .foregroundColor(roleColor(employee.role))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(employee.fullName).font(.subheadline).bold()
                    if !employee.isActive {
                        Text("Inactive").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.gray.opacity(0.15))
                            .foregroundColor(.gray)
                            .cornerRadius(4)
                    }
                }
                Text(employee.role.displayName)
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if store.currentUser?.id == employee.id {
                Image(systemName: "person.fill.checkmark")
                    .foregroundColor(.blue).font(.caption)
            }
        }
        .padding(.vertical, 2)
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
        case .owner:          return .pink
        case .client:         return .gray
        }
    }
}

// MARK: - Workflow Rules View

struct WorkflowRulesView: View {
    @EnvironmentObject var store: AppStore
    @State private var showCreate   = false
    @State private var showRunAlert = false
    @State private var lastRunMsg   = ""

    private var rulesByCategory: [(WorkflowCategory, [WorkflowRule])] {
        let grouped = Dictionary(grouping: store.workflowRules) { $0.trigger.category }
        return WorkflowCategory.allCases.compactMap { cat in
            guard let rules = grouped[cat], !rules.isEmpty else { return nil }
            return (cat, rules)
        }
    }

    var body: some View {
        List {
            // Run Now button
            Section {
                Button {
                    store.runWorkflowEngine()
                    lastRunMsg = "Workflow engine executed — \(store.workflowRules.filter { $0.isEnabled }.count) rule\(store.workflowRules.filter { $0.isEnabled }.count == 1 ? "" : "s") evaluated."
                    showRunAlert = true
                } label: {
                    Label("Run Engine Now", systemImage: "play.fill")
                        .foregroundColor(.blue)
                }
            } footer: {
                Text("The engine also runs automatically on every sync. Triggered rules fire push notifications or in-app alerts.")
            }

            // Rules grouped by category
            ForEach(rulesByCategory, id: \.0) { cat, rules in
                Section(cat.displayName) {
                    ForEach(rules) { rule in
                        WorkflowRuleRow(rule: rule)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { rules[$0].id }
                        ids.forEach { store.deleteWorkflowRule(id: $0) }
                    }
                }
            }

            Section {
                Button {
                    showCreate = true
                } label: {
                    Label("Add Custom Rule", systemImage: "plus.circle")
                }
            }
        }
        .listStyle(.plain)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
        }
        .sheet(isPresented: $showCreate) {
            WorkflowRuleEditView(rule: nil)
        }
        .alert("Workflow Engine", isPresented: $showRunAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lastRunMsg)
        }
    }
}

struct WorkflowRuleRow: View {
    @EnvironmentObject var store: AppStore
    let rule: WorkflowRule
    @State private var showEdit = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(rule.isEnabled ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
                    .frame(width: 36, height: 36)
                Image(systemName: rule.trigger.icon)
                    .font(.system(size: 14))
                    .foregroundColor(rule.isEnabled ? .blue : .gray)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(rule.name).font(.subheadline).bold()
                HStack(spacing: 6) {
                    Text(rule.trigger.displayName)
                        .font(.caption).foregroundColor(.secondary)
                    Text("→")
                        .font(.caption2).foregroundColor(.secondary)
                    Text(rule.action.displayName)
                        .font(.caption).foregroundColor(.secondary)
                }
                if let fired = rule.lastFiredAt {
                    Text("Last fired \(fired.shortDate) · \(rule.fireCount) time\(rule.fireCount == 1 ? "" : "s")")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { newVal in
                    var updated = rule
                    updated.isEnabled = newVal
                    store.updateWorkflowRule(updated)
                }
            ))
            .labelsHidden()
        }
        .contentShape(Rectangle())
        .onTapGesture { showEdit = true }
        .sheet(isPresented: $showEdit) {
            WorkflowRuleEditView(rule: rule)
        }
    }
}

struct WorkflowRuleEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let rule: WorkflowRule?

    @State private var name:          String
    @State private var trigger:       WorkflowTrigger
    @State private var action:        WorkflowAction
    @State private var isEnabled:     Bool
    @State private var thresholdDays: Int
    @State private var notes:         String

    init(rule: WorkflowRule?) {
        self.rule = rule
        _name          = State(initialValue: rule?.name          ?? "")
        _trigger       = State(initialValue: rule?.trigger       ?? .invoiceOverdue)
        _action        = State(initialValue: rule?.action        ?? .pushNotification)
        _isEnabled     = State(initialValue: rule?.isEnabled     ?? true)
        _thresholdDays = State(initialValue: rule?.thresholdDays ?? 7)
        _notes         = State(initialValue: rule?.notes         ?? "")
    }

    private var showThreshold: Bool {
        [.invoiceUnpaidAfterDays, .certExpiringSoon, .timesheetPendingTooLong].contains(trigger)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Rule") {
                    HStack {
                        Text("Name")
                        TextField("Rule name", text: $name).multilineTextAlignment(.trailing)
                    }
                    Toggle("Enabled", isOn: $isEnabled)
                }
                Section("Trigger") {
                    Picker("When…", selection: $trigger) {
                        ForEach(WorkflowTrigger.allCases, id: \.self) { t in
                            Label(t.displayName, systemImage: t.icon).tag(t)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    if showThreshold {
                        Stepper("Threshold: \(thresholdDays) day\(thresholdDays == 1 ? "" : "s")",
                                value: $thresholdDays, in: 1...90)
                    }
                }
                Section("Action") {
                    Picker("Then…", selection: $action) {
                        ForEach(WorkflowAction.allCases, id: \.self) { a in
                            Text(a.displayName).tag(a)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                Section("Notes") {
                    TextField("Optional description", text: $notes, axis: .vertical).lineLimit(3)
                }
                if let rule = rule {
                    Section("Stats") {
                        HStack {
                            Text("Times Fired"); Spacer()
                            Text("\(rule.fireCount)").foregroundColor(.secondary)
                        }
                        if let last = rule.lastFiredAt {
                            HStack {
                                Text("Last Fired"); Spacer()
                                Text(last.shortDate).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(rule == nil ? "New Rule" : "Edit Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }.bold()
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        var r = rule ?? WorkflowRule(name: name, trigger: trigger)
        r.name          = name.trimmingCharacters(in: .whitespaces)
        r.trigger       = trigger
        r.action        = action
        r.isEnabled     = isEnabled
        r.thresholdDays = thresholdDays
        r.notes         = notes
        r.updatedAt     = Date()
        rule == nil ? store.addWorkflowRule(r) : store.updateWorkflowRule(r)
        dismiss()
    }
}

// MARK: - Workflow Log View (standalone, accessible from More)

struct WorkflowLogView: View {
    @EnvironmentObject var store: AppStore
    @State private var searchText = ""

    private var filtered: [WorkflowLogEntry] {
        store.workflowLog
            .filter { entry in
                searchText.isEmpty ||
                entry.ruleName.localizedCaseInsensitiveContains(searchText) ||
                entry.title.localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.firedAt > $1.firedAt }
    }

    var body: some View {
        Group {
            if filtered.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "gearshape.2").font(.system(size: 48)).foregroundColor(.secondary.opacity(0.3))
                    Text("No Workflow Log Entries").font(.headline)
                    Text("Events logged by automation rules will appear here.")
                        .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Spacer()
                }
                .padding()
            } else {
                List {
                    ForEach(filtered) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.title).font(.subheadline).bold()
                                Spacer()
                                Text(entry.firedAt.shortDate).font(.caption2).foregroundColor(.secondary)
                            }
                            Text(entry.body).font(.caption).foregroundColor(.secondary)
                            Text(entry.ruleName)
                                .font(.caption2).foregroundColor(.blue)
                        }
                        .padding(.vertical, 3)
                    }
                }
                .listStyle(.plain)
            }
        }
        .searchable(text: $searchText, prompt: "Rule name or event…")
        .navigationTitle("Workflow Log")
        .navigationBarTitleDisplayMode(.inline)
    }
}
