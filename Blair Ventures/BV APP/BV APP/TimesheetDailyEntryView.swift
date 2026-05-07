// TimesheetDailyEntryView.swift
// FieldOS – Daily Timesheet Entry (Single Employee)

import SwiftUI

struct TimesheetDailyEntryView: View {
    @EnvironmentObject var store: AppStore
    @State private var vm: TimesheetViewModel = TimesheetViewModel(store: AppStore.shared);    @Environment(\.dismiss) var dismiss

    var preselectedEmployeeID: UUID? = nil
    var preselectedProjectID: UUID? = nil
    var preselectedDate: Date = Date()

    @State private var selectedEmployeeID: UUID? = nil
    @State private var selectedProjectID: UUID? = nil
    @State private var date: Date = Date()
    @State private var hasStartTime = true
    @State private var startTime: Date = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var hasEndTime = true
    @State private var endTime: Date = Calendar.current.date(bySettingHour: 15, minute: 30, second: 0, of: Date()) ?? Date()
    @State private var breakMinutes: Int = 30
    @State private var costCode: String = ""
    @State private var costCodeLabel: String = ""
    @State private var taskDescription: String = ""
    @State private var notes: String = ""
    @State private var costCodePickerShown = false

    @State private var showValidationError = false
    @State private var validationMessage = ""
    @State private var saved = false

    /// Phase 1 handoff — when the user picks a scheduled shift, we
    /// capture its ID here so the saved TimesheetEntry can back-link
    /// for plan-vs-actual reporting later. Cleared if the user
    /// changes employee/project/date away from the picked shift.
    @State private var pickedScheduleEntryID: UUID? = nil
    @State private var showSchedulePicker: Bool = false

    private var calculatedHours: Decimal {
        vm.calculateRegularHours(
            start: hasStartTime ? startTime : nil,
            end: hasEndTime ? endTime : nil,
            breakMinutes: breakMinutes
        )
    }

    private var overtimeHours: Decimal {
        vm.calculateOvertimeHours(total: calculatedHours)
    }

    private var regularHours: Decimal {
        min(calculatedHours, 8)
    }

    private var activeEmployees: [Employee] {
        store.employees.filter { $0.isActive }.sorted { $0.lastName < $1.lastName }
    }

    private var activeProjects: [Project] {
        store.projects.filter { $0.status == .active }.sorted { $0.name < $1.name }
    }

    /// Phase 1 — today's scheduled shifts on crews that include the
    /// currently selected employee (or the current user if no
    /// employee is selected yet). Surfaces as a quick "start from
    /// scheduled shift" CTA that pre-fills the form.
    private var todayScheduledShiftsForUser: [ScheduleEntry] {
        let cal = Calendar.current
        let today = date
        // Resolve the employee ID we care about. Prefers the picker's
        // selection; falls back to currentUser. If neither, no shifts.
        guard let empID = selectedEmployeeID ?? store.currentUser?.id else { return [] }
        // Crews this employee is on (member or foreman).
        let crewIDs = Set(store.crews
            .filter { $0.isActive && (($0.foremanID == empID) || $0.memberIDs.contains(empID)) }
            .map { $0.id })
        guard !crewIDs.isEmpty else { return [] }
        return store.scheduleEntries
            .filter {
                !$0.isDeleted
                && cal.isDate($0.date, inSameDayAs: today)
                && $0.crewID != nil
                && crewIDs.contains($0.crewID!)
                && $0.status != .cancelled
                && $0.status != .completed
            }
            .sorted { ($0.shiftStart ?? .distantFuture) < ($1.shiftStart ?? .distantFuture) }
    }

    var body: some View {
        Form {
                // MARK: - Phase 1 — Start from scheduled shift
                // CTA appears only when the current user has at least
                // one open scheduled shift today on a crew they're
                // part of. Pre-fills project / start time / cost code
                // / task description and stamps scheduleEntryID for
                // plan-vs-actual reporting downstream.
                if !todayScheduledShiftsForUser.isEmpty {
                    Section {
                        ForEach(todayScheduledShiftsForUser) { sched in
                            Button {
                                applyScheduledShift(sched)
                            } label: {
                                ScheduledShiftRow(
                                    entry: sched,
                                    isPicked: pickedScheduleEntryID == sched.id
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Label("Start from scheduled shift", systemImage: "calendar.circle.fill")
                            .foregroundColor(.blue)
                    } footer: {
                        Text(pickedScheduleEntryID == nil
                             ? "Tap a scheduled shift to pre-fill project, start time, cost code, and task. Times still need confirming after work ends."
                             : "Pre-filled from scheduled shift. Edit any field below before submitting.")
                            .font(.caption)
                    }
                }

                // MARK: - Who + Where
                Section("Entry Details *") {
                    Picker("Employee", selection: $selectedEmployeeID) {
                        Text("Select Employee").tag(UUID?.none)
                        ForEach(activeEmployees) { emp in
                            Text(emp.fullName).tag(Optional(emp.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(activeEmployees.isEmpty)

                    if activeEmployees.isEmpty {
                        Label(
                            "No employees available. Load Sample Data or add an employee first.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundColor(.orange)
                    }

                    Picker("Project", selection: $selectedProjectID) {
                        Text("Select Project").tag(UUID?.none)
                        ForEach(activeProjects) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                    .pickerStyle(.menu)

                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }

                // MARK: - Time
                Section("Time") {
                    Toggle("Set Start Time", isOn: $hasStartTime)
                    if hasStartTime {
                        DatePicker("Start Time", selection: $startTime, displayedComponents: .hourAndMinute)
                    }

                    Toggle("Set End Time", isOn: $hasEndTime)
                    if hasEndTime {
                        DatePicker("End Time", selection: $endTime, displayedComponents: .hourAndMinute)
                    }

                    Stepper("Break: \(breakMinutes) min", value: $breakMinutes, in: 0...120, step: 15)
                }

                // MARK: - Calculated Hours
                Section("Calculated Hours") {
                    HStack {
                        Label("Regular Hours", systemImage: "clock")
                        Spacer()
                        Text("\(regularHours) hrs")
                            .bold()
                            .foregroundColor(.green)
                    }
                    if overtimeHours > 0 {
                        HStack {
                            Label("Overtime Hours", systemImage: "clock.badge.exclamationmark")
                            Spacer()
                            Text("\(overtimeHours) hrs")
                                .bold()
                                .foregroundColor(.orange)
                        }
                    }
                    HStack {
                        Label("Total", systemImage: "sum")
                        Spacer()
                        Text("\(calculatedHours) hrs")
                            .bold()
                    }
                }

                // MARK: - Work Details
                Section("Work Details") {
                    Button {
                        costCodePickerShown = true
                    } label: {
                        HStack {
                            Label("Cost Code", systemImage: "tag")
                                .foregroundColor(.primary)
                            Spacer()
                            if costCode.isEmpty {
                                Text("Select…")
                                    .foregroundColor(.secondary)
                            } else {
                                Text(costCode)
                                    .font(.system(.subheadline, design: .monospaced))
                                    .bold()
                                    .foregroundStyle(.tint)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    if !costCodeLabel.isEmpty {
                        Text(costCodeLabel)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    TextField("Task Description", text: $taskDescription)
                    TextField("Notes", text: $notes)
                }
                .onChange(of: selectedProjectID) { _, _ in
                    costCode = ""
                    costCodeLabel = ""
                }
                .sheet(isPresented: $costCodePickerShown) {
                    CostCodePickerSheet(projectID: selectedProjectID) { selected in
                        costCode      = selected.code
                        costCodeLabel = selected.description
                    }
                    .environmentObject(store)
                }
            }
            .navigationTitle("Log Hours")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Submit") { submit() }
                        .bold()
                        .foregroundColor(selectedEmployeeID == nil ? .secondary : .green)
                        .disabled(selectedEmployeeID == nil)
                }
            }
            .alert("Missing Info", isPresented: $showValidationError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationMessage)
            }
            .onAppear {
                // Only pre-select the current user if they actually exist as an active
                // Employee. Setting selection to a UUID that isn't in the picker's tags
                // makes SwiftUI render the field blank instead of the "Select Employee"
                // placeholder.
                if let preselected = preselectedEmployeeID,
                   activeEmployees.contains(where: { $0.id == preselected }) {
                    selectedEmployeeID = preselected
                } else if let userID = store.currentUser?.id,
                          activeEmployees.contains(where: { $0.id == userID }) {
                    selectedEmployeeID = userID
                } else {
                    selectedEmployeeID = nil
                }
                selectedProjectID = preselectedProjectID
                date = preselectedDate
            }
            .onChange(of: store.employees) { _, _ in
                // If sample data loads (or an employee is deactivated) after this
                // sheet appears, drop a stale selection so the picker doesn't sit on
                // an ID that no longer matches any tag.
                if let id = selectedEmployeeID,
                   !activeEmployees.contains(where: { $0.id == id }) {
                    selectedEmployeeID = nil
                }
            }
    }

    private func submit() {
        guard let empID = selectedEmployeeID else {
            validationMessage = "Please select an employee."
            showValidationError = true
            return
        }
        guard let projID = selectedProjectID else {
            validationMessage = "Please select a project."
            showValidationError = true
            return
        }
        guard calculatedHours > 0 else {
            validationMessage = "Hours must be greater than zero. Check start and end times."
            showValidationError = true
            return
        }

        let entry = vm.createEntry(
            projectID: projID,
            employeeID: empID,
            date: date,
            startTime: hasStartTime ? startTime : nil,
            endTime: hasEndTime ? endTime : nil,
            breakMinutes: breakMinutes,
            costCode: costCode.isEmpty ? nil : costCode,
            taskDescription: taskDescription.isEmpty ? nil : taskDescription,
            notes: notes.isEmpty ? nil : notes,
            scheduleEntryID: pickedScheduleEntryID
        )
        vm.submit(entry)
        dismiss()
    }

    // MARK: - Phase 1 handoff helpers

    /// Pre-fills the form from a scheduled shift. Captures the
    /// schedule entry's ID so the saved timesheet entry back-links.
    /// Only overwrites fields that are still empty — the user might
    /// have already typed something they want to keep.
    private func applyScheduledShift(_ sched: ScheduleEntry) {
        pickedScheduleEntryID = sched.id
        // Project always overwrites — that's the strongest signal of intent
        selectedProjectID = sched.projectID
        // Date matches the schedule's date (user can re-pick if needed)
        date = sched.date
        // Start time — only set if user hasn't already typed
        if let s = sched.shiftStart {
            startTime = s
            hasStartTime = true
        }
        // End time isn't pre-filled — they'll set it when work ends
        // Cost code from the schedule
        if let cc = sched.costCode, costCode.isEmpty {
            costCode = cc
        }
        // Task description — same gentle fill rule
        if let task = sched.taskDescription, taskDescription.isEmpty {
            taskDescription = task
        }
    }
}

// MARK: - Scheduled-shift row (Phase 1)

/// Compact row used in the "Start from scheduled shift" section.
/// Shows project name, time range, and a check when the row is
/// currently the picked one.
private struct ScheduledShiftRow: View {
    @EnvironmentObject var store: AppStore
    let entry: ScheduleEntry
    let isPicked: Bool

    private var projectName: String {
        store.projects.first(where: { $0.id == entry.projectID })?.name ?? "—"
    }
    private var crewName: String {
        guard let cid = entry.crewID else { return "" }
        return store.crews.first(where: { $0.id == cid })?.name ?? ""
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isPicked ? "checkmark.circle.fill" : "calendar")
                .foregroundColor(isPicked ? .green : .blue)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(projectName).font(.subheadline.bold())
                Text(timeRange).font(.caption).foregroundColor(.secondary)
                if !crewName.isEmpty {
                    Text("Crew: \(crewName)").font(.caption2).foregroundColor(.secondary)
                }
                if let task = entry.taskDescription, !task.isEmpty {
                    Text(task).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
