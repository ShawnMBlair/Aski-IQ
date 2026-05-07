// ScheduleCalendarView.swift
// FieldOS – Schedule Calendar (Week View)

import SwiftUI

/// User's chosen calendar grain. Persisted across launches via @SceneStorage
/// so opening the Schedule tab returns them to the same density.
enum ScheduleViewMode: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var label: String {
        switch self {
        case .day:   return "Day"
        case .week:  return "Week"
        case .month: return "Month"
        }
    }
}

struct ScheduleCalendarView: View {
    @EnvironmentObject var store: AppStore
    @State private var selectedDate: Date = Date()
    @State private var weekOffset: Int = 0
    @State private var monthOffset: Int = 0
    @State private var showCreateEntry = false
    @State private var showConflicts = false
    @State private var showFilter = false
    @SceneStorage("aski_schedule_view_mode") private var viewModeRaw: String = ScheduleViewMode.week.rawValue
    /// Phase 1 — filter state persisted as JSON via @SceneStorage so
    /// the user's last filter survives app suspends/restarts within
    /// the scene without polluting UserDefaults.
    @SceneStorage("aski_schedule_filter") private var filterJSON: String = "{}"
    @State private var filter: ScheduleFilter = ScheduleFilter()

    /// Bridge between the @SceneStorage string and the typed enum.
    private var viewMode: Binding<ScheduleViewMode> {
        Binding(
            get: { ScheduleViewMode(rawValue: viewModeRaw) ?? .week },
            set: { viewModeRaw = $0.rawValue }
        )
    }

    private var weekDates: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let startOfWeek = calendar.date(
            from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
        )!
        let offsetStart = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: startOfWeek)!
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: offsetStart) }
    }

    private var weekLabel: String {
        guard let first = weekDates.first, let last = weekDates.last else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "\(formatter.string(from: first)) – \(formatter.string(from: last))"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // MARK: - Phase A — Command Centre entry banner
                // Sits above the calendar grain picker so it's the first
                // thing the user sees on the Schedule tab. Toolbar icons
                // get overlooked on small devices; a body-level card is
                // unmissable. Pushes SchedulingCommandCentreView; the
                // calendar stays the default landing per Phase A scope.
                NavigationLink {
                    SchedulingCommandCentreView()
                        .environmentObject(store)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "tray.full.fill")
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Command Centre")
                                .font(.subheadline.bold())
                                .foregroundColor(.primary)
                            Text("See what needs scheduling, today's work, and live issues")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemGroupedBackground))
                }
                .buttonStyle(.plain)

                // MARK: - View-mode picker (Day / Week / Month)
                Picker("Schedule grain", selection: viewMode) {
                    ForEach(ScheduleViewMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, AskiSpacing.lg)
                .padding(.top, AskiSpacing.sm)
                .padding(.bottom, AskiSpacing.xs)

                // MARK: - Conflict banner (visible regardless of grain when crew clash on selected day)
                // Filter through `liveConflictsOn` so acknowledged clashes
                // disappear from the banner — operator already approved.
                let dayConflicts = store.liveConflictsOn(date: selectedDate)
                    .filter { $0.conflictType == .crewDoubleBooked }
                if !dayConflicts.isEmpty {
                    Button {
                        showConflicts = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text("\(dayConflicts.count) scheduling conflict\(dayConflicts.count == 1 ? "" : "s") — tap to review")
                                .font(.subheadline).bold()
                                .foregroundColor(.red)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.red.opacity(0.6))
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.08))
                    }
                }

                Divider()

                // MARK: - Mode-specific content
                switch viewMode.wrappedValue {
                case .day:   dayMode
                case .week:  weekMode
                case .month: monthMode
                }
            }
            .navigationTitle("Schedule")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCreateEntry = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                // Phase 2 — Dispatch Board entry point. Pushes a sibling
                // view rather than swapping the calendar body, so the
                // user can flip between calendar grain and operational
                // worklist without losing place.
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink {
                        DispatchBoardView()
                            .environmentObject(store)
                    } label: {
                        Image(systemName: "rectangle.split.3x1.fill")
                    }
                    .accessibilityLabel("Dispatch Board")
                }
                // Phase 1 — filter button. Shows count badge when
                // any dimension is active so the user knows they're
                // not seeing the full schedule.
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showFilter = true
                    } label: {
                        if filter.isActive {
                            Label("\(filter.activeCount)", systemImage: "line.3.horizontal.decrease.circle.fill")
                                .foregroundColor(.blue)
                                .font(.subheadline)
                        } else {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Today") {
                        weekOffset = 0
                        selectedDate = Date()
                    }
                    .font(.subheadline)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    let critical = store.liveCriticalScheduleConflicts.count
                    if critical > 0 {
                        Button {
                            showConflicts = true
                        } label: {
                            Label("\(critical)", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                                .font(.subheadline)
                        }
                    }
                }
            }
            .sheet(isPresented: $showCreateEntry) {
                ScheduleEntryCreateEditView(preselectedDate: selectedDate)
            }
            .sheet(isPresented: $showConflicts) {
                ScheduleConflictListView(date: selectedDate)
                    .environmentObject(store)
            }
            .sheet(isPresented: $showFilter) {
                ScheduleFilterSheet(filter: $filter)
                    .environmentObject(store)
            }
            // Persist filter changes through @SceneStorage as JSON.
            // onAppear re-hydrates from JSON; onChange writes back.
            .onAppear {
                if let restored = ScheduleFilter(jsonString: filterJSON) {
                    filter = restored
                }
            }
            .onChange(of: filter) { _, newValue in
                filterJSON = newValue.jsonString
            }
        }
    }

    private func entriesFor(date: Date) -> [ScheduleEntry] {
        let raw = store.scheduleEntries(for: date)
        // Phase 1 — apply active filter. Empty filter = pass-through.
        return filter.apply(to: raw, crews: store.crews)
    }

    // MARK: - Mode bodies

    /// Day mode: just the selected day's entries + a date-stepper at top.
    /// Useful when the user has tapped through from a calendar pin / search /
    /// wants a focused single-day view.
    private var dayMode: some View {
        VStack(spacing: 0) {
            HStack {
                Button { selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate } label: {
                    Image(systemName: "chevron.left").padding(8)
                }
                Spacer()
                Text(dayLabel(selectedDate)).font(.headline)
                Spacer()
                Button { selectedDate = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate } label: {
                    Image(systemName: "chevron.right").padding(8)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, AskiSpacing.sm)
            Divider()
            ScheduleDayView(date: selectedDate)
        }
    }

    /// Week mode: the original week-strip + day list. Default view.
    private var weekMode: some View {
        VStack(spacing: 0) {
            HStack {
                Button { weekOffset -= 1 } label: { Image(systemName: "chevron.left").padding(8) }
                Spacer()
                Text(weekLabel).font(.headline)
                Spacer()
                Button { weekOffset += 1 } label: { Image(systemName: "chevron.right").padding(8) }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            HStack(spacing: 6) {
                ForEach(weekDates, id: \.self) { date in
                    DayButton(
                        date: date,
                        isSelected: Calendar.current.isDate(date, inSameDayAs: selectedDate),
                        entryCount: entriesFor(date: date).count,
                        hasConflict: !store.liveConflictsOn(date: date).filter { $0.conflictType == .crewDoubleBooked }.isEmpty
                    ) {
                        selectedDate = date
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()
            ScheduleDayView(date: selectedDate)
        }
    }

    /// Month mode: 6-week grid with shift / delivery / conflict indicators.
    /// Tap a day to jump into Day mode focused on it.
    private var monthMode: some View {
        ScheduleMonthView(
            selectedDate: $selectedDate,
            monthOffset:  $monthOffset,
            onTapDay:     { _ in viewModeRaw = ScheduleViewMode.day.rawValue }
        )
    }

    private func dayLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: d)
    }
}

// MARK: - Day Button

struct DayButton: View {
    let date: Date
    let isSelected: Bool
    let entryCount: Int
    var hasConflict: Bool = false
    let action: () -> Void

    private var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }

    private var dayLetter: String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return String(f.string(from: date).prefix(1))
    }

    private var dayNumber: String {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f.string(from: date)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(dayLetter)
                    .font(.caption2)
                    .foregroundColor(isSelected ? .white : .secondary)

                Text(dayNumber)
                    .font(.subheadline)
                    .bold(isToday)
                    .foregroundColor(isSelected ? .white : (isToday ? .blue : .primary))

                if hasConflict {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 8))
                        .foregroundColor(isSelected ? .white : .red)
                } else {
                    Circle()
                        .fill(entryCount > 0
                              ? (isSelected ? Color.white.opacity(0.7) : Color.blue)
                              : Color.clear)
                        .frame(width: 5, height: 5)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(isSelected ? Color.blue : Color.clear)
            .cornerRadius(10)
        }
    }
}

// MARK: - Conflict List View

struct ScheduleConflictListView: View {
    let date: Date?
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    /// Toggle to peek at conflicts the operator has previously
    /// acknowledged. Off by default — once you've ack'd a clash you
    /// shouldn't be re-prompted. Manager-level escape hatch only.
    @State private var showAcknowledged = false

    /// Currently selected conflict for the resolution sheet. Using an
    /// item-style sheet binding so the sheet always reflects the latest
    /// row tapped (no stale state from the previous conflict).
    @State private var resolveTarget: ConflictPick?

    /// Lightweight wrapper so a ScheduleConflict (which is not
    /// Identifiable through a stable hash) can drive `.sheet(item:)`.
    private struct ConflictPick: Identifiable {
        let id: String        // stableKey
        let conflict: ScheduleConflict
    }

    /// Source list: live conflicts unless the operator opts into
    /// "show acknowledged." Either way we still narrow by date when
    /// the sheet was launched from a specific day.
    private var conflicts: [ScheduleConflict] {
        let base = showAcknowledged
            ? store.scheduleConflicts
            : store.liveScheduleConflicts
        guard let d = date else { return base }
        return base.filter {
            Calendar.current.isDate($0.date, inSameDayAs: d) ||
            $0.conflictType == .crewDoubleBooked
        }
    }

    /// Count of conflicts the operator has already approved — used to
    /// decide whether to show the "Show acknowledged" toggle at all.
    private var acknowledgedCount: Int {
        store.scheduleConflicts
            .filter { store.isAcknowledged($0) }
            .count
    }

    var body: some View {
        NavigationStack {
            Group {
                if conflicts.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 52))
                            .foregroundColor(.green)
                        Text("No Scheduling Conflicts")
                            .font(.headline)
                        Text("The schedule is clear.")
                            .foregroundColor(.secondary)
                        if acknowledgedCount > 0 && !showAcknowledged {
                            Button {
                                showAcknowledged = true
                            } label: {
                                Label("Show \(acknowledgedCount) acknowledged", systemImage: "eye")
                                    .font(.subheadline)
                            }
                            .padding(.top, 8)
                        }
                        Spacer()
                    }
                } else {
                    List {
                        if acknowledgedCount > 0 {
                            Section {
                                Toggle("Show acknowledged", isOn: $showAcknowledged)
                                    .font(.subheadline)
                            } footer: {
                                Text("Acknowledged conflicts have been approved by an operator and won't show in the banner.")
                            }
                        }
                        Section {
                            ForEach(conflicts) { conflict in
                                Button {
                                    resolveTarget = ConflictPick(id: conflict.stableKey, conflict: conflict)
                                } label: {
                                    ScheduleConflictRow(conflict: conflict)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Schedule Conflicts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.bold()
                }
            }
            .sheet(item: $resolveTarget) { pick in
                ConflictResolutionSheet(conflict: pick.conflict)
                    .environmentObject(store)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ScheduleConflictRow: View {
    let conflict: ScheduleConflict
    @EnvironmentObject var store: AppStore

    private var conflictColor: Color {
        switch conflict.conflictType {
        case .crewDoubleBooked,
             .employeeDoubleBooked,
             .certificationMissing:   return .red
        case .projectOverlap,
             .travelBuffer:            return .orange
        case .weekendWork,
             .overtimeRisk:            return .yellow
        }
    }

    private var isAcknowledged: Bool {
        store.isAcknowledged(conflict)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: conflict.conflictType.icon)
                    .foregroundColor(isAcknowledged ? .secondary : conflictColor)
                Text(conflict.conflictType.severity)
                    .font(.caption).bold()
                    .foregroundColor(isAcknowledged ? .secondary : conflictColor)
                if isAcknowledged {
                    Text("ACKNOWLEDGED")
                        .font(.caption2).bold()
                        .foregroundColor(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(4)
                }
                Spacer()
                Text(conflict.date.shortDate)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text(conflict.description)
                .font(.subheadline)
                .strikethrough(isAcknowledged, color: .secondary)
                .foregroundColor(isAcknowledged ? .secondary : .primary)

            // Affected entries
            ForEach(conflict.affectedEntries) { entry in
                HStack(spacing: 6) {
                    let projName = store.projects.first(where: { $0.id == entry.projectID })?.name ?? "Unknown Project"
                    let crewName = entry.crewID.flatMap { cid in store.crews.first(where: { $0.id == cid }) }?.name ?? ""
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(projName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !crewName.isEmpty {
                        Text("· \(crewName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if !isAcknowledged {
                Text("Tap to resolve")
                    .font(.caption2)
                    .foregroundColor(.blue)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
