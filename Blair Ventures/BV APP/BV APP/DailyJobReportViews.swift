// DailyJobReportViews.swift
// Aski IQ – Daily Job Report UI

import SwiftUI
import Combine
import PhotosUI

// MARK: - DJR List View (embedded in Project Detail)

struct DailyJobReportListView: View {
    let project: Project
    @EnvironmentObject var store: AppStore
    @State private var showCreate = false

    private var reports: [DailyJobReport] {
        store.dailyJobReports(for: project.id)
    }

    var body: some View {
        NavigationStack {
            List {
                if reports.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "doc.text.below.ecg")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary.opacity(0.4))
                            Text("No Daily Reports Yet")
                                .font(.headline)
                            Text("Tap + to submit the first Daily Job Report for this project.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                } else {
                    Section {
                        ForEach(reports) { report in
                            NavigationLink {
                                DJRDetailView(report: report)
                            } label: {
                                DJRRow(report: report)
                            }
                        }
                        .onDelete { idxSet in
                            idxSet.forEach { store.deleteDJR(reports[$0]) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Daily Reports")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreate) {
                DJRCreateEditView(projectID: project.id)
            }
        }
    }
}

// MARK: - DJR Row

struct DJRRow: View {
    let report: DailyJobReport

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(statusColor(report.status).opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "doc.text.fill")
                    .foregroundColor(statusColor(report.status))
                    .font(.system(size: 18))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(report.reportNumber)
                        .font(.subheadline).bold()
                    DJRStatusBadge(status: report.status)
                }
                Text(report.reportDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Label("\(report.totalWorkers) workers", systemImage: "person.2")
                    Label(String(format: "%.1f hrs", report.totalHoursWorked), systemImage: "clock")
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Image(systemName: report.weatherCondition.icon)
                    .foregroundColor(weatherColor(report.weatherCondition))
                    .font(.system(size: 18))
                if let pct = report.percentComplete {
                    Text("\(pct)%")
                        .font(.caption2).bold()
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func statusColor(_ status: DJRStatus) -> Color {
        switch status {
        case .draft:     return .gray
        case .submitted: return .blue
        case .approved:  return .green
        case .rejected:  return .red
        }
    }

    private func weatherColor(_ w: WeatherCondition) -> Color {
        switch w {
        case .sunny:        return .orange
        case .partlyCloudy: return .yellow
        case .overcast:     return .gray
        case .lightRain, .heavyRain: return .blue
        case .snow, .freezingRain:   return .cyan
        case .fog:          return .gray
        case .windy:        return .teal
        }
    }
}

// MARK: - DJR Status Badge

struct DJRStatusBadge: View {
    let status: DJRStatus

    var body: some View {
        Text(status.displayName.uppercased())
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(4)
    }

    private var color: Color {
        switch status {
        case .draft:     return .gray
        case .submitted: return .blue
        case .approved:  return .green
        case .rejected:  return .red
        }
    }
}

// MARK: - DJR Detail View

struct DJRDetailView: View {
    let report: DailyJobReport
    @EnvironmentObject var store: AppStore
    @State private var localReport: DailyJobReport
    @State private var showEdit = false
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var isGeneratingPDF = false
    @State private var showDeleteAlert = false
    @Environment(\.dismiss) var dismiss

    init(report: DailyJobReport) {
        self.report = report
        self._localReport = State(initialValue: report)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // MARK: Header Card
                djrHeaderCard

                // MARK: Weather
                djrWeatherSection

                // MARK: Workforce
                if !localReport.crewEntries.isEmpty {
                    djrCrewSection
                }

                // MARK: Work Performed
                djrWorkSection

                // MARK: Equipment
                if !localReport.equipmentEntries.isEmpty {
                    djrEquipmentSection
                }

                // MARK: Materials
                if !localReport.materialDeliveries.isEmpty {
                    djrMaterialsSection
                }

                // MARK: Delays
                if !localReport.delays.isEmpty {
                    djrDelaysSection
                }

                // MARK: Visitors / Inspections
                if !localReport.visitors.isEmpty || localReport.inspectionsPassed {
                    djrVisitorsSection
                }

                // MARK: Safety
                djrSafetySection

                // MARK: Notes
                if !localReport.notes.isEmpty {
                    SectionHeader(title: "Notes")
                    Text(localReport.notes)
                        .font(.subheadline)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                }

                // MARK: Site Photos
                if !localReport.photoData.isEmpty {
                    SectionHeader(title: "Site Photos (\(localReport.photoData.count))")
                    DJRPhotoGrid(photoData: localReport.photoData)
                        .padding(.horizontal)
                }

                // MARK: Actions
                VStack(spacing: 12) {
                    // Submit button (draft only)
                    if localReport.status == .draft {
                        Button {
                            var updated = localReport
                            updated.status = .submitted
                            updated.submittedAt = Date()
                            store.updateDJR(updated)
                            store.createAuditSnapshot(
                                for: updated,
                                eventType: "djr_submitted",
                                by: store.currentUser?.fullName ?? "Unknown"
                            )
                            let projName = store.projects.first(where: { $0.id == updated.projectID })?.name ?? "project"
                            NotificationManager.shared.notifyDJRSubmitted(
                                reportNumber: updated.reportNumber,
                                projectName:  projName,
                                submittedBy:  updated.submittedByName
                            )
                            localReport = updated
                        } label: {
                            Label("Submit Report", systemImage: "paperplane.fill")
                                .font(.subheadline).bold()
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }
                    }

                    // Approve/Reject (submitted, manager-level)
                    if localReport.status == .submitted && store.canPerform(action: .timesheetApprove) {
                        HStack(spacing: 12) {
                            Button {
                                var updated = localReport
                                updated.status = .approved
                                updated.approvedByName = store.currentUser?.fullName ?? "Manager"
                                updated.approvedAt = Date()
                                store.updateDJR(updated)
                                store.createAuditSnapshot(
                                    for: updated,
                                    eventType: "djr_approved",
                                    by: store.currentUser?.fullName ?? "Manager"
                                )
                                localReport = updated
                            } label: {
                                Label("Approve", systemImage: "checkmark.circle.fill")
                                    .font(.subheadline).bold()
                                    .frame(maxWidth: .infinity).padding()
                                    .background(Color.green)
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                            }
                            Button(role: .destructive) {
                                var updated = localReport
                                updated.status = .rejected
                                store.updateDJR(updated)
                                store.createAuditSnapshot(
                                    for: updated,
                                    eventType: "djr_rejected",
                                    by: store.currentUser?.fullName ?? "Manager"
                                )
                                localReport = updated
                            } label: {
                                Label("Reject", systemImage: "xmark.circle.fill")
                                    .font(.subheadline).bold()
                                    .frame(maxWidth: .infinity).padding()
                                    .background(Color.red.opacity(0.1))
                                    .foregroundColor(.red)
                                    .cornerRadius(12)
                            }
                        }
                    }

                    // PDF Export
                    Button {
                        exportPDF()
                    } label: {
                        HStack {
                            if isGeneratingPDF {
                                ProgressView().progressViewStyle(.circular)
                            } else {
                                Label("Export PDF", systemImage: "arrow.down.doc.fill")
                            }
                        }
                        .font(.subheadline).bold()
                        .frame(maxWidth: .infinity).padding()
                        .background(Color.orange.opacity(0.1))
                        .foregroundColor(.orange)
                        .cornerRadius(12)
                    }
                    .disabled(isGeneratingPDF)
                }
                .padding(.horizontal)
                .padding(.top, 4)

                Spacer(minLength: 32)
            }
            .padding(.top)
        }
        .navigationTitle(localReport.reportNumber)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showEdit = true
                } label: {
                    Image(systemName: "pencil")
                }
                Button(role: .destructive) {
                    showDeleteAlert = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            DJRCreateEditView(projectID: localReport.projectID, existingReport: localReport) { updated in
                localReport = updated
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .alert("Delete Report?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                store.deleteDJR(localReport)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete \(localReport.reportNumber). This cannot be undone.")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            if let updated = store.dailyJobReport(id: localReport.id) {
                localReport = updated
            }
        }
    }

    // MARK: - Section Cards

    private var djrHeaderCard: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localReport.reportDate.formatted(date: .complete, time: .omitted))
                        .font(.headline)
                    Text("Submitted by \(localReport.submittedByName)")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
                DJRStatusBadge(status: localReport.status)
            }

            Divider()

            HStack(spacing: 0) {
                DJRStatCell(value: "\(localReport.totalWorkers)", label: "Workers", icon: "person.2.fill", color: .blue)
                DJRStatCell(value: String(format: "%.1f", localReport.totalHoursWorked), label: "Total Hrs", icon: "clock.fill", color: .purple)
                if let pct = localReport.percentComplete {
                    DJRStatCell(value: "\(pct)%", label: "Complete", icon: "chart.pie.fill", color: .green)
                }
                if localReport.hasDelays {
                    DJRStatCell(value: String(format: "%.1f", localReport.totalHoursLost), label: "Hrs Lost", icon: "exclamationmark.triangle.fill", color: .red)
                }
            }

            if let approvedBy = localReport.approvedByName, let approvedAt = localReport.approvedAt {
                Divider()
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                    Text("Approved by \(approvedBy) on \(approvedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .padding(.horizontal)
    }

    private var djrWeatherSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Weather")
            HStack(spacing: 16) {
                Image(systemName: localReport.weatherCondition.icon)
                    .font(.system(size: 32))
                    .foregroundColor(weatherColor(localReport.weatherCondition))
                VStack(alignment: .leading, spacing: 4) {
                    Text(localReport.weatherCondition.displayName)
                        .font(.headline)
                    HStack(spacing: 16) {
                        if let hi = localReport.temperatureHigh {
                            Text("High: \(hi)°C").font(.subheadline).foregroundColor(.secondary)
                        }
                        if let lo = localReport.temperatureLow {
                            Text("Low: \(lo)°C").font(.subheadline).foregroundColor(.secondary)
                        }
                        if let wind = localReport.windSpeed {
                            Label("\(wind) km/h", systemImage: "wind")
                                .font(.subheadline).foregroundColor(.secondary)
                        }
                    }
                    if !localReport.weatherNotes.isEmpty {
                        Text(localReport.weatherNotes)
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    private var djrCrewSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Crew On Site", count: localReport.crewEntries.count)
            VStack(spacing: 0) {
                ForEach(localReport.crewEntries) { entry in
                    HStack {
                        Circle()
                            .fill(Color.blue.opacity(0.1))
                            .frame(width: 36, height: 36)
                            .overlay(
                                Text(String(entry.name.prefix(1)))
                                    .font(.subheadline).bold()
                                    .foregroundColor(.blue)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).font(.subheadline)
                            Text(entry.trade).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.1f hrs", entry.hoursWorked))
                                .font(.subheadline).bold()
                            if entry.overtime > 0 {
                                Text(String(format: "+%.1f OT", entry.overtime))
                                    .font(.caption2).foregroundColor(.orange)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    if entry.id != localReport.crewEntries.last?.id {
                        Divider().padding(.leading, 60)
                    }
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    private var djrWorkSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Work Performed")
            VStack(alignment: .leading, spacing: 12) {
                if !localReport.workAreas.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.circle.fill").foregroundColor(.blue)
                        Text(localReport.workAreas.joined(separator: " · "))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Text(localReport.workPerformed.isEmpty ? "—" : localReport.workPerformed)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    private var djrEquipmentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Equipment Used", count: localReport.equipmentEntries.count)
            VStack(spacing: 0) {
                ForEach(localReport.equipmentEntries) { item in
                    HStack {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .foregroundColor(.orange)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.description).font(.subheadline)
                            if !item.notes.isEmpty {
                                Text(item.notes).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Text(String(format: "%.1f hrs", item.hours))
                            .font(.subheadline).bold()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    if item.id != localReport.equipmentEntries.last?.id {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    private var djrMaterialsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Materials Delivered", count: localReport.materialDeliveries.count)
            VStack(spacing: 0) {
                ForEach(localReport.materialDeliveries) { item in
                    HStack {
                        Image(systemName: "shippingbox.fill")
                            .foregroundColor(.brown)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.material).font(.subheadline)
                            if !item.supplier.isEmpty {
                                Text(item.supplier).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Text(item.quantity)
                            .font(.subheadline).bold()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    if item.id != localReport.materialDeliveries.last?.id {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    private var djrDelaysSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Delays & Impacts", count: localReport.delays.count)
            VStack(spacing: 0) {
                ForEach(localReport.delays) { delay in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .frame(width: 28)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(delay.type.displayName)
                                    .font(.caption).bold()
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.red.opacity(0.1))
                                    .foregroundColor(.red)
                                    .cornerRadius(6)
                                Spacer()
                                Text(String(format: "%.1f hrs lost", delay.hoursLost))
                                    .font(.caption).bold().foregroundColor(.red)
                            }
                            Text(delay.description).font(.subheadline)
                            if !delay.impactDescription.isEmpty {
                                Text(delay.impactDescription).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                    if delay.id != localReport.delays.last?.id {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    private var djrVisitorsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Visitors & Inspections")
            VStack(alignment: .leading, spacing: 12) {
                if localReport.inspectionsPassed {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                        Text("Inspections Passed").font(.subheadline).bold()
                    }
                    if !localReport.inspectionNotes.isEmpty {
                        Text(localReport.inspectionNotes)
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if !localReport.visitors.isEmpty { Divider() }
                }
                ForEach(localReport.visitors) { visitor in
                    HStack {
                        Image(systemName: "person.crop.square").foregroundColor(.teal).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(visitor.name).font(.subheadline)
                            HStack {
                                if !visitor.company.isEmpty {
                                    Text(visitor.company).font(.caption).foregroundColor(.secondary)
                                }
                                Text("·").font(.caption).foregroundColor(.secondary)
                                Text(visitor.purpose).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if !visitor.timeArrived.isEmpty {
                            Text(visitor.timeArrived).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    private var djrSafetySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Safety")
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: localReport.safetyMeetingHeld ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(localReport.safetyMeetingHeld ? .green : .secondary)
                    Text("Safety Toolbox Meeting")
                        .font(.subheadline)
                    Spacer()
                    if localReport.firstAidIncidents > 0 {
                        Label("\(localReport.firstAidIncidents) first aid", systemImage: "cross.fill")
                            .font(.caption).foregroundColor(.red)
                    }
                }
                if localReport.safetyMeetingHeld && !localReport.safetyMeetingTopic.isEmpty {
                    Text("Topic: \(localReport.safetyMeetingTopic)")
                        .font(.caption).foregroundColor(.secondary)
                }
                if !localReport.safetyObservations.isEmpty {
                    Divider()
                    Text(localReport.safetyObservations)
                        .font(.subheadline)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }

    // MARK: - PDF Export

    private func exportPDF() {
        isGeneratingPDF = true
        let copy = localReport
        let projectName = store.projects.first { $0.id == copy.projectID }?.name ?? "Project"
        Task.detached(priority: .userInitiated) {
            let pdfData = DJRPDFRenderer(report: copy, projectName: projectName).render()
            let safe = copy.reportNumber.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("DJR_\(safe).pdf")
            try? pdfData.write(to: url)
            await MainActor.run {
                shareItems = [url]
                isGeneratingPDF = false
                showShareSheet = true
            }
        }
    }

    private func weatherColor(_ w: WeatherCondition) -> Color {
        switch w {
        case .sunny:                  return .orange
        case .partlyCloudy:           return .yellow
        case .overcast, .fog:         return .gray
        case .lightRain, .heavyRain:  return .blue
        case .snow, .freezingRain:    return .cyan
        case .windy:                  return .teal
        }
    }
}

// MARK: - DJR Stat Cell

private struct DJRStatCell: View {
    let value: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundColor(color).font(.system(size: 16))
            Text(value).font(.headline).bold()
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - DJR Create / Edit View

struct DJRCreateEditView: View {
    let projectID: UUID
    var existingReport: DailyJobReport? = nil
    var onSave: ((DailyJobReport) -> Void)? = nil

    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    // MARK: State
    @State private var reportDate    = Date()
    @State private var status        = DJRStatus.draft
    @State private var weather       = WeatherCondition.sunny
    @State private var tempHigh      = ""
    @State private var tempLow       = ""
    @State private var windSpeed     = ""
    @State private var weatherNotes  = ""
    @State private var workPerformed = ""
    @State private var workAreas     = ""
    @State private var percentComplete = ""
    @State private var notes         = ""

    @State private var crewEntries: [DJRCrewEntry] = []
    @State private var equipmentEntries: [DJREquipmentEntry] = []
    @State private var materialDeliveries: [DJRMaterialDelivery] = []
    @State private var delays: [DJRDelay] = []
    @State private var visitors: [DJRVisitor] = []

    @State private var safetyMeetingHeld = false
    @State private var safetyTopic = ""
    @State private var safetyObs = ""
    @State private var firstAidCount = ""
    @State private var inspectionsPassed = false
    @State private var inspectionNotes = ""

    // Photos
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var photoDataArray: [Data] = []

    // Add-item sheets
    @State private var showAddCrew = false
    @State private var showAddEquip = false
    @State private var showAddMaterial = false
    @State private var showAddDelay = false
    @State private var showAddVisitor = false

    // MARK: - Init

    init(projectID: UUID, existingReport: DailyJobReport? = nil, onSave: ((DailyJobReport) -> Void)? = nil) {
        self.projectID = projectID
        self.existingReport = existingReport
        self.onSave = onSave

        if let r = existingReport {
            _reportDate      = State(initialValue: r.reportDate)
            _status          = State(initialValue: r.status)
            _weather         = State(initialValue: r.weatherCondition)
            _tempHigh        = State(initialValue: r.temperatureHigh.map { "\($0)" } ?? "")
            _tempLow         = State(initialValue: r.temperatureLow.map { "\($0)" } ?? "")
            _windSpeed       = State(initialValue: r.windSpeed.map { "\($0)" } ?? "")
            _weatherNotes    = State(initialValue: r.weatherNotes)
            _workPerformed   = State(initialValue: r.workPerformed)
            _workAreas       = State(initialValue: r.workAreas.joined(separator: ", "))
            _percentComplete = State(initialValue: r.percentComplete.map { "\($0)" } ?? "")
            _notes           = State(initialValue: r.notes)
            _crewEntries     = State(initialValue: r.crewEntries)
            _equipmentEntries = State(initialValue: r.equipmentEntries)
            _materialDeliveries = State(initialValue: r.materialDeliveries)
            _delays          = State(initialValue: r.delays)
            _visitors        = State(initialValue: r.visitors)
            _safetyMeetingHeld = State(initialValue: r.safetyMeetingHeld)
            _safetyTopic     = State(initialValue: r.safetyMeetingTopic)
            _safetyObs       = State(initialValue: r.safetyObservations)
            _firstAidCount   = State(initialValue: r.firstAidIncidents > 0 ? "\(r.firstAidIncidents)" : "")
            _inspectionsPassed = State(initialValue: r.inspectionsPassed)
            _inspectionNotes   = State(initialValue: r.inspectionNotes)
            _photoDataArray    = State(initialValue: r.photoData)
        }
    }

    var body: some View {
        NavigationStack {
            Form {

                // MARK: Date & Status
                Section("Report Info") {
                    DatePicker("Date", selection: $reportDate, displayedComponents: .date)
                    Picker("Status", selection: $status) {
                        ForEach(DJRStatus.allCases, id: \.self) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                }

                // MARK: Weather
                Section("Weather") {
                    Picker("Condition", selection: $weather) {
                        ForEach(WeatherCondition.allCases, id: \.self) { w in
                            Label(w.displayName, systemImage: w.icon).tag(w)
                        }
                    }
                    HStack {
                        TextField("High °C", text: $tempHigh)
                            .keyboardType(.numberPad)
                        Divider()
                        TextField("Low °C", text: $tempLow)
                            .keyboardType(.numberPad)
                        Divider()
                        TextField("Wind km/h", text: $windSpeed)
                            .keyboardType(.numberPad)
                    }
                    TextField("Weather notes…", text: $weatherNotes, axis: .vertical)
                        .lineLimit(2...4)
                }

                // MARK: Crew
                Section {
                    ForEach($crewEntries) { $entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                TextField("Name", text: $entry.name)
                                    .font(.subheadline)
                                TextField("Trade", text: $entry.trade)
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            TextField("Hrs", value: $entry.hoursWorked, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 44)
                        }
                    }
                    .onDelete { crewEntries.remove(atOffsets: $0) }
                    Button {
                        crewEntries.append(DJRCrewEntry(name: "", trade: "Labourer", hoursWorked: 8))
                    } label: {
                        Label("Add Crew Member", systemImage: "person.badge.plus")
                    }
                } header: {
                    Text("Crew On Site (\(crewEntries.count))")
                }

                // MARK: Work Performed
                Section("Work Performed") {
                    TextField("Areas worked (e.g. Grid A1, North Wall…)", text: $workAreas)
                    TextField("Describe work done today…", text: $workPerformed, axis: .vertical)
                        .lineLimit(4...10)
                    HStack {
                        Text("% Complete")
                        Spacer()
                        TextField("e.g. 25", text: $percentComplete)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Text("%").foregroundColor(.secondary)
                    }
                }

                // MARK: Equipment
                Section {
                    ForEach($equipmentEntries) { $item in
                        HStack {
                            TextField("Equipment description", text: $item.description)
                            Spacer()
                            TextField("Hrs", value: $item.hours, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 44)
                        }
                    }
                    .onDelete { equipmentEntries.remove(atOffsets: $0) }
                    Button {
                        equipmentEntries.append(DJREquipmentEntry(description: "", hours: 8))
                    } label: {
                        Label("Add Equipment", systemImage: "plus")
                    }
                } header: {
                    Text("Equipment (\(equipmentEntries.count))")
                }

                // MARK: Materials
                Section {
                    ForEach($materialDeliveries) { $item in
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Material", text: $item.material)
                            HStack {
                                TextField("Quantity", text: $item.quantity)
                                Divider()
                                TextField("Supplier", text: $item.supplier)
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                    }
                    .onDelete { materialDeliveries.remove(atOffsets: $0) }
                    Button {
                        materialDeliveries.append(DJRMaterialDelivery(material: "", quantity: ""))
                    } label: {
                        Label("Add Delivery", systemImage: "shippingbox")
                    }
                } header: {
                    Text("Materials Delivered (\(materialDeliveries.count))")
                }

                // MARK: Delays
                Section {
                    ForEach($delays) { $delay in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Picker("Type", selection: $delay.type) {
                                    ForEach(DelayType.allCases, id: \.self) { t in
                                        Text(t.displayName).tag(t)
                                    }
                                }
                                .pickerStyle(.menu)
                                Spacer()
                                TextField("Hrs", value: $delay.hoursLost, format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 44)
                            }
                            TextField("Description…", text: $delay.description, axis: .vertical)
                                .lineLimit(2...4)
                                .font(.subheadline)
                        }
                    }
                    .onDelete { delays.remove(atOffsets: $0) }
                    Button {
                        delays.append(DJRDelay(type: .weather, description: "", hoursLost: 0))
                    } label: {
                        Label("Add Delay", systemImage: "exclamationmark.triangle")
                    }
                } header: {
                    Text("Delays & Impacts (\(delays.count))")
                }

                // MARK: Visitors
                Section {
                    ForEach($visitors) { $visitor in
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Name", text: $visitor.name)
                            HStack {
                                TextField("Company", text: $visitor.company)
                                Divider()
                                TextField("Purpose", text: $visitor.purpose)
                                Divider()
                                TextField("Time", text: $visitor.timeArrived).frame(width: 60)
                            }
                            .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .onDelete { visitors.remove(atOffsets: $0) }
                    Button {
                        visitors.append(DJRVisitor(name: "", purpose: ""))
                    } label: {
                        Label("Add Visitor", systemImage: "person.crop.square.badge.plus")
                    }

                    Toggle("Inspections Passed", isOn: $inspectionsPassed)
                    if inspectionsPassed {
                        TextField("Inspection notes…", text: $inspectionNotes, axis: .vertical)
                            .lineLimit(2...4)
                            .font(.subheadline)
                    }
                } header: {
                    Text("Visitors & Inspections")
                }

                // MARK: Safety
                Section("Safety") {
                    Toggle("Toolbox Safety Meeting", isOn: $safetyMeetingHeld)
                    if safetyMeetingHeld {
                        TextField("Topic discussed", text: $safetyTopic)
                    }
                    TextField("Safety observations…", text: $safetyObs, axis: .vertical)
                        .lineLimit(2...4)
                    HStack {
                        Text("First Aid Incidents")
                        Spacer()
                        TextField("0", text: $firstAidCount)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 44)
                    }
                }

                // MARK: Notes
                Section("Notes") {
                    TextField("Additional notes…", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                // MARK: Site Photos
                Section {
                    // Thumbnail grid
                    if !photoDataArray.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(photoDataArray.enumerated()), id: \.offset) { idx, data in
                                    ZStack(alignment: .topTrailing) {
                                        if let ui = UIImage(data: data) {
                                            Image(uiImage: ui)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: 90, height: 90)
                                                .clipped()
                                                .cornerRadius(8)
                                        }
                                        Button {
                                            photoDataArray.remove(at: idx)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.white)
                                                .background(Color.black.opacity(0.5))
                                                .clipShape(Circle())
                                        }
                                        .padding(4)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    PhotosPicker(
                        selection: $selectedPhotoItems,
                        maxSelectionCount: 20,
                        matching: .images
                    ) {
                        Label(
                            photoDataArray.isEmpty
                                ? "Add Site Photos"
                                : "Add More Photos (\(photoDataArray.count) selected)",
                            systemImage: "camera.fill"
                        )
                    }
                    .onChange(of: selectedPhotoItems) { items in
                        Task {
                            for item in items {
                                if let data = try? await item.loadTransferable(type: Data.self) {
                                    photoDataArray.append(compressPhoto(data))
                                }
                            }
                            selectedPhotoItems = []
                        }
                    }
                } header: {
                    Text("Site Photos (\(photoDataArray.count))")
                }
            }
            .navigationTitle(existingReport == nil ? "New Daily Report" : "Edit Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }.bold()
                }
            }
        }
    }

    // MARK: - Save

    private func save() {
        var report = existingReport ?? DailyJobReport(
            projectID: projectID,
            reportNumber: store.nextDJRNumber(for: projectID),
            reportDate: reportDate,
            submittedByName: store.currentUser?.fullName ?? "Unknown"
        )

        report.reportDate       = reportDate
        report.status           = status
        report.weatherCondition = weather
        report.temperatureHigh  = Int(tempHigh)
        report.temperatureLow   = Int(tempLow)
        report.windSpeed        = Int(windSpeed)
        report.weatherNotes     = weatherNotes
        report.workPerformed    = workPerformed
        report.workAreas        = workAreas.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        report.percentComplete  = Int(percentComplete)
        report.notes            = notes
        report.crewEntries      = crewEntries.filter { !$0.name.isEmpty }
        report.equipmentEntries = equipmentEntries.filter { !$0.description.isEmpty }
        report.materialDeliveries = materialDeliveries.filter { !$0.material.isEmpty }
        report.delays           = delays
        report.visitors         = visitors.filter { !$0.name.isEmpty }
        report.safetyMeetingHeld = safetyMeetingHeld
        report.safetyMeetingTopic = safetyTopic
        report.safetyObservations = safetyObs
        report.firstAidIncidents = Int(firstAidCount) ?? 0
        report.inspectionsPassed = inspectionsPassed
        report.inspectionNotes   = inspectionNotes
        report.photoData         = photoDataArray

        if existingReport != nil {
            store.updateDJR(report)
            onSave?(report)
        } else {
            store.addDJR(report)
        }
        dismiss()
    }
}

// MARK: - Photo Grid

struct DJRPhotoGrid: View {
    let photoData: [Data]
    @State private var selectedIndex: Int? = nil

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Array(photoData.enumerated()), id: \.offset) { idx, data in
                if let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                        .cornerRadius(8)
                        .onTapGesture { selectedIndex = idx }
                }
            }
        }
        .sheet(item: Binding(
            get: { selectedIndex.map { PhotoIndexWrapper(index: $0) } },
            set: { selectedIndex = $0?.index }
        )) { wrapper in
            DJRPhotoFullScreenView(
                photoData: photoData,
                startIndex: wrapper.index
            )
        }
    }
}

private struct PhotoIndexWrapper: Identifiable {
    let index: Int
    var id: Int { index }
}

struct DJRPhotoFullScreenView: View {
    let photoData: [Data]
    let startIndex: Int
    @Environment(\.dismiss) var dismiss
    @State private var currentIndex: Int

    init(photoData: [Data], startIndex: Int) {
        self.photoData  = photoData
        self.startIndex = startIndex
        _currentIndex   = State(initialValue: startIndex)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $currentIndex) {
                ForEach(Array(photoData.enumerated()), id: \.offset) { idx, data in
                    if let ui = UIImage(data: data) {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFit()
                            .tag(idx)
                    }
                }
            }
            .tabViewStyle(.page)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("\(currentIndex + 1) of \(photoData.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.bold().foregroundColor(.white)
                }
            }
            .toolbarBackground(Color.black.opacity(0.6), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

// MARK: - DJR Section (Inline in Project Detail)

struct DJRProjectSection: View {
    let project: Project
    @EnvironmentObject var store: AppStore
    @State private var showAll = false
    @State private var showCreate = false

    private var reports: [DailyJobReport] {
        store.dailyJobReports(for: project.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Daily Reports", count: reports.count)
                Spacer()
                if !reports.isEmpty {
                    Button("View All") { showAll = true }
                        .font(.subheadline)
                        .padding(.trailing)
                }
            }

            if reports.isEmpty {
                EmptyCard(message: "No daily reports yet. Tap + to create the first one.")
            } else {
                VStack(spacing: 0) {
                    ForEach(reports.prefix(3)) { report in
                        NavigationLink {
                            DJRDetailView(report: report)
                        } label: {
                            DJRRow(report: report)
                                .padding(.horizontal)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        if report.id != reports.prefix(3).last?.id {
                            Divider().padding(.leading, 72)
                        }
                    }
                }
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
            }

            Button {
                showCreate = true
            } label: {
                Label("New Daily Report", systemImage: "plus.circle.fill")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.blue.opacity(0.1))
                    .foregroundColor(.blue)
                    .cornerRadius(12)
            }
            .padding(.horizontal)
        }
        .sheet(isPresented: $showAll) {
            DailyJobReportListView(project: project)
        }
        .sheet(isPresented: $showCreate) {
            DJRCreateEditView(projectID: project.id)
        }
    }
}

// MARK: - DJR PDF Renderer

struct DJRPDFRenderer {
    let report: DailyJobReport
    let projectName: String

    private let pageW: CGFloat = 612
    private let pageH: CGFloat = 792
    private let margin: CGFloat = 44
    private var cW: CGFloat { pageW - margin * 2 }

    func render() -> Data {
        let fmt = UIGraphicsPDFRendererFormat()
        fmt.documentInfo = [
            kCGPDFContextTitle as String: "\(report.reportNumber) — Daily Job Report"
        ]
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: pageW, height: pageH),
            format: fmt
        )
        return renderer.pdfData { ctx in
            ctx.beginPage()
            var y = drawHeader(y: margin)
            y = drawMeta(y: y)
            y = drawWeather(y: y)
            if !report.crewEntries.isEmpty { y = drawCrew(ctx: ctx, y: y) }
            y = drawWork(ctx: ctx, y: y)
            if !report.equipmentEntries.isEmpty { y = drawEquipment(ctx: ctx, y: y) }
            if !report.materialDeliveries.isEmpty { y = drawMaterials(ctx: ctx, y: y) }
            if !report.delays.isEmpty { y = drawDelays(ctx: ctx, y: y) }
            y = drawSafety(ctx: ctx, y: y)
            if !report.notes.isEmpty { y = drawNotes(ctx: ctx, y: y) }
            if !report.photoData.isEmpty { drawPhotos(ctx: ctx, y: y) }
            drawFooter()
        }
    }

    // MARK: Header

    private func drawHeader(y: CGFloat) -> CGFloat {
        let settings = AppSettings.shared
        var posY = y

        // Company name
        let companyAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .heavy),
            .foregroundColor: UIColor(red: 0.07, green: 0.15, blue: 0.35, alpha: 1)
        ]
        let companyName = settings.companyName.isEmpty ? "Aski IQ" : settings.companyName
        (companyName as NSString).draw(at: CGPoint(x: margin, y: posY), withAttributes: companyAttr)
        posY += 22

        // Report type
        let subAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: UIColor.darkGray
        ]
        ("DAILY JOB REPORT" as NSString).draw(at: CGPoint(x: margin, y: posY), withAttributes: subAttr)

        // DJR badge
        let badgeText = report.status.displayName.uppercased()
        let badgeAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: UIColor.white
        ]
        let badgeSize = (badgeText as NSString).size(withAttributes: badgeAttr)
        let badgeRect = CGRect(x: pageW - margin - badgeSize.width - 16,
                               y: posY - 2,
                               width: badgeSize.width + 16,
                               height: 18)
        UIBezierPath(roundedRect: badgeRect, cornerRadius: 4).fill()
        statusColor(report.status).setFill()
        UIBezierPath(roundedRect: badgeRect, cornerRadius: 4).fill()
        (badgeText as NSString).draw(
            at: CGPoint(x: badgeRect.minX + 8, y: badgeRect.minY + 2),
            withAttributes: badgeAttr
        )

        posY += 18
        // Divider
        UIColor(red: 0.07, green: 0.15, blue: 0.35, alpha: 1).setFill()
        UIBezierPath(rect: CGRect(x: margin, y: posY, width: cW, height: 2)).fill()
        return posY + 10
    }

    // MARK: Meta block

    private func drawMeta(y: CGFloat) -> CGFloat {
        let lAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8.5, weight: .semibold), .foregroundColor: UIColor.gray]
        let vAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9.5), .foregroundColor: UIColor.black]
        let colW = cW / 4
        let leftX = margin, col2 = margin + colW, col3 = margin + colW * 2, col4 = margin + colW * 3
        var posY = y

        ("REPORT #" as NSString).draw(at: CGPoint(x: leftX, y: posY), withAttributes: lAttr)
        ("PROJECT" as NSString).draw(at: CGPoint(x: col2, y: posY), withAttributes: lAttr)
        ("DATE" as NSString).draw(at: CGPoint(x: col3, y: posY), withAttributes: lAttr)
        ("SUBMITTED BY" as NSString).draw(at: CGPoint(x: col4, y: posY), withAttributes: lAttr)
        posY += 12

        (report.reportNumber as NSString).draw(at: CGPoint(x: leftX, y: posY), withAttributes: vAttr)
        (projectName as NSString).draw(at: CGPoint(x: col2, y: posY), withAttributes: vAttr)
        let dateStr = report.reportDate.formatted(date: .abbreviated, time: .omitted)
        (dateStr as NSString).draw(at: CGPoint(x: col3, y: posY), withAttributes: vAttr)
        (report.submittedByName as NSString).draw(at: CGPoint(x: col4, y: posY), withAttributes: vAttr)
        posY += 20

        UIColor.lightGray.setFill()
        UIBezierPath(rect: CGRect(x: margin, y: posY, width: cW, height: 0.5)).fill()
        return posY + 10
    }

    // MARK: Weather

    private func drawWeather(y: CGFloat) -> CGFloat {
        var posY = drawSectionTitle("WEATHER CONDITIONS", y: y)
        let vAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9.5), .foregroundColor: UIColor.black]
        let lAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8.5, weight: .semibold), .foregroundColor: UIColor.gray]
        let col = cW / 4

        var parts = [String]()
        parts.append(report.weatherCondition.displayName)
        if let h = report.temperatureHigh { parts.append("High \(h)°C") }
        if let l = report.temperatureLow  { parts.append("Low \(l)°C") }
        if let w = report.windSpeed       { parts.append("Wind \(w) km/h") }

        (parts.joined(separator: "   ·   ") as NSString).draw(
            at: CGPoint(x: margin, y: posY), withAttributes: vAttr)
        posY += 14

        if !report.weatherNotes.isEmpty {
            (report.weatherNotes as NSString).draw(
                at: CGPoint(x: margin, y: posY), withAttributes: lAttr)
            posY += 12
        }
        return posY + 6
    }

    // MARK: Crew

    private func drawCrew(ctx: UIGraphicsPDFRendererContext, y: CGFloat) -> CGFloat {
        var posY = drawSectionTitle("CREW ON SITE (\(report.crewEntries.count) workers — \(String(format: "%.1f", report.totalHoursWorked)) hrs total)", y: y)
        let hAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: UIColor.white]
        let vAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.black]

        let col1 = cW * 0.45, col2 = cW * 0.30, col3 = cW * 0.15, col4 = cW * 0.10

        // Header row
        UIColor(red: 0.07, green: 0.15, blue: 0.35, alpha: 1).setFill()
        UIBezierPath(rect: CGRect(x: margin, y: posY, width: cW, height: 16)).fill()
        ("NAME" as NSString).draw(at: CGPoint(x: margin + 4, y: posY + 2), withAttributes: hAttr)
        ("TRADE" as NSString).draw(at: CGPoint(x: margin + col1 + 4, y: posY + 2), withAttributes: hAttr)
        ("HOURS" as NSString).draw(at: CGPoint(x: margin + col1 + col2 + 4, y: posY + 2), withAttributes: hAttr)
        ("OT" as NSString).draw(at: CGPoint(x: margin + col1 + col2 + col3 + 4, y: posY + 2), withAttributes: hAttr)
        posY += 16

        for (i, entry) in report.crewEntries.enumerated() {
            if posY + 20 > pageH - margin { ctx.beginPage(); posY = margin }
            let bg = i % 2 == 0 ? UIColor(white: 0.97, alpha: 1) : UIColor.white
            bg.setFill()
            UIBezierPath(rect: CGRect(x: margin, y: posY, width: cW, height: 16)).fill()
            (entry.name as NSString).draw(at: CGPoint(x: margin + 4, y: posY + 2), withAttributes: vAttr)
            (entry.trade as NSString).draw(at: CGPoint(x: margin + col1 + 4, y: posY + 2), withAttributes: vAttr)
            (String(format: "%.1f", entry.hoursWorked) as NSString).draw(at: CGPoint(x: margin + col1 + col2 + 4, y: posY + 2), withAttributes: vAttr)
            if entry.overtime > 0 {
                (String(format: "%.1f", entry.overtime) as NSString).draw(at: CGPoint(x: margin + col1 + col2 + col3 + 4, y: posY + 2), withAttributes: vAttr)
            }
            posY += 16
        }
        return posY + 10
    }

    // MARK: Work

    private func drawWork(ctx: UIGraphicsPDFRendererContext, y: CGFloat) -> CGFloat {
        var posY = y
        if posY + 60 > pageH - margin { ctx.beginPage(); posY = margin }
        posY = drawSectionTitle("WORK PERFORMED", y: posY)
        let vAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9.5), .foregroundColor: UIColor.black]
        let capAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8.5), .foregroundColor: UIColor.darkGray]

        if !report.workAreas.isEmpty {
            ("Areas: " + report.workAreas.joined(separator: " · ") as NSString).draw(
                at: CGPoint(x: margin, y: posY), withAttributes: capAttr)
            posY += 14
        }
        if let pct = report.percentComplete {
            ("Project completion estimate: \(pct)%" as NSString).draw(
                at: CGPoint(x: margin, y: posY), withAttributes: capAttr)
            posY += 14
        }

        let paraStyle = NSMutableParagraphStyle()
        paraStyle.lineSpacing = 2
        let textAttr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9.5),
            .foregroundColor: UIColor.black,
            .paragraphStyle: paraStyle
        ]
        let textRect = CGRect(x: margin, y: posY, width: cW, height: 200)
        let attrStr = NSAttributedString(string: report.workPerformed, attributes: textAttr)
        let textH = attrStr.boundingRect(with: CGSize(width: cW, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin], context: nil).height
        attrStr.draw(in: CGRect(x: margin, y: posY, width: cW, height: textH + 4))
        return posY + textH + 16
    }

    // MARK: Equipment

    private func drawEquipment(ctx: UIGraphicsPDFRendererContext, y: CGFloat) -> CGFloat {
        var posY = y
        if posY + 40 > pageH - margin { ctx.beginPage(); posY = margin }
        posY = drawSectionTitle("EQUIPMENT USED", y: posY)
        let vAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.black]
        for item in report.equipmentEntries {
            if posY + 16 > pageH - margin { ctx.beginPage(); posY = margin }
            ("• \(item.description) — \(String(format: "%.1f", item.hours)) hrs" as NSString)
                .draw(at: CGPoint(x: margin + 4, y: posY), withAttributes: vAttr)
            posY += 14
        }
        return posY + 8
    }

    // MARK: Materials

    private func drawMaterials(ctx: UIGraphicsPDFRendererContext, y: CGFloat) -> CGFloat {
        var posY = y
        if posY + 40 > pageH - margin { ctx.beginPage(); posY = margin }
        posY = drawSectionTitle("MATERIALS DELIVERED", y: posY)
        let vAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.black]
        for item in report.materialDeliveries {
            if posY + 16 > pageH - margin { ctx.beginPage(); posY = margin }
            var line = "• \(item.material) — \(item.quantity)"
            if !item.supplier.isEmpty { line += " (\(item.supplier))" }
            (line as NSString).draw(at: CGPoint(x: margin + 4, y: posY), withAttributes: vAttr)
            posY += 14
        }
        return posY + 8
    }

    // MARK: Delays

    private func drawDelays(ctx: UIGraphicsPDFRendererContext, y: CGFloat) -> CGFloat {
        var posY = y
        if posY + 40 > pageH - margin { ctx.beginPage(); posY = margin }
        posY = drawSectionTitle("DELAYS & IMPACTS (\(String(format: "%.1f", report.totalHoursLost)) hrs total)", y: posY)
        let vAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.black]
        let capAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8.5), .foregroundColor: UIColor.darkGray]
        for delay in report.delays {
            if posY + 28 > pageH - margin { ctx.beginPage(); posY = margin }
            ("[\(delay.type.displayName)] \(String(format: "%.1f", delay.hoursLost)) hrs lost" as NSString)
                .draw(at: CGPoint(x: margin + 4, y: posY), withAttributes: vAttr)
            posY += 13
            (delay.description as NSString).draw(at: CGPoint(x: margin + 12, y: posY), withAttributes: capAttr)
            posY += 13
        }
        return posY + 8
    }

    // MARK: Safety

    private func drawSafety(ctx: UIGraphicsPDFRendererContext, y: CGFloat) -> CGFloat {
        var posY = y
        if posY + 40 > pageH - margin { ctx.beginPage(); posY = margin }
        posY = drawSectionTitle("SAFETY", y: posY)
        let vAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.black]
        let meeting = report.safetyMeetingHeld ? "✓ Toolbox Safety Meeting Held" : "✗ No Toolbox Meeting"
        (meeting as NSString).draw(at: CGPoint(x: margin + 4, y: posY), withAttributes: vAttr)
        posY += 14
        if report.safetyMeetingHeld && !report.safetyMeetingTopic.isEmpty {
            let capAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8.5), .foregroundColor: UIColor.darkGray]
            ("Topic: \(report.safetyMeetingTopic)" as NSString).draw(at: CGPoint(x: margin + 12, y: posY), withAttributes: capAttr)
            posY += 13
        }
        if report.inspectionsPassed {
            ("✓ Site Inspection Passed" as NSString).draw(at: CGPoint(x: margin + 4, y: posY), withAttributes: vAttr)
            posY += 14
        }
        if report.firstAidIncidents > 0 {
            let faAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: UIColor.red]
            ("⚠ First Aid Incidents: \(report.firstAidIncidents)" as NSString).draw(at: CGPoint(x: margin + 4, y: posY), withAttributes: faAttr)
            posY += 14
        }
        return posY + 8
    }

    // MARK: Notes

    private func drawNotes(ctx: UIGraphicsPDFRendererContext, y: CGFloat) -> CGFloat {
        var posY = y
        if posY + 40 > pageH - margin { ctx.beginPage(); posY = margin }
        posY = drawSectionTitle("NOTES", y: posY)
        let vAttr: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9.5), .foregroundColor: UIColor.black]
        let textRect = CGRect(x: margin, y: posY, width: cW, height: 200)
        let attrStr = NSAttributedString(string: report.notes, attributes: vAttr)
        let h = attrStr.boundingRect(with: CGSize(width: cW, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin], context: nil).height
        attrStr.draw(in: CGRect(x: margin, y: posY, width: cW, height: h + 4))
        return posY + h + 10
    }

    // MARK: Photos

    private func drawPhotos(ctx: UIGraphicsPDFRendererContext, y: CGFloat) {
        let photos = report.photoData.compactMap { UIImage(data: $0) }
        guard !photos.isEmpty else { return }

        // Always start photos on a new page
        ctx.beginPage()
        var posY: CGFloat = margin

        posY = drawSectionTitle("SITE PHOTOS (\(photos.count))", y: posY)
        posY += 4

        let cols: CGFloat = 3
        let spacing: CGFloat = 8
        let thumbW = (cW - spacing * (cols - 1)) / cols
        let thumbH = thumbW * 0.75

        var col: Int = 0
        for photo in photos {
            let x = margin + CGFloat(col) * (thumbW + spacing)
            if posY + thumbH > pageH - margin {
                ctx.beginPage()
                posY = margin
            }
            let rect = CGRect(x: x, y: posY, width: thumbW, height: thumbH)
            // Clip to rounded rect
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 4)
            ctx.cgContext.saveGState()
            path.addClip()
            photo.draw(in: rect)
            ctx.cgContext.restoreGState()
            // Border
            UIColor.lightGray.setStroke()
            path.lineWidth = 0.5
            path.stroke()

            col += 1
            if col == Int(cols) {
                col = 0
                posY += thumbH + spacing
            }
        }
    }

    // MARK: Footer

    private func drawFooter() {
        let attr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 7.5),
            .foregroundColor: UIColor.lightGray
        ]
        let text = "\(report.reportNumber) · \(AppSettings.shared.companyName) · Generated \(Date().formatted(date: .abbreviated, time: .shortened))"
        let size = (text as NSString).size(withAttributes: attr)
        (text as NSString).draw(
            at: CGPoint(x: (pageW - size.width) / 2, y: pageH - margin + 8),
            withAttributes: attr
        )
    }

    // MARK: Helpers

    private func drawSectionTitle(_ title: String, y: CGFloat) -> CGFloat {
        let attr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: UIColor(red: 0.07, green: 0.15, blue: 0.35, alpha: 1)
        ]
        (title as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attr)
        UIColor(red: 0.07, green: 0.15, blue: 0.35, alpha: 0.3).setFill()
        UIBezierPath(rect: CGRect(x: margin, y: y + 13, width: cW, height: 0.5)).fill()
        return y + 20
    }

    private func statusColor(_ status: DJRStatus) -> UIColor {
        switch status {
        case .draft:     return UIColor.systemGray
        case .submitted: return UIColor.systemBlue
        case .approved:  return UIColor.systemGreen
        case .rejected:  return UIColor.systemRed
        }
    }
}
