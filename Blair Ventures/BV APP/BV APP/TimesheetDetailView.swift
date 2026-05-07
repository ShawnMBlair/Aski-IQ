// TimesheetDetailView.swift
// FieldOS – Timesheet Detail (Read-Only)

import SwiftUI

struct TimesheetDetailView: View {
    let entry: TimesheetEntry
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    private var employeeName: String {
        store.employee(id: entry.employeeID)?.fullName ?? "Unknown"
    }
    private var projectName: String {
        store.project(id: entry.projectID)?.name ?? "Unknown"
    }

    private var timeRange: String {
        guard let start = entry.startTime else { return "Not recorded" }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        if let end = entry.endTime {
            return "\(f.string(from: start)) – \(f.string(from: end))"
        }
        return f.string(from: start)
    }

    var body: some View {
        NavigationStack {
            List {

                // MARK: - Employee + Project
                Section {
                    LabeledRow(label: "Employee", value: employeeName)
                    LabeledRow(label: "Project", value: projectName)
                    LabeledRow(label: "Date", value: entry.date.shortDate)
                }

                // MARK: - Hours
                Section("Hours") {
                    LabeledRow(label: "Regular", value: "\(entry.regularHours) hrs")
                    if entry.overtimeHours > 0 {
                        LabeledRow(label: "Overtime", value: "\(entry.overtimeHours) hrs")
                    }
                    LabeledRow(label: "Total", value: "\(entry.totalHours) hrs")
                    LabeledRow(label: "Break", value: "\(entry.breakMinutes) min")
                    LabeledRow(label: "Shift Time", value: timeRange)
                }

                // MARK: - Work Detail
                if entry.costCode != nil || entry.taskDescription != nil {
                    Section("Work Details") {
                        if let code = entry.costCode {
                            LabeledRow(label: "Cost Code", value: code)
                        }
                        if let task = entry.taskDescription {
                            LabeledRow(label: "Task", value: task)
                        }
                        if let notes = entry.notes {
                            LabeledRow(label: "Notes", value: notes)
                        }
                    }
                }

                // MARK: - Approval Status
                Section("Approval") {
                    HStack {
                        Text("Status")
                            .foregroundColor(.secondary)
                        Spacer()
                        ApprovalBadge(status: entry.approvalStatus)
                    }
                    if let approvedBy = entry.approvedBy {
                        LabeledRow(label: "Approved By", value: approvedBy)
                    }
                    if let approvedAt = entry.approvedAt {
                        LabeledRow(label: "Approved At", value: approvedAt.shortDate)
                    }
                    if let reason = entry.rejectionReason {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Rejection Reason")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text(reason)
                                .font(.subheadline)
                                .foregroundColor(.red)
                        }
                        .padding(.vertical, 4)
                    }
                }

                // MARK: - Audit
                Section("Record Info") {
                    if let submitted = entry.submittedAt {
                        LabeledRow(label: "Submitted", value: submitted.shortDate)
                    }
                    LabeledRow(label: "Last Modified", value: entry.lastModifiedAt.shortDate)
                    LabeledRow(label: "Modified By", value: entry.lastModifiedBy)
                    HStack {
                        Text("Sync Status")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(entry.syncStatus.rawValue.capitalized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Timesheet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Labeled Row

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
