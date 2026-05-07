// ExceptionLogViews.swift
// FieldOS – Exception Logging
// Replaces the ExceptionLogCreateView stub in SharedComponents.swift

import SwiftUI

// MARK: - Exception Log Create View

struct ExceptionLogCreateView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    var preselectedProjectID: UUID? = nil
    var preselectedEntryID: UUID? = nil

    @State private var selectedProjectID: UUID? = nil
    @State private var exceptionType: ExceptionType = .delay
    @State private var description: String = ""
    @State private var impactHoursString: String = ""

    @State private var showValidationError = false
    @State private var validationMessage = ""

    private var activeProjects: [Project] {
        store.projects.filter { $0.status == .active }.sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            Form {

                // MARK: - Project
                Section("Project *") {
                    Picker("Project", selection: $selectedProjectID) {
                        Text("Select Project").tag(UUID?.none)
                        ForEach(activeProjects) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                    .pickerStyle(.menu)
                }

                // MARK: - Type
                Section("Exception Type") {
                    Picker("Type", selection: $exceptionType) {
                        ForEach(ExceptionType.allCases, id: \.self) { type in
                            Label(type.displayName, systemImage: type.icon)
                                .tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                }

                // MARK: - Details
                Section("Details *") {
                    TextEditor(text: $description)
                        .frame(minHeight: 80)
                }

                // MARK: - Impact
                Section("Impact") {
                    HStack {
                        TextField("Hours Lost", text: $impactHoursString)
                            .keyboardType(.decimalPad)
                        Text("hrs")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Log Exception")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }.bold()
                }
            }
            .alert("Missing Info", isPresented: $showValidationError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationMessage)
            }
            .onAppear {
                selectedProjectID = preselectedProjectID
            }
        }
    }

    private func save() {
        guard selectedProjectID != nil else {
            validationMessage = "Please select a project."
            showValidationError = true
            return
        }
        guard !description.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationMessage = "Please describe the exception."
            showValidationError = true
            return
        }

        let relatedID = preselectedEntryID ?? selectedProjectID ?? UUID()

        var log = ExceptionLog(
            relatedEntryID: relatedID,
            type: exceptionType,
            description: description
        )
        log.impactHours = Decimal(string: impactHoursString)
        log.lastModifiedBy = store.currentUser?.fullName ?? "Unknown"
        log.lastModifiedAt = Date()
        log.syncStatus = .pending
        // Phase 1 Step 2: stamp tenant client-side. RLS + the
        // stamp_company_id trigger are still the server-side guarantee,
        // but stamping here means the row survives a trigger regression
        // intact. If currentCompanyID is nil (no auth) we skip the stamp
        // and the trigger backfills on insert; the row will not be visible
        // until a tenant is set anyway.
        log.companyID = store.currentCompanyID

        store.exceptionLogs.append(log)
        store.saveToDisk()
        dismiss()
    }
}

// MARK: - Exception Log List View

struct ExceptionLogListView: View {
    @EnvironmentObject var store: AppStore
    var projectID: UUID? = nil

    @State private var showCreate = false

    private var logs: [ExceptionLog] {
        store.exceptionLogs
            .filter { projectID == nil || $0.relatedEntryID == projectID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        Group {
            if logs.isEmpty {
                EmptyCard(message: "No exceptions logged.")
            } else {
                VStack(spacing: 10) {
                    ForEach(logs) { log in
                        ExceptionLogRow(log: log)
                            .padding(.horizontal)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            ExceptionLogCreateView(preselectedProjectID: projectID)
        }
    }
}

// MARK: - Exception Log Row

struct ExceptionLogRow: View {
    let log: ExceptionLog

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(log.type.color.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: log.type.icon)
                    .foregroundColor(log.type.color)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(log.type.displayName)
                        .font(.subheadline)
                        .bold()
                    Spacer()
                    Text(log.createdAt.shortDate)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(log.description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                if let hours = log.impactHours, hours > 0 {
                    Label("\(hours) hrs lost", systemImage: "clock.badge.xmark")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - ExceptionType Extensions

extension ExceptionType: CaseIterable {
    public static var allCases: [ExceptionType] {
        [.delay, .weather, .missingWorker, .equipmentFailure, .safetyIncident, .other]
    }

    var displayName: String {
        switch self {
        case .delay: return "Delay"
        case .weather: return "Weather"
        case .missingWorker: return "Missing Worker"
        case .equipmentFailure: return "Equipment Failure"
        case .safetyIncident: return "Safety Incident"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .delay: return "clock.badge.xmark"
        case .weather: return "cloud.rain.fill"
        case .missingWorker: return "person.fill.xmark"
        case .equipmentFailure: return "wrench.and.screwdriver"
        case .safetyIncident: return "exclamationmark.shield.fill"
        case .other: return "ellipsis.circle"
        }
    }

    var color: Color {
        switch self {
        case .delay: return .orange
        case .weather: return .blue
        case .missingWorker: return .red
        case .equipmentFailure: return .purple
        case .safetyIncident: return .red
        case .other: return .gray
        }
    }
}
