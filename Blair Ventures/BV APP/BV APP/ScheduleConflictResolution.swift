// ScheduleConflictResolution.swift
// Aski IQ — Resolve a detected schedule conflict (Tier A).
//
// WHY THIS EXISTS
// `ScheduleConflictService` already detects three kinds of conflicts and
// `ScheduleCalendarView` already shows a red banner when one exists on
// the selected day. Until now the user could SEE the conflict but had no
// way to DO anything about it — they had to navigate back to the entry,
// edit it, save, return to the calendar, and hope the banner cleared.
//
// This file closes that loop. From any conflict row we let the user
// pick one of the affected entries and apply one of three resolutions:
//
//   1. Reassign — change the crew on the entry. Resolves crew double-
//      bookings 99% of the time (just put a different crew on the second
//      project).
//
//   2. Move shift — bump the entry to a different day. Used when both
//      projects genuinely need the same crew but on different days.
//
//   3. Acknowledge override — the operator has decided to proceed
//      anyway (e.g. crew is splitting their day across two projects on
//      purpose). Stamps a "✓ acknowledged" note on each affected entry
//      and persists the conflict's stable hash to UserDefaults so the
//      banner stops re-firing for it.
//
// PERSISTENCE NOTE
// Acknowledged keys live in UserDefaults — this is a UI/operator
// preference, not business data. Each conflict gets a STABLE hash from
// type + date + sorted entry IDs so the same conflict re-detected on
// the next app launch matches the stored key.
//
// MULTI-TENANT NOTE
// The UserDefaults key is namespaced by `currentCompanyID` so a user
// who switches between companies doesn't see one company's
// acknowledgements bleed into another.

import SwiftUI
import Foundation
import Combine

// MARK: - Stable Conflict Key

extension ScheduleConflict {
    /// Deterministic hash that survives detection passes. We can't use
    /// `id` because `ScheduleConflictService.detect(...)` mints a fresh
    /// UUID each call. Affected-entry IDs are sorted so order shifts in
    /// the input array don't invalidate stored acknowledgements.
    var stableKey: String {
        let entryIDs = affectedEntries
            .map { $0.id.uuidString }
            .sorted()
            .joined(separator: ",")
        let typeTag: String
        switch conflictType {
        case .crewDoubleBooked:     typeTag = "crewdb"
        case .projectOverlap:       typeTag = "projovl"
        case .weekendWork:          typeTag = "weekend"
        case .employeeDoubleBooked: typeTag = "empdb"
        case .travelBuffer:         typeTag = "travel"
        case .certificationMissing: typeTag = "certmiss"
        case .overtimeRisk:         typeTag = "ot"
        }
        let day = Int(date.timeIntervalSince1970)
        return "\(typeTag)|\(day)|\(entryIDs)"
    }
}

// MARK: - AppStore: Acknowledgement Persistence

extension AppStore {

    /// UserDefaults key. Per-company so switching tenants doesn't
    /// leak acknowledgements across them.
    private var conflictAckDefaultsKey: String {
        let suffix = currentCompanyID?.uuidString ?? "anon"
        return "aski.scheduleConflict.acknowledged.\(suffix)"
    }

    /// All currently-acknowledged conflict stable keys for this tenant.
    var acknowledgedConflictKeys: Set<String> {
        let arr = UserDefaults.standard
            .stringArray(forKey: conflictAckDefaultsKey) ?? []
        return Set(arr)
    }

    /// True when the operator has already dismissed this exact conflict.
    /// `ScheduleConflictRow` uses this to render an "acknowledged" pill
    /// instead of the urgent banner color.
    func isAcknowledged(_ conflict: ScheduleConflict) -> Bool {
        acknowledgedConflictKeys.contains(conflict.stableKey)
    }

    /// Persists the ack and stamps a marker into each affected entry's
    /// `notes` so the audit trail survives even if the UserDefaults
    /// store is wiped (reinstall, new device, multi-device user).
    /// Idempotent — calling twice with the same conflict only stamps once.
    func acknowledgeConflict(_ conflict: ScheduleConflict, reason: String?) {
        var keys = acknowledgedConflictKeys
        guard !keys.contains(conflict.stableKey) else { return }
        keys.insert(conflict.stableKey)
        UserDefaults.standard.set(Array(keys), forKey: conflictAckDefaultsKey)

        // Stamp a note line on each affected entry. Using a stable
        // marker prefix means we can detect already-stamped entries
        // and not double-stamp on a second ack pass.
        let stampDate = ISO8601DateFormatter().string(from: Date())
        let by = currentUser?.fullName ?? "operator"
        let marker = "✓ Conflict acknowledged \(stampDate) by \(by)"
        let suffix = (reason?.isEmpty ?? true) ? "" : " — \(reason!)"
        let line = marker + suffix

        for entry in conflict.affectedEntries {
            guard let idx = scheduleEntries.firstIndex(where: { $0.id == entry.id }) else { continue }
            var current = scheduleEntries[idx]
            let existingNotes = current.notes ?? ""
            // Skip if marker already present (idempotency safety net).
            if existingNotes.contains("✓ Conflict acknowledged") {
                continue
            }
            current.notes = existingNotes.isEmpty ? line : existingNotes + "\n" + line
            current.updatedAt = Date()
            current.lastModifiedAt = Date()
            current.syncStatus = .pending
            scheduleEntries[idx] = current
        }
        saveToDisk()
        Task { await SyncEngine.shared.pushPending() }
        // Force published refresh — UserDefaults isn't observed.
        objectWillChange.send()
    }

    /// Undo a previous acknowledgement (admin-only escape hatch — e.g.
    /// the operator clicked through too fast and wants the warning back).
    /// Does NOT remove the audit-trail note line from `entry.notes` —
    /// the historical ack is still visible for auditors.
    func unacknowledgeConflict(_ conflict: ScheduleConflict) {
        var keys = acknowledgedConflictKeys
        guard keys.contains(conflict.stableKey) else { return }
        keys.remove(conflict.stableKey)
        UserDefaults.standard.set(Array(keys), forKey: conflictAckDefaultsKey)
        objectWillChange.send()
    }

    /// Live (un-acknowledged) view of `scheduleConflicts`. Used by the
    /// toolbar badge and the conflict banner — once you ack a clash you
    /// shouldn't see the alarm anymore. The ack record stays in entry
    /// notes for audit.
    var liveScheduleConflicts: [ScheduleConflict] {
        scheduleConflicts.filter { !isAcknowledged($0) }
    }

    /// Same idea but only the high-severity (true) conflicts.
    var liveCriticalScheduleConflicts: [ScheduleConflict] {
        criticalScheduleConflicts.filter { !isAcknowledged($0) }
    }

    /// Live conflicts on a specific day. Replaces direct calls to
    /// `conflictsOn(date:)` for UI purposes.
    func liveConflictsOn(date: Date) -> [ScheduleConflict] {
        conflictsOn(date: date).filter { !isAcknowledged($0) }
    }
}

// MARK: - AppStore: Reassign / Move Helpers

extension AppStore {

    /// Reassign one schedule entry to a different crew. The double-book
    /// check runs again on the new crew so we don't simply move the
    /// problem onto a second crew. Returns the new conflict (if any) so
    /// the caller can prompt again. Returns nil on success.
    @discardableResult
    func reassignScheduleEntry(_ entryID: UUID, to newCrewID: UUID?) -> ScheduleConflict? {
        guard let idx = scheduleEntries.firstIndex(where: { $0.id == entryID }) else { return nil }
        var entry = scheduleEntries[idx]
        // No-op: same crew. Don't churn a sync push for nothing.
        if entry.crewID == newCrewID { return nil }
        entry.crewID = newCrewID
        entry.updatedAt = Date()
        entry.lastModifiedAt = Date()
        entry.syncStatus = .pending
        return upsertScheduleEntry(entry)
    }

    /// Move a schedule entry to a different day. Same double-book
    /// re-check as `reassignScheduleEntry`. The shift's start/end times
    /// (if set) keep their hour/minute but slide to the new calendar day.
    @discardableResult
    func moveScheduleEntry(_ entryID: UUID, to newDate: Date) -> ScheduleConflict? {
        guard let idx = scheduleEntries.firstIndex(where: { $0.id == entryID }) else { return nil }
        var entry = scheduleEntries[idx]
        let cal = Calendar.current
        let oldDay = cal.startOfDay(for: entry.date)
        let newDay = cal.startOfDay(for: newDate)
        if oldDay == newDay { return nil }

        // Slide shift bounds onto the new day (preserve hour/minute).
        if let s = entry.shiftStart {
            let comps = cal.dateComponents([.hour, .minute], from: s)
            entry.shiftStart = cal.date(bySettingHour: comps.hour ?? 0,
                                        minute: comps.minute ?? 0,
                                        second: 0,
                                        of: newDay)
        }
        if let e = entry.shiftEnd {
            let comps = cal.dateComponents([.hour, .minute], from: e)
            entry.shiftEnd = cal.date(bySettingHour: comps.hour ?? 0,
                                      minute: comps.minute ?? 0,
                                      second: 0,
                                      of: newDay)
        }
        entry.date = newDay
        entry.status = .rescheduled
        entry.updatedAt = Date()
        entry.lastModifiedAt = Date()
        entry.syncStatus = .pending
        return upsertScheduleEntry(entry)
    }
}

// MARK: - Conflict Resolution Sheet

/// Bottom sheet presented from a tap on `ScheduleConflictRow`. Shows
/// the affected entries, lets the user pick one, then offers the three
/// resolution actions. Only crew double-bookings expose all three
/// actions — project-overlap and weekend-work conflicts are warnings
/// where "Acknowledge" is the only sensible move.
struct ConflictResolutionSheet: View {
    let conflict: ScheduleConflict
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    @State private var selectedEntryID: UUID?
    @State private var showReassign = false
    @State private var showMove = false
    @State private var showAck = false
    @State private var ackReason: String = ""
    @State private var resultMessage: String?
    @State private var resultIsError = false

    private var canAct: Bool {
        conflict.conflictType == .crewDoubleBooked && selectedEntryID != nil
    }

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

    private var selectedEntry: ScheduleEntry? {
        guard let id = selectedEntryID else { return nil }
        return conflict.affectedEntries.first(where: { $0.id == id })
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Header
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: conflict.conflictType.icon)
                            .font(.title2)
                            .foregroundColor(conflictColor)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conflict.conflictType.severity)
                                .font(.caption).bold()
                                .foregroundColor(conflictColor)
                            Text(conflict.description)
                                .font(.subheadline)
                            Text(conflict.date.formatted(date: .complete, time: .omitted))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // MARK: Already-acknowledged state
                if store.isAcknowledged(conflict) {
                    Section {
                        Label("Already acknowledged", systemImage: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        Button(role: .destructive) {
                            store.unacknowledgeConflict(conflict)
                            resultMessage = "Acknowledgement removed."
                            resultIsError = false
                        } label: {
                            Label("Re-open this conflict", systemImage: "arrow.uturn.backward")
                        }
                    } footer: {
                        Text("The audit-trail note on each affected shift is preserved.")
                    }
                } else {
                    // MARK: Pick which shift to fix (only matters for
                    // double-bookings — single-entry conflicts auto-pick).
                    if conflict.affectedEntries.count > 1 {
                        Section {
                            ForEach(conflict.affectedEntries) { entry in
                                Button {
                                    selectedEntryID = entry.id
                                } label: {
                                    affectedEntryRow(entry,
                                                     selected: selectedEntryID == entry.id)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text("Which shift to change")
                        } footer: {
                            Text("Pick the shift you want to move or reassign. Acknowledging applies to both.")
                        }
                    } else if let only = conflict.affectedEntries.first {
                        Section("Shift") {
                            affectedEntryRow(only, selected: true)
                                .onAppear { selectedEntryID = only.id }
                        }
                    }

                    // MARK: Resolution actions
                    Section("Fix options") {
                        Button {
                            showReassign = true
                        } label: {
                            actionRow(
                                title: "Reassign to different crew",
                                subtitle: "Move just this shift to a free crew.",
                                systemImage: "person.2.crop.square.stack",
                                tint: .blue,
                                enabled: canAct
                            )
                        }
                        .disabled(!canAct)

                        Button {
                            showMove = true
                        } label: {
                            actionRow(
                                title: "Move shift to a different day",
                                subtitle: "Slide the same crew + project to another date.",
                                systemImage: "calendar.badge.plus",
                                tint: .indigo,
                                enabled: selectedEntryID != nil
                            )
                        }
                        .disabled(selectedEntryID == nil)

                        Button {
                            showAck = true
                        } label: {
                            actionRow(
                                title: "Acknowledge override",
                                subtitle: "Approve this clash. Stamps an audit note and silences the banner.",
                                systemImage: "checkmark.shield",
                                tint: .green,
                                enabled: true
                            )
                        }
                    }
                }

                // MARK: Result toast
                if let msg = resultMessage {
                    Section {
                        Label(msg, systemImage: resultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundColor(resultIsError ? .red : .green)
                    }
                }
            }
            .navigationTitle("Resolve Conflict")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.bold()
                }
            }
            .sheet(isPresented: $showReassign) {
                if let entry = selectedEntry {
                    ReassignCrewSheet(entry: entry, conflict: conflict) { newCrewID, conflictAfter in
                        applyReassignResult(newCrewID: newCrewID, conflict: conflictAfter)
                    }
                    .environmentObject(store)
                }
            }
            .sheet(isPresented: $showMove) {
                if let entry = selectedEntry {
                    MoveShiftSheet(entry: entry, conflict: conflict) { newDate, conflictAfter in
                        applyMoveResult(newDate: newDate, conflict: conflictAfter)
                    }
                    .environmentObject(store)
                }
            }
            .alert("Acknowledge this conflict?", isPresented: $showAck) {
                TextField("Optional reason", text: $ackReason)
                Button("Cancel", role: .cancel) { }
                Button("Acknowledge") {
                    store.acknowledgeConflict(conflict, reason: ackReason.trimmingCharacters(in: .whitespaces).isEmpty ? nil : ackReason)
                    resultMessage = "Conflict acknowledged. The banner will clear."
                    resultIsError = false
                    ackReason = ""
                }
            } message: {
                Text("Stamps an audit note on each affected shift. You can re-open it later.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Result handlers

    private func applyReassignResult(newCrewID: UUID?, conflict newConflict: ScheduleConflict?) {
        if let nc = newConflict {
            resultMessage = "Reassign would still clash: \(nc.description). Try a different crew."
            resultIsError = true
        } else {
            let newCrewName = newCrewID
                .flatMap { id in store.crews.first(where: { $0.id == id }) }?
                .name ?? "Unassigned"
            resultMessage = "Reassigned to \(newCrewName)."
            resultIsError = false
            // Refresh selection — entry has new crewID under same id.
            objectWillChangeBump()
        }
    }

    private func applyMoveResult(newDate: Date, conflict newConflict: ScheduleConflict?) {
        if let nc = newConflict {
            resultMessage = "Moving would still clash: \(nc.description). Try another day."
            resultIsError = true
        } else {
            resultMessage = "Moved to \(newDate.formatted(date: .abbreviated, time: .omitted))."
            resultIsError = false
            objectWillChangeBump()
        }
    }

    /// Forces a re-render so the (newly resolved) conflict either
    /// disappears from the live list or shows the updated metadata.
    private func objectWillChangeBump() {
        // Touching @State triggers a body recompute.
        let bump = selectedEntryID
        selectedEntryID = nil
        selectedEntryID = bump
    }

    // MARK: - Subviews

    @ViewBuilder
    private func affectedEntryRow(_ entry: ScheduleEntry, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundColor(selected ? .blue : .secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(projectName(for: entry))
                    .font(.subheadline).bold()
                HStack(spacing: 6) {
                    if let crewName = crewName(for: entry) {
                        Label(crewName, systemImage: "person.2.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let s = entry.shiftStart {
                        Label(s.formatted(date: .omitted, time: .shortened),
                              systemImage: "clock")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                if let task = entry.taskDescription, !task.isEmpty {
                    Text(task).font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func actionRow(title: String, subtitle: String, systemImage: String, tint: Color, enabled: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundColor(enabled ? tint : .secondary)
                .frame(width: 28, height: 28)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundColor(enabled ? .primary : .secondary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Lookups

    private func projectName(for entry: ScheduleEntry) -> String {
        store.projects.first(where: { $0.id == entry.projectID })?.name ?? "Unknown Project"
    }

    private func crewName(for entry: ScheduleEntry) -> String? {
        guard let cid = entry.crewID else { return "Unassigned" }
        return store.crews.first(where: { $0.id == cid })?.name
    }
}

// MARK: - Reassign Crew Sheet

private struct ReassignCrewSheet: View {
    let entry: ScheduleEntry
    let conflict: ScheduleConflict
    let onApply: (UUID?, ScheduleConflict?) -> Void

    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var newCrewID: UUID?

    private var availableCrews: [Crew] {
        // Drop the current crew (already double-booked) and inactive crews.
        store.crews
            .filter { $0.isActive && $0.id != entry.crewID }
            .sorted { $0.name < $1.name }
    }

    /// Crews already booked on this same calendar day for any project.
    /// We don't HIDE them (operator may still want to pick one) but we
    /// flag them so the user makes the choice with eyes open.
    private var busyCrewIDs: Set<UUID> {
        let cal = Calendar.current
        let day = cal.startOfDay(for: entry.date)
        let busy = store.scheduleEntries
            .filter { !$0.isDeleted && $0.id != entry.id }
            .filter { cal.isDate($0.date, inSameDayAs: day) }
            .compactMap { $0.crewID }
        return Set(busy)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        newCrewID = nil
                    } label: {
                        HStack {
                            Image(systemName: newCrewID == nil ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(newCrewID == nil ? .blue : .secondary)
                            Text("Unassigned (clear crew)")
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section("Available crews") {
                    if availableCrews.isEmpty {
                        Text("No other active crews to choose from.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(availableCrews, id: \.id) { crew in
                            Button {
                                newCrewID = crew.id
                            } label: {
                                HStack {
                                    Image(systemName: newCrewID == crew.id ? "largecircle.fill.circle" : "circle")
                                        .foregroundColor(newCrewID == crew.id ? .blue : .secondary)
                                    Text(crew.name)
                                    if busyCrewIDs.contains(crew.id) {
                                        Text("busy that day")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.15))
                                            .cornerRadius(4)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Reassign Crew")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Apply") {
                        let result = store.reassignScheduleEntry(entry.id, to: newCrewID)
                        onApply(newCrewID, result)
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Move Shift Sheet

private struct MoveShiftSheet: View {
    let entry: ScheduleEntry
    let conflict: ScheduleConflict
    let onApply: (Date, ScheduleConflict?) -> Void

    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var newDate: Date

    init(entry: ScheduleEntry, conflict: ScheduleConflict, onApply: @escaping (Date, ScheduleConflict?) -> Void) {
        self.entry = entry
        self.conflict = conflict
        self.onApply = onApply
        // Default the picker to "tomorrow" of the conflict day so a
        // single tap of Apply produces a meaningful move.
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: entry.date) ?? entry.date
        _newDate = State(initialValue: nextDay)
    }

    private var sameDay: Bool {
        Calendar.current.isDate(newDate, inSameDayAs: entry.date)
    }

    /// Soft warning when crew is already booked on the proposed new day.
    /// Just a hint — the Apply action still re-checks via `upsertScheduleEntry`
    /// and surfaces a hard conflict back through `onApply`.
    private var crewBusyOnNewDate: Bool {
        guard let cid = entry.crewID else { return false }
        let cal = Calendar.current
        return store.scheduleEntries.contains { other in
            !other.isDeleted &&
            other.id != entry.id &&
            other.crewID == cid &&
            other.projectID != entry.projectID &&
            cal.isDate(other.date, inSameDayAs: newDate)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("New date",
                               selection: $newDate,
                               displayedComponents: .date)
                } header: {
                    Text("Move from \(entry.date.formatted(date: .abbreviated, time: .omitted))")
                } footer: {
                    if sameDay {
                        Text("Pick a different day to move the shift.")
                            .foregroundColor(.orange)
                    } else if crewBusyOnNewDate {
                        Text("Heads up: this crew already has a shift on a different project that day. Apply will re-check and warn if it would still clash.")
                            .foregroundColor(.orange)
                    } else {
                        Text("Shift start/end times are preserved. Status will be flipped to 'Rescheduled'.")
                    }
                }
            }
            .navigationTitle("Move Shift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Apply") {
                        let result = store.moveScheduleEntry(entry.id, to: newDate)
                        onApply(newDate, result)
                        dismiss()
                    }
                    .bold()
                    .disabled(sameDay)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
