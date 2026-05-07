// EmployeeDetailView.swift
// FieldOS – Employee Detail

import SwiftUI

struct EmployeeDetailView: View {
    let employee: Employee
    @EnvironmentObject var store: AppStore
    @State private var showEdit = false

    private var assignedCrews: [Crew] {
        store.crews.filter { $0.memberIDs.contains(employee.id) }
    }

    private var signedForms: [FormSubmission] {
        store.formSubmissions.filter {
            $0.isSigned && ($0.signedBy == employee.fullName || $0.submittedBy == employee.fullName)
        }.sorted { ($0.signedAt ?? $0.createdAt) > ($1.signedAt ?? $1.createdAt) }
    }

    private var recentTimesheets: [TimesheetEntry] {
        store.timesheetEntries
            .filter { $0.employeeID == employee.id }
            .sorted { $0.date > $1.date }
            .prefix(5)
            .map { $0 }
    }

    private var totalHoursThisMonth: Decimal {
        let start = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
        return store.timesheetEntries
            .filter { $0.employeeID == employee.id && $0.date >= start }
            .reduce(0) { $0 + $1.totalHours }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // MARK: - Profile Card
                VStack(spacing: 12) {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 72, height: 72)
                        .overlay(
                            Text(employee.initials)
                                .font(.title)
                                .bold()
                                .foregroundColor(.blue)
                        )
                    Text(employee.fullName)
                        .font(.title2).bold()
                    HStack(spacing: 8) {
                        Text(employee.role.rawValue.capitalized)
                            .font(.subheadline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue)
                            .cornerRadius(8)
                        if let trade = employee.trade {
                            Text(trade)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    if let email = employee.email {
                        Label(email, systemImage: "envelope")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    if let phone = employee.phone {
                        Label(phone, systemImage: "phone")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
                .padding(.horizontal)

                // MARK: - Stats
                HStack(spacing: 12) {
                    MiniKPICard(value: "\(totalHoursThisMonth)", label: "Hrs This Month", icon: "clock")
                    MiniKPICard(value: "\(assignedCrews.count)", label: "Crews", icon: "person.3")
                    MiniKPICard(value: "\(recentTimesheets.count)", label: "Timesheets", icon: "doc.text")
                }
                .padding(.horizontal)

                // MARK: - Pay Rates (managers and above only)
                if store.currentUserRole.canSeePay && (employee.regularRate != nil || employee.overtimeRate != nil) {
                    SectionHeader(title: "Pay Rates")
                    VStack(spacing: 0) {
                        if let rate = employee.regularRate {
                            PayRateRow(label: "Regular Rate", value: rate)
                            Divider().padding(.leading)
                        }
                        if let rate = employee.overtimeRate {
                            PayRateRow(label: "Overtime Rate", value: rate)
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                // MARK: - Certifications
                EmployeeCertificateSection(employee: employee)

                // MARK: - Assigned Crews
                SectionHeader(title: "Assigned Crews", count: assignedCrews.count)
                if assignedCrews.isEmpty {
                    EmptyCard(message: "Not assigned to any crew.")
                } else {
                    ForEach(assignedCrews) { crew in
                        NavigationLink {
                            CrewDetailView(crew: crew)
                        } label: {
                            CrewSummaryRow(crew: crew)
                                .padding(.horizontal)
                        }
                    }
                }

                // MARK: - Recent Timesheets
                SectionHeader(title: "Recent Timesheets", count: recentTimesheets.count)
                if recentTimesheets.isEmpty {
                    EmptyCard(message: "No timesheets logged.")
                } else {
                    ForEach(recentTimesheets) { entry in
                        TimesheetSummaryRow(entry: entry)
                    }
                }

                // MARK: - Signed Documents
                SectionHeader(title: "Signed Documents", count: signedForms.count)
                if signedForms.isEmpty {
                    EmptyCard(message: "No signed documents on file.")
                } else {
                    ForEach(signedForms) { submission in
                        EmployeeSignedFormRow(submission: submission)
                            .padding(.horizontal)
                    }
                }

                Spacer(minLength: 32)
            }
            .padding(.top)
        }
        .navigationTitle(employee.firstName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Edit") { showEdit = true }
            }
        }
        .sheet(isPresented: $showEdit) {
            EmployeeCreateEditView(existing: employee)
        }
    }
}

// MARK: - Signed Form Row

struct EmployeeSignedFormRow: View {
    let submission: FormSubmission
    @EnvironmentObject var store: AppStore

    private var templateName: String {
        store.formTemplates.first { $0.id == submission.templateID }?.name ?? "Form"
    }
    private var projectName: String? {
        submission.projectID.flatMap { store.project(id: $0) }?.name
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 16))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(templateName).font(.subheadline).bold().lineLimit(1)
                if let proj = projectName {
                    Text(proj).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if let date = submission.signedAt ?? submission.submittedAt {
                    Text(date.shortDate).font(.caption2).foregroundColor(.secondary)
                }
                Text("Signed").font(.caption2).bold()
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.green.opacity(0.12)).foregroundColor(.green)
                    .cornerRadius(4)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Pay Rate Row

struct PayRateRow: View {
    let label: String
    let value: Decimal

    var body: some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            Text("\(value.currencyString)/hr")
                .font(.subheadline)
                .bold()
        }
        .padding()
    }
}
