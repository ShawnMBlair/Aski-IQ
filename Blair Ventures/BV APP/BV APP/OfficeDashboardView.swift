// OfficeDashboardView.swift
// FieldOS – Office, Management & Foreman Dashboards
// Salus Pro-style KPI cards: Forms, Active Workers, Active Sites, Active Assets

import SwiftUI

// MARK: - Office Dashboard

struct OfficeDashboardView: View {
    @EnvironmentObject var store: AppStore
    @State private var latestTab: LatestTab = .forms

    enum LatestTab: String, CaseIterable { case forms = "Forms", timesheets = "Timesheets" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // MARK: Weather
                    WeatherCard()

                    // MARK: KPI Grid — each card navigates to its detail view
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        NavigationLink { FormSubmissionListView() } label: { FormsKPICard() }.buttonStyle(.plain)
                        NavigationLink { EmployeeListView() } label: { ActiveWorkersKPICard() }.buttonStyle(.plain)
                        NavigationLink { ProjectListView() } label: { ActiveSitesKPICard() }.buttonStyle(.plain)
                        NavigationLink { IncidentListView() } label: { OpenIncidentsKPICard() }.buttonStyle(.plain)
                        NavigationLink { CertificateListView() } label: { CertComplianceKPICard() }.buttonStyle(.plain)
                    }
                    .padding(.horizontal)

                    // MARK: Approval Queue Banner (2026-05 unified)
                    //
                    // Pre-fix this banner only counted timesheets, so
                    // a manager with estimates pending their review or
                    // AI schedule plans awaiting approval had no top-
                    // level signal that work was waiting. The unified
                    // queue rolls up estimates, schedule plans, and
                    // timesheets into one count + landing surface.
                    let approvalCount = store.approvalQueueCount
                    if approvalCount > 0 {
                        NavigationLink { ApprovalQueueView() } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle().fill(Color.orange.opacity(0.15)).frame(width: 44, height: 44)
                                    Image(systemName: "clock.badge.exclamationmark").foregroundColor(.orange)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(approvalCount) item\(approvalCount == 1 ? "" : "s") awaiting your approval")
                                        .font(.subheadline).bold().foregroundColor(.primary)
                                    Text("Estimates · Schedule plans · Timesheets")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(.secondary).font(.caption)
                            }
                            .padding()
                            .background(Color.orange.opacity(0.07))
                            .cornerRadius(14)
                        }
                        .padding(.horizontal)
                    }

                    // MARK: Open Incidents Section
                    DashboardIncidentsSection()

                    // MARK: Compliance Section
                    DashboardComplianceSection()

                    // MARK: Latest Section
                    VStack(spacing: 0) {
                        HStack {
                            Picker("Latest", selection: $latestTab) {
                                ForEach(LatestTab.allCases, id: \.self) { t in Text(t.rawValue).tag(t) }
                            }
                            .pickerStyle(.segmented)
                            Spacer()
                            NavigationLink("View All") {
                                latestTab == .forms ? AnyView(FormSubmissionListView()) : AnyView(TimesheetApprovalQueueView())
                            }
                            .font(.subheadline)
                            .foregroundColor(.blue)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 10)

                        Divider()

                        switch latestTab {
                        case .forms:
                            LatestFormsList()
                        case .timesheets:
                            LatestTimesheetsList()
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)
                    .padding(.horizontal)

                    Spacer(minLength: 80)
                }
                .padding(.top, 16)
            }
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

// MARK: - Management Dashboard

struct ManagementDashboardView: View {
    @EnvironmentObject var store: AppStore
    @State private var latestTab: OfficeDashboardView.LatestTab = .forms

    /// Active project contract value, excluding soft-deleted rows. Without
    /// the deletion guard, archived/voided projects were inflating the KPI.
    private var totalContractValue: Decimal {
        store.projects
            .filter { $0.status == .active && !$0.isDeleted }
            .compactMap { $0.contractValue }
            .reduce(0, +)
    }
    /// Confirmed hours this week. Excludes draft entries (not yet submitted
    /// by the employee), rejected entries (already disallowed by a manager),
    /// and soft-deleted rows. Submitted/approved/locked entries all count
    /// because all three represent labor that actually happened.
    private var hoursThisWeek: Decimal {
        let weekStart = Calendar.current.date(from: Calendar.current.dateComponents(
            [.yearForWeekOfYear, .weekOfYear], from: Date()))!
        return store.timesheetEntries
            .filter {
                $0.date >= weekStart &&
                !$0.isDeleted &&
                $0.approvalStatus != .draft &&
                $0.approvalStatus != .rejected
            }
            .reduce(0) { $0 + $1.totalHours }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // MARK: Weather
                    WeatherCard()

                    // MARK: KPI Grid (Salus-style)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        NavigationLink { FormSubmissionListView() } label: { FormsKPICard() }.buttonStyle(.plain)
                        NavigationLink { EmployeeListView() } label: { ActiveWorkersKPICard() }.buttonStyle(.plain)
                        NavigationLink { ProjectListView() } label: { ActiveSitesKPICard() }.buttonStyle(.plain)
                        NavigationLink { TimesheetApprovalQueueView() } label: {
                            SalusKPICard(
                                title: "Hours This Week",
                                total: "\(hoursThisWeek)",
                                icon: "clock.fill",
                                color: .purple,
                                rows: []
                            )
                        }.buttonStyle(.plain)
                        NavigationLink { IncidentListView() } label: { OpenIncidentsKPICard() }.buttonStyle(.plain)
                        NavigationLink { CertificateListView() } label: { CertComplianceKPICard() }.buttonStyle(.plain)
                    }
                    .padding(.horizontal)

                    // MARK: PMI Lifecycle (Phase 5)
                    PMILifecycleDashboardCard()

                    // MARK: Open Incidents Section
                    DashboardIncidentsSection()

                    // MARK: Approval Queue Banner (2026-05 unified)
                    let approvalCount = store.approvalQueueCount
                    if approvalCount > 0 {
                        NavigationLink { ApprovalQueueView() } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle().fill(Color.orange.opacity(0.15)).frame(width: 44, height: 44)
                                    Image(systemName: "clock.badge.exclamationmark").foregroundColor(.orange)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(approvalCount) item\(approvalCount == 1 ? "" : "s") awaiting your approval")
                                        .font(.subheadline).bold().foregroundColor(.primary)
                                    Text("Estimates · Schedule plans · Timesheets")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(.secondary).font(.caption)
                            }
                            .padding()
                            .background(Color.orange.opacity(0.07))
                            .cornerRadius(14)
                        }
                        .padding(.horizontal)
                    }

                    // MARK: Compliance Section
                    DashboardComplianceSection()

                    // MARK: Charts
                    MgmtBudgetUtilChart()
                    MgmtRevenuePipelineChart()
                    MgmtOpenItemsChart()

                    // MARK: Contract Value Banner
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Active Contract Value")
                                .font(.caption).foregroundColor(.secondary)
                            Text(totalContractValue.currencyString)
                                .font(.title2).bold()
                        }
                        Spacer()
                        Image(systemName: "dollarsign.circle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.green.opacity(0.3))
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)
                    .padding(.horizontal)

                    // MARK: Latest
                    VStack(spacing: 0) {
                        HStack {
                            Picker("Latest", selection: $latestTab) {
                                ForEach(OfficeDashboardView.LatestTab.allCases, id: \.self) { t in
                                    Text(t.rawValue).tag(t)
                                }
                            }
                            .pickerStyle(.segmented)
                            Spacer()
                            NavigationLink("View All") {
                                latestTab == .forms ? AnyView(FormSubmissionListView()) : AnyView(TimesheetApprovalQueueView())
                            }
                            .font(.subheadline).foregroundColor(.blue)
                        }
                        .padding(.horizontal).padding(.vertical, 10)
                        Divider()
                        switch latestTab {
                        case .forms:      LatestFormsList()
                        case .timesheets: LatestTimesheetsList()
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)
                    .padding(.horizontal)

                    // MARK: Active Projects
                    // Uses the shared `liveActiveProjects` helper so the
                    // section count and list agree, and so soft-deleted
                    // projects don't reappear here after deletion.
                    SectionHeader(title: "Active Projects",
                                  count: store.liveActiveProjects.count)
                    ForEach(store.liveActiveProjects) { project in
                        NavigationLink { ProjectDetailView(project: project) } label: {
                            ProjectSummaryRow(project: project).padding(.horizontal)
                        }
                    }

                    Spacer(minLength: 80)
                }
                .padding(.top, 16)
            }
            .navigationTitle("Overview")
        }
    }
}

// MARK: - Salus KPI Card (base component)

struct SalusKPICard: View {
    let title: String
    let total: String
    let icon: String
    let color: Color
    let rows: [(label: String, value: String)]   // e.g. [("Today", "3"), ("Week", "12"), ("Month", "40")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(color.opacity(0.15))
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .foregroundColor(color)
                        .font(.system(size: 16))
                }
                Spacer()
                Text(total)
                    .font(.title2).bold()
            }

            Text(title)
                .font(.subheadline).bold()
                .lineLimit(1)

            if !rows.isEmpty {
                Divider()
                ForEach(rows, id: \.label) { row in
                    HStack {
                        Text(row.label)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(row.value)
                            .font(.caption).bold()
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }
}

// MARK: - Specific KPI Cards

struct FormsKPICard: View {
    @EnvironmentObject var store: AppStore

    /// Submitted (non-draft, non-deleted) forms. Centralizes the filter so
    /// today / week / month / total all agree — previously the period
    /// counters were stricter than `total` because they required
    /// `submittedAt` to be non-nil even though some non-draft forms in
    /// older data were missing that timestamp.
    private var liveSubmissions: [FormSubmission] {
        store.formSubmissions.filter { !$0.isDraft && !$0.isDeleted }
    }

    /// The date a submission "lands" in the time-period buckets. Falls back
    /// to `createdAt` when `submittedAt` is missing so legacy / synced rows
    /// don't disappear from the counters.
    private func submissionDate(_ s: FormSubmission) -> Date {
        s.submittedAt ?? s.createdAt
    }

    private var today: Int {
        liveSubmissions.filter {
            Calendar.current.isDateInToday(submissionDate($0))
        }.count
    }
    private var week: Int {
        let weekStart = Calendar.current.date(from: Calendar.current.dateComponents(
            [.yearForWeekOfYear, .weekOfYear], from: Date()))!
        return liveSubmissions.filter { submissionDate($0) >= weekStart }.count
    }
    private var month: Int {
        let monthStart = Calendar.current.date(from: Calendar.current.dateComponents(
            [.year, .month], from: Date()))!
        return liveSubmissions.filter { submissionDate($0) >= monthStart }.count
    }
    private var total: Int { liveSubmissions.count }

    var body: some View {
        SalusKPICard(
            title: "Forms",
            total: "\(total)",
            icon: "doc.text.fill",
            color: .blue,
            rows: [
                ("Today", "\(today)"),
                ("Week",  "\(week)"),
                ("Month", "\(month)")
            ]
        )
    }
}

struct ActiveWorkersKPICard: View {
    @EnvironmentObject var store: AppStore

    private var activeToday: Int {
        // Workers with a timesheet entry today
        let ids = Set(store.timesheetEntries
            .filter { Calendar.current.isDateInToday($0.date) }
            .map { $0.employeeID })
        return ids.count
    }

    var body: some View {
        SalusKPICard(
            title: "Active Workers",
            total: "\(activeToday)",
            icon: "person.2.fill",
            color: .green,
            rows: [
                ("Total", "\(store.employees.filter { $0.isActive }.count)")
            ]
        )
    }
}

struct ActiveSitesKPICard: View {
    @EnvironmentObject var store: AppStore

    /// Live count of active projects via the shared `liveActiveProjects`
    /// helper — ensures soft-deleted rows don't inflate the KPI.
    private var activeSites: Int { store.liveActiveProjects.count }

    var body: some View {
        SalusKPICard(
            title: "Active Sites",
            total: "\(activeSites)",
            icon: "mappin.and.ellipse",
            color: .orange,
            rows: [
                ("Total", "\(store.projects.count)")
            ]
        )
    }
}

struct ActiveAssetsKPICard: View {
    var body: some View {
        SalusKPICard(
            title: "Active Assets",
            total: "0",
            icon: "truck.box.fill",
            color: .purple,
            rows: [
                ("Total", "0")
            ]
        )
    }
}

// MARK: - Latest Forms List

struct LatestFormsList: View {
    @EnvironmentObject var store: AppStore

    private var latest: [FormSubmission] {
        store.formSubmissions
            .filter { !$0.isDraft }
            .sorted { ($0.submittedAt ?? $0.createdAt) > ($1.submittedAt ?? $1.createdAt) }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            if latest.isEmpty {
                Text("No forms submitted yet.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ForEach(latest) { submission in
                    LatestFormsRow(submission: submission)
                    if submission.id != latest.last?.id { Divider().padding(.leading, 56) }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct LatestFormsRow: View {
    let submission: FormSubmission
    @EnvironmentObject var store: AppStore

    private var templateName: String {
        store.formTemplates.first { $0.id == submission.templateID }?.name ?? "Form"
    }
    private var projectName: String? {
        submission.projectID.flatMap { store.project(id: $0) }?.name
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(submission.isSigned ? Color.green.opacity(0.12) : Color.blue.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: submission.isSigned ? "checkmark.seal.fill" : "doc.text")
                    .foregroundColor(submission.isSigned ? .green : .blue)
                    .font(.system(size: 16))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(templateName).font(.subheadline).bold().lineLimit(1)
                HStack(spacing: 6) {
                    Text(submission.submittedBy).font(.caption).foregroundColor(.secondary)
                    if let proj = projectName {
                        Text("·").foregroundColor(.secondary).font(.caption)
                        Text(proj).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                if let date = submission.submittedAt {
                    Text(date.shortDate).font(.caption2).foregroundColor(.secondary)
                }
                if submission.isSigned {
                    Text("Signed").font(.caption2).bold()
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.green.opacity(0.12)).foregroundColor(.green)
                        .cornerRadius(4)
                } else {
                    Text("Submitted").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1)).foregroundColor(.blue)
                        .cornerRadius(4)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Latest Timesheets List

struct LatestTimesheetsList: View {
    @EnvironmentObject var store: AppStore

    private var latest: [TimesheetEntry] {
        store.timesheetEntries
            .sorted { $0.date > $1.date }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            if latest.isEmpty {
                Text("No timesheet entries yet.")
                    .font(.subheadline).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                ForEach(latest) { entry in
                    LatestTimesheetRow(entry: entry)
                    if entry.id != latest.last?.id { Divider().padding(.leading, 56) }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct LatestTimesheetRow: View {
    let entry: TimesheetEntry
    @EnvironmentObject var store: AppStore

    private var employeeName: String {
        store.employee(id: entry.employeeID)?.fullName ?? "Unknown"
    }
    private var projectName: String {
        store.project(id: entry.projectID)?.name ?? "Unknown"
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
                    .font(.system(size: 16))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(employeeName).font(.subheadline).bold()
                Text(projectName).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(entry.date.shortDate).font(.caption2).foregroundColor(.secondary)
                Text("\(entry.totalHours) hrs").font(.caption).bold()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statusIcon: String {
        switch entry.approvalStatus {
        case .approved: return "checkmark.circle.fill"
        case .rejected: return "xmark.circle.fill"
        default:        return "clock"
        }
    }
    private var statusColor: Color {
        switch entry.approvalStatus {
        case .approved: return .green
        case .rejected: return .red
        default:        return .orange
        }
    }
}

// MARK: - Office Schedule Row (kept for compatibility)

struct OfficeScheduleRow: View {
    let entry: ScheduleEntry
    @EnvironmentObject var store: AppStore

    private var projectName: String { store.project(id: entry.projectID)?.name ?? "Unknown" }
    private var crewName: String? { entry.crewID.flatMap { store.crew(id: $0) }?.name }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(projectName).font(.subheadline).bold()
                if let crew = crewName {
                    Text(crew).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(entry.date.shortDate).font(.caption).foregroundColor(.secondary)
                ScheduleStatusBadge(status: entry.status)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - KPI Card (kept for backward compat)

struct KPICard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        SalusKPICard(title: title, total: value, icon: icon, color: color, rows: [])
    }
}

// MARK: - Open Incidents KPI Card

struct OpenIncidentsKPICard: View {
    @EnvironmentObject var store: AppStore

    private var open: [Incident]     { store.openIncidents }
    private var critical: Int        { open.filter { $0.severity == .critical }.count }
    private var high: Int            { open.filter { $0.severity == .high     }.count }
    private var cardColor: Color     { critical > 0 ? .red : high > 0 ? .orange : .blue }

    var body: some View {
        SalusKPICard(
            title: "Open Incidents",
            total: "\(open.count)",
            icon:  "exclamationmark.shield.fill",
            color: cardColor,
            rows: [
                ("Critical", "\(critical)"),
                ("High",     "\(high)"),
                ("Other",    "\(open.count - critical - high)"),
            ]
        )
    }
}

// MARK: - Cert Compliance KPI Card

struct CertComplianceKPICard: View {
    @EnvironmentObject var store: AppStore

    private var expired:  Int { store.expiredCertificates.count }
    private var expiring: Int { store.expiringCertificates.count }
    private var cardColor: Color { expired > 0 ? .red : expiring > 0 ? .orange : .green }

    var body: some View {
        SalusKPICard(
            title: "Cert Compliance",
            total: expired + expiring > 0 ? "\(expired + expiring)" : "✓",
            icon:  "checkmark.seal.fill",
            color: cardColor,
            rows: [
                ("Expired",       "\(expired)"),
                ("Expiring Soon", "\(expiring)"),
            ]
        )
    }
}

// MARK: - Dashboard Open Incidents Section

struct DashboardIncidentsSection: View {
    @EnvironmentObject var store: AppStore

    /// Top 4: critical first, then high, then by date descending
    private var topIncidents: [Incident] {
        store.openIncidents
            .sorted {
                let s0 = severityWeight($0.severity)
                let s1 = severityWeight($1.severity)
                if s0 != s1 { return s0 > s1 }
                return $0.incidentDate > $1.incidentDate
            }
            .prefix(4)
            .map { $0 }
    }

    var body: some View {
        if !topIncidents.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Label("Open Incidents", systemImage: "exclamationmark.shield.fill")
                        .font(.headline)
                        .foregroundColor(topIncidents.contains { $0.severity == .critical } ? .red : .primary)
                    Spacer()
                    NavigationLink {
                        IncidentListView()
                    } label: {
                        Text("View All (\(store.openIncidents.count))")
                            .font(.subheadline).foregroundColor(.blue)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 14)
                .padding(.bottom, 8)

                Divider()

                ForEach(topIncidents) { incident in
                    NavigationLink {
                        IncidentDetailView(incident: incident)
                    } label: {
                        DashboardIncidentRow(incident: incident)
                    }
                    .buttonStyle(.plain)
                    if incident.id != topIncidents.last?.id {
                        Divider().padding(.leading, 64)
                    }
                }

                if store.openIncidents.count > 4 {
                    Divider()
                    NavigationLink {
                        IncidentListView()
                    } label: {
                        Text("See all \(store.openIncidents.count) open incidents")
                            .font(.subheadline).foregroundColor(.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)
            .padding(.horizontal)
        }
    }

    private func severityWeight(_ s: IncidentSeverity) -> Int {
        switch s {
        case .critical: return 4
        case .high:     return 3
        case .medium:   return 2
        case .low:      return 1
        }
    }
}

struct DashboardIncidentRow: View {
    let incident: Incident
    @EnvironmentObject var store: AppStore

    private var projectName: String? {
        incident.projectID.flatMap { store.project(id: $0) }?.name
    }
    private var daysAgo: String {
        let days = Calendar.current.dateComponents([.day], from: incident.incidentDate, to: Date()).day ?? 0
        if days == 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        return "\(days)d ago"
    }

    var body: some View {
        HStack(spacing: 12) {
            // Severity colour stripe
            ZStack {
                Circle()
                    .fill(incident.incidentType.color.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: incident.incidentType.icon)
                    .foregroundColor(incident.incidentType.color)
                    .font(.system(size: 15))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(incident.title)
                    .font(.subheadline).bold().lineLimit(1).foregroundColor(.primary)
                HStack(spacing: 6) {
                    if let proj = projectName {
                        Text(proj).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        Text("·").font(.caption).foregroundColor(.secondary)
                    }
                    Text(daysAgo).font(.caption).foregroundColor(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                SeverityBadge(severity: incident.severity)
                IncidentStatusBadge(status: incident.status)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Dashboard Compliance Section

struct DashboardComplianceSection: View {
    @EnvironmentObject var store: AppStore

    /// Expired first (most overdue), then expiring soonest
    private var topAlerts: [Certificate] {
        Array(store.complianceAlerts.prefix(4))
    }

    var body: some View {
        if !topAlerts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Label("Certification Alerts", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundColor(store.expiredCertificates.isEmpty ? .orange : .red)
                    Spacer()
                    NavigationLink {
                        CertificateListView()
                    } label: {
                        Text("View All (\(store.complianceAlerts.count))")
                            .font(.subheadline).foregroundColor(.blue)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 14)
                .padding(.bottom, 8)

                Divider()

                ForEach(topAlerts) { cert in
                    NavigationLink {
                        CertificateDetailView(certificate: cert)
                    } label: {
                        DashboardCertAlertRow(cert: cert)
                    }
                    .buttonStyle(.plain)
                    if cert.id != topAlerts.last?.id {
                        Divider().padding(.leading, 64)
                    }
                }

                if store.complianceAlerts.count > 4 {
                    Divider()
                    NavigationLink {
                        CertificateListView()
                    } label: {
                        Text("See all \(store.complianceAlerts.count) alerts")
                            .font(.subheadline).foregroundColor(.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)
            .padding(.horizontal)
        }
    }
}

struct DashboardCertAlertRow: View {
    let cert: Certificate
    @EnvironmentObject var store: AppStore

    private var employeeName: String {
        store.employees.first { $0.id == cert.employeeID }?.fullName ?? "Unknown"
    }
    private var urgencyLabel: String {
        guard let days = cert.daysUntilExpiry else { return "No expiry" }
        if days < 0 { return "Expired \(abs(days))d ago" }
        return "Expires in \(days)d"
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(cert.status.color.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: cert.type.icon)
                    .foregroundColor(cert.status.color)
                    .font(.system(size: 15))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(cert.displayName)
                    .font(.subheadline).bold().lineLimit(1).foregroundColor(.primary)
                Text(employeeName)
                    .font(.caption).foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                CertStatusBadge(status: cert.status)
                Text(urgencyLabel)
                    .font(.caption2)
                    .foregroundColor(cert.status == .expired ? .red : .orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Management Dashboard Charts

private struct DashboardChartCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            content()
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .padding(.horizontal)
    }
}

// MARK: Budget Utilisation per Active Project

struct MgmtBudgetUtilChart: View {
    @EnvironmentObject var store: AppStore

    private struct ProjectUtil: Identifiable {
        let id: UUID
        let name: String
        let budgeted: Double
        let invoiced: Double
        var utilPct: Double { budgeted > 0 ? min(invoiced / budgeted * 100, 150) : 0 }
    }

    private var data: [ProjectUtil] {
        // Use liveActiveProjects so deleted projects don't show as 0% util
        // bars; sum invoiced from non-deleted invoices only so voided
        // invoices don't drag the % down.
        store.liveActiveProjects
            .compactMap { proj -> ProjectUtil? in
                guard let bud = store.projectBudgets.first(where: { $0.projectID == proj.id }) else { return nil }
                let budgeted = NSDecimalNumber(decimal: bud.totalBudgeted).doubleValue
                let invoiced = store.invoices
                    .filter { $0.projectID == proj.id && !$0.isDeleted }
                    .reduce(0.0) { $0 + NSDecimalNumber(decimal: $1.subtotal).doubleValue }
                return ProjectUtil(id: proj.id,
                                   name: proj.name.components(separatedBy: " ").prefix(3).joined(separator: " "),
                                   budgeted: budgeted,
                                   invoiced: invoiced)
            }
    }

    var body: some View {
        if data.isEmpty { EmptyView() } else {
            DashboardChartCard(title: "Budget Utilisation",
                               subtitle: "Invoiced vs. budgeted per active project") {
                VStack(spacing: 10) {
                    ForEach(data) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(item.name)
                                    .font(.caption).lineLimit(1)
                                Spacer()
                                Text("\(Int(item.utilPct))%")
                                    .font(.caption).bold()
                                    .foregroundColor(item.utilPct > 90 ? .red : item.utilPct > 70 ? .orange : .green)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color(.systemFill))
                                        .frame(height: 10)
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(item.utilPct > 90 ? Color.red : item.utilPct > 70 ? Color.orange : Color.green)
                                        .frame(width: geo.size.width * CGFloat(min(item.utilPct / 100, 1.0)), height: 10)
                                }
                            }
                            .frame(height: 10)
                        }
                    }
                }
            }
        }
    }
}

// MARK: Revenue Pipeline (Estimate Status Breakdown)

struct MgmtRevenuePipelineChart: View {
    @EnvironmentObject var store: AppStore

    private struct PipelineSlice: Identifiable {
        let id = UUID()
        let label: String
        let value: Double
        let color: Color
    }

    private var slices: [PipelineSlice] {
        let statuses: [(EstimateStatus, String, Color)] = [
            (.awarded,    "Awarded",    .green),
            (.submitted,  "Submitted",  .blue),
            (.estimating, "Estimating", .orange),
            (.lost,       "Lost",       .red),
        ]
        return statuses.compactMap { (status, label, color) in
            let total = store.estimates
                .filter { $0.status == status }
                .reduce(0.0) { $0 + NSDecimalNumber(decimal: $1.subtotal).doubleValue }
            guard total > 0 else { return nil }
            return PipelineSlice(label: label, value: total, color: color)
        }
    }

    private var grandTotal: Double { slices.reduce(0) { $0 + $1.value } }

    var body: some View {
        if slices.isEmpty { EmptyView() } else {
            DashboardChartCard(title: "Revenue Pipeline",
                               subtitle: "Estimates by status — total value") {
                VStack(spacing: 8) {
                    ForEach(slices) { slice in
                        HStack(spacing: 10) {
                            Circle().fill(slice.color).frame(width: 10, height: 10)
                            Text(slice.label).font(.caption)
                            Spacer()
                            Text(Decimal(slice.value).currencyString)
                                .font(.caption).bold()
                            Text(grandTotal > 0 ? "(\(Int(slice.value / grandTotal * 100))%)" : "")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    // Stacked bar
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(slices) { slice in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(slice.color)
                                    .frame(width: grandTotal > 0
                                           ? geo.size.width * CGFloat(slice.value / grandTotal)
                                           : 0,
                                           height: 14)
                            }
                        }
                    }
                    .frame(height: 14)
                }
            }
        }
    }
}

// MARK: Open Items Summary (RFIs + COs + Overdue Invoices)

struct MgmtOpenItemsChart: View {
    @EnvironmentObject var store: AppStore

    private struct OpenBucket: Identifiable {
        let id = UUID()
        let label: String
        let count: Int
        let color: Color
        let icon: String
    }

    private var buckets: [OpenBucket] {
        [
            OpenBucket(label: "Open RFIs",    count: store.openRFIs.count,                          color: .blue,   icon: "questionmark.bubble.fill"),
            OpenBucket(label: "Overdue RFIs", count: store.overdueRFIs.count,                       color: .red,    icon: "exclamationmark.bubble.fill"),
            OpenBucket(label: "Open COs",     count: store.openChangeOrders.count,                  color: .orange, icon: "arrow.left.arrow.right.circle.fill"),
            OpenBucket(label: "Overdue Inv.", count: store.overdueInvoices.count,                   color: .red,    icon: "doc.plaintext.fill"),
            OpenBucket(label: "Sub Alerts",   count: store.subcontractorsWithComplianceAlerts.count, color: .purple, icon: "building.2.fill"),
        ].filter { $0.count > 0 }
    }

    var body: some View {
        if buckets.isEmpty { EmptyView() } else {
            DashboardChartCard(title: "Open Items",
                               subtitle: "Action required across all modules") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(buckets) { bucket in
                        HStack(spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(bucket.color.opacity(0.12))
                                    .frame(width: 36, height: 36)
                                Image(systemName: bucket.icon)
                                    .font(.caption)
                                    .foregroundColor(bucket.color)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(bucket.count)")
                                    .font(.title3).bold()
                                    .foregroundColor(bucket.color)
                                Text(bucket.label)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}
