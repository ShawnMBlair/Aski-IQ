// WidgetContentViews.swift
// BV APP – Individual widget content for the dashboard

import SwiftUI
import MapKit

// MARK: - Widget Content Router

struct WidgetContent: View {
    let widget: DashboardWidget
    @EnvironmentObject var store: AppStore

    var body: some View {
        switch widget.type {
        case .todaysSchedule:  TodaysScheduleWidget()
        case .activeProjects:  ActiveProjectsWidget()
        case .estimatesDue:    EstimatesDueWidget()
        case .crewStatus:      CrewStatusWidget()
        case .safetyForms:     SafetyFormsWidget()
        case .openRFIs:        OpenRFIsWidget()
        case .revenueSnapshot: RevenueSnapshotWidget()
        case .weather:         WeatherWidgetView()
        case .mapView:         MapViewWidget()
        case .recentActivity:  RecentActivityWidget()
        case .crmTasks:        CRMTasksWidget()
        case .pipelineSummary: PipelineSummaryWidget()
        case .forecastSnapshot:ForecastSnapshotWidget()
        }
    }
}

// MARK: - Weather Widget

struct WeatherWidgetView: View {
    @ObservedObject private var service = WeatherService.shared

    var body: some View {
        Group {
            if let w = service.weather {
                loadedView(w)
            } else if service.isLoading {
                widgetEmptyState(icon: "arrow.clockwise", message: "Fetching weather…")
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "cloud.slash.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Weather unavailable")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Retry") { service.fetchIfNeeded() }
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { service.fetchIfNeeded() }
    }

    private func loadedView(_ w: WeatherData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Main row: icon + temp + location
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: w.conditionIcon)
                    .font(.system(size: 30))
                    .foregroundColor(WMOCode.color(for: w.conditionCode))
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(w.tempString)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(w.conditionText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let city = w.locationName {
                    VStack(alignment: .trailing, spacing: 2) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.blue)
                        Text(city)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            Divider()
            // Stats row
            HStack(spacing: 0) {
                miniStat(icon: "thermometer.medium", value: w.feelsLikeString, color: .orange)
                Divider().frame(height: 28)
                miniStat(icon: "wind", value: w.windString, color: .blue)
                Divider().frame(height: 28)
                miniStat(icon: "humidity.fill", value: w.humidityString, color: .cyan)
                Divider().frame(height: 28)
                miniStat(icon: "cloud.rain.fill", value: w.precipString, color: .indigo)
            }
        }
    }

    private func miniStat(icon: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(color)
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Today's Schedule

struct TodaysScheduleWidget: View {
    @EnvironmentObject var store: AppStore

    private var todayEntries: [ScheduleEntry] {
        let cal = Calendar.current
        return store.scheduleEntries
            .filter { cal.isDateInToday($0.date) }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        if todayEntries.isEmpty {
            widgetEmptyState(icon: "calendar", message: "No schedule entries for today")
        } else {
            VStack(spacing: 0) {
                ForEach(todayEntries.prefix(6)) { entry in
                    NavigationLink(destination: ScheduleDayView(date: entry.date)) {
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.blue.opacity(0.12))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "person.3.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.blue)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(crewName(entry.crewID))
                                    .font(.caption).bold()
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                if let proj = store.projects.first(where: { $0.id == entry.projectID }) {
                                    Text(proj.name)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(entry.date, style: .time)
                                    .font(.caption2).bold()
                                    .foregroundColor(.blue)
                                Text("Today")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    if entry.id != todayEntries.prefix(6).last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func crewName(_ id: UUID?) -> String {
        guard let id else { return "Unassigned" }
        return store.crews.first(where: { $0.id == id })?.name ?? "Unknown Crew"
    }
}

// MARK: - Active Projects

struct ActiveProjectsWidget: View {
    @EnvironmentObject var store: AppStore

    /// Active, non-soft-deleted projects via the shared `liveActiveProjects`
    /// helper — keeps this widget in agreement with the Office dashboard
    /// "Active Projects" section.
    private var active: [Project] { store.liveActiveProjects }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            widgetKPIHeader(
                count: active.count,
                label: "Active Projects",
                color: .blue,
                destination: AnyView(ProjectListView())
            )
            Divider()
            VStack(spacing: 0) {
                ForEach(Array(active.prefix(3).enumerated()), id: \.element.id) { idx, project in
                    NavigationLink(destination: ProjectDetailView(project: project)) {
                        widgetListRow(icon: "folder.fill", iconColor: .blue,
                                      title: project.name, subtitle: project.clientName)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    if idx < min(active.count, 3) - 1 { Divider() }
                }
                if active.count > 3 {
                    Text("+ \(active.count - 3) more")
                        .font(.caption2).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 4)
                }
            }
        }
    }
}

// MARK: - Estimates Due

struct EstimatesDueWidget: View {
    @EnvironmentObject var store: AppStore

    /// Active estimates with soft-deleted rows excluded so a deleted bid
    /// can't keep ringing the "estimate due" alarm.
    private var activeEstimates: [Estimate] {
        store.liveEstimates.filter { $0.status.isActive }
            .sorted { $0.bidDueDate ?? .distantFuture < $1.bidDueDate ?? .distantFuture }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            widgetKPIHeader(
                count: activeEstimates.count,
                label: "Active Estimates",
                color: .purple,
                destination: AnyView(EstimateListView())
            )
            Divider()
            VStack(spacing: 0) {
                ForEach(Array(activeEstimates.prefix(3).enumerated()), id: \.element.id) { idx, est in
                    NavigationLink(destination: EstimateDetailView(estimate: est)) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(est.status.color))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(est.name)
                                    .font(.caption).bold()
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                if let due = est.bidDueDate {
                                    Text("Due \(due.shortDate)")
                                        .font(.caption2)
                                        .foregroundColor(due < Date() ? .red : .secondary)
                                }
                            }
                            Spacer()
                            Text(est.status.displayName)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Color(est.status.color))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color(est.status.color).opacity(0.12))
                                .cornerRadius(5)
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    if idx < min(activeEstimates.count, 3) - 1 { Divider() }
                }
            }
        }
    }
}

// MARK: - Crew Status

struct CrewStatusWidget: View {
    @EnvironmentObject var store: AppStore

    private var crewsOnDuty: [(crew: Crew, projectName: String)] {
        let cal = Calendar.current
        let today = store.scheduleEntries.filter { cal.isDateInToday($0.date) }
        let crewIDs = Set(today.compactMap(\.crewID))
        return store.crews.filter { crewIDs.contains($0.id) }.map { crew in
            let entry = today.first { $0.crewID == crew.id }
            let proj = entry.flatMap { e in store.projects.first { $0.id == e.projectID } }
            return (crew: crew, projectName: proj?.name ?? "Site work")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            widgetKPIHeader(
                count: crewsOnDuty.count,
                label: "Crews On Duty",
                color: .orange,
                destination: AnyView(CrewListView())
            )
            Divider()
            if crewsOnDuty.isEmpty {
                widgetEmptyState(icon: "person.3", message: "No crews scheduled today")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(crewsOnDuty.prefix(5).enumerated()), id: \.element.crew.id) { idx, item in
                        NavigationLink(destination: CrewDetailView(crew: item.crew)) {
                            widgetListRow(
                                icon: "person.3.fill", iconColor: .orange,
                                title: item.crew.name, subtitle: item.projectName,
                                badge: "\(item.crew.memberIDs.count)", badgeColor: .orange
                            )
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        if idx < min(crewsOnDuty.count, 5) - 1 { Divider() }
                    }
                }
            }
        }
    }
}

// MARK: - Safety & Forms

struct SafetyFormsWidget: View {
    @EnvironmentObject var store: AppStore

    private var recentForms: [FormSubmission] {
        store.formSubmissions.sorted { $0.createdAt > $1.createdAt }.prefix(3).map { $0 }
    }

    private func templateName(_ form: FormSubmission) -> String {
        store.formTemplates.first { $0.id == form.templateID }?.name ?? "Form"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Stat pill row
            HStack(spacing: 8) {
                NavigationLink(destination: IncidentListView()) {
                    statPill(
                        count: store.openIncidents.count,
                        label: "Incidents",
                        icon: "exclamationmark.shield.fill",
                        color: store.openIncidents.isEmpty ? .green : .red
                    )
                }
                .buttonStyle(.plain)
                NavigationLink(destination: FormSubmissionListView()) {
                    statPill(
                        count: store.formSubmissions.count,
                        label: "Forms Filed",
                        icon: "doc.text.fill",
                        color: .blue
                    )
                }
                .buttonStyle(.plain)
            }
            Divider()
            // Recent forms list
            if recentForms.isEmpty {
                widgetEmptyState(icon: "doc.text", message: "No forms filed yet")
            } else {
                VStack(spacing: 5) {
                    ForEach(recentForms) { form in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.blue)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(templateName(form))
                                    .font(.caption).bold()
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Text(form.submittedBy)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(form.createdAt.shortDate)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func statPill(count: Int, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(color)
                Text("\(count)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(color)
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.08))
        .cornerRadius(10)
    }
}

// MARK: - Open RFIs

struct OpenRFIsWidget: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            widgetKPIHeader(
                count: store.openRFIs.count,
                label: "Open RFIs",
                color: .orange,
                destination: AnyView(RFIListView())
            )
            Divider()
            if store.openRFIs.isEmpty {
                widgetEmptyState(icon: "questionmark.bubble", message: "No open RFIs")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.openRFIs.prefix(3).enumerated()), id: \.element.id) { idx, rfi in
                        NavigationLink(destination: RFIDetailView(rfi: rfi)) {
                            widgetListRow(icon: rfi.priority.icon,
                                          iconColor: Color(rfi.priority.color),
                                          title: rfi.title,
                                          subtitle: rfi.status.displayName)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        if idx < min(store.openRFIs.count, 3) - 1 { Divider() }
                    }
                }
            }
        }
    }
}

// MARK: - Revenue Snapshot

struct RevenueSnapshotWidget: View {
    @EnvironmentObject var store: AppStore

    /// Live invoices (excludes soft-deleted) — drives both the total and the
    /// "N invoices" subtitle so they stay in agreement.
    private var liveInvoices: [Invoice] {
        store.invoices.filter { !$0.isDeleted }
    }
    /// Active, non-deleted estimates — the legitimate pipeline.
    private var liveActiveEstimates: [Estimate] {
        store.estimates.filter { $0.status.isActive && !$0.isDeleted }
    }
    private var totalInvoiced: Decimal {
        liveInvoices.reduce(0) { $0 + $1.total }
    }
    private var totalOverdue: Decimal {
        // overdueInvoices already excludes soft-deleted (filter at the source)
        store.overdueInvoices.reduce(0) { $0 + $1.total }
    }
    private var pipelineValue: Decimal {
        liveActiveEstimates.reduce(0) { $0 + $1.totalEstimated }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                revenueCard(
                    title: "Invoiced",
                    amount: totalInvoiced,
                    subtitle: "\(liveInvoices.count) invoices",
                    icon: "doc.plaintext.fill",
                    color: .green
                )
                revenueCard(
                    title: "Overdue",
                    amount: totalOverdue,
                    subtitle: "\(store.overdueInvoices.count) overdue",
                    icon: "exclamationmark.circle.fill",
                    color: totalOverdue > 0 ? .red : .green
                )
                revenueCard(
                    title: "Pipeline",
                    amount: pipelineValue,
                    subtitle: "\(liveActiveEstimates.count) estimates",
                    icon: "chart.line.uptrend.xyaxis",
                    color: .purple
                )
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func revenueCard(title: String, amount: Decimal, subtitle: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            Text(amount.currencyString)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07))
        .cornerRadius(10)
    }
}

// MARK: - Map View Widget

struct ProjectPin: Identifiable {
    let id: UUID
    let name: String
    let coordinate: CLLocationCoordinate2D
}

struct MapViewWidget: View {
    @EnvironmentObject var store: AppStore

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 53.5461, longitude: -113.4938),
        span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4)
    )
    @State private var pins: [ProjectPin] = []
    @State private var isGeocoding = false

    /// Active, non-soft-deleted projects — pinned on the map widget.
    private var activeProjects: [Project] { store.liveActiveProjects }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Map(coordinateRegion: $region, annotationItems: pins) { pin in
                MapAnnotation(coordinate: pin.coordinate) {
                    NavigationLink(destination: ProjectListView()) {
                        ZStack {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 30, height: 30)
                                .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 2)
                            Image(systemName: "folder.fill")
                                .font(.system(size: 13))
                                .foregroundColor(.white)
                        }
                    }
                }
            }

            HStack(spacing: 5) {
                if isGeocoding {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Image(systemName: "folder.fill")
                        .font(.caption2)
                }
                Text("\(pins.count) of \(activeProjects.count) sites mapped")
                    .font(.caption).bold()
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .cornerRadius(8)
            .padding(10)
        }
        .clipped()
        .onAppear { geocodeProjects() }
        .onChange(of: store.projects.count) { geocodeProjects() }
    }

    private func geocodeProjects() {
        let projects = activeProjects.filter { $0.siteAddress != nil }
        guard !projects.isEmpty else { return }
        isGeocoding = true
        let geocoder = CLGeocoder()
        var resolved: [ProjectPin] = []
        var remaining = projects.count

        for project in projects {
            guard let address = project.siteAddress, !address.isEmpty else {
                remaining -= 1
                if remaining == 0 { finalize(resolved) }
                continue
            }
            geocoder.geocodeAddressString(address) { placemarks, _ in
                DispatchQueue.main.async {
                    if let loc = placemarks?.first?.location?.coordinate {
                        resolved.append(ProjectPin(id: project.id, name: project.name, coordinate: loc))
                    }
                    remaining -= 1
                    if remaining == 0 { finalize(resolved) }
                }
            }
        }
    }

    private func finalize(_ resolved: [ProjectPin]) {
        pins = resolved
        isGeocoding = false
        guard let first = resolved.first else { return }
        if resolved.count == 1 {
            region = MKCoordinateRegion(
                center: first.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        } else {
            let lats  = resolved.map(\.coordinate.latitude)
            let lons  = resolved.map(\.coordinate.longitude)
            let minLat = lats.min()!, maxLat = lats.max()!
            let minLon = lons.min()!, maxLon = lons.max()!
            let center = CLLocationCoordinate2D(
                latitude:  (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            )
            let span = MKCoordinateSpan(
                latitudeDelta:  (maxLat - minLat) * 1.5 + 0.02,
                longitudeDelta: (maxLon - minLon) * 1.5 + 0.02
            )
            region = MKCoordinateRegion(center: center, span: span)
        }
    }
}

// MARK: - Recent Activity

struct RecentActivityWidget: View {
    @EnvironmentObject var store: AppStore

    private struct ActivityItem: Identifiable {
        let id = UUID()
        let icon: String
        let color: Color
        let title: String
        let subtitle: String
        let date: Date
    }

    private var items: [ActivityItem] {
        var result: [ActivityItem] = []
        // Filter soft-deleted rows out of every source. Deleted submissions /
        // timesheets were polluting the activity feed before; openIncidents
        // already excludes deleted rows at its source.
        for f in store.formSubmissions.filter({ !$0.isDeleted }).prefix(3) {
            let tName = store.formTemplates.first { $0.id == f.templateID }?.name ?? "Form"
            result.append(ActivityItem(icon: "doc.text.fill", color: .blue,
                title: tName, subtitle: "by \(f.submittedBy)", date: f.createdAt))
        }
        for i in store.openIncidents.prefix(2) {
            result.append(ActivityItem(icon: "exclamationmark.shield.fill", color: .red,
                title: i.title, subtitle: "Reported by \(i.reportedByName)", date: i.incidentDate))
        }
        for t in store.timesheetEntries.filter({ !$0.isDeleted }).prefix(2) {
            let name = store.employees.first(where: { $0.id == t.employeeID })?.fullName ?? "Unknown"
            let hours = NSDecimalNumber(decimal: t.regularHours).doubleValue
            result.append(ActivityItem(icon: "clock.fill", color: .green,
                title: "Timesheet – \(String(format: "%.1f", hours))h", subtitle: name, date: t.date))
        }
        return result.sorted { $0.date > $1.date }.prefix(6).map { $0 }
    }

    var body: some View {
        if items.isEmpty {
            widgetEmptyState(icon: "clock.arrow.circlepath", message: "No recent activity")
        } else {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(item.color.opacity(0.13))
                                .frame(width: 30, height: 30)
                            Image(systemName: item.icon)
                                .font(.system(size: 12))
                                .foregroundColor(item.color)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.caption).bold()
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Text(item.subtitle)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(item.date.shortDate)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 5)
                    if item.id != items.last?.id { Divider() }
                }
            }
        }
    }
}

// MARK: - Shared widget helpers

/// Consistent KPI header used across all widgets
func widgetKPIHeader(count: Int, label: String, color: Color, destination: AnyView) -> some View {
    HStack(alignment: .center, spacing: 0) {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        Spacer()
        NavigationLink(destination: destination) {
            HStack(spacing: 3) {
                Text("All")
                    .font(.caption2).bold()
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundColor(color)
        }
    }
}

/// Consistent list row used across all widgets
func widgetListRow(icon: String, iconColor: Color, title: String, subtitle: String, badge: String? = nil, badgeColor: Color = .secondary) -> some View {
    HStack(spacing: 8) {
        Image(systemName: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(iconColor)
            .frame(width: 20)
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption).bold()
                .foregroundColor(.primary)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        Spacer()
        if let badge {
            Text(badge)
                .font(.caption2).bold()
                .foregroundColor(badgeColor)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(badgeColor.opacity(0.12))
                .cornerRadius(5)
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
    }
}

func widgetEmptyState(icon: String, message: String) -> some View {
    VStack(spacing: 8) {
        Image(systemName: icon)
            .font(.title2)
            .foregroundColor(Color(.tertiaryLabel))
        Text(message)
            .font(.caption)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

// String-based color name → SwiftUI Color (matches the app's existing raw-value pattern)
private extension Color {
    init(_ name: String) {
        switch name {
        case "red":       self = .red
        case "orange":    self = .orange
        case "yellow":    self = .yellow
        case "green":     self = .green
        case "blue":      self = .blue
        case "purple":    self = .purple
        case "indigo":    self = .indigo
        case "teal":      self = .teal
        case "mint":      self = .mint
        case "cyan":      self = .cyan
        case "gray":      self = .gray
        case "secondary": self = Color(.secondaryLabel)
        default:          self = .secondary
        }
    }
}

// MARK: - CRM Tasks Widget

struct CRMTasksWidget: View {
    @EnvironmentObject var store: AppStore

    private var myTasks: [CRMTask] {
        let uid = store.currentUser?.id
        return store.crmTasks
            .filter { $0.status != .done && ($0.assignedToID == uid || uid == nil) }
            .sorted { lhs, rhs in
                if lhs.isOverdue != rhs.isOverdue { return lhs.isOverdue }
                switch (lhs.dueDate, rhs.dueDate) {
                case let (l?, r?): return l < r
                case (nil, _?): return false
                default: return true
                }
            }
    }

    private var overdueCount: Int { myTasks.filter(\.isOverdue).count }

    private var dueTodayCount: Int {
        myTasks.filter { task in
            guard let d = task.dueDate else { return false }
            return !task.isOverdue && Calendar.current.isDateInToday(d)
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statPill(count: overdueCount,   label: "Overdue",   color: overdueCount > 0 ? .red : .green)
                statPill(count: dueTodayCount,  label: "Due Today", color: dueTodayCount > 0 ? .orange : .green)
            }
            Divider()
            if myTasks.isEmpty {
                widgetEmptyState(icon: "checklist", message: "No open tasks assigned to you")
            } else {
                VStack(spacing: 5) {
                    ForEach(myTasks.prefix(5)) { task in
                        NavigationLink(destination: CRMTaskListView()) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(task.effectiveStatusColor)
                                    .frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(task.title)
                                        .font(.caption).bold()
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    if let due = task.dueDate {
                                        Text(task.isOverdue ? "Overdue · \(due.shortDate)" : due.shortDate)
                                            .font(.caption2)
                                            .foregroundColor(task.isOverdue ? .red : .secondary)
                                    }
                                }
                                Spacer()
                                priorityBadge(task.priority)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if myTasks.count > 5 {
                        Text("+ \(myTasks.count - 5) more")
                            .font(.caption2).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func statPill(count: Int, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text("\(count)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.08))
        .cornerRadius(10)
    }

    private func priorityBadge(_ priority: CRMTaskPriority) -> some View {
        let color: Color = priority == .urgent ? .red : priority == .high ? .orange : .clear
        return Group {
            if priority == .urgent || priority == .high {
                Text(priority.rawValue)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(color)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(color.opacity(0.12))
                    .cornerRadius(5)
            }
        }
    }
}

// MARK: - Pipeline Summary Widget

struct PipelineSummaryWidget: View {
    @EnvironmentObject var store: AppStore

    private var activeOpps: [CRMOpportunity] {
        store.crmOpportunities
            .filter(\.isActive)
            .sorted { $0.value > $1.value }
    }

    private var totalWeighted: Decimal {
        activeOpps.reduce(0) { $0 + $1.weightedValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            pipelineHeader
            Divider()
            pipelineList
        }
    }

    private var pipelineHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                Text(totalWeighted.currencyString)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.indigo)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("Weighted Pipeline · \(activeOpps.count) deals")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            NavigationLink(destination: CRMHubView()) {
                Label("Pipeline", systemImage: "arrow.right")
                    .font(.caption2).bold()
                    .foregroundColor(.indigo)
            }
        }
    }

    @ViewBuilder
    private var pipelineList: some View {
        if activeOpps.isEmpty {
            widgetEmptyState(icon: "chart.bar", message: "No active opportunities")
        } else {
            VStack(spacing: 5) {
                ForEach(Array(activeOpps.prefix(5)), id: \.id) { opp in
                    PipelineOppRow(opp: opp)
                }
                if activeOpps.count > 5 {
                    Text("+ \(activeOpps.count - 5) more")
                        .font(.caption2).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }
}

private struct PipelineOppRow: View {
    let opp: CRMOpportunity
    var body: some View {
        NavigationLink(destination: CRMHubView()) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.indigo.opacity(0.10))
                        .frame(width: 28, height: 28)
                    Text("\(opp.probability)%")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.indigo)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(opp.title)
                        .font(.caption).bold()
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(opp.stage.rawValue)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(opp.value.currencyString)
                    .font(.caption2).bold()
                    .foregroundColor(.primary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Forecast Snapshot Widget

struct ForecastSnapshotWidget: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var settings = AppSettings.shared

    private var forecast: [ForecastMonth] { store.forecastForYear() }

    private var wonYTD: Decimal { forecast.filter(\.isPast).reduce(0) { $0 + $1.won } }
    private var weightedRemaining: Decimal { forecast.filter { !$0.isPast }.reduce(0) { $0 + $1.forecast } }
    private var annualTarget: Decimal { Decimal(settings.annualRevenueTarget) }

    private var progressFraction: Double {
        guard annualTarget > 0 else { return 0 }
        let total = wonYTD + weightedRemaining
        return min(NSDecimalNumber(decimal: total / annualTarget).doubleValue, 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                kpiCard(title: "Won YTD",  value: wonYTD,            color: .green)
                kpiCard(title: "Forecast", value: weightedRemaining, color: .blue)
                if annualTarget > 0 {
                    kpiCard(title: "Target", value: annualTarget, color: .orange)
                }
            }
            if annualTarget > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(.systemFill))
                                .frame(height: 8)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(progressFraction >= 1 ? Color.green : Color.blue)
                                .frame(width: max(geo.size.width * progressFraction, 4), height: 8)
                        }
                    }
                    .frame(height: 8)
                    Text("\(Int(progressFraction * 100))% of annual target")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Divider()
            NavigationLink(destination: CRMHubView()) {
                HStack {
                    Text("View Revenue Forecast")
                        .font(.caption).bold()
                        .foregroundColor(.green)
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func kpiCard(title: String, value: Decimal, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
            Text(value.currencyString)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(color)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07))
        .cornerRadius(8)
    }
}
