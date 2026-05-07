// StartShiftFlowView.swift
// FieldOS – Start Shift Smart Flow
// Auto-loads today's project, crew, and workers.
// Replaces the stub in SharedComponents.swift

import SwiftUI

struct StartShiftFlowView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var step: ShiftStep = .selectProject
    @State private var selectedProjectID: UUID? = nil
    @State private var selectedCrewID: UUID? = nil
    @State private var selectedMemberIDs: Set<UUID> = []
    @State private var shiftStartTime: Date = Date()
    @State private var shiftStarted = false

    enum ShiftStep { case selectProject, selectCrew, confirmCrew, started }

    private var todaySchedule: [ScheduleEntry] {
        store.scheduleEntries(for: Date())
    }

    private var suggestedProject: Project? {
        todaySchedule.first.flatMap { store.project(id: $0.projectID) }
    }

    private var suggestedCrew: Crew? {
        todaySchedule.first?.crewID.flatMap { store.crew(id: $0) }
    }

    private var selectedProject: Project? {
        selectedProjectID.flatMap { store.project(id: $0) }
    }

    private var selectedCrew: Crew? {
        selectedCrewID.flatMap { store.crew(id: $0) }
    }

    private var crewMembers: [Employee] {
        selectedCrew?.memberIDs.compactMap { store.employee(id: $0) } ?? []
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // MARK: - Progress Bar
                StepProgressBar(currentStep: step)
                    .padding()

                ScrollView {
                    VStack(spacing: 20) {
                        switch step {
                        case .selectProject:
                            selectProjectStep
                        case .selectCrew:
                            selectCrewStep
                        case .confirmCrew:
                            confirmCrewStep
                        case .started:
                            shiftStartedStep
                        }
                    }
                    .padding()
                }

                // MARK: - Navigation Buttons
                if step != .started {
                    HStack(spacing: 16) {
                        if step != .selectProject {
                            Button("Back") { goBack() }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel("Go back to previous step")
                        }
                        Button(step == .confirmCrew ? "Start Shift" : "Next") {
                            goNext()
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .tint(step == .confirmCrew ? .green : .blue)
                        .disabled(!canProceed)
                        .accessibilityLabel(step == .confirmCrew
                            ? "Start shift — \(selectedProject?.name ?? "selected project")"
                            : "Next step")
                        .accessibilityHint(canProceed ? "" : "Complete required selections first")
                    }
                    .padding()
                }
            }
            .navigationTitle("Start Shift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { autoPopulate() }
        }
    }

    // MARK: - Step Views

    private var selectProjectStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                icon: "folder.fill",
                title: "Select Project",
                subtitle: "Which project are you working on today?"
            )

            if let suggested = suggestedProject {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scheduled Today")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)

                    Button {
                        selectedProjectID = suggested.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(suggested.name).font(.headline).foregroundColor(.primary)
                                Text(suggested.clientName).font(.subheadline).foregroundColor(.secondary)
                            }
                            Spacer()
                            if selectedProjectID == suggested.id {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            }
                        }
                        .padding()
                        .background(selectedProjectID == suggested.id
                                    ? Color.green.opacity(0.1)
                                    : Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(selectedProjectID == suggested.id ? Color.green : Color.clear, lineWidth: 2)
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("All Active Projects")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                ForEach(store.projects.filter { $0.status == .active && $0.id != suggestedProject?.id }) { project in
                    Button {
                        selectedProjectID = project.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.name).font(.subheadline).foregroundColor(.primary)
                                Text(project.clientName).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            if selectedProjectID == project.id {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            }
                        }
                        .padding()
                        .background(selectedProjectID == project.id
                                    ? Color.green.opacity(0.1)
                                    : Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    }
                }
            }
        }
    }

    private var selectCrewStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                icon: "person.3.fill",
                title: "Select Crew",
                subtitle: "Which crew is working today?"
            )

            if let suggested = suggestedCrew {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Assigned to This Project")
                        .font(.caption).foregroundColor(.secondary).padding(.horizontal)

                    Button {
                        selectedCrewID = suggested.id
                        selectedMemberIDs = Set(suggested.memberIDs)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(suggested.name).font(.headline).foregroundColor(.primary)
                                Text("\(suggested.memberIDs.count) members").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            if selectedCrewID == suggested.id {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            }
                        }
                        .padding()
                        .background(selectedCrewID == suggested.id
                                    ? Color.green.opacity(0.1)
                                    : Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(selectedCrewID == suggested.id ? Color.green : Color.clear, lineWidth: 2)
                        )
                    }
                }
            }

            ForEach(store.crews.filter { $0.isActive && $0.id != suggestedCrew?.id }) { crew in
                Button {
                    selectedCrewID = crew.id
                    selectedMemberIDs = Set(crew.memberIDs)
                } label: {
                    HStack {
                        Text(crew.name).font(.subheadline).foregroundColor(.primary)
                        Spacer()
                        if selectedCrewID == crew.id {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }
            }
        }
    }

    private var confirmCrewStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                icon: "checkmark.circle.fill",
                title: "Confirm Crew",
                subtitle: "Who is on site today? Toggle off anyone absent."
            )

            if let project = selectedProject {
                HStack {
                    Image(systemName: "folder.fill").foregroundColor(.blue)
                    Text(project.name).font(.subheadline).bold()
                    Spacer()
                    StatusBadge(status: project.status)
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }

            VStack(spacing: 0) {
                ForEach(crewMembers) { member in
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(
                            get: { selectedMemberIDs.contains(member.id) },
                            set: { included in
                                if included { selectedMemberIDs.insert(member.id) }
                                else { selectedMemberIDs.remove(member.id) }
                            }
                        ))
                        .labelsHidden()
                        .tint(.green)

                        Circle()
                            .fill(Color.blue.opacity(0.12))
                            .frame(width: 36, height: 36)
                            .overlay(
                                Text(member.initials).font(.subheadline).foregroundColor(.blue)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(member.fullName).font(.subheadline).bold()
                                if member.id == selectedCrew?.foremanID {
                                    Image(systemName: "star.fill")
                                        .font(.caption2).foregroundColor(.orange)
                                }
                            }
                            if let trade = member.trade {
                                Text(trade).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .opacity(selectedMemberIDs.contains(member.id) ? 1.0 : 0.4)

                    if member.id != crewMembers.last?.id {
                        Divider().padding(.leading, 84)
                    }
                }
            }
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)

            Text("\(selectedMemberIDs.count) of \(crewMembers.count) members on site")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var shiftStartedStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(.green)

            VStack(spacing: 8) {
                Text("Shift Started")
                    .font(.title).bold()
                Text("Started at \(shiftStartTime.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline).foregroundColor(.secondary)
            }

            if let project = selectedProject {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledRow(label: "Project", value: project.name)
                    if let crew = selectedCrew {
                        LabeledRow(label: "Crew", value: crew.name)
                    }
                    LabeledRow(label: "Members on Site", value: "\(selectedMemberIDs.count)")
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .frame(maxWidth: .infinity)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Navigation Logic

    private var canProceed: Bool {
        switch step {
        case .selectProject: return selectedProjectID != nil
        case .selectCrew: return selectedCrewID != nil
        case .confirmCrew: return !selectedMemberIDs.isEmpty
        case .started: return true
        }
    }

    private func goNext() {
        switch step {
        case .selectProject: step = .selectCrew
        case .selectCrew: step = .confirmCrew
        case .confirmCrew:
            shiftStartTime = Date()
            shiftStarted = true
            step = .started
        case .started: dismiss()
        }
    }

    private func goBack() {
        switch step {
        case .selectCrew: step = .selectProject
        case .confirmCrew: step = .selectCrew
        default: break
        }
    }

    private func autoPopulate() {
        if let project = suggestedProject {
            selectedProjectID = project.id
        }
        if let crew = suggestedCrew {
            selectedCrewID = crew.id
            selectedMemberIDs = Set(crew.memberIDs)
        }
    }
}

// MARK: - Step Progress Bar

struct StepProgressBar: View {
    let currentStep: StartShiftFlowView.ShiftStep

    private let steps: [StartShiftFlowView.ShiftStep] = [.selectProject, .selectCrew, .confirmCrew, .started]

    private func index(of step: StartShiftFlowView.ShiftStep) -> Int {
        steps.firstIndex(of: step) ?? 0
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<steps.count, id: \.self) { i in
                Capsule()
                    .fill(i <= index(of: currentStep) ? Color.green : Color(.systemGray4))
                    .frame(height: 4)
                    .animation(.easeInOut, value: currentStep)
            }
        }
    }
}

extension StartShiftFlowView.ShiftStep: Equatable, CaseIterable {
    static var allCases: [StartShiftFlowView.ShiftStep] {
        [.selectProject, .selectCrew, .confirmCrew, .started]
    }
}

// MARK: - Step Header

struct StepHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 44, height: 44)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(10)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}
