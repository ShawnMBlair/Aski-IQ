// ReportsHubView.swift
// FieldOS – Reports Hub

import SwiftUI

struct ReportsHubView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        NavigationStack {
            List {

                // MARK: - Project Reports
                Section("Project Reports") {
                    ForEach(store.projects.filter { $0.status == .active }) { project in
                        NavigationLink {
                            ProjectReportView(project: project)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(project.name).font(.subheadline).bold()
                                    Text(project.clientName)
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                let hours = store.timesheets(for: project.id)
                                    .reduce(Decimal(0)) { $0 + $1.totalHours }
                                Text("\(hours) hrs")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    if store.projects.filter({ $0.status == .active }).isEmpty {
                        Text("No active projects.")
                            .foregroundColor(.secondary).font(.subheadline)
                    }
                }

                // MARK: - Daily Summary
                Section("Daily Reports") {
                    NavigationLink {
                        DailySummaryReportView()
                    } label: {
                        Label("Daily Summary", systemImage: "calendar.day.timeline.left")
                    }
                }

                // MARK: - Payroll
                Section("Payroll") {
                    NavigationLink {
                        PayrollExportView()
                    } label: {
                        Label("Payroll Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .navigationTitle("Reports")
        }
    }
}
