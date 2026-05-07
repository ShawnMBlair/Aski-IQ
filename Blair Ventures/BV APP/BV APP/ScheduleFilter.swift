// ScheduleFilter.swift
// Aski IQ — Schedule filters (Phase 1).
//
// Sits between AppStore.scheduleEntries and the calendar/list views.
// Five filter dimensions:
//   • Project (single, optional)
//   • Crew (single, optional)
//   • Foreman — filters to crews led by that foreman
//   • Status (multi-select of ScheduleEntryStatus)
//   • Date range — quick presets + custom start/end
//
// Persisted in @SceneStorage so the user's last filter survives
// across launches but doesn't pollute UserDefaults.

import Foundation
import SwiftUI

// MARK: - Filter model

/// Lightweight value type representing the active filter set.
/// Codable so it can ride through @SceneStorage as JSON.
struct ScheduleFilter: Codable, Equatable {
    var projectID:  UUID?         = nil
    var crewID:     UUID?         = nil
    var foremanID:  UUID?         = nil
    /// When empty, ALL statuses are included. When populated, only
    /// entries with status in this set pass.
    var statuses:   Set<ScheduleEntryStatus> = []
    /// When nil, no date constraint (handled by the calendar's own
    /// day/week/month grain). When set, only entries whose date
    /// falls in [startDate, endDate] pass — useful when the user
    /// wants "next 30 days" without flipping calendar mode.
    var startDate:  Date?         = nil
    var endDate:    Date?         = nil

    /// True when at least one dimension is constrained. Drives the
    /// "active filter" badge on the toolbar button.
    var isActive: Bool {
        projectID != nil
        || crewID != nil
        || foremanID != nil
        || !statuses.isEmpty
        || startDate != nil
        || endDate != nil
    }

    /// Count of distinct active dimensions (for badge text).
    var activeCount: Int {
        var n = 0
        if projectID != nil { n += 1 }
        if crewID    != nil { n += 1 }
        if foremanID != nil { n += 1 }
        if !statuses.isEmpty { n += 1 }
        if startDate != nil || endDate != nil { n += 1 }
        return n
    }

    /// Reset to "no filter".
    mutating func reset() {
        self = ScheduleFilter()
    }
}

// MARK: - SceneStorage bridge

/// Codable values can't go directly into @SceneStorage — wrap as JSON
/// string. Keep this in one place so the calendar view doesn't have
/// to think about encoding.
extension ScheduleFilter {
    init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ScheduleFilter.self, from: data) else {
            return nil
        }
        self = decoded
    }
    var jsonString: String {
        guard let data = try? JSONEncoder().encode(self),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}

// MARK: - Filter application

extension ScheduleFilter {
    /// Apply the filter to a list of entries. Order-preserving.
    /// `crews` is needed only when foreman is set so we can resolve
    /// foreman → crews → entries.
    func apply(to entries: [ScheduleEntry], crews: [Crew] = []) -> [ScheduleEntry] {
        guard isActive else { return entries }

        let crewIDsForForeman: Set<UUID>? = {
            guard let foremanID else { return nil }
            return Set(crews.filter { $0.foremanID == foremanID }.map { $0.id })
        }()

        return entries.filter { entry in
            if let projectID, entry.projectID != projectID { return false }
            if let crewID,    entry.crewID    != crewID    { return false }
            if let crewSet = crewIDsForForeman {
                guard let cid = entry.crewID, crewSet.contains(cid) else { return false }
            }
            if !statuses.isEmpty, !statuses.contains(entry.status) { return false }
            if let startDate {
                let cal = Calendar.current
                if cal.startOfDay(for: entry.date) < cal.startOfDay(for: startDate) { return false }
            }
            if let endDate {
                let cal = Calendar.current
                if cal.startOfDay(for: entry.date) > cal.startOfDay(for: endDate)   { return false }
            }
            return true
        }
    }
}

// MARK: - Quick date-range presets

enum ScheduleDateRangePreset: String, CaseIterable, Identifiable {
    case today, thisWeek, next7Days, next30Days, thisMonth, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .today:      return "Today"
        case .thisWeek:   return "This Week"
        case .next7Days:  return "Next 7 days"
        case .next30Days: return "Next 30 days"
        case .thisMonth:  return "This Month"
        case .custom:     return "Custom…"
        }
    }
    /// Resolves the preset to (start, end) bounds. Both inclusive.
    /// Custom returns nil so the caller knows to drop into manual pickers.
    func resolve(calendar: Calendar = .current, now: Date = Date()) -> (Date, Date)? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today:
            return (today, today)
        case .thisWeek:
            let start = calendar.date(from: calendar.dateComponents(
                [.yearForWeekOfYear, .weekOfYear], from: today)) ?? today
            let end = calendar.date(byAdding: .day, value: 6, to: start) ?? today
            return (start, end)
        case .next7Days:
            let end = calendar.date(byAdding: .day, value: 6, to: today) ?? today
            return (today, end)
        case .next30Days:
            let end = calendar.date(byAdding: .day, value: 29, to: today) ?? today
            return (today, end)
        case .thisMonth:
            let comps = calendar.dateComponents([.year, .month], from: today)
            let start = calendar.date(from: comps) ?? today
            let range = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
            let end = calendar.date(byAdding: .day, value: range - 1, to: start) ?? today
            return (start, end)
        case .custom:
            return nil
        }
    }
}

// MARK: - Filter sheet

/// Modal sheet that edits a `ScheduleFilter` binding. Apply on
/// dismiss — no separate Apply button. Cancel reverts to the
/// snapshot taken on appear.
struct ScheduleFilterSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @Binding var filter: ScheduleFilter

    @State private var snapshot: ScheduleFilter = ScheduleFilter()
    @State private var datePreset: ScheduleDateRangePreset = .custom
    @State private var customStart: Date = Date()
    @State private var customEnd:   Date = Date()
    @State private var useCustomRange: Bool = false

    private var activeProjects: [Project] {
        store.projects
            .filter { !$0.isDeleted }
            .sorted { $0.name < $1.name }
    }
    private var activeCrews: [Crew] {
        store.crews
            .filter { $0.isActive }
            .sorted { $0.name < $1.name }
    }
    /// Foreman set is the union of foremanIDs on all active crews.
    /// Ordered by name so the picker is stable.
    private var foremen: [Employee] {
        let foremanIDs = Set(store.crews.compactMap { $0.foremanID })
        return store.employees
            .filter { foremanIDs.contains($0.id) }
            .sorted { $0.lastName < $1.lastName }
    }

    var body: some View {
        NavigationStack {
            Form {
                projectSection
                crewSection
                foremanSection
                statusSection
                dateRangeSection
            }
            .navigationTitle("Filter Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        filter = snapshot
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        applyDateChoices()
                        dismiss()
                    } label: {
                        Text(filter.isActive ? "Apply" : "Done").bold()
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) {
                        filter.reset()
                        useCustomRange = false
                        datePreset = .custom
                    } label: {
                        Label("Clear all filters", systemImage: "xmark.circle")
                    }
                    .disabled(!filter.isActive)
                }
            }
            .onAppear {
                snapshot = filter
                useCustomRange = (filter.startDate != nil || filter.endDate != nil)
                if let s = filter.startDate { customStart = s }
                if let e = filter.endDate   { customEnd   = e }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var projectSection: some View {
        Section("Project") {
            Picker("Project", selection: $filter.projectID) {
                Text("All projects").tag(UUID?.none)
                ForEach(activeProjects) { p in
                    Text(p.name).tag(Optional(p.id))
                }
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var crewSection: some View {
        Section("Crew") {
            Picker("Crew", selection: $filter.crewID) {
                Text("All crews").tag(UUID?.none)
                ForEach(activeCrews) { c in
                    Text(c.name).tag(Optional(c.id))
                }
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var foremanSection: some View {
        Section {
            if foremen.isEmpty {
                Text("No foremen assigned to active crews.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Picker("Foreman", selection: $filter.foremanID) {
                    Text("All foremen").tag(UUID?.none)
                    ForEach(foremen) { f in
                        Text(f.fullName).tag(Optional(f.id))
                    }
                }
                .pickerStyle(.menu)
            }
        } header: {
            Text("Foreman")
        } footer: {
            Text("Filtering by foreman shows shifts on crews led by that foreman.")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            ForEach(Array(ScheduleEntryStatus.allCases), id: \.self) { status in
                Button {
                    if filter.statuses.contains(status) {
                        filter.statuses.remove(status)
                    } else {
                        filter.statuses.insert(status)
                    }
                } label: {
                    HStack {
                        Image(systemName: filter.statuses.contains(status)
                              ? "checkmark.square.fill"
                              : "square")
                            .foregroundColor(filter.statuses.contains(status) ? .blue : .secondary)
                        Text(status.displayLabel)
                            .foregroundColor(.primary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Status")
        } footer: {
            Text(filter.statuses.isEmpty
                 ? "Showing all statuses."
                 : "Tap to toggle. Showing only the selected status\(filter.statuses.count == 1 ? "" : "es").")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var dateRangeSection: some View {
        Section {
            Picker("Range", selection: $datePreset) {
                ForEach(ScheduleDateRangePreset.allCases) { p in
                    Text(p.label).tag(p)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: datePreset) { _, newValue in
                if newValue == .custom {
                    useCustomRange = true
                } else if let (s, e) = newValue.resolve() {
                    customStart = s
                    customEnd   = e
                    useCustomRange = true
                }
            }

            if useCustomRange {
                DatePicker("Start", selection: $customStart, displayedComponents: .date)
                DatePicker("End",   selection: $customEnd,   displayedComponents: .date)
                Button(role: .destructive) {
                    useCustomRange = false
                    filter.startDate = nil
                    filter.endDate   = nil
                    datePreset = .custom
                } label: {
                    Label("Clear date range", systemImage: "calendar.badge.minus")
                }
            }
        } header: {
            Text("Date range")
        } footer: {
            Text("When set, the date filter overrides the calendar grain — useful for views like \"next 7 days\" without flipping to Week mode.")
                .font(.caption)
        }
    }

    /// Persist the date-range pickers into the filter struct on Apply.
    /// Other dimensions are bound directly so they're already live.
    private func applyDateChoices() {
        if useCustomRange {
            // Defensive: swap if user picked an inverted range
            if customEnd < customStart {
                filter.startDate = customEnd
                filter.endDate   = customStart
            } else {
                filter.startDate = customStart
                filter.endDate   = customEnd
            }
        } else {
            filter.startDate = nil
            filter.endDate   = nil
        }
    }
}

// MARK: - Convenience for the iterating UI

extension ScheduleEntryStatus {
    /// Capitalized human label for the filter list.
    /// `CaseIterable` conformance + `allCases` lives on the
    /// extension declared in ScheduleEntryCreateEditView.swift —
    /// the filter UI iterates that.
    var displayLabel: String {
        switch self {
        case .scheduled:   return "Scheduled"
        case .inProgress:  return "In Progress"
        case .completed:   return "Completed"
        case .cancelled:   return "Cancelled"
        case .rescheduled: return "Rescheduled"
        }
    }
}
