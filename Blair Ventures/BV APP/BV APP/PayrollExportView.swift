// PayrollExportView.swift
// FieldOS – Payroll Export (CSV)

import SwiftUI

struct PayrollExportView: View {
    @EnvironmentObject var store: AppStore

    @State private var startDate: Date = Calendar.current.date(
        from: Calendar.current.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
    ) ?? Date()
    @State private var endDate: Date = Date()
    @State private var selectedCrewID: UUID? = nil
    @State private var includeOnlyApproved: Bool = true
    @State private var showShareSheet = false
    @State private var csvURL: URL? = nil
    @State private var showPreview = false

    private var filteredEntries: [TimesheetEntry] {
        store.timesheetEntries.filter { entry in
            let inRange = entry.date >= startDate && entry.date <= endDate
            let statusOK = includeOnlyApproved ? entry.approvalStatus == .approved : true
            let crewOK: Bool = {
                guard let crewID = selectedCrewID,
                      let crew = store.crew(id: crewID) else { return true }
                return crew.memberIDs.contains(entry.employeeID)
            }()
            return inRange && statusOK && crewOK
        }.sorted { $0.date < $1.date }
    }

    private var payrollRows: [PayrollRow] {
        let grouped = Dictionary(grouping: filteredEntries) { $0.employeeID }
        return grouped.compactMap { empID, entries in
            guard let emp = store.employee(id: empID) else { return nil }
            let regular = entries.reduce(Decimal(0)) { $0 + $1.regularHours }
            let overtime = entries.reduce(Decimal(0)) { $0 + $1.overtimeHours }
            let total = regular + overtime
            return PayrollRow(
                employee: emp,
                regularHours: regular,
                overtimeHours: overtime,
                totalHours: total,
                entryCount: entries.count
            )
        }.sorted { $0.employee.lastName < $1.employee.lastName }
    }

    private var totalRegular: Decimal { payrollRows.reduce(0) { $0 + $1.regularHours } }
    private var totalOvertime: Decimal { payrollRows.reduce(0) { $0 + $1.overtimeHours } }
    private var totalAll: Decimal { payrollRows.reduce(0) { $0 + $1.totalHours } }

    var body: some View {
        NavigationStack {
            Form {

                // MARK: - Filters
                Section("Pay Period") {
                    DatePicker("From", selection: $startDate, displayedComponents: .date)
                    DatePicker("To", selection: $endDate, displayedComponents: .date)
                }

                Section("Filters") {
                    Picker("Crew", selection: $selectedCrewID) {
                        Text("All Crews").tag(UUID?.none)
                        ForEach(store.crews.filter { $0.isActive }) { crew in
                            Text(crew.name).tag(Optional(crew.id))
                        }
                    }
                    .pickerStyle(.menu)
                    Toggle("Approved Timesheets Only", isOn: $includeOnlyApproved)
                }

                // MARK: - Summary
                Section("Summary — \(payrollRows.count) Employees") {
                    HStack {
                        Text("Regular Hours").foregroundColor(.secondary)
                        Spacer()
                        Text("\(totalRegular) hrs").bold()
                    }
                    HStack {
                        Text("Overtime Hours").foregroundColor(.secondary)
                        Spacer()
                        Text("\(totalOvertime) hrs")
                            .bold()
                            .foregroundColor(totalOvertime > 0 ? .orange : .primary)
                    }
                    HStack {
                        Text("Total Hours").foregroundColor(.secondary)
                        Spacer()
                        Text("\(totalAll) hrs").bold().foregroundColor(.green)
                    }
                }

                // MARK: - Preview
                Section("Preview") {
                    if payrollRows.isEmpty {
                        Text("No entries match the selected filters.")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(payrollRows) { row in
                            PayrollPreviewRow(row: row)
                        }
                    }
                }

                // MARK: - Export
                Section {
                    Button {
                        exportCSV()
                    } label: {
                        Label("Export as CSV", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .foregroundColor(payrollRows.isEmpty ? .secondary : .blue)
                    }
                    .disabled(payrollRows.isEmpty)
                }
            }
            .navigationTitle("Payroll Export")
            .sheet(isPresented: $showShareSheet) {
                if let url = csvURL {
                    ShareSheet(items: [url])
                }
            }
        }
    }

    private func exportCSV() {
        let csv = CSVExporter.buildPayrollCSV(
            rows: payrollRows,
            startDate: startDate,
            endDate: endDate
        )
        let fileName = "Payroll_\(startDate.csvDate)_to_\(endDate.csvDate).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        csvURL = url
        showShareSheet = true
    }
}

// MARK: - Payroll Row Model

struct PayrollRow: Identifiable {
    let id = UUID()
    let employee: Employee
    let regularHours: Decimal
    let overtimeHours: Decimal
    let totalHours: Decimal
    let entryCount: Int
}

// MARK: - Payroll Preview Row

struct PayrollPreviewRow: View {
    let row: PayrollRow

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.employee.fullName).font(.subheadline).bold()
                Text("\(row.entryCount) entries")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(row.totalHours) hrs").font(.subheadline).bold()
                if row.overtimeHours > 0 {
                    Text("\(row.overtimeHours) OT")
                        .font(.caption).foregroundColor(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - CSV Exporter

struct CSVExporter {
    static func buildPayrollCSV(rows: [PayrollRow], startDate: Date, endDate: Date) -> String {
        var lines: [String] = []
        lines.append("Payroll Export")
        lines.append("Period: \(startDate.csvDate) to \(endDate.csvDate)")
        lines.append("")
        lines.append("Employee,Regular Hours,Overtime Hours,Total Hours,Entries")
        for row in rows {
            let line = "\(row.employee.fullName),\(row.regularHours),\(row.overtimeHours),\(row.totalHours),\(row.entryCount)"
            lines.append(line)
        }
        lines.append("")
        let totalReg = rows.reduce(Decimal(0)) { $0 + $1.regularHours }
        let totalOT = rows.reduce(Decimal(0)) { $0 + $1.overtimeHours }
        let totalAll = rows.reduce(Decimal(0)) { $0 + $1.totalHours }
        lines.append("TOTALS,\(totalReg),\(totalOT),\(totalAll),")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}

// MARK: - Date Extension

extension Date {
    var csvDate: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: self)
    }
}
