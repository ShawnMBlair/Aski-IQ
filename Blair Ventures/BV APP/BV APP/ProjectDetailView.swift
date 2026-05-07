// ProjectDetailView.swift
// FieldOS – Project Detail
// Replaces the stub in SharedComponents.swift

import SwiftUI

struct ProjectDetailView: View {
    let project: Project
    @EnvironmentObject var store: AppStore
    @State private var showEdit             = false
    @State private var showCommercialIntake = false
    /// Phase 7 audit fix: project-driven invoice generation. Pre-fix
    /// the only auto-invoice path was Material Sales — projects had
    /// no first-class billing flow. Now an admin can pick a quote
    /// (or skip and start blank) and pick deposit/progress/final.
    @State private var showGenerateInvoice  = false

    /// Read assigned crews from the LIVE store version of the project, not
    /// the `let project` snapshot captured when this view was pushed.
    /// Pre-fix: when a schedule entry was saved on this project, the
    /// store updated `assignedCrewIDs` correctly, but the open detail
    /// view kept showing "No crews assigned" because it was rendering
    /// from the stale snapshot. Looking up via `store.project(id:)` makes
    /// the section refresh on the next `objectWillChange`.
    private var assignedCrews: [Crew] {
        let live = store.project(id: project.id) ?? project
        return live.assignedCrewIDs.compactMap { store.crew(id: $0) }
    }

    /// RA-4: workers attached directly via custom-crew or
    /// individual-worker schedule entries. Auto-populated by
    /// `syncProjectAssignedWorkersFromScheduleEntry` on every save.
    /// Same live-store-read pattern as `assignedCrews` so the
    /// section refreshes on the next `objectWillChange`.
    private var assignedWorkers: [Employee] {
        let live = store.project(id: project.id) ?? project
        return live.assignedWorkerIDs
            .compactMap { id in store.employees.first(where: { $0.id == id }) }
            .sorted {
                if $0.lastName != $1.lastName { return $0.lastName < $1.lastName }
                return $0.firstName < $1.firstName
            }
    }

    private var timesheets: [TimesheetEntry] {
        store.timesheets(for: project.id)
            .sorted { $0.date > $1.date }
    }

    private var recentTimesheets: [TimesheetEntry] {
        Array(timesheets.prefix(5))
    }

    private var totalHours: Decimal {
        timesheets.reduce(0) { $0 + $1.totalHours }
    }

    private var scheduleEntries: [ScheduleEntry] {
        store.scheduleEntries
            .filter { $0.projectID == project.id }
            .sorted { $0.date > $1.date }
    }

    private var recentScheduleEntries: [ScheduleEntry] {
        Array(scheduleEntries.prefix(5))
    }

    private var formSubmissions: [FormSubmission] {
        store.formSubmissions.filter {
            ($0.projectID == project.id || $0.linkType == .project && $0.projectID == project.id)
            && !$0.isArchived
        }
        .sorted { ($0.submittedAt ?? $0.createdAt) > ($1.submittedAt ?? $1.createdAt) }
    }

    private var projectIncidents: [Incident] {
        store.incidents(for: project.id)
    }

    private var recentIncidents: [Incident] {
        Array(projectIncidents.prefix(3))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ProjectDetailTopSection(project: project,
                                        timesheetCount: timesheets.count,
                                        scheduleCount: scheduleEntries.count,
                                        formCount: formSubmissions.count,
                                        incidentCount: projectIncidents.count,
                                        highSeverityIncident: projectIncidents.contains { $0.severity == .critical || $0.severity == .high })
                ProjectDetailFieldSection(project: project,
                                          assignedCrews: assignedCrews,
                                          assignedWorkers: assignedWorkers,
                                          recentSchedule: recentScheduleEntries,
                                          scheduleTotal: scheduleEntries.count,
                                          recentTimesheets: recentTimesheets,
                                          timesheetTotal: timesheets.count,
                                          formSubmissions: formSubmissions)
                ProjectDetailSafetySection(project: project,
                                           recentIncidents: recentIncidents,
                                           incidentTotal: projectIncidents.count)
                ProjectDetailCommercialSection(project: project)
                Spacer(minLength: 32)
            }
            .padding(.top)
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { showEdit = true } label: {
                        Label("Edit Project", systemImage: "pencil")
                    }
                    Button { showCommercialIntake = true } label: {
                        Label("New Commercial Work", systemImage: "plus.circle.fill")
                    }
                    // Phase 7 audit fix: invoice generation entry
                    // point on the project itself. Admin-only to
                    // mirror the server-side role gate added the
                    // same audit pass.
                    if store.currentUserRole.isAdmin
                        || store.currentUserRole == .manager
                        || store.currentUserRole == .officeAdmin {
                        Button { showGenerateInvoice = true } label: {
                            Label("Generate Invoice…", systemImage: "doc.text.fill")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            ProjectCreateEditView(existing: project)
        }
        .sheet(isPresented: $showCommercialIntake) {
            CommercialIntakeView(
                prefillContext: CommercialContext.from(
                    project:    project,
                    clientName: store.client(id: project.clientID ?? UUID())?.name
                              ?? project.clientName
                )
            )
            .environmentObject(store)
        }
        .sheet(isPresented: $showGenerateInvoice) {
            ProjectInvoiceGeneratorSheet(project: project)
                .environmentObject(store)
        }
    }
}

// MARK: - ProjectDetailTopSection

private struct ProjectDetailTopSection: View {
    let project: Project
    let timesheetCount: Int
    let scheduleCount: Int
    let formCount: Int
    let incidentCount: Int
    let highSeverityIncident: Bool
    @EnvironmentObject var store: AppStore

    var body: some View {
        Group {
            headerCard
            kpiRow
            NavigationLink(destination: ProjectCostView(project: project)) {
                ProjectCostBannerRow(project: project)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusBadge(status: project.status)
                Spacer()
                if !store.currentUserRole.isFieldRole, let value = project.contractValue {
                    Text(value.currencyString).font(.title3).bold()
                }
            }
            // Client name — prefer CRM link, fallback to stored string
            let displayClient = project.clientID.flatMap { store.client(id: $0)?.name } ?? project.clientName
            Text(displayClient).font(.subheadline).foregroundColor(.secondary)

            // Site — prefer structured site name, fallback to free-text address
            if let clientID = project.clientID,
               let siteID   = project.siteID,
               let site     = store.client(id: clientID)?.sites.first(where: { $0.id == siteID }) {
                Label(site.name, systemImage: "mappin.circle.fill")
                    .font(.subheadline).foregroundColor(.orange)
                let addr = site.formattedAddress.isEmpty ? site.address : site.formattedAddress
                if !addr.isEmpty {
                    Text(addr).font(.caption).foregroundColor(.secondary)
                }
            } else if let address = project.siteAddress {
                Label(address, systemImage: "mappin.circle")
                    .font(.subheadline).foregroundColor(.secondary)
            }
            HStack(spacing: 20) {
                if let start = project.startDate {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start").font(.caption).foregroundColor(.secondary)
                        Text(start.shortDate).font(.subheadline)
                    }
                }
                if let end = project.endDate {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("End").font(.caption).foregroundColor(.secondary)
                        Text(end.shortDate).font(.subheadline)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .padding(.horizontal)
    }

    private var kpiRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                MiniKPICard(value: "\(timesheetCount)",  label: "Timesheets", icon: "clock")
                MiniKPICard(value: "\(scheduleCount)",   label: "Shifts",     icon: "calendar")
                MiniKPICard(value: "\(formCount)",       label: "Forms",      icon: "doc.text")
                MiniKPICard(value: "\(store.dailyJobReports(for: project.id).count)",
                            label: "DJRs", icon: "doc.text.below.ecg", color: .teal)
                MiniKPICard(value: "\(store.documents(for: project.id).count)",
                            label: "Docs", icon: "doc.fill", color: .indigo)
                MiniKPICard(value: "\(incidentCount)", label: "Incidents",
                            icon: "exclamationmark.shield",
                            color: highSeverityIncident ? .red : .orange)
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - ProjectDetailFieldSection

private struct ProjectDetailFieldSection: View {
    let project: Project
    let assignedCrews: [Crew]
    /// RA-4: workers assigned directly via custom-crew or
    /// individual-worker schedule entries. Auto-populated by the
    /// upsertScheduleEntry chokepoint.
    let assignedWorkers: [Employee]
    let recentSchedule: [ScheduleEntry]
    let scheduleTotal: Int
    let recentTimesheets: [TimesheetEntry]
    let timesheetTotal: Int
    let formSubmissions: [FormSubmission]

    var body: some View {
        Group {
            crewsSection
            // RA-4: surface direct-worker assignments as their own
            // section. Hidden when empty so projects that only use
            // fixed crews don't see an unused header.
            if !assignedWorkers.isEmpty {
                workersSection
            }
            scheduleSection
            timesheetsSection
            ProjectFormsSection(project: project, submissions: formSubmissions)
            ProjectRFISection(project: project)
        }
    }

    private var crewsSection: some View {
        Group {
            SectionHeader(title: "Assigned Crews", count: assignedCrews.count)
            if assignedCrews.isEmpty {
                EmptyCard(message: "No crews assigned.")
            } else {
                ForEach(assignedCrews) { crew in
                    CrewSummaryRow(crew: crew).padding(.horizontal)
                }
            }
        }
    }

    /// RA-4: lightweight worker rows. Mirrors the shape of CrewSummaryRow
    /// without dragging in the full crew structure (members, foreman, etc.)
    /// — these are individuals attached via custom-crew or direct
    /// assignment, not crew memberships.
    private var workersSection: some View {
        Group {
            SectionHeader(title: "Assigned Workers", count: assignedWorkers.count)
            VStack(spacing: 0) {
                ForEach(assignedWorkers) { worker in
                    NavigationLink {
                        EmployeeDetailView(employee: worker)
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.blue.opacity(0.15))
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Text(worker.initials)
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(worker.fullName)
                                    .font(.subheadline.bold())
                                    .foregroundColor(.primary)
                                if let trade = worker.trade, !trade.isEmpty {
                                    Text(trade)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal)
                    }
                    if worker.id != assignedWorkers.last?.id {
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    private var scheduleSection: some View {
        Group {
            HStack {
                SectionHeader(title: "Recent Schedule", count: scheduleTotal)
                Spacer()
                if scheduleTotal > 5 {
                    NavigationLink("View All", destination: ProjectScheduleListView(projectID: project.id))
                        .font(.subheadline).foregroundColor(.blue).padding(.trailing)
                }
            }
            if recentSchedule.isEmpty {
                EmptyCard(message: "No shifts scheduled.")
            } else {
                ForEach(recentSchedule) { entry in ScheduleEntryRow(entry: entry) }
            }
        }
    }

    private var timesheetsSection: some View {
        Group {
            HStack {
                SectionHeader(title: "Recent Timesheets", count: timesheetTotal)
                Spacer()
                if timesheetTotal > 5 {
                    NavigationLink("View All", destination: ProjectTimesheetListView(projectID: project.id))
                        .font(.subheadline).foregroundColor(.blue).padding(.trailing)
                }
            }
            if recentTimesheets.isEmpty {
                EmptyCard(message: "No timesheets logged.")
            } else {
                ForEach(recentTimesheets) { entry in TimesheetSummaryRow(entry: entry) }
            }
        }
    }
}

// MARK: - ProjectDetailSafetySection

private struct ProjectDetailSafetySection: View {
    let project: Project
    let recentIncidents: [Incident]
    let incidentTotal: Int

    var body: some View {
        Group {
            incidentListPart
            NavigationLink(destination: IncidentCreateEditView(prelinkedProjectID: project.id)) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Report an Incident")
                }
                .font(.subheadline).bold()
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.red.opacity(0.85))
                .cornerRadius(12)
                .padding(.horizontal)
            }
            DJRProjectSection(project: project)
        }
    }

    @ViewBuilder
    private var incidentListPart: some View {
        HStack {
            SectionHeader(title: "Safety / Incidents", count: incidentTotal)
            Spacer()
            if incidentTotal > 3 {
                NavigationLink("View All",
                    destination: ProjectIncidentListView(projectID: project.id, projectName: project.name))
                    .font(.subheadline).foregroundColor(.blue).padding(.trailing)
            }
        }
        if recentIncidents.isEmpty {
            EmptyCard(message: "No incidents reported for this project.")
        } else {
            VStack(spacing: 8) {
                ForEach(recentIncidents) { incident in
                    NavigationLink(destination: IncidentDetailView(incident: incident)) {
                        ProjectIncidentRow(incident: incident).padding(.horizontal)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - ProjectDetailCommercialSection

private struct ProjectDetailCommercialSection: View {
    let project: Project
    @EnvironmentObject var store: AppStore

    var body: some View {
        Group {
            changeOrdersPart
            subcontractorsPart
            procurementPart
            invoicePart
            ProjectDocumentsSection(project: project)
            notesPart
        }
    }

    @ViewBuilder
    private var subcontractorsPart: some View {
        let role = store.currentUserRole
        if role == .projectManager || role == .officeAdmin || role == .manager || role == .executive {
            ProjectSubcontractorsSection(project: project)
        }
    }

    @ViewBuilder
    private var changeOrdersPart: some View {
        let cos = store.changeOrders(for: project.id)
        let role = store.currentUserRole
        if role == .projectManager || role == .officeAdmin || role == .manager || role == .executive || role == .foreman {
            Divider().padding(.horizontal)
            HStack {
                SectionHeader(title: "Change Orders", count: cos.count)
                if !cos.isEmpty {
                    NavigationLink("See All", destination: ChangeOrderListView(projectID: project.id))
                        .font(.subheadline).padding(.trailing)
                }
            }
            if cos.isEmpty {
                EmptyCard(message: "No change orders on this project.")
            } else {
                VStack(spacing: 0) {
                    let open     = cos.filter { $0.status.isOpen }
                    let approved = cos.filter { $0.status == .approved }
                    let value    = approved.reduce(Decimal(0)) { $0 + $1.effectiveCostImpact }
                    HStack(spacing: 0) {
                        ProjectCOStat(label: "Total",    value: "\(cos.count)")
                        Divider().frame(height: 36)
                        ProjectCOStat(label: "Open",     value: "\(open.count)",
                                      color: open.isEmpty ? .secondary : .orange)
                        Divider().frame(height: 36)
                        ProjectCOStat(label: "Approved $", value: value.coDisplayString,
                                      color: value > 0 ? .green : .secondary)
                    }
                    .padding(.vertical, 8)
                    Divider()
                    ForEach(cos.prefix(3)) { co in
                        NavigationLink(destination: ChangeOrderDetailView(changeOrder: co)) {
                            ChangeOrderRow(co: co, showProject: false)
                                .padding(.horizontal)
                        }
                        if co.id != cos.prefix(3).last?.id { Divider().padding(.leading) }
                    }
                    if cos.count > 3 {
                        Divider()
                        NavigationLink(destination: ChangeOrderListView(projectID: project.id)) {
                            Text("See all \(cos.count) change orders")
                                .font(.subheadline).foregroundColor(.blue)
                                .frame(maxWidth: .infinity).padding()
                        }
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var procurementPart: some View {
        if !store.currentUserRole.isExternal {
            Divider().padding(.horizontal)
            ProjectProcurementSection(project: project)
        }
    }

    @ViewBuilder
    private var invoicePart: some View {
        let role = store.currentUserRole
        if role == .projectManager || role == .officeAdmin || role == .manager || role == .executive {
            Divider().padding(.horizontal)
            ProjectBudgetBannerRow(project: project)
            ProjectBudgetSummaryCard(project: project)
            ProjectCloseoutChecklistCard(project: project)
            Divider().padding(.horizontal)
            // Week 4 audit closeout: prompt to generate a Final
            // invoice when the project is .completed and no .final
            // invoice exists yet. Inserted ABOVE the regular
            // invoice section so it's the first thing the PM sees.
            FinalInvoicePromptBanner(project: project)
            ProjectInvoiceSection(project: project)
        }
    }

    @ViewBuilder
    private var notesPart: some View {
        if let notes = project.notes, !notes.isEmpty {
            SectionHeader(title: "Notes")
            Text(notes)
                .font(.subheadline).foregroundColor(.secondary)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
        }
    }
}

// MARK: - Mini KPI Card

struct MiniKPICard: View {
    let value: String
    let label: String
    let icon: String
    var color: Color = .blue

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(color)
            Text(value)
                .font(.headline)
                .bold()
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Crew Summary Row

struct CrewSummaryRow: View {
    let crew: Crew
    @EnvironmentObject var store: AppStore

    private var foreman: Employee? {
        crew.foremanID.flatMap { store.employee(id: $0) }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(crew.name).font(.headline)
                if let foreman {
                    Text("Foreman: \(foreman.fullName)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Text("\(crew.memberIDs.count) members")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Timesheet Summary Row

struct TimesheetSummaryRow: View {
    let entry: TimesheetEntry
    @EnvironmentObject var store: AppStore

    private var employeeName: String {
        store.employee(id: entry.employeeID)?.fullName ?? "Unknown"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(employeeName).font(.subheadline).bold()
                Text(entry.date.shortDate).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(entry.totalHours) hrs")
                    .font(.subheadline)
                    .bold()
                ApprovalBadge(status: entry.approvalStatus)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// MARK: - Approval Badge

struct ApprovalBadge: View {
    let status: ApprovalStatus

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption2)
            .bold()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(backgroundColor)
            .foregroundColor(.white)
            .cornerRadius(4)
    }

    private var backgroundColor: Color {
        switch status {
        case .draft: return .gray
        case .submitted: return .orange
        case .approved: return .green
        case .rejected: return .red
        case .locked: return .purple
        }
    }
}

// MARK: - Project Forms Section

struct ProjectFormsSection: View {
    let project: Project
    let submissions: [FormSubmission]

    @EnvironmentObject var store: AppStore
    @State private var showFormPicker = false
    @State private var showAllForms   = false

    private var recentSubmissions: [FormSubmission] {
        Array(submissions.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header row
            HStack {
                SectionHeader(title: "Forms", count: submissions.count)
                Spacer()
                Button {
                    showAllForms = true
                } label: {
                    Text("View All")
                        .font(.subheadline)
                        .foregroundColor(.blue)
                }
                .padding(.trailing)
                .opacity(submissions.isEmpty ? 0 : 1)
            }

            if submissions.isEmpty {
                EmptyCard(message: "No forms submitted for this project.")
            } else {
                ForEach(recentSubmissions) { submission in
                    NavigationLink {
                        FormSubmissionDetailView(submission: submission)
                    } label: {
                        ProjectFormRow(submission: submission)
                            .padding(.horizontal)
                    }
                    .buttonStyle(.plain)
                }

                if submissions.count > 3 {
                    Button {
                        showAllForms = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("See all \(submissions.count) forms")
                                .font(.subheadline)
                                .foregroundColor(.blue)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.blue)
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                    }
                    .padding(.top, 4)
                }
            }

            // Submit form button
            Button {
                showFormPicker = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Submit a Form")
                }
                .font(.subheadline)
                .bold()
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.blue)
                .cornerRadius(12)
                .padding(.horizontal)
            }
            .padding(.top, 10)
        }
        .sheet(isPresented: $showFormPicker) {
            FormPickerSheet(projectID: project.id)
        }
        .navigationDestination(isPresented: $showAllForms) {
            ProjectFormsListView(project: project, submissions: submissions)
        }
    }
}

// MARK: - Project Form Row

struct ProjectFormRow: View {
    let submission: FormSubmission
    @EnvironmentObject var store: AppStore

    private var templateName: String {
        store.formTemplates.first(where: { $0.id == submission.templateID })?.name ?? "Form"
    }

    private var statusColor: Color {
        if submission.isDraft { return .orange }
        if submission.isSigned { return .purple }
        return .green
    }

    private var statusLabel: String {
        if submission.isDraft { return "Draft" }
        if submission.isSigned { return "Signed" }
        return "Submitted"
    }

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(statusColor.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: submission.isDraft ? "doc.badge.clock" : "doc.text.fill")
                    .foregroundColor(statusColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(templateName)
                    .font(.subheadline)
                    .bold()
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text((submission.submittedAt ?? submission.createdAt).shortDate + " · " + submission.submittedBy)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(statusLabel)
                .font(.caption2)
                .bold()
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(statusColor)
                .cornerRadius(6)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Project Forms List View (all forms for a project)

struct ProjectFormsListView: View {
    let project: Project
    let submissions: [FormSubmission]

    @EnvironmentObject var store: AppStore
    @State private var showFormPicker = false
    @State private var searchText = ""

    private var filtered: [FormSubmission] {
        if searchText.isEmpty { return submissions }
        let q = searchText.lowercased()
        return submissions.filter { sub in
            let tName = store.formTemplates.first(where: { $0.id == sub.templateID })?.name ?? ""
            return tName.lowercased().contains(q) ||
                   sub.submittedBy.lowercased().contains(q)
        }
    }

    var body: some View {
        List {
            if !filtered.isEmpty {
                Section {
                    ForEach(filtered) { submission in
                        NavigationLink {
                            FormSubmissionDetailView(submission: submission)
                        } label: {
                            ProjectFormRow(submission: submission)
                                .padding(.vertical, 2)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Forms",
                    systemImage: "doc.text",
                    description: Text(searchText.isEmpty
                        ? "No forms submitted for \(project.name) yet."
                        : "No forms match \"\(searchText)\".")
                )
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Search forms…")
        .navigationTitle("Forms — \(project.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showFormPicker = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showFormPicker) {
            FormPickerSheet(projectID: project.id)
        }
    }
}


// MARK: - Project Timesheet Full List

struct ProjectTimesheetListView: View {
    let projectID: UUID
    @EnvironmentObject var store: AppStore
    @StateObject private var pagination = PaginationState(pageSize: 20)

    private var entries: [TimesheetEntry] {
        store.timesheets(for: projectID).sorted { $0.date > $1.date }
    }
    private var visible: [TimesheetEntry] {
        Array(entries.prefix(pagination.displayLimit))
    }

    var body: some View {
        List {
            ForEach(visible) { entry in
                TimesheetSummaryRow(entry: entry)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 16))
            }
            LoadMoreFooter(showing: visible.count, total: entries.count) {
                pagination.loadMore()
            }
        }
        .listStyle(.plain)
        .navigationTitle("Timesheets")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Project Incident Row

struct ProjectIncidentRow: View {
    let incident: Incident

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(incident.incidentType.color.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: incident.incidentType.icon)
                    .foregroundColor(incident.incidentType.color)
                    .font(.system(size: 16))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(incident.title)
                    .font(.subheadline).bold().lineLimit(1).foregroundColor(.primary)
                HStack(spacing: 6) {
                    SeverityBadge(severity: incident.severity)
                    Text(incident.incidentDate.shortDate)
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
            IncidentStatusBadge(status: incident.status)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Project Incident Full List

struct ProjectIncidentListView: View {
    let projectID: UUID
    let projectName: String
    @EnvironmentObject var store: AppStore
    @State private var showCreate = false

    private var incidents: [Incident] {
        store.incidents(for: projectID)
    }

    var body: some View {
        Group {
            if incidents.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 52)).foregroundColor(.green)
                    Text("No incidents recorded.").font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(incidents) { incident in
                        NavigationLink {
                            IncidentDetailView(incident: incident)
                        } label: {
                            IncidentListRow(incident: incident)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.deleteIncident(incident)
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Incidents — \(projectName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreate = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showCreate) {
            IncidentCreateEditView(prelinkedProjectID: projectID)
        }
    }
}

// MARK: - Project Schedule Full List

struct ProjectScheduleListView: View {
    let projectID: UUID
    @EnvironmentObject var store: AppStore
    @StateObject private var pagination = PaginationState(pageSize: 20)

    private var entries: [ScheduleEntry] {
        store.scheduleEntries
            .filter { $0.projectID == projectID }
            .sorted { $0.date > $1.date }
    }
    private var visible: [ScheduleEntry] {
        Array(entries.prefix(pagination.displayLimit))
    }

    var body: some View {
        List {
            ForEach(visible) { entry in
                ScheduleEntryRow(entry: entry)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            LoadMoreFooter(showing: visible.count, total: entries.count) {
                pagination.loadMore()
            }
        }
        .listStyle(.plain)
        .navigationTitle("Schedule")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Change Order mini-stat (local to ProjectDetailView)

private struct ProjectCOStat: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).foregroundColor(color)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private extension Decimal {
    /// Compact currency string (no cents) for change-order summaries in project detail.
    var coDisplayString: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 0
        return formatter.string(from: self as NSDecimalNumber) ?? "$\(self)"
    }
}

// MARK: - Final Invoice Prompt Banner (Week 4 audit closeout)
//
// Pre-fix the Project → Invoice generator was reachable only via the
// ⋯ menu. Operators routinely forgot to bill the final draw on
// completed projects (the audit's #4 risk: "Project completion or
// milestone does NOT auto-generate invoice — bills get forgotten").
// This banner makes the gap visible.
//
// VISIBILITY RULES
// Shown when:
//   * Project status is .completed
//   * AND no invoice with invoice_type = .final exists for this
//     project
//   * AND there's at least one accepted/approved quote linked to the
//     project (otherwise the generator can't seed line items
//     meaningfully and would produce a placeholder).
//
// One-tap opens the existing ProjectInvoiceGeneratorSheet pre-set to
// .final — the same sheet PMs use voluntarily from the ⋯ menu.

private struct FinalInvoicePromptBanner: View {
    let project: Project
    @EnvironmentObject var store: AppStore
    @State private var showGenerator = false

    private var hasFinalInvoice: Bool {
        store.invoices.contains { inv in
            inv.projectID == project.id
                && inv.invoiceType == .final
                && !inv.isDeleted
        }
    }

    private var hasEligibleQuote: Bool {
        store.quotes.contains { q in
            q.projectID == project.id
                && (q.status == .accepted || q.status == .approved)
                && !q.isDeleted
        }
    }

    private var shouldShow: Bool {
        project.status == .completed
            && !hasFinalInvoice
            && hasEligibleQuote
    }

    var body: some View {
        if shouldShow {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title3)
                        .foregroundColor(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ready to bill the final?")
                            .font(.subheadline.weight(.semibold))
                        Text("This project is marked Completed but no Final invoice has been generated yet.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        showGenerator = true
                    } label: {
                        Text("Generate")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.purple)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                }
                .padding(12)
                .background(Color.purple.opacity(0.08))
                .cornerRadius(12)
                .padding(.horizontal)
                .padding(.bottom, 4)
            }
            .sheet(isPresented: $showGenerator) {
                ProjectInvoiceGeneratorSheet(project: project)
                    .environmentObject(store)
            }
        }
    }
}

// MARK: - Project Budget Summary Card (Phase 3 PMI workflow)
//
// Surfaces the full PMI cost row — Original / Approved COs / Revised /
// Committed / Actual / Forecast / Margin / Variance — driven by
// `BudgetActualService.actuals(for:in:)`. Sits below the lighter
// `ProjectBudgetBannerRow` (which only shows the headline tile).
//
// Hidden when the project has no budget, no contract value, and no
// actuals yet — there's nothing meaningful to show on a brand-new
// project, and a row of "—" cells is just noise.
//
// Banner rules:
//   * red  — over budget (variance > 0)
//   * orange — approaching budget (>= 80% spent) OR margin under 10%
//             OR pending COs > 0 (exposure)
//   * green — healthy (under 70% and margin OK)

private struct ProjectBudgetSummaryCard: View {
    let project: Project
    @EnvironmentObject var store: AppStore

    private var actuals: ProjectBudgetActuals {
        BudgetActualService.actuals(for: project.id, in: store)
    }

    private var hasAnything: Bool {
        let a = actuals
        return a.originalBudget > 0
            || a.totalBudgetedLines > 0
            || a.actualCost > 0
            || a.approvedCOTotal != 0
            || a.pendingCOTotal != 0
    }

    var body: some View {
        if hasAnything {
            let a = actuals
            VStack(alignment: .leading, spacing: 12) {
                header(actuals: a)
                Divider()
                budgetRow(actuals: a)
                Divider()
                actualRow(actuals: a)
                Divider()
                marginRow(actuals: a)
                if !warnings(for: a).isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(warnings(for: a), id: \.self) { w in
                            Label(w.message, systemImage: w.icon)
                                .font(.caption)
                                .foregroundColor(w.color)
                        }
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
            .padding(.top, 4)
        }
    }

    private func header(actuals a: ProjectBudgetActuals) -> some View {
        HStack {
            Label("Budget vs Actual", systemImage: "chart.bar.doc.horizontal")
                .font(.subheadline.weight(.semibold))
            Spacer()
            statusBadge(for: a)
        }
    }

    @ViewBuilder
    private func statusBadge(for a: ProjectBudgetActuals) -> some View {
        if a.isOverBudget {
            badge(text: "Over Budget", color: .red)
        } else if a.isApproachingBudget {
            badge(text: "Approaching", color: .orange)
        } else if a.isMarginBelowTarget {
            badge(text: "Margin Watch", color: .orange)
        } else if a.totalBudgetedLines > 0 || a.originalBudget > 0 {
            badge(text: "On Track", color: .green)
        }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    private func budgetRow(actuals a: ProjectBudgetActuals) -> some View {
        HStack(spacing: 0) {
            BudgetStat(label: "Original",
                       value: a.originalBudget.currencyString,
                       color: .primary)
            Divider().frame(height: 36)
            BudgetStat(label: "Approved COs",
                       value: signedCurrency(a.approvedCOTotal),
                       color: a.approvedCOTotal == 0 ? .secondary : .blue)
            Divider().frame(height: 36)
            BudgetStat(label: "Revised",
                       value: a.revisedBudget.currencyString,
                       color: .primary)
        }
    }

    private func actualRow(actuals a: ProjectBudgetActuals) -> some View {
        HStack(spacing: 0) {
            BudgetStat(label: "Committed",
                       value: a.materialCommitted.currencyString,
                       color: .secondary)
            Divider().frame(height: 36)
            BudgetStat(label: "Actual",
                       value: a.actualCost.currencyString,
                       color: a.isOverBudget ? .red : .primary)
            Divider().frame(height: 36)
            BudgetStat(label: "Forecast",
                       value: a.forecastCost.currencyString,
                       color: a.forecastCost > a.revisedBudget && a.revisedBudget > 0 ? .orange : .primary)
        }
    }

    private func marginRow(actuals a: ProjectBudgetActuals) -> some View {
        HStack(spacing: 0) {
            BudgetStat(label: "Margin",
                       value: a.margin.currencyString,
                       color: a.margin <= 0 ? .red : (a.isMarginBelowTarget ? .orange : .green))
            Divider().frame(height: 36)
            BudgetStat(label: "Variance",
                       value: signedCurrency(a.variance),
                       color: a.variance > 0 ? .red : .secondary)
            Divider().frame(height: 36)
            BudgetStat(label: "% Spent",
                       value: String(format: "%.0f%%", a.percentSpent * 100),
                       color: a.isOverBudget ? .red : (a.isApproachingBudget ? .orange : .primary))
        }
    }

    // MARK: Warnings

    private struct CardWarning: Hashable {
        let message: String
        let icon: String
        let color: Color
    }

    private func warnings(for a: ProjectBudgetActuals) -> [CardWarning] {
        var out: [CardWarning] = []
        if a.isOverBudget {
            out.append(.init(
                message: "Actuals exceed total budget by \(a.variance.currencyString).",
                icon: "exclamationmark.triangle.fill",
                color: .red
            ))
        } else if a.isApproachingBudget {
            out.append(.init(
                message: "Spent \(Int(a.percentSpent * 100))% of budget — monitor remaining work closely.",
                icon: "exclamationmark.circle.fill",
                color: .orange
            ))
        }
        if a.isMarginBelowTarget && !a.isOverBudget {
            out.append(.init(
                message: "Projected margin is below the \(Int(BudgetActualService.minMarginRatio * 100))% target.",
                icon: "percent",
                color: .orange
            ))
        }
        if a.pendingCOTotal != 0 {
            out.append(.init(
                message: "\(a.openChangeOrderCount) open change order(s) — \(signedCurrency(a.pendingCOTotal)) exposure.",
                icon: "doc.badge.clock",
                color: .blue
            ))
        }
        if a.unratedTimesheetCount > 0 {
            out.append(.init(
                message: "\(a.unratedTimesheetCount) timesheet entr\(a.unratedTimesheetCount == 1 ? "y" : "ies") have no employee rate — labor actuals understated.",
                icon: "person.crop.circle.badge.questionmark",
                color: .secondary
            ))
        }
        if a.pendingFieldLaborHours > 0 {
            let hoursText = String(format: "%.1f", a.pendingFieldLaborHours)
            let suffix: String
            if a.pendingFieldLaborEstimatedCost > 0 {
                suffix = " (~\(a.pendingFieldLaborEstimatedCost.currencyString) once timesheeted)"
            } else {
                suffix = ""
            }
            out.append(.init(
                message: "\(hoursText) hrs from approved daily reports not yet timesheeted\(suffix) — actuals will rise.",
                icon: "clock.arrow.circlepath",
                color: .blue
            ))
        }
        return out
    }

    private func signedCurrency(_ value: Decimal) -> String {
        if value > 0 { return "+" + value.currencyString }
        return value.currencyString
    }
}

// MARK: - Project Closeout Checklist Card (Phase 4 PMI workflow)
//
// Surfaces the PMI-aligned closeout list (open COs, final invoice,
// lien waivers, RFIs, subs, timesheets, budget reconciled). Each
// item is .done / .pending / .notApplicable.
//
// VISIBILITY RULES
// Shown when:
//   * Project status is .completed (closeout in progress), OR
//   * Project status is .inProgress AND any item is pending — gives
//     the PM a running view of what's left before they CAN close.
// Hidden on .planned / .onHold / .cancelled — closeout is irrelevant.

private struct ProjectCloseoutChecklistCard: View {
    let project: Project
    @EnvironmentObject var store: AppStore

    @State private var expanded: Bool = false

    private var closeout: ProjectCloseout {
        ProjectCloseoutChecklist.checklist(for: project.id, in: store)
    }

    private var shouldShow: Bool {
        switch project.status {
        case .completed: return true
        case .active:    return closeout.pendingCount > 0
        default:         return false
        }
    }

    var body: some View {
        if shouldShow {
            let c = closeout
            VStack(alignment: .leading, spacing: 12) {
                header(closeout: c)
                progressBar(closeout: c)
                if expanded {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(c.items) { item in
                            CloseoutChecklistRow(item: item)
                        }
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
            .padding(.top, 4)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
        }
    }

    private func header(closeout c: ProjectCloseout) -> some View {
        HStack {
            Label("Project Closeout", systemImage: "checkmark.seal")
                .font(.subheadline.weight(.semibold))
            Spacer()
            if c.isReadyToClose {
                badge(text: "Ready", color: .green)
            } else {
                badge(text: "\(c.pendingCount) pending", color: .orange)
            }
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    private func progressBar(closeout c: ProjectCloseout) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.systemGray5))
                    .frame(height: 8)
                RoundedRectangle(cornerRadius: 4)
                    .fill(c.isReadyToClose ? Color.green : Color.orange)
                    .frame(width: max(geo.size.width * CGFloat(c.progress), 4), height: 8)
            }
        }
        .frame(height: 8)
    }
}

private struct CloseoutChecklistRow: View {
    let item: CloseoutChecklistItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline)
                    .foregroundColor(textColor)
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch item.state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .pending:
            Image(systemName: "circle").foregroundColor(.orange)
        case .notApplicable:
            Image(systemName: "minus.circle").foregroundColor(.secondary)
        }
    }

    private var textColor: Color {
        switch item.state {
        case .done:          return .primary
        case .pending:       return .primary
        case .notApplicable: return .secondary
        }
    }
}
