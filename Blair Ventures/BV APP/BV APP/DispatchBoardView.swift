// DispatchBoardView.swift
// Aski IQ — Phase 2 Dispatch Board.
//
// WHAT THIS IS
// An operational view of the schedule that complements (does not replace)
// the existing day/week/month calendar. Where the calendar answers
// "what's on this day?", the board answers "what needs my attention
// right now?"  Six time/state buckets, each a stack of cards:
//
//   • Unscheduled — shifts created without a crew. The dispatcher's
//     primary worklist. Each card has a Quick Assign action that opens
//     a crew picker.
//   • Today       — assigned, today's date, not completed/cancelled.
//   • Tomorrow    — assigned, tomorrow's date, not completed/cancelled.
//   • This Week   — assigned, later this week (after tomorrow, ≤ end
//     of week), not completed/cancelled. Lookahead for capacity planning.
//   • Conflicts   — live (un-acknowledged) ScheduleConflicts. Reuses
//     the Phase 1 detector, so all 7 conflict types surface here.
//   • Completed   — completed shifts in the last 14 days. Bounded so
//     the column doesn't grow forever.
//
// PHASE 2 SCOPE — DELIBERATE OMISSIONS
//   • Drag-and-drop reassignment between columns — Phase 4
//   • Recurring shifts / "Copy week" — Phase 4
//   • Notifications on assignment / change — Phase 3
//   • Equipment scheduling — Phase 4
//   • Customer arrival notices — Phase 4
//
// FILTER REUSE
// Uses the same ScheduleFilter struct as the calendar, persisted under
// its own SceneStorage key so a user's "Project A only" filter on the
// calendar doesn't accidentally hide shifts on the board, and vice-versa.
//
// PERMISSION MODEL
// Inherits the existing role gate via upsertScheduleEntry — foreman+
// can edit / quick-assign / create. Field workers see the board for
// situational awareness but write-side affordances are HIDDEN
// (not-just-disabled) so the screen reflects only the actions they
// can actually take. A safety-net toast covers any edge where a tap
// slips through to the gate anyway.
//
// PHASE 2 HARDENING (enterprise pass):
//   • Smart Quick Assign — last-used-crew suggestion, pre-flight
//     conflict simulation, "Use suggested crew" / "Assign Anyway" /
//     "Cancel" pattern. No silent assigns into a clash.
//   • Today/Tomorrow/Later are grouped by crew so the dispatcher sees
//     workload-per-crew at a glance.
//   • Each card shows an inline red dot when its entry participates
//     in a live conflict — no need to scroll to the Conflicts column.
//   • Completed cards are read-only (taps no-op) — historical data
//     should not be silently mutable.
//   • Conflict snapshots are computed ONCE per render and indexed by
//     entry id, so cards stay scroll-smooth as the schedule grows.
//   • Every save flows through the same `upsertScheduleEntry` chokepoint
//     that writes the audit log row, so dispatcher-driven changes have
//     full who/when/what trail without any additional UI work.

import SwiftUI

struct DispatchBoardView: View {
    @EnvironmentObject var store: AppStore

    // MARK: - Filter (own SceneStorage key — independent of the calendar)
    @State private var filter = ScheduleFilter()
    @SceneStorage("aski_dispatch_filter") private var filterJSON: String = ""
    @State private var showFilter = false

    // MARK: - Sheet pickers
    @State private var editingEntryID: EntryPick?       = nil
    @State private var quickAssignTarget: EntryPick?    = nil
    @State private var conflictTarget: BoardConflictPick? = nil
    @State private var showCreateSheet                  = false
    @State private var newShiftDate: Date               = Date()
    @State private var newShiftCrewID: UUID?            = nil

    // MARK: - Section collapse state
    /// Section keys that are currently collapsed. By default all are
    /// expanded; user collapses to focus on a column.
    @State private var collapsed: Set<DispatchSectionKey> = []

    // MARK: - Body
    var body: some View {
        // Phase 2 hardening: snapshot live conflicts ONCE per render
        // and index by entry id. Card cells reference this index for
        // their red-dot conflict marker without rerunning the detector
        // hundreds of times in a single body pass.
        let conflictsByEntry = makeConflictIndex()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if filter.isActive {
                    filterBanner
                }
                section(.unscheduled,
                        title: "Unscheduled",
                        icon: "person.crop.circle.badge.questionmark",
                        accent: .orange,
                        entries: unscheduled,
                        emptyMessage: "Every shift has a crew assigned. To swap a crew, tap Reassign on any card below.",
                        conflictIDs: conflictsByEntry,
                        groupByCrew: false,
                        readOnly: false)
                section(.today,
                        title: "Today",
                        icon: "sun.max.fill",
                        accent: .blue,
                        entries: today,
                        emptyMessage: "No shifts on today.",
                        conflictIDs: conflictsByEntry,
                        groupByCrew: true,
                        readOnly: false)
                section(.tomorrow,
                        title: "Tomorrow",
                        icon: "sunrise.fill",
                        accent: .indigo,
                        entries: tomorrow,
                        emptyMessage: "No shifts on tomorrow.",
                        conflictIDs: conflictsByEntry,
                        groupByCrew: true,
                        readOnly: false)
                section(.thisWeek,
                        title: "Later This Week",
                        icon: "calendar",
                        accent: .purple,
                        entries: thisWeek,
                        emptyMessage: "Nothing scheduled later this week.",
                        conflictIDs: conflictsByEntry,
                        groupByCrew: true,
                        readOnly: false)
                conflictSection
                section(.completed,
                        title: "Completed (last 14 days)",
                        icon: "checkmark.circle.fill",
                        accent: .green,
                        entries: completed,
                        emptyMessage: "No shifts completed in the last 14 days.",
                        conflictIDs: [:],            // historical — no live conflicts
                        groupByCrew: false,
                        readOnly: true)              // taps no-op
                Spacer(minLength: 32)
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .navigationTitle("Dispatch")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Phase 2 hardening: only foreman+ can create shifts.
            // Hide the affordance entirely for field workers rather
            // than show a button that errors on tap.
            if store.canEditSchedule {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        newShiftDate = Date()
                        newShiftCrewID = nil
                        showCreateSheet = true
                    } label: { Image(systemName: "plus") }
                }
            }
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
        }
        .sheet(isPresented: $showFilter) {
            ScheduleFilterSheet(filter: $filter)
                .environmentObject(store)
        }
        .sheet(item: $editingEntryID) { pick in
            ScheduleEntryCreateEditView(existing: pick.entry)
                .environmentObject(store)
        }
        .sheet(item: $quickAssignTarget) { pick in
            QuickAssignSheet(entry: pick.entry)
                .environmentObject(store)
        }
        .sheet(item: $conflictTarget) { pick in
            ConflictResolutionSheet(conflict: pick.conflict)
                .environmentObject(store)
        }
        .sheet(isPresented: $showCreateSheet) {
            ScheduleEntryCreateEditView(
                preselectedDate: newShiftDate,
                preselectedCrewID: newShiftCrewID
            )
            .environmentObject(store)
        }
        .onAppear {
            if let restored = ScheduleFilter(jsonString: filterJSON) {
                filter = restored
            }
        }
        .onChange(of: filter) { _, newValue in
            filterJSON = newValue.jsonString
        }
    }

    // MARK: - Filter banner

    private var filterBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundColor(.blue)
            Text("Filter active — \(filter.activeCount) dimension\(filter.activeCount == 1 ? "" : "s")")
                .font(.caption).bold()
            Spacer()
            Button("Clear") { filter.reset() }
                .font(.caption.bold())
                .foregroundColor(.blue)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.10))
        .cornerRadius(10)
    }

    // MARK: - Generic section builder (entries variant)

    @ViewBuilder
    private func section(
        _ key: DispatchSectionKey,
        title: String,
        icon: String,
        accent: Color,
        entries: [ScheduleEntry],
        emptyMessage: String,
        conflictIDs: [UUID: Bool],
        groupByCrew: Bool,
        readOnly: Bool
    ) -> some View {
        let isCollapsed = collapsed.contains(key)
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(key: key,
                          title: title,
                          icon: icon,
                          accent: accent,
                          count: entries.count,
                          createDate: createDate(for: key))
            if !isCollapsed {
                if entries.isEmpty {
                    EmptyDispatchCard(message: emptyMessage)
                } else if groupByCrew {
                    crewGroupedList(entries: entries,
                                    conflictIDs: conflictIDs,
                                    sectionKey: key,
                                    readOnly: readOnly)
                } else {
                    VStack(spacing: 8) {
                        ForEach(entries) { entry in
                            shiftCard(for: entry,
                                      sectionKey: key,
                                      conflictIDs: conflictIDs,
                                      readOnly: readOnly)
                        }
                    }
                }
            }
        }
    }

    /// Phase 2 hardening: group cards by crew on Today/Tomorrow/Week so
    /// the dispatcher sees workload-per-crew at a glance. Unassigned
    /// shifts (no crew) cluster under a single "Unassigned" header.
    /// RA-3: also groups custom-crew and individual-worker shifts under
    /// a synthetic "Workers (N)" group, since they don't belong to a
    /// standing crew but should still be grouped distinctly from the
    /// genuinely-unassigned shifts.
    @ViewBuilder
    private func crewGroupedList(
        entries: [ScheduleEntry],
        conflictIDs: [UUID: Bool],
        sectionKey: DispatchSectionKey,
        readOnly: Bool
    ) -> some View {
        // Stable, name-sorted grouping. RA-3: group key is now the
        // assignment label, so custom/individual shifts cluster under
        // their own headings instead of all collapsing to "Unassigned".
        let groups: [(name: String, entries: [ScheduleEntry])] = {
            let byKey = Dictionary(grouping: entries) { entry in
                entry.assignmentLabel(crews: store.crews, employees: store.employees)
            }
            var out: [(String, [ScheduleEntry])] = []
            for (key, list) in byKey {
                out.append((key, list.sorted(by: bucketOrder)))
            }
            return out.sorted { $0.0 < $1.0 }
        }()
        VStack(spacing: 12) {
            ForEach(groups, id: \.name) { group in
                // RA-3: derive the group icon from the first entry's
                // assignment mode so customs/individuals show the
                // right glyph (3-people / 1-person) instead of always
                // the crew icon.
                let firstEntry = group.entries.first
                let icon = firstEntry?.assignmentIconName ?? "person.crop.circle.badge.questionmark"
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: icon)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(group.name)
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        Text("\(group.entries.count)")
                            .font(.caption2.bold())
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                        Spacer()
                    }
                    .padding(.leading, 4)
                    VStack(spacing: 6) {
                        ForEach(group.entries) { entry in
                            shiftCard(for: entry,
                                      sectionKey: sectionKey,
                                      conflictIDs: conflictIDs,
                                      readOnly: readOnly)
                        }
                    }
                }
            }
        }
    }

    /// Single source of truth for "render a shift card" — keeps the
    /// readonly + quick-assign + conflict-marker logic in one place.
    /// A card is treated as read-only when EITHER the caller marked
    /// the section read-only (Completed) OR the current user lacks
    /// schedule-edit permission. Either way the result is the same —
    /// no tap target, no quick-assign affordance.
    ///
    /// Discoverability fix 2026-05: the QuickAssign button is now
    /// surfaced as "Assign Crew" on Unscheduled cards AND as
    /// "Reassign" on assigned cards in Today/Tomorrow/Week, because
    /// dispatchers spend most of their time swapping crews on
    /// already-assigned shifts (not first-time assigns). The same
    /// QuickAssignSheet handles both paths — it preselects the last-
    /// used crew when the entry has no crew, or the CURRENT crew when
    /// the entry already has one.
    @ViewBuilder
    private func shiftCard(
        for entry: ScheduleEntry,
        sectionKey: DispatchSectionKey,
        conflictIDs: [UUID: Bool],
        readOnly: Bool
    ) -> some View {
        let effectivelyReadOnly = readOnly || !store.canEditSchedule
        // Show the reassign affordance on operational cards (Today /
        // Tomorrow / This Week / Unscheduled), not on Conflicts or
        // Completed (Conflicts route through ConflictResolutionSheet,
        // Completed is historical).
        let showQuickAssign: Bool = {
            guard store.canEditSchedule else { return false }
            switch sectionKey {
            case .unscheduled, .today, .tomorrow, .thisWeek: return true
            case .conflicts, .completed: return false
            }
        }()
        DispatchShiftCard(
            entry: entry,
            inLiveConflict: conflictIDs[entry.id] == true,
            onTap: effectivelyReadOnly
                ? nil
                : { editingEntryID = EntryPick(id: entry.id, entry: entry) },
            onQuickAssign: showQuickAssign
                ? { quickAssignTarget = EntryPick(id: entry.id, entry: entry) }
                : nil
        )
    }

    // MARK: - Conflicts section (different cell type)

    private var conflictSection: some View {
        let key = DispatchSectionKey.conflicts
        let isCollapsed = collapsed.contains(key)
        let items = conflicts
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader(key: key,
                          title: "Conflicts",
                          icon: "exclamationmark.triangle.fill",
                          accent: .red,
                          count: items.count,
                          createDate: nil)
            if !isCollapsed {
                if items.isEmpty {
                    EmptyDispatchCard(message: "No live conflicts. Existing acknowledgements are hidden.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(items) { conflict in
                            DispatchConflictCard(
                                conflict: conflict,
                                // Field workers see the conflict card
                                // (situational awareness) but cannot
                                // open the resolution flow.
                                onTap: store.canEditSchedule
                                    ? {
                                        conflictTarget = BoardConflictPick(
                                            id: conflict.stableKey,
                                            conflict: conflict
                                        )
                                      }
                                    : nil
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Section header

    @ViewBuilder
    private func sectionHeader(
        key: DispatchSectionKey,
        title: String,
        icon: String,
        accent: Color,
        count: Int,
        createDate: Date?
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                if collapsed.contains(key) {
                    collapsed.remove(key)
                } else {
                    collapsed.insert(key)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed.contains(key) ? "chevron.right" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Image(systemName: icon)
                        .foregroundColor(accent)
                    Text(title)
                        .font(.headline)
                    Text("\(count)")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(count > 0 ? accent : Color.secondary)
                        .clipShape(Capsule())
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            if let d = createDate {
                Button {
                    newShiftDate = d
                    newShiftCrewID = nil
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add shift in \(title)")
            }
        }
    }

    // MARK: - Bucketing inputs

    private var calendar: Calendar { .current }

    /// Filtered, non-deleted entries — the population every bucket draws from.
    private var filteredEntries: [ScheduleEntry] {
        filter.apply(
            to: store.scheduleEntries.filter { !$0.isDeleted },
            crews: store.crews
        )
    }

    private var unscheduled: [ScheduleEntry] {
        filteredEntries
            .filter {
                $0.crewID == nil
                && $0.status != .cancelled
                && $0.status != .completed
            }
            .sorted(by: bucketOrder)
    }

    private var today: [ScheduleEntry] {
        filteredEntries
            .filter {
                $0.crewID != nil
                && calendar.isDateInToday($0.date)
                && $0.status != .completed
                && $0.status != .cancelled
            }
            .sorted(by: bucketOrder)
    }

    private var tomorrow: [ScheduleEntry] {
        filteredEntries
            .filter {
                $0.crewID != nil
                && calendar.isDateInTomorrow($0.date)
                && $0.status != .completed
                && $0.status != .cancelled
            }
            .sorted(by: bucketOrder)
    }

    private var thisWeek: [ScheduleEntry] {
        let now = Date()
        let weekStart = calendar.dispatchStartOfWeek(for: now)
        let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? now
        return filteredEntries.filter { entry in
            guard entry.crewID != nil else { return false }
            guard entry.status != .completed, entry.status != .cancelled else { return false }
            if calendar.isDateInToday(entry.date) || calendar.isDateInTomorrow(entry.date) {
                return false
            }
            let day = calendar.startOfDay(for: entry.date)
            return day >= calendar.startOfDay(for: now) && day <= calendar.startOfDay(for: weekEnd)
        }.sorted(by: bucketOrder)
    }

    /// Live (un-acknowledged) conflicts, narrowed to those whose
    /// affected entries intersect the active filter. So if the filter
    /// is "Project A only", a conflict that involves only Project B
    /// shifts is hidden.
    private var conflicts: [ScheduleConflict] {
        let visibleIDs = Set(filteredEntries.map { $0.id })
        return store.liveScheduleConflicts.filter { conflict in
            conflict.affectedEntries.contains { visibleIDs.contains($0.id) }
        }
    }

    /// Phase 2 hardening: precomputed [entryID: hasConflict] table
    /// derived from `conflicts`. Lets every card check participation
    /// in a live conflict in O(1) without rerunning the detector.
    /// Built once per `body` invocation by the caller.
    private func makeConflictIndex() -> [UUID: Bool] {
        var out: [UUID: Bool] = [:]
        for conflict in conflicts {
            for entry in conflict.affectedEntries {
                out[entry.id] = true
            }
        }
        return out
    }

    private var completed: [ScheduleEntry] {
        let cutoff = calendar.date(byAdding: .day, value: -14, to: Date()) ?? Date()
        return filteredEntries
            .filter {
                $0.status == .completed
                && calendar.startOfDay(for: $0.date) >= calendar.startOfDay(for: cutoff)
            }
            .sorted(by: { $0.date > $1.date })  // most recent first
    }

    /// Order shifts in a bucket: by date, then by start time, then by
    /// project name as a stable tiebreaker so consecutive renders show
    /// rows in the same order.
    private func bucketOrder(_ a: ScheduleEntry, _ b: ScheduleEntry) -> Bool {
        if a.date != b.date { return a.date < b.date }
        switch (a.shiftStart, b.shiftStart) {
        case let (sa?, sb?): return sa < sb
        case (nil, _?):      return true   // all-day shifts sort first
        case (_?, nil):      return false
        case (nil, nil):
            return projectName(a) < projectName(b)
        }
    }

    private func projectName(_ entry: ScheduleEntry) -> String {
        store.projects.first(where: { $0.id == entry.projectID })?.name ?? ""
    }

    /// Default date used by the section "+" button when creating a
    /// shift directly into a bucket. Conflicts has no creation entry
    /// (they're derived, not authored).
    private func createDate(for key: DispatchSectionKey) -> Date? {
        let now = Date()
        switch key {
        case .unscheduled: return now                                                  // crew left blank
        case .today:       return now
        case .tomorrow:    return calendar.date(byAdding: .day, value: 1, to: now) ?? now
        case .thisWeek:    return calendar.date(byAdding: .day, value: 2, to: now) ?? now
        case .conflicts:   return nil
        case .completed:   return nil
        }
    }
}

// MARK: - Section keys

private enum DispatchSectionKey: Hashable {
    case unscheduled, today, tomorrow, thisWeek, conflicts, completed
}

// MARK: - Sheet item wrappers

private struct EntryPick: Identifiable {
    let id: UUID
    let entry: ScheduleEntry
}

/// Local conflict-pick wrapper. Mirrors the one in ScheduleCalendarView.swift,
/// which is `private` there — we can't reuse it cross-file.
private struct BoardConflictPick: Identifiable {
    let id: String
    let conflict: ScheduleConflict
}

// MARK: - Shift card

private struct DispatchShiftCard: View {
    let entry: ScheduleEntry
    /// Phase 2 hardening: pre-resolved by the parent so we don't
    /// rerun the conflict detector per card.
    let inLiveConflict: Bool
    /// nil = read-only (no tap action). Used for Completed-section cards.
    let onTap: (() -> Void)?
    /// Provided only on Unscheduled cards (and only when the user has
    /// schedule edit permission) — surfaces the Quick Assign affordance.
    let onQuickAssign: (() -> Void)?

    @EnvironmentObject var store: AppStore

    private var project: Project? { store.projects.first(where: { $0.id == entry.projectID }) }
    private var crew: Crew? { entry.crewID.flatMap { cid in store.crews.first(where: { $0.id == cid }) } }

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) { cardContent }
                    .buttonStyle(.plain)
            } else {
                // Read-only — no tap target, no haptic.
                cardContent
            }
        }
    }

    private var cardContent: some View {
        HStack(alignment: .top, spacing: 10) {
            statusStripe
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if inLiveConflict {
                        // Inline conflict marker so the dispatcher
                        // doesn't have to scroll to the Conflicts
                        // column to know which cards need attention.
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                            .accessibilityLabel("In live conflict")
                    }
                    Text(project?.name ?? "Unknown Project")
                        .font(.subheadline).bold()
                        .lineLimit(1)
                    Spacer()
                    statusPill
                }
                HStack(spacing: 12) {
                    // RA-3: render via assignment helper so custom_crew
                    // and individual_worker shifts show the correct
                    // label instead of misleading "Unassigned".
                    Label(entry.assignmentLabel(crews: store.crews, employees: store.employees),
                          systemImage: entry.assignmentIconName)
                        .font(.caption)
                        .foregroundColor(entry.hasNoResources ? .orange : .secondary)
                    if let timeRange = formattedTimeRange {
                        Label(timeRange, systemImage: "clock")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Label(entry.date.formatted(date: .abbreviated, time: .omitted),
                          systemImage: "calendar")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let task = entry.taskDescription, !task.isEmpty {
                    Text(task)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                if !entry.requiredCertifications.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.shield")
                            .font(.caption2)
                            .foregroundColor(.indigo)
                        Text(entry.requiredCertifications.joined(separator: " · "))
                            .font(.caption2)
                            .foregroundColor(.indigo)
                            .lineLimit(1)
                    }
                }
                if let onQuickAssign {
                    // Label adapts to whether the shift already has a
                    // crew. "Assign Crew" on Unscheduled = first-time
                    // attach. "Reassign" on Today/Tomorrow/Week = swap
                    // the existing crew. Same sheet in both cases.
                    let isUnassigned = entry.crewID == nil
                    Button(action: onQuickAssign) {
                        Label(isUnassigned ? "Assign Crew" : "Reassign",
                              systemImage: isUnassigned ? "person.badge.plus" : "arrow.triangle.2.circlepath")
                            .font(.caption.bold())
                            .foregroundColor(isUnassigned ? .white : .primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(isUnassigned ? Color.blue : Color.secondary.opacity(0.18))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(10)
    }

    private var statusStripe: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(statusColor)
            .frame(width: 4)
            .frame(maxHeight: .infinity)
    }

    private var statusColor: Color {
        switch entry.status {
        case .scheduled:   return .blue
        case .inProgress:  return .green
        case .completed:   return .gray
        case .cancelled:   return .red
        case .rescheduled: return .orange
        }
    }

    private var statusPill: some View {
        Text(entry.status.displayLabel.uppercased())
            .font(.caption2).bold()
            .foregroundColor(statusColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.15))
            .clipShape(Capsule())
    }

    private var formattedTimeRange: String? {
        switch (entry.shiftStart, entry.shiftEnd) {
        case let (s?, e?):
            return "\(s.formatted(date: .omitted, time: .shortened))–\(e.formatted(date: .omitted, time: .shortened))"
        case let (s?, nil):
            return s.formatted(date: .omitted, time: .shortened)
        case (nil, let e?):
            return "until \(e.formatted(date: .omitted, time: .shortened))"
        case (nil, nil):
            return nil
        }
    }
}

// MARK: - Conflict card

private struct DispatchConflictCard: View {
    let conflict: ScheduleConflict
    /// nil = read-only (no tap target). Used for field-worker views.
    let onTap: (() -> Void)?

    @EnvironmentObject var store: AppStore

    private var color: Color {
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

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) { conflictContent }
                    .buttonStyle(.plain)
            } else {
                conflictContent
            }
        }
    }

    private var conflictContent: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: conflict.conflictType.icon)
                        .foregroundColor(color)
                    Text(conflict.conflictType.severity.uppercased())
                        .font(.caption2).bold()
                        .foregroundColor(color)
                    Spacer()
                    Text(conflict.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Text(conflict.description)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(3)
                if !conflict.affectedEntries.isEmpty {
                    Text(affectedSummary)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(10)
    }

    private var affectedSummary: String {
        conflict.affectedEntries.prefix(3).map { entry in
            let proj = store.projects.first(where: { $0.id == entry.projectID })?.name ?? "Unknown"
            let crew = entry.crewID.flatMap { cid in store.crews.first(where: { $0.id == cid })?.name }
            if let crew { return "\(crew) · \(proj)" }
            return proj
        }.joined(separator: " ↔ ")
    }
}

// MARK: - Empty card

private struct EmptyDispatchCard: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(.tertiarySystemGroupedBackground))
            .cornerRadius(10)
    }
}

// MARK: - Quick Assign Sheet (Phase 2 enterprise hardening)

/// Smart crew picker used by Unscheduled-column cards. The Phase 1
/// version was a simple dropdown + busy-chip warning; this version:
///
///   • SUGGESTS the last-used crew on this project (top of list, "Last
///     used" pill). Reduces typical clicks from 3 → 1 (just "Assign")
///     because the suggestion is preselected on appear.
///   • PRE-FLIGHT CONFLICT SIMULATION — when the user picks a crew, we
///     snapshot the entry with that crew, run the same detector that
///     would run on save, and surface the result inline. No silent
///     assigns into a clash; no surprise alert after the user already
///     committed.
///   • RECOMMENDED ALTERNATIVE — when the selected crew would clash,
///     we look for a free, equally-active crew and offer it as a
///     one-tap fix.
///   • AUTO-FILL — on apply, any task description / cost code that's
///     blank on the entry but set on the project's most recent shift
///     gets quietly populated. The dispatcher doesn't have to retype
///     metadata that's already in the system.
///   • Goes through the same `upsertScheduleEntry(force:auditNote:)`
///     chokepoint as everywhere else, so the audit log captures the
///     "Quick Assign from Dispatch Board" provenance.
///
/// Permission: this whole sheet is unreachable for non-edit roles
/// because the parent only attaches `onQuickAssign` when canEditSchedule
/// is true. The sheet itself doesn't re-check the gate.
private struct QuickAssignSheet: View {
    let entry: ScheduleEntry
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    @State private var selectedCrewID: UUID?
    /// The crew we'd pre-select on appear (last-used for this project).
    @State private var suggestedCrewID: UUID?
    /// Computed live in the body — no @State needed, just for clarity.
    private var simulatedConflict: ScheduleConflict? {
        guard let crewID = selectedCrewID else { return nil }
        var probe = entry
        probe.crewID = crewID
        // Detect against the full schedule + crews + employees so all
        // 7 conflict types fire (not just crew double-book).
        let pool = store.scheduleEntries.filter { !$0.isDeleted }
            .filter { $0.id != entry.id }
            + [probe]
        let conflicts = ScheduleConflictService.detect(
            in: pool,
            projects: store.projects,
            crews: store.crews,
            employees: store.employees,
            travelBufferMinutes: AppSettings.shared.travelBufferMinutes,
            overtimeWeeklyThresholdHours: AppSettings.shared.overtimeWeeklyThresholdHours
        )
        return conflicts.first(where: { $0.affectedEntries.contains(where: { $0.id == probe.id }) })
    }

    private var availableCrews: [Crew] {
        store.crews.filter { $0.isActive }.sorted { $0.name < $1.name }
    }

    /// Crews already booked on this same calendar day (any project).
    /// Soft warning, not a block — used by the row chip.
    private var busyCrewIDs: Set<UUID> {
        let cal = Calendar.current
        let day = cal.startOfDay(for: entry.date)
        let busy = store.scheduleEntries
            .filter { !$0.isDeleted && $0.id != entry.id }
            .filter { cal.isDate($0.date, inSameDayAs: day) }
            .compactMap { $0.crewID }
        return Set(busy)
    }

    /// "Last-used crew on this project" — the crew most recently
    /// scheduled on this entry's project (other than nil). Drives the
    /// preselect + the "Last used" pill. nil if the project has never
    /// had a crew assigned.
    private var lastUsedCrewID: UUID? {
        store.scheduleEntries
            .filter { !$0.isDeleted && $0.projectID == entry.projectID && $0.id != entry.id }
            .compactMap { e -> (Date, UUID)? in
                guard let cid = e.crewID else { return nil }
                return (e.date, cid)
            }
            .max(by: { $0.0 < $1.0 })?
            .1
    }

    /// First active crew that wouldn't clash with the entry — the
    /// "Use Crew X instead" recommendation when the picked crew has
    /// a conflict. We use the simulated-conflict detector (full Phase
    /// 1 detection) so the recommendation is robust across all 7
    /// conflict types, not just crew double-book.
    private var recommendedFreeCrew: Crew? {
        let pool = store.scheduleEntries.filter { !$0.isDeleted && $0.id != entry.id }
        for crew in availableCrews where crew.id != selectedCrewID {
            var probe = entry
            probe.crewID = crew.id
            let conflicts = ScheduleConflictService.detect(
                in: pool + [probe],
                projects: store.projects,
                crews: store.crews,
                employees: store.employees,
                travelBufferMinutes: AppSettings.shared.travelBufferMinutes,
                overtimeWeeklyThresholdHours: AppSettings.shared.overtimeWeeklyThresholdHours
            )
            if !conflicts.contains(where: { $0.affectedEntries.contains(where: { $0.id == probe.id }) }) {
                return crew
            }
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                shiftSummarySection
                if let suggested = suggestedCrewID,
                   let crew = store.crews.first(where: { $0.id == suggested }) {
                    suggestionSection(crew: crew)
                }
                crewListSection
                if let conflict = simulatedConflict {
                    conflictPreviewSection(conflict: conflict)
                }
            }
            .navigationTitle(entry.crewID == nil ? "Assign Crew" : "Reassign Crew")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    // When the simulator has flagged a conflict, the
                    // primary Assign button is INTENTIONALLY disabled.
                    // The user must explicitly route through the
                    // "Assign Anyway" / "Use suggested crew" buttons
                    // in the conflict preview section — no silent
                    // overrides via the main toolbar button.
                    let isReassign = entry.crewID != nil
                    let actionLabel = isReassign ? "Save" : "Assign"
                    // Reassign: also disable when nothing changed.
                    let nothingChanged = isReassign && selectedCrewID == entry.crewID
                    Button(actionLabel) { applyAssign(force: false) }
                        .bold()
                        .disabled(selectedCrewID == nil
                                  || simulatedConflict != nil
                                  || nothingChanged)
                }
            }
            .onAppear {
                // Two preselect paths:
                //   • Reassign — the entry already has a crew. Preselect
                //     the CURRENT crew so the dispatcher just sees
                //     "this shift has Crew X" and picks a different one.
                //     Don't show the "Suggested" pill in this case
                //     (the current assignment isn't a suggestion).
                //   • First-time assign — preselect the last-used crew
                //     on this project. Show the "Suggested" pill.
                if selectedCrewID == nil {
                    if let current = entry.crewID {
                        selectedCrewID = current
                        suggestedCrewID = nil
                    } else if let last = lastUsedCrewID {
                        suggestedCrewID = last
                        selectedCrewID = last
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var shiftSummarySection: some View {
        Section {
            Text(store.projects.first(where: { $0.id == entry.projectID })?.name ?? "Unknown Project")
                .font(.headline)
            Text(entry.date.formatted(date: .complete, time: .omitted))
                .font(.caption)
                .foregroundColor(.secondary)
            if let s = entry.shiftStart {
                Label(s.formatted(date: .omitted, time: .shortened),
                      systemImage: "clock")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Shift")
        }
    }

    @ViewBuilder
    private func suggestionSection(crew: Crew) -> some View {
        Section {
            Button {
                selectedCrewID = crew.id
            } label: {
                HStack {
                    Image(systemName: selectedCrewID == crew.id ? "largecircle.fill.circle" : "circle")
                        .foregroundColor(selectedCrewID == crew.id ? .blue : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(crew.name).foregroundColor(.primary)
                        Text("Last used on this project")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text("SUGGESTED")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue)
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(.plain)
        } header: {
            Text("Suggested")
        }
    }

    private var crewListSection: some View {
        Section {
            if availableCrews.isEmpty {
                Text("No active crews available.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(availableCrews) { crew in
                    Button {
                        selectedCrewID = crew.id
                    } label: {
                        HStack {
                            Image(systemName: selectedCrewID == crew.id ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(selectedCrewID == crew.id ? .blue : .secondary)
                            Text(crew.name).foregroundColor(.primary)
                            if busyCrewIDs.contains(crew.id) {
                                Text("busy that day")
                                    .font(.caption2).bold()
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("All active crews")
        } footer: {
            Text("Conflicts surface here before you assign — no surprises after the fact.")
        }
    }

    @ViewBuilder
    private func conflictPreviewSection(conflict: ScheduleConflict) -> some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: conflict.conflictType.icon)
                    .foregroundColor(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text(conflict.conflictType.severity)
                        .font(.caption.bold())
                        .foregroundColor(.red)
                    Text(conflict.description)
                        .font(.subheadline)
                }
            }
            if let alt = recommendedFreeCrew {
                Button {
                    selectedCrewID = alt.id
                } label: {
                    Label("Use \(alt.name) instead (no clash)", systemImage: "wand.and.stars")
                        .font(.subheadline.bold())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Text("No free crew found this day. Reschedule or override.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Button(role: .destructive) {
                applyAssign(force: true)
            } label: {
                Label("Assign Anyway (override)", systemImage: "exclamationmark.shield")
                    .font(.subheadline)
            }
        } header: {
            Text("Conflict preview")
        } footer: {
            Text("Override is logged to the audit trail with the conflict types that were active.")
        }
    }

    /// Saves the assignment via the central chokepoint. When a
    /// conflict was simulated and the user explicitly clicked "Assign
    /// Anyway", we pass force=true and a clear audit note.
    private func applyAssign(force: Bool) {
        guard let crewID = selectedCrewID else { return }
        var updated = entry
        updated.crewID = crewID
        // Auto-fill: if the entry has no cost code or task, pull from
        // the project's most recent shift. Reduces redundant data entry.
        if updated.costCode == nil || updated.costCode?.isEmpty == true {
            updated.costCode = lastUsedCostCodeForProject(entry.projectID)
        }
        if updated.taskDescription == nil || updated.taskDescription?.isEmpty == true {
            updated.taskDescription = lastUsedTaskForProject(entry.projectID)
        }
        updated.updatedAt = Date()
        updated.lastModifiedAt = Date()
        updated.syncStatus = .pending
        // Audit note distinguishes first-time assign vs reassign vs
        // override, so a reviewer reading the audit log can see the
        // intent at a glance.
        let isReassign = entry.crewID != nil
        let baseLabel  = isReassign ? "Reassign" : "Quick Assign"
        let auditNote  = force
            ? "\(baseLabel) override (Dispatch Board)"
            : "\(baseLabel) (Dispatch Board)"
        let conflict = store.upsertScheduleEntry(updated, force: force, auditNote: auditNote)
        if let conflict, !force {
            // Shouldn't reach here — the simulator should have surfaced
            // this BEFORE the user tapped Assign. If it does, the most
            // likely cause is a concurrent edit from another device
            // changing the underlying state between simulation and save.
            // Safety net: toast and refuse silent overwrite.
            ToastService.shared.error("Conflict appeared between preview and save: \(conflict.description). Please review.")
            return
        }
        dismiss()
    }

    private func lastUsedCostCodeForProject(_ pid: UUID) -> String? {
        store.scheduleEntries
            .filter { !$0.isDeleted && $0.projectID == pid && $0.id != entry.id }
            .sorted { $0.date > $1.date }
            .first(where: { $0.costCode != nil && !($0.costCode?.isEmpty ?? true) })?
            .costCode
    }

    private func lastUsedTaskForProject(_ pid: UUID) -> String? {
        store.scheduleEntries
            .filter { !$0.isDeleted && $0.projectID == pid && $0.id != entry.id }
            .sorted { $0.date > $1.date }
            .first(where: { $0.taskDescription != nil && !($0.taskDescription?.isEmpty ?? true) })?
            .taskDescription
    }
}

// MARK: - Calendar.startOfWeek (file-private)
//
// Mirrors the helper in CrewCalendarView.swift (which is fileprivate
// there). Promoting either to a shared extension is a refactor for
// later; duplicating one line keeps Phase 2 self-contained.

extension Calendar {
    fileprivate func dispatchStartOfWeek(for date: Date) -> Date {
        let comps = dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return self.date(from: comps) ?? startOfDay(for: date)
    }
}
