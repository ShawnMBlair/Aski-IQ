// DashboardWidgetModel.swift
// BV APP – Widget Dashboard Models & Layout Manager

import Foundation
import SwiftUI
import Combine

// MARK: - Widget Type

enum WidgetType: String, Codable, CaseIterable {
    case todaysSchedule   = "todays_schedule"
    case activeProjects   = "active_projects"
    case estimatesDue     = "estimates_due"
    case crewStatus       = "crew_status"
    case safetyForms      = "safety_forms"
    case openRFIs         = "open_rfis"
    case revenueSnapshot  = "revenue_snapshot"
    case weather          = "weather"
    case mapView          = "map_view"
    case recentActivity   = "recent_activity"
    case crmTasks         = "crm_tasks"
    case pipelineSummary  = "pipeline_summary"
    case forecastSnapshot = "forecast_snapshot"

    var displayName: String {
        switch self {
        case .todaysSchedule:  return "Today's Schedule"
        case .activeProjects:  return "Active Projects"
        case .estimatesDue:    return "Estimates Due"
        case .crewStatus:      return "Crew Status"
        case .safetyForms:     return "Safety & Forms"
        case .openRFIs:        return "Open RFIs"
        case .revenueSnapshot: return "Revenue Snapshot"
        case .weather:         return "Weather"
        case .mapView:         return "Site Map"
        case .recentActivity:  return "Recent Activity"
        case .crmTasks:        return "My CRM Tasks"
        case .pipelineSummary: return "Pipeline"
        case .forecastSnapshot:return "Forecast"
        }
    }

    var icon: String {
        switch self {
        case .todaysSchedule:  return "calendar.day.timeline.left"
        case .activeProjects:  return "folder.fill"
        case .estimatesDue:    return "doc.text.magnifyingglass"
        case .crewStatus:      return "person.3.fill"
        case .safetyForms:     return "exclamationmark.shield.fill"
        case .openRFIs:        return "questionmark.bubble.fill"
        case .revenueSnapshot: return "dollarsign.circle.fill"
        case .weather:         return "cloud.sun.fill"
        case .mapView:         return "map.fill"
        case .recentActivity:  return "clock.arrow.circlepath"
        case .crmTasks:        return "checklist"
        case .pipelineSummary: return "chart.bar.fill"
        case .forecastSnapshot:return "chart.line.uptrend.xyaxis"
        }
    }

    var category: WidgetCategory {
        switch self {
        case .todaysSchedule:  return .scheduling
        case .activeProjects:  return .projects
        case .estimatesDue:    return .estimating
        case .crewStatus:      return .crew
        case .safetyForms:     return .safety
        case .openRFIs:        return .projects
        case .revenueSnapshot: return .financial
        case .weather:         return .activity
        case .mapView:         return .maps
        case .recentActivity:  return .activity
        case .crmTasks:        return .crm
        case .pipelineSummary: return .crm
        case .forecastSnapshot:return .crm
        }
    }

    var defaultSize: WidgetSize {
        switch self {
        case .todaysSchedule:  return .wide
        case .activeProjects:  return .small
        case .estimatesDue:    return .small
        case .crewStatus:      return .tall
        case .safetyForms:     return .tall
        case .openRFIs:        return .small
        case .revenueSnapshot: return .wide
        case .weather:         return .small
        case .mapView:         return .large
        case .recentActivity:  return .wide
        case .crmTasks:        return .tall
        case .pipelineSummary: return .tall
        case .forecastSnapshot:return .wide
        }
    }

    var supportedSizes: [WidgetSize] {
        switch self {
        case .mapView:         return [.large]
        case .todaysSchedule:  return [.wide, .large]
        case .revenueSnapshot: return [.wide, .large]
        case .recentActivity:  return [.wide, .large]
        case .forecastSnapshot:return [.wide, .large]
        default:               return [.small, .tall, .wide, .large]
        }
    }
}

// MARK: - Widget Category

enum WidgetCategory: String, CaseIterable {
    case projects, scheduling, estimating, crew, safety, financial, maps, activity, crm

    var displayName: String {
        switch self {
        case .projects:    return "Projects"
        case .scheduling:  return "Scheduling"
        case .estimating:  return "Estimating"
        case .crew:        return "Crew"
        case .safety:      return "Safety & Forms"
        case .financial:   return "Financial"
        case .maps:        return "Maps"
        case .activity:    return "Activity"
        case .crm:         return "CRM"
        }
    }
}

// MARK: - Widget Size

enum WidgetSize: String, Codable, CaseIterable {
    case small = "small"   // 2 col × 1 row
    case tall  = "tall"    // 2 col × 2 rows
    case wide  = "wide"    // 4 col × 1 row
    case large = "large"   // 4 col × 2 rows

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .tall:  return "Tall"
        case .wide:  return "Wide"
        case .large: return "Large"
        }
    }

    var columnSpan: Int {
        switch self {
        case .small, .tall: return 2
        case .wide, .large: return 4
        }
    }

    var rowSpan: Int {
        switch self {
        case .small, .wide: return 1
        case .tall, .large: return 2
        }
    }

    var icon: String {
        switch self {
        case .small: return "square"
        case .tall:  return "rectangle.portrait"
        case .wide:  return "rectangle"
        case .large: return "rectangle.fill"
        }
    }
}

// MARK: - Dashboard Widget

struct DashboardWidget: Identifiable, Codable, Equatable {
    var id:        UUID        = UUID()
    var type:      WidgetType
    var title:     String
    var size:      WidgetSize
    var position:  Int
    var isVisible: Bool        = true

    init(type: WidgetType, size: WidgetSize? = nil, position: Int = 0) {
        self.type     = type
        self.title    = type.displayName
        self.size     = size ?? type.defaultSize
        self.position = position
    }
}

// MARK: - Layout Manager

final class DashboardLayoutManager: ObservableObject {
    @Published var widgets: [DashboardWidget] = []

    private let storageKey = "bv_widget_layout"

    init() { load() }

    // MARK: Persistence

    func save() {
        if let data = try? JSONEncoder().encode(widgets) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([DashboardWidget].self, from: data)
        else { return }
        widgets = decoded
    }

    func reset(for role: UserRole) {
        widgets = Self.defaultLayout(for: role)
        save()
    }

    func ensureLayout(for role: UserRole) {
        if widgets.isEmpty {
            widgets = Self.defaultLayout(for: role)
        }
    }

    // MARK: Mutation

    func addWidget(_ type: WidgetType) {
        guard !widgets.contains(where: { $0.type == type && $0.isVisible }) else { return }
        let next = (widgets.map(\.position).max() ?? -1) + 1
        var w = DashboardWidget(type: type, position: next)
        widgets.append(w)
        save()
    }

    func removeWidget(id: UUID) {
        widgets.removeAll { $0.id == id }
        reposition()
        save()
    }

    func resizeWidget(id: UUID, to size: WidgetSize) {
        guard let idx = widgets.firstIndex(where: { $0.id == id }) else { return }
        widgets[idx].size = size
        save()
    }

    func moveWidget(from source: IndexSet, to destination: Int) {
        widgets.move(fromOffsets: source, toOffset: destination)
        reposition()
        save()
    }

    func swapWidgets(sourceID: UUID, targetID: UUID) {
        guard let si = widgets.firstIndex(where: { $0.id == sourceID }),
              let ti = widgets.firstIndex(where: { $0.id == targetID }) else { return }
        widgets.swapAt(si, ti)
        reposition()
        save()
    }

    private func reposition() {
        for i in widgets.indices { widgets[i].position = i }
    }

    // MARK: Grid Packing

    func packedRows() -> [[DashboardWidget]] {
        let sorted = widgets.filter(\.isVisible).sorted { $0.position < $1.position }
        var rows: [[DashboardWidget]] = []
        var row: [DashboardWidget] = []
        var usedCols = 0

        for w in sorted {
            let span = w.size.columnSpan
            if usedCols + span > 4 {
                if !row.isEmpty { rows.append(row) }
                row = [w]; usedCols = span
            } else {
                row.append(w); usedCols += span
            }
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    // MARK: Default Layouts

    static func defaultLayout(for role: UserRole) -> [DashboardWidget] {
        switch role {
        // Owner gets the same dashboard layout as executive/manager —
        // peer at the top of the hierarchy.
        case .executive, .manager, .owner:
            return layout([
                (.weather,          .small),
                (.activeProjects,   .small),
                (.forecastSnapshot, .wide),
                (.pipelineSummary,  .tall),
                (.crmTasks,         .tall),
                (.revenueSnapshot,  .wide),
                (.estimatesDue,     .small),
                (.openRFIs,         .small),
                (.crewStatus,       .tall),
                (.safetyForms,      .tall),
                (.recentActivity,   .wide),
            ])

        case .projectManager:
            return layout([
                (.todaysSchedule,  .wide),
                (.activeProjects,  .small),
                (.crmTasks,        .small),
                (.crewStatus,      .tall),
                (.safetyForms,     .tall),
                (.openRFIs,        .small),
                (.pipelineSummary, .small),
                (.recentActivity,  .wide),
            ])

        case .estimator:
            return layout([
                (.estimatesDue,     .wide),
                (.pipelineSummary,  .tall),
                (.crmTasks,         .tall),
                (.forecastSnapshot, .wide),
                (.activeProjects,   .small),
                (.revenueSnapshot,  .small),
                (.recentActivity,   .wide),
            ])

        case .officeAdmin:
            return layout([
                (.activeProjects,  .small),
                (.openRFIs,        .small),
                (.revenueSnapshot, .wide),
                (.crewStatus,      .tall),
                (.safetyForms,     .tall),
                (.recentActivity,  .wide),
            ])

        case .foreman:
            return layout([
                (.todaysSchedule,  .wide),
                (.weather,         .small),
                (.crewStatus,      .small),
                (.safetyForms,     .tall),
                (.recentActivity,  .wide),
            ])

        case .safetyAdvisor:
            return layout([
                (.safetyForms,     .wide),
                (.openRFIs,        .small),
                (.crewStatus,      .small),
                (.todaysSchedule,  .wide),
            ])

        case .fieldWorker:
            return layout([
                (.todaysSchedule, .wide),
                (.weather,        .small),
                (.crewStatus,     .small),
            ])

        case .client:
            return layout([
                (.activeProjects,  .wide),
                (.recentActivity,  .wide),
            ])
        }
    }

    private static func layout(_ pairs: [(WidgetType, WidgetSize)]) -> [DashboardWidget] {
        pairs.enumerated().map { i, p in
            DashboardWidget(type: p.0, size: p.1, position: i)
        }
    }
}
