// EmployeeCreateEditView.swift
// FieldOS – Create / Edit Employee

import SwiftUI

struct EmployeeCreateEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    var existing: Employee? = nil

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var role: UserRole = .foreman
    @State private var trade = ""
    @State private var certificationInput = ""
    @State private var certifications: [String] = []
    @State private var regularRateString = ""
    @State private var overtimeRateString = ""
    @State private var isActive = true

    @State private var showValidationError = false
    @State private var validationMessage = ""

    @State private var showDeletionBlocked = false
    @State private var deletionBlockedReason = ""

    private var isEditing: Bool { existing != nil }

    var body: some View {
        NavigationStack {
            Form {

                Section("Name *") {
                    TextField("First Name", text: $firstName)
                    TextField("Last Name", text: $lastName)
                }

                Section("Contact") {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                }

                Section("Role & Trade") {
                    Picker("Role", selection: $role) {
                        ForEach(UserRole.allCases, id: \.self) { r in
                            Text(r.rawValue.capitalized).tag(r)
                        }
                    }
                    .pickerStyle(.menu)
                    TextField("Trade (e.g. Insulation, Scaffolding)", text: $trade)
                }

                Section("Pay Rates") {
                    HStack {
                        Text("$")
                        TextField("Regular Rate / hr", text: $regularRateString)
                            .keyboardType(.decimalPad)
                    }
                    HStack {
                        Text("$")
                        TextField("Overtime Rate / hr", text: $overtimeRateString)
                            .keyboardType(.decimalPad)
                    }
                }

                Section("Certifications") {
                    HStack {
                        TextField("Add certification", text: $certificationInput)
                        Button("Add") {
                            let trimmed = certificationInput.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                certifications.append(trimmed)
                                certificationInput = ""
                            }
                        }
                        .disabled(certificationInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    ForEach(certifications, id: \.self) { cert in
                        Label(cert, systemImage: "checkmark.seal.fill")
                            .foregroundColor(.green)
                    }
                    .onDelete { indices in
                        certifications.remove(atOffsets: indices)
                    }
                }

                Section("Status") {
                    Toggle("Active Employee", isOn: $isActive)
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            if let emp = existing {
                                switch store.deleteEmployee(emp) {
                                case .success:
                                    dismiss()
                                case .failure(let err):
                                    deletionBlockedReason = err.errorDescription ?? "Cannot delete employee."
                                    showDeletionBlocked = true
                                }
                            }
                        } label: {
                            Label("Delete Employee", systemImage: "trash")
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isEditing ? "Edit Employee" : "New Employee")
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
            .alert("Cannot Delete Employee", isPresented: $showDeletionBlocked) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deletionBlockedReason)
            }
            .onAppear { populate() }
        }
    }

    private func populate() {
        guard let e = existing else { return }
        firstName = e.firstName
        lastName = e.lastName
        email = e.email ?? ""
        phone = e.phone ?? ""
        role = e.role
        trade = e.trade ?? ""
        certifications = e.certifications
        regularRateString = e.regularRate.map { "\($0)" } ?? ""
        overtimeRateString = e.overtimeRate.map { "\($0)" } ?? ""
        isActive = e.isActive
    }

    private func save() {
        guard !firstName.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationMessage = "First name is required."
            showValidationError = true
            return
        }
        guard !lastName.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationMessage = "Last name is required."
            showValidationError = true
            return
        }

        var emp = existing ?? Employee(firstName: firstName, lastName: lastName)
        emp.firstName = firstName
        emp.lastName = lastName
        emp.email = email.isEmpty ? nil : email
        emp.phone = phone.isEmpty ? nil : phone
        emp.role = role
        emp.trade = trade.isEmpty ? nil : trade
        emp.certifications = certifications
        emp.regularRate = Decimal(string: regularRateString)
        emp.overtimeRate = Decimal(string: overtimeRateString)
        emp.isActive = isActive
        emp.updatedAt = Date()
        emp.lastModifiedAt = Date()
        emp.syncStatus = .pending

        store.upsertEmployee(emp)
        dismiss()
    }
}
