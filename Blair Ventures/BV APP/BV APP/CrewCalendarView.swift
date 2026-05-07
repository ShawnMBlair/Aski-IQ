// CrewCalendarView.swift
// Aski IQ — Per-crew weekly calendar (Phase 1 scheduling upgrade).
//
// Where the main ScheduleCalendarView is "all crews on a date",
// this view inverts the axis: ONE crew, multiple days.
//
// Layout:
//   • Top: crew name + week navigation (prev / today / next)
//   • Body: 7 day rows. Each row shows the crew's shifts for that
//           day (count + total scheduled hours), with conflict
//           indicators and a tap-through to the standard schedule
//           detail view.
//   • Footer: weekly summary — total scheduled hours vs the
//             configured overtime threshold.
//
// Reuses ScheduleConflictService (Phase 1 detector) so the same
// conflicts that surface on the global calendar surface here too.

import SwiftUI

struct CrewCalendarView: View {
    @EnvironmentObject var store: AppStore

    let crew: Crew
    /// Day-zero of the week shown. Mutated by prev/next chevrons.
    @State private var weekStart: Date = Calendar.current.startOfWeek(for: Date())
    @State private var showEntryDetail: ScheduleEntry? = nil
    @State private var showCreateEntry = false

    // MARK: - Derived

    private var weekDates: [Date] {
        let cal = Calendar.current
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
    }

    private var weekLabel: String {
        guard let first = weekDates.first, let last = weekDates.last else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return "\(f.string(from: first)) – \(f.string(from: last))"
    }

    /// Crew's shifts for the visible week, sorted by date+start.
    private var weekEntries: [ScheduleEntry] {
        let cal = Calendar.current
        guard let first = weekDates.first, let last = weekDates.last else { return [] }
        let firstDay = cal.startOfDay(for: first)
        let lastDay  = cal.startOfDay(for: last)
        return store.scheduleEntries
            .filter {
                !$0.isDeleted
                && $0.crewID == crew.id
                && cal.startOfDay(for: $0.date) >= firstDay
                && cal.startOfDay(for: $0.date) <= lastDay
            }
            .sorted { lhs, rhs in
                if lhs.date != rhs.date { return lhs.date < rhs.date }
                return (lhs.shiftStart ?? .distantFuture) < (rhs.shiftStart ?? .distantFuture)
            }
    }

    private var totalWeekHours: Double {
        weekEntries.reduce(0.0) { sum, e in
            guard let s = e.shiftStart, let f = e.shiftEnd, f > s else { return sum }
            return sum + f.timeIntervalSince(s) / 3600.0
        }
    }

    private var overtimeThreshold: Double {
        AppSettings.shared.overtimeWeeklyThresholdHours
    }

    /// Conflicts scoped to this crew + this week. Pulls through the
    /// upgraded detector via AppStore.conflicts(from:to:) which
    /// already wires AppSettings tunables, then narrows to entries
    /// for THIS crew.
    private var conflictsThisWeek: [ScheduleConflict] {
        guard let first = weekDates.first, let last = weekDates.last else { return [] }
        let crewEntryIDs = Set(weekEntries.map { $0.id })
        return store.conflicts(from: first, to: last)
            .filter { conflict in
                conflict.affectedEntries.contains(where: { crewEntryIDs.contains($0.id) })
            }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                weekNavigationBar
                weekSummaryCard
                if !conflictsThisWeek.isEmpty { conflictBanner }
                dayRows
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("\(crew.name) — Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showCreateEntry = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showCreateEntry) {
            // Pre-pick this crew when creating from the crew calendar
            // so the form arrives already tied to the correct crew.
            ScheduleEntryCreateEditView(
                preselectedDate: weekDates.first ?? Date(),
                preselectedCrewID: crew.id
            )
        }
        .sheet(item: $showEntryDetail) { entry in
            ScheduleEntryCreateEditView(existing: entry)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var weekNavigationBar: some View {
        HStack(spacing: 12) {
            Button {
                weekStart = Calendar.current.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart
            } label: {
                Image(systemName: "chevron.left")
                    .padding(8)
            }
            Spacer()
            VStack(spacing: 2) {
                Text(weekLabel).font(.subheadline.bold())
                Text("Week of").font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            Button {
                weekStart = Calendar.current.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
            } label: {
                Image(systemName: "chevron.right")
                    .padding(8)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var weekSummaryCard: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Scheduled this week").font(.caption).foregroundColor(.secondary)
                    Text(String(format: "%.1f hrs", totalWeekHours))
                        .font(.title2.bold())
                        .foregroundColor(overtimeThreshold > 0 && totalWeekHours > overtimeThreshold
                                         ? .orange
                                         : .primary)
                }
                Spacer()
                if overtimeThreshold > 0 {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Threshold").font(.caption).foregroundColor(.secondary)
                        Text(String(format: "%.0f hrs", overtimeThreshold))
                            .font(.subheadline.bold())
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
        }
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    @ViewBuilder
    private var conflictBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(conflictsThisWeek.count) conflict\(conflictsThisWeek.count == 1 ? "" : "s") this week")
                    .font(.subheadline.bold())
                ForEach(conflictsThisWeek.prefix(3)) { c in
                    Text("• \(c.description)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                if conflictsThisWeek.count > 3 {
                    Text("…and \(conflictsThisWeek.count - 3) more")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding()
        .background(Color.red.opacity(0.08))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    @ViewBuilder
    private var dayRows: some View {
        VStack(spacing: 8) {
            ForEach(weekDates, id: \.self) { day in
                let dayEntries = weekEntries.filter {
                    Calendar.current.isDate($0.date, inSameDayAs: day)
                }
                CrewCalendarDayRow(
                    day: day,
                    entries: dayEntries,
                    onTapEntry: { showEntryDetail = $0 }
                )
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Day row component

private struct CrewCalendarDayRow: View {
    let day: Date
    let entries: [ScheduleEntry]
    let onTapEntry: (ScheduleEntry) -> Void

    private var dayLabel: String {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        return f.string(from: day)
    }

    private var totalHours: Double {
        entries.reduce(0.0) { sum, e in
            guard let s = e.shiftStart, let f = e.shiftEnd, f > s else { return sum }
            return sum + f.timeIntervalSince(s) / 3600.0
        }
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(day)
    }
    private var isWeekend: Bool {
        let wd = Calendar.current.component(.weekday, from: day)
        return wd == 1 || wd == 7
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(dayLabel)
                    .font(.subheadline.bold())
                    .foregroundColor(isToday ? .blue : (isWeekend ? .secondary : .primary))
                if isToday {
                    Text("TODAY")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }
                Spacer()
                if entries.isEmpty {
                    Text("Open").font(.caption).foregroundColor(.secondary)
                } else {
                    Text(totalHours > 0 ? String(format: "%.1f hrs", totalHours)
                                         : "\(entries.count) shift\(entries.count == 1 ? "" : "s")")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                }
            }

            if entries.isEmpty {
                Text(isWeekend ? "Weekend — no shifts scheduled" : "No shifts scheduled")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(entries) { e in
                    Button { onTapEntry(e) } label: {
                        ShiftCell(entry: e)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(10)
    }
}

// MARK: - Shift cell

private struct ShiftCell: View {
    @EnvironmentObject var store: AppStore
    let entry: ScheduleEntry

    private var projectName: String {
        store.projects.first(where: { $0.id == entry.projectID })?.name ?? "—"
    }

    private var timeRange: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        switch (entry.shiftStart, entry.shiftEnd) {
        case let (s?, e?): return "\(f.string(from: s)) – \(f.string(from: e))"
        case let (s?, nil): return "From \(f.string(from: s))"
        case let (nil, e?): return "Until \(f.string(from: e))"
        default: return "All day"
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .scheduled:   return .blue
        case .inProgress:  return .green
        case .completed:   return .secondary
        case .cancelled:   return .red
        case .rescheduled: return .orange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(statusColor)
                .frame(width: 3)
                .cornerRadius(1.5)
            VStack(alignment: .leading, spacing: 3) {
                Text(projectName).font(.subheadline.bold())
                Text(timeRange).font(.caption).foregroundColor(.secondary)
                if let task = entry.taskDescription, !task.isEmpty {
                    Text(task).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                if !entry.requiredCertifications.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.shield")
                            .font(.caption2)
                            .foregroundColor(.indigo)
                        Text(entry.requiredCertifications.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundColor(.indigo)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color(.tertiarySystemGroupedBackground))
        .cornerRadius(8)
    }
}

// MARK: - Calendar.startOfWeek helper

extension Calendar {
    /// Returns the first day of the calendar's week for the given date.
    /// Uses the calendar's `firstWeekday` (Sunday in en_US, Monday in
    /// most other locales). Falls back to the date itself on failure.
    fileprivate func startOfWeek(for date: Date) -> Date {
        let comps = dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return self.date(from: comps) ?? startOfDay(for: date)
    }
}
