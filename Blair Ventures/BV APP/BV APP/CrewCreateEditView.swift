// CrewCreateEditView.swift
// FieldOS – Create / Edit Crew

import SwiftUI

struct CrewCreateEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    var existing: Crew? = nil

    @State private var name = ""
    @State private var foremanID: UUID? = nil
    @State private var selectedMemberIDs: Set<UUID> = []
    @State private var notes = ""
    @State private var isActive = true

    @State private var showValidationError = false
    @State private var validationMessage = ""

    @State private var showDeletionBlocked = false
    @State private var deletionBlockedReason = ""

    private var isEditing: Bool { existing != nil }

    private var activeEmployees: [Employee] {
        store.employees.filter { $0.isActive }.sorted { $0.lastName < $1.lastName }
    }

    var body: some View {
        NavigationStack {
            Form {

                // MARK: - Crew Name
                Section("Crew Name *") {
                    TextField("e.g. Insulation Crew A", text: $name)
                }

                // MARK: - Foreman
                Section("Foreman") {
                    Picker("Select Foreman", selection: $foremanID) {
                        Text("None").tag(UUID?.none)
                        ForEach(activeEmployees) { emp in
                            Text(emp.fullName).tag(Optional(emp.id))
                        }
                    }
                    .pickerStyle(.menu)
                }

                // MARK: - Members
                Section("Members (\(selectedMemberIDs.count) selected)") {
                    ForEach(activeEmployees) { emp in
                        HStack {
                            Circle()
                                .fill(Color.blue.opacity(0.12))
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Text(emp.initials)
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(emp.fullName).font(.subheadline)
                                if let trade = emp.trade {
                                    Text(trade).font(.caption).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            if selectedMemberIDs.contains(emp.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedMemberIDs.contains(emp.id) {
                                selectedMemberIDs.remove(emp.id)
                                if foremanID == emp.id { foremanID = nil }
                            } else {
                                selectedMemberIDs.insert(emp.id)
                            }
                        }
                    }
                }

                // MARK: - Notes
                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 60)
                }

                Section("Status") {
                    Toggle("Active Crew", isOn: $isActive)
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            if let crew = existing {
                                switch store.deleteCrew(crew) {
                                case .success:
                                    dismiss()
                                case .failure(let err):
                                    deletionBlockedReason = err.errorDescription ?? "Cannot delete crew."
                                    showDeletionBlocked = true
                                }
                            }
                        } label: {
                            Label("Delete Crew", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Crew" : "New Crew")
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
            .alert("Cannot Delete Crew", isPresented: $showDeletionBlocked) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deletionBlockedReason)
            }
            .onAppear { populate() }
        }
    }

    private func populate() {
        guard let c = existing else { return }
        name = c.name
        foremanID = c.foremanID
        selectedMemberIDs = Set(c.memberIDs)
        notes = c.notes ?? ""
        isActive = c.isActive
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationMessage = "Crew name is required."
            showValidationError = true
            return
        }

        var crew = existing ?? Crew(name: name)
        crew.name = name
        crew.foremanID = foremanID
        crew.memberIDs = Array(selectedMemberIDs)
        crew.notes = notes.isEmpty ? nil : notes
        crew.isActive = isActive
        crew.updatedAt = Date()
        crew.lastModifiedAt = Date()
        crew.syncStatus = .pending

        store.upsertCrew(crew)
        dismiss()
    }
}
