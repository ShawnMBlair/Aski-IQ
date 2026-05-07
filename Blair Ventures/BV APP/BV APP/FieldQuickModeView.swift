// FieldQuickModeView.swift
// FieldOS – Field Quick Mode
// Big buttons. Minimal fields. Works offline.
// Replaces the stub in SharedComponents.swift.

import SwiftUI
import Combine

struct FieldQuickModeView: View {
    @EnvironmentObject var store: AppStore
    @State private var vm: TimesheetViewModel = TimesheetViewModel(store: AppStore.shared)
    @Environment(\.dismiss) var dismiss

    @State private var shiftStarted = false
    @State private var shiftStartTime: Date = Date()
    @State private var shiftEndTime: Date = Date()
    @State private var shiftEnded = false

    @State private var selectedProjectID: UUID? = nil
    @State private var selectedEmployeeID: UUID? = nil
    @State private var breakMinutes: Int = 30
    @State private var showProjectPicker = false
    @State private var showSummary = false

    /// Ticks every second while a shift is active so `elapsedString` stays live.
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now: Date = Date()

    private var todayProject: Project? {
        store.scheduleEntries(for: Date()).first
            .flatMap { store.project(id: $0.projectID) }
    }

    private var elapsedHours: Decimal {
        guard shiftStarted else { return 0 }
        let end = shiftEnded ? shiftEndTime : now
        return vm.calculateRegularHours(start: shiftStartTime, end: end, breakMinutes: breakMinutes)
    }

    private var elapsedString: String {
        guard shiftStarted else { return "0:00" }
        let end = shiftEnded ? shiftEndTime : now
        let seconds = Int(end.timeIntervalSince(shiftStartTime))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return String(format: "%d:%02d", h, m)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // MARK: - Header
                VStack(spacing: 6) {
                    Text(shiftStarted ? (shiftEnded ? "Shift Complete" : "Shift In Progress") : "Ready to Start")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    Text(elapsedString)
                        .font(.system(size: 64, weight: .bold, design: .monospaced))
                        .foregroundColor(shiftStarted && !shiftEnded ? .green : .primary)

                    Text("hours : minutes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(Color(.secondarySystemBackground))

                ScrollView {
                    VStack(spacing: 16) {

                        // MARK: - Project Selection
                        Button {
                            showProjectPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(.blue)
                                Text(selectedProject?.name ?? "Select Project")
                                    .foregroundColor(selectedProject != nil ? .primary : .secondary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                        }
                        .padding(.horizontal)
                        .padding(.top, 16)

                        // MARK: - Employee Selection
                        if store.currentUser == nil {
                            Picker("Select Employee", selection: $selectedEmployeeID) {
                                Text("Select Employee").tag(UUID?.none)
                                ForEach(store.employees.filter { $0.isActive }) { emp in
                                    Text(emp.fullName).tag(Optional(emp.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                            .padding(.horizontal)
                        }

                        // MARK: - Break Stepper
                        HStack {
                            Label("Break", systemImage: "cup.and.saucer")
                            Spacer()
                            Stepper("\(breakMinutes) min", value: $breakMinutes, in: 0...120, step: 15)
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)

                        // MARK: - Start Shift Button
                        if !shiftStarted {
                            Button {
                                startShift()
                            } label: {
                                Label("Start Shift", systemImage: "play.fill")
                                    .font(.title2)
                                    .bold()
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 20)
                                    .background(selectedProject != nil ? Color.green : Color(.systemGray4))
                                    .foregroundColor(.white)
                                    .cornerRadius(16)
                            }
                            .disabled(selectedProject == nil)
                            .padding(.horizontal)
                            .accessibilityLabel(selectedProject != nil
                                ? "Start shift on \(selectedProject!.name)"
                                : "Start shift — select a project first")
                            .accessibilityHint(selectedProject == nil ? "Select a project above to enable" : "")
                            .accessibilityAddTraits(.isButton)
                        }

                        // MARK: - End Shift Button
                        if shiftStarted && !shiftEnded {
                            VStack(spacing: 8) {
                                Text("Started at \(shiftStartTime.formatted(date: .omitted, time: .shortened))")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .accessibilityLabel("Shift started at \(shiftStartTime.formatted(date: .omitted, time: .shortened))")

                                Button {
                                    endShift()
                                } label: {
                                    Label("End Shift", systemImage: "stop.fill")
                                        .font(.title2)
                                        .bold()
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 20)
                                        .background(Color.orange)
                                        .foregroundColor(.white)
                                        .cornerRadius(16)
                                }
                                .accessibilityLabel("End shift — clock out now")
                                .accessibilityHint("Records your shift end time and prepares the timesheet")
                            }
                            .padding(.horizontal)
                        }

                        // MARK: - Submit Button
                        if shiftEnded {
                            VStack(spacing: 12) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text("Total Hours").font(.subheadline).foregroundColor(.secondary)
                                        Text("\(elapsedHours) hrs").font(.title2).bold()
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing) {
                                        Text("Break").font(.subheadline).foregroundColor(.secondary)
                                        Text("\(breakMinutes) min").font(.title2).bold()
                                    }
                                }
                                .padding()
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(12)

                                Button {
                                    submitShift()
                                } label: {
                                    Label("Submit Timesheet", systemImage: "checkmark.circle.fill")
                                        .font(.title2)
                                        .bold()
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 20)
                                        .background(Color.blue)
                                        .foregroundColor(.white)
                                        .cornerRadius(16)
                                }
                                .accessibilityLabel("Submit timesheet — \(elapsedHours) hours worked")
                                .accessibilityHint("Saves your timesheet for manager approval")
                            }
                            .padding(.horizontal)
                        }

                        Spacer(minLength: 40)
                    }
                }
            }
            .navigationTitle("Field Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showProjectPicker) {
                ProjectPickerSheet(selectedProjectID: $selectedProjectID)
            }
            .onReceive(ticker) { tick in
                // Only update `now` while a shift is actively running —
                // once ended the elapsed time is frozen at shiftEndTime.
                if shiftStarted && !shiftEnded {
                    now = tick
                }
            }
            .onAppear {
                selectedProjectID = todayProject?.id
                selectedEmployeeID = store.currentUser?.id
            }
        }
    }

    private var selectedProject: Project? {
        selectedProjectID.flatMap { store.project(id: $0) }
    }

    private func startShift() {
        shiftStartTime = Date()
        shiftStarted = true
    }

    private func endShift() {
        shiftEndTime = Date()
        shiftEnded = true
    }

    private func submitShift() {
        guard let projID = selectedProjectID else { return }
        let empID = selectedEmployeeID ?? store.currentUser?.id ?? UUID()

        let entry = vm.createEntry(
            projectID: projID,
            employeeID: empID,
            date: Date(),
            startTime: shiftStartTime,
            endTime: shiftEndTime,
            breakMinutes: breakMinutes,
            costCode: nil,
            taskDescription: "Field Quick Mode entry",
            notes: nil
        )
        vm.submit(entry)
        dismiss()
    }
}

// MARK: - Project Picker Sheet

struct ProjectPickerSheet: View {
    @EnvironmentObject var store: AppStore
    @Binding var selectedProjectID: UUID?
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.projects.filter { $0.status == .active }) { project in
                    Button {
                        selectedProjectID = project.id
                        dismiss()
                    } label: {
                        HStack {
                            Text(project.name)
                            Spacer()
                            if selectedProjectID == project.id {
                                Image(systemName: "checkmark").foregroundColor(.blue)
                            }
                        }
                    }
                    .foregroundColor(.primary)
                }
            }
            .navigationTitle("Select Project")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
