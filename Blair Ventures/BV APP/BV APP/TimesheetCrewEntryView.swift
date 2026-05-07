// TimesheetCrewEntryView.swift
// FieldOS – Crew Timesheet Entry (Bulk)
// Foreman enters hours for the entire crew in one screen.
// Replaces the stub in SharedComponents.swift

import SwiftUI

struct TimesheetCrewEntryView: View {
    @EnvironmentObject var store: AppStore
    @State private var vm: TimesheetViewModel = TimesheetViewModel(store: AppStore.shared);    @Environment(\.dismiss) var dismiss

    var preselectedProjectID: UUID? = nil
    var preselectedCrewID: UUID? = nil

    @State private var selectedProjectID: UUID? = nil
    @State private var selectedCrewID: UUID? = nil
    @State private var date: Date = Date()
    @State private var globalStartTime: Date = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var globalEndTime: Date = Calendar.current.date(bySettingHour: 15, minute: 30, second: 0, of: Date()) ?? Date()
    @State private var globalBreakMinutes: Int = 30
    @State private var applyToAll: Bool = true
    @State private var crewRows: [CrewTimesheetRow] = []
    @State private var costCode: String = ""
    @State private var taskDescription: String = ""

    @State private var showValidationError = false
    @State private var validationMessage = ""
    @State private var showConfirmation = false

    private var activeProjects: [Project] {
        store.projects.filter { $0.status == .active }.sorted { $0.name < $1.name }
    }

    private var activeCrews: [Crew] {
        store.crews.filter { $0.isActive }.sorted { $0.name < $1.name }
    }

    private var totalHoursAllCrew: Decimal {
        crewRows.filter { $0.isIncluded }.reduce(0) { $0 + $1.calculatedHours }
    }

    var body: some View {
        NavigationStack {
            Form {

                // MARK: - Project + Crew
                Section("Assignment *") {
                    Picker("Project", selection: $selectedProjectID) {
                        Text("Select Project").tag(UUID?.none)
                        ForEach(activeProjects) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedProjectID) { loadCrewForProject() }

                    Picker("Crew", selection: $selectedCrewID) {
                        Text("Select Crew").tag(UUID?.none)
                        ForEach(activeCrews) { c in
                            Text(c.name).tag(Optional(c.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedCrewID) { loadCrewMembers() }

                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }

                // MARK: - Global Time (Apply to All)
                Section {
                    Toggle("Apply Same Hours to All", isOn: $applyToAll)
                    if applyToAll {
                        DatePicker("Start Time", selection: $globalStartTime, displayedComponents: .hourAndMinute)
                        DatePicker("End Time", selection: $globalEndTime, displayedComponents: .hourAndMinute)
                        Stepper("Break: \(globalBreakMinutes) min", value: $globalBreakMinutes, in: 0...120, step: 15)
                        TextField("Cost Code", text: $costCode)
                        TextField("Task Description", text: $taskDescription)

                        Button("Apply to All Members") {
                            applyGlobalToAll()
                        }
                        .foregroundColor(.blue)
                    }
                } header: {
                    Text("Shift Time")
                } footer: {
                    if applyToAll {
                        let hrs = vm.calculateRegularHours(
                            start: globalStartTime,
                            end: globalEndTime,
                            breakMinutes: globalBreakMinutes
                        )
                        Text("Calculated: \(hrs) hrs per person")
                    }
                }

                // MARK: - Crew Member Rows
                if !crewRows.isEmpty {
                    Section("Crew Members (\(crewRows.filter { $0.isIncluded }.count) of \(crewRows.count))") {
                        ForEach($crewRows) { $row in
                            CrewMemberTimesheetRow(row: $row, vm: vm)
                        }
                    }

                    Section {
                        HStack {
                            Text("Total Hours — All Crew")
                                .font(.headline)
                            Spacer()
                            Text("\(totalHoursAllCrew) hrs")
                                .font(.headline)
                                .bold()
                                .foregroundColor(.green)
                        }
                    }
                }
            }
            .navigationTitle("Crew Hours Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Submit All") { validateAndSubmit() }
                        .bold()
                        .foregroundColor(.green)
                        .disabled(crewRows.filter { $0.isIncluded }.isEmpty)
                }
            }
            .alert("Missing Info", isPresented: $showValidationError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationMessage)
            }
            .alert("Submit Timesheets?", isPresented: $showConfirmation) {
                Button("Submit", role: .none) { submitAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Submit \(crewRows.filter { $0.isIncluded }.count) timesheet entries for \(date.shortDate)?")
            }
            .onAppear {
                selectedProjectID = preselectedProjectID
                selectedCrewID = preselectedCrewID
                if preselectedCrewID != nil { loadCrewMembers() }
            }
        }
    }

    // MARK: - Load Crew for Project

    private func loadCrewForProject() {
        guard let pid = selectedProjectID,
              let project = store.project(id: pid),
              let firstCrewID = project.assignedCrewIDs.first else { return }
        selectedCrewID = firstCrewID
        loadCrewMembers()
    }

    // MARK: - Load Members

    private func loadCrewMembers() {
        guard let cid = selectedCrewID,
              let crew = store.crew(id: cid) else {
            crewRows = []
            return
        }
        crewRows = crew.memberIDs.compactMap { store.employee(id: $0) }.map { emp in
            CrewTimesheetRow(
                employee: emp,
                startTime: globalStartTime,
                endTime: globalEndTime,
                breakMinutes: globalBreakMinutes,
                costCode: costCode,
                taskDescription: taskDescription
            )
        }
    }

    // MARK: - Apply Global to All

    private func applyGlobalToAll() {
        for i in crewRows.indices {
            crewRows[i].startTime = globalStartTime
            crewRows[i].endTime = globalEndTime
            crewRows[i].breakMinutes = globalBreakMinutes
            crewRows[i].costCode = costCode
            crewRows[i].taskDescription = taskDescription
        }
    }

    // MARK: - Validate + Submit

    private func validateAndSubmit() {
        guard selectedProjectID != nil else {
            validationMessage = "Please select a project."
            showValidationError = true
            return
        }
        guard !crewRows.filter({ $0.isIncluded }).isEmpty else {
            validationMessage = "No crew members selected."
            showValidationError = true
            return
        }
        showConfirmation = true
    }

    private func submitAll() {
        guard let projID = selectedProjectID else { return }
        let entries: [TimesheetEntry] = crewRows
            .filter { $0.isIncluded }
            .map { row in
                vm.createEntry(
                    projectID: projID,
                    employeeID: row.employee.id,
                    date: date,
                    startTime: row.startTime,
                    endTime: row.endTime,
                    breakMinutes: row.breakMinutes,
                    costCode: row.costCode.isEmpty ? nil : row.costCode,
                    taskDescription: row.taskDescription.isEmpty ? nil : row.taskDescription,
                    notes: nil
                )
            }
        vm.submitAll(entries)
        dismiss()
    }
}

// MARK: - Crew Timesheet Row Model

struct CrewTimesheetRow: Identifiable {
    let id = UUID()
    let employee: Employee
    var isIncluded: Bool = true
    var startTime: Date
    var endTime: Date
    var breakMinutes: Int
    var costCode: String
    var taskDescription: String

    var calculatedHours: Decimal {
        let totalMinutes = Int(endTime.timeIntervalSince(startTime) / 60) - breakMinutes
        guard totalMinutes > 0 else { return 0 }
        return Decimal(totalMinutes) / 60
    }
}

// MARK: - Crew Member Row View

struct CrewMemberTimesheetRow: View {
    @Binding var row: CrewTimesheetRow
    let vm: TimesheetViewModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("", isOn: $row.isIncluded)
                    .labelsHidden()
                    .tint(.green)

                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 34, height: 34)
                    .overlay(
                        Text(row.employee.initials)
                            .font(.caption)
                            .foregroundColor(.blue)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.employee.fullName).font(.subheadline).bold()
                    if row.isIncluded {
                        Text("\(row.calculatedHours) hrs")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                Spacer()

                if row.isIncluded {
                    Button {
                        withAnimation { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if expanded && row.isIncluded {
                VStack(spacing: 8) {
                    DatePicker("Start", selection: $row.startTime, displayedComponents: .hourAndMinute)
                        .font(.subheadline)
                    DatePicker("End", selection: $row.endTime, displayedComponents: .hourAndMinute)
                        .font(.subheadline)
                    Stepper("Break: \(row.breakMinutes) min", value: $row.breakMinutes, in: 0...120, step: 15)
                        .font(.subheadline)
                }
                .padding(.leading, 48)
            }
        }
        .padding(.vertical, 4)
        .opacity(row.isIncluded ? 1.0 : 0.4)
    }
}
