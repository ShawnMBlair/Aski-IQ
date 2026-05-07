// WidgetLibraryView.swift
// BV APP – Widget picker sheet for adding widgets to the dashboard

import SwiftUI

struct WidgetLibraryView: View {
    @ObservedObject var layout: DashboardLayoutManager
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    private var groupedTypes: [(WidgetCategory, [WidgetType])] {
        let allCases = WidgetType.allCases
        return WidgetCategory.allCases.compactMap { cat in
            let types = allCases.filter { $0.category == cat }
            return types.isEmpty ? nil : (cat, types)
        }
    }

    private func isAdded(_ type: WidgetType) -> Bool {
        layout.widgets.contains { $0.type == type && $0.isVisible }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groupedTypes, id: \.0) { cat, types in
                    Section(cat.displayName) {
                        ForEach(types, id: \.self) { type in
                            widgetRow(type)
                        }
                    }
                }
            }
            .navigationTitle("Add Widget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.bold()
                }
            }
        }
        .presentationDetents([.large])
    }

    private func widgetRow(_ type: WidgetType) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(iconColor(type).opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: type.icon)
                    .foregroundColor(iconColor(type))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(type.displayName)
                    .font(.headline)
                Text(widgetDescription(type))
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 4) {
                    Image(systemName: type.defaultSize.icon)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(type.defaultSize.displayName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if isAdded(type) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Button {
                    layout.addWidget(type)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.blue)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func widgetDescription(_ type: WidgetType) -> String {
        switch type {
        case .todaysSchedule:  return "Crew assignments and schedule entries for today"
        case .activeProjects:  return "Count and list of currently active projects"
        case .estimatesDue:    return "Pending estimates with due dates"
        case .crewStatus:      return "Crews on duty and their current assignments"
        case .safetyForms:     return "Open incidents and recent form submissions"
        case .openRFIs:        return "Unanswered requests for information"
        case .revenueSnapshot: return "Invoiced totals, overdue amounts, and pipeline"
        case .weather:         return "Current site weather conditions"
        case .mapView:         return "Map showing active project locations"
        case .recentActivity:  return "Latest forms, timesheets, and incidents"
        case .crmTasks:        return "My open and overdue CRM tasks"
        case .pipelineSummary: return "Weighted pipeline value and top deals"
        case .forecastSnapshot:return "Revenue won vs weighted forecast vs target"
        }
    }

    private func iconColor(_ type: WidgetType) -> Color {
        switch type {
        case .todaysSchedule:  return .blue
        case .activeProjects:  return .blue
        case .estimatesDue:    return .purple
        case .crewStatus:      return .orange
        case .safetyForms:     return .red
        case .openRFIs:        return .orange
        case .revenueSnapshot: return .green
        case .weather:         return .cyan
        case .mapView:         return .teal
        case .recentActivity:  return .indigo
        case .crmTasks:        return .blue
        case .pipelineSummary: return .indigo
        case .forecastSnapshot:return .green
        }
    }
}
