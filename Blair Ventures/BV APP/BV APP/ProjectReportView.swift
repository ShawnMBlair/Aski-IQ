// ProjectReportView.swift
// FieldOS – Project Report (Labor vs Estimate)

import SwiftUI

struct ProjectReportView: View {
    let project: Project
    @EnvironmentObject var store: AppStore

    private var timesheets: [TimesheetEntry] {
        store.timesheets(for: project.id)
    }

    private var approvedTimesheets: [TimesheetEntry] {
        timesheets.filter { $0.approvalStatus == .approved }
    }

    private var totalHours: Decimal {
        timesheets.reduce(0) { $0 + $1.totalHours }
    }

    private var approvedHours: Decimal {
        approvedTimesheets.reduce(0) { $0 + $1.totalHours }
    }

    private var overtimeHours: Decimal {
        timesheets.reduce(0) { $0 + $1.overtimeHours }
    }

    private var hoursByEmployee: [(Employee, Decimal)] {
        let grouped = Dictionary(grouping: timesheets) { $0.employeeID }
        return grouped.compactMap { empID, entries in
            guard let emp = store.employee(id: empID) else { return nil }
            let total = entries.reduce(0) { $0 + $1.totalHours }
            return (emp, total)
        }.sorted { $0.1 > $1.1 }
    }

    private var hoursByCostCode: [(String, Decimal)] {
        let grouped = Dictionary(grouping: timesheets.filter { $0.costCode != nil }) {
            $0.costCode!
        }
        return grouped.map { code, entries in
            (code, entries.reduce(0) { $0 + $1.totalHours })
        }.sorted { $0.1 > $1.1 }
    }

    private var exceptions: [ExceptionLog] {
        store.exceptionLogs.filter { $0.relatedEntryID == project.id }
    }

    private var budgetUtilization: Double {
        guard let budget = project.contractValue, budget > 0 else { return 0 }
        // Use real per-employee labour cost (regular + overtime rates) instead of
        // a hardcoded $150/hr assumption. Mirrors ProjectCostView.laborCost(for:).
        let utilized = NSDecimalNumber(decimal: store.laborCost(for: project.id)).doubleValue
        let total = NSDecimalNumber(decimal: budget).doubleValue
        return min(utilized / total, 1.0)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // MARK: - Project Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        StatusBadge(status: project.status)
                        Spacer()
                        if let value = project.contractValue {
                            Text(value.currencyString)
                                .font(.title3).bold()
                        }
                    }
                    Text(project.clientName)
                        .font(.subheadline).foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
                .padding(.horizontal)

                // MARK: - Hours Summary
                SectionHeader(title: "Hours Summary")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    MiniKPICard(value: "\(totalHours)", label: "Total Hours", icon: "clock")
                    MiniKPICard(value: "\(approvedHours)", label: "Approved", icon: "checkmark.circle")
                    MiniKPICard(value: "\(overtimeHours)", label: "Overtime", icon: "clock.badge.exclamationmark")
                    MiniKPICard(value: "\(timesheets.count)", label: "Entries", icon: "doc.text")
                }
                .padding(.horizontal)

                // MARK: - Hours by Employee
                SectionHeader(title: "Hours by Employee", count: hoursByEmployee.count)
                if hoursByEmployee.isEmpty {
                    EmptyCard(message: "No timesheet entries yet.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(hoursByEmployee, id: \.0.id) { emp, hours in
                            HStack {
                                Circle()
                                    .fill(Color.blue.opacity(0.12))
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Text(emp.initials).font(.caption).foregroundColor(.blue)
                                    )
                                Text(emp.fullName).font(.subheadline)
                                Spacer()
                                Text("\(hours) hrs")
                                    .font(.subheadline).bold()
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                            if emp.id != hoursByEmployee.last?.0.id {
                                Divider().padding(.leading, 56)
                            }
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                // MARK: - Hours by Cost Code
                if !hoursByCostCode.isEmpty {
                    SectionHeader(title: "Hours by Cost Code", count: hoursByCostCode.count)
                    VStack(spacing: 0) {
                        ForEach(hoursByCostCode, id: \.0) { code, hours in
                            HStack {
                                Label(code, systemImage: "number")
                                    .font(.subheadline)
                                    .foregroundColor(.blue)
                                Spacer()
                                Text("\(hours) hrs")
                                    .font(.subheadline).bold()
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                            if code != hoursByCostCode.last?.0 {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                // MARK: - Exception Summary
                SectionHeader(title: "Exceptions", count: exceptions.count)
                if exceptions.isEmpty {
                    EmptyCard(message: "No exceptions logged.")
                } else {
                    ForEach(exceptions) { log in
                        ExceptionLogRow(log: log)
                            .padding(.horizontal)
                    }
                }

                // MARK: - Recent Timesheets
                SectionHeader(title: "Recent Timesheets", count: timesheets.count)
                ForEach(timesheets.prefix(5)) { entry in
                    TimesheetSummaryRow(entry: entry)
                }
                if timesheets.count > 5 {
                    Text("+ \(timesheets.count - 5) more entries")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }

                Spacer(minLength: 32)
            }
            .padding(.top)
        }
        .navigationTitle("Project Report")
        .navigationBarTitleDisplayMode(.inline)
    }
}
