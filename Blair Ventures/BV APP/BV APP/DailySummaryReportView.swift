// DailySummaryReportView.swift
// FieldOS – Daily Summary Report

import SwiftUI

struct DailySummaryReportView: View {
    @EnvironmentObject var store: AppStore
    @State private var selectedDate: Date = Date()

    private var timesheetsForDay: [TimesheetEntry] {
        store.timesheetEntries.filter {
            Calendar.current.isDate($0.date, inSameDayAs: selectedDate)
        }.sorted { $0.totalHours > $1.totalHours }
    }

    private var scheduledShifts: [ScheduleEntry] {
        store.scheduleEntries(for: selectedDate)
    }

    private var formsSubmitted: [FormSubmission] {
        store.formSubmissions.filter {
            guard let submitted = $0.submittedAt else { return false }
            return Calendar.current.isDate(submitted, inSameDayAs: selectedDate)
        }
    }

    private var exceptionsForDay: [ExceptionLog] {
        store.exceptionLogs.filter {
            Calendar.current.isDate($0.createdAt, inSameDayAs: selectedDate)
        }
    }

    private var totalHoursForDay: Decimal {
        timesheetsForDay.reduce(0) { $0 + $1.totalHours }
    }

    private var hoursByCrew: [(Crew, Decimal)] {
        let crewIDs = Set(scheduledShifts.compactMap { $0.crewID })
        return crewIDs.compactMap { crewID -> (Crew, Decimal)? in
            guard let crew = store.crew(id: crewID) else { return nil }
            let memberIDs = Set(crew.memberIDs)
            let hours = timesheetsForDay
                .filter { memberIDs.contains($0.employeeID) }
                .reduce(0) { $0 + $1.totalHours }
            return (crew, hours)
        }.sorted { $0.1 > $1.1 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // MARK: - Date Picker
                    VStack(alignment: .leading, spacing: 8) {
                        DatePicker(
                            "Select Date",
                            selection: $selectedDate,
                            displayedComponents: .date
                        )
                        .datePickerStyle(.graphical)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)
                    .padding(.horizontal)

                    // MARK: - Day Summary KPIs
                    HStack(spacing: 12) {
                        MiniKPICard(value: "\(totalHoursForDay)", label: "Total Hrs", icon: "clock")
                        MiniKPICard(value: "\(timesheetsForDay.count)", label: "Timesheets", icon: "doc.text")
                        MiniKPICard(value: "\(scheduledShifts.count)", label: "Shifts", icon: "calendar")
                        MiniKPICard(value: "\(formsSubmitted.count)", label: "Forms", icon: "checkmark.seal")
                    }
                    .padding(.horizontal)

                    // MARK: - Hours by Crew
                    SectionHeader(title: "Hours by Crew", count: hoursByCrew.count)
                    if hoursByCrew.isEmpty {
                        EmptyCard(message: "No crew activity for this day.")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(hoursByCrew, id: \.0.id) { crew, hours in
                                HStack {
                                    Image(systemName: "person.3.fill")
                                        .foregroundColor(.blue)
                                        .frame(width: 24)
                                    Text(crew.name).font(.subheadline)
                                    Spacer()
                                    Text("\(hours) hrs")
                                        .font(.subheadline).bold()
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 10)
                                if crew.id != hoursByCrew.last?.0.id {
                                    Divider().padding(.leading, 48)
                                }
                            }
                        }
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                    }

                    // MARK: - Individual Timesheets
                    SectionHeader(title: "Timesheets", count: timesheetsForDay.count)
                    if timesheetsForDay.isEmpty {
                        EmptyCard(message: "No timesheets logged for this day.")
                    } else {
                        ForEach(timesheetsForDay) { entry in
                            TimesheetSummaryRow(entry: entry)
                        }
                    }

                    // MARK: - Forms Submitted
                    SectionHeader(title: "Forms Submitted", count: formsSubmitted.count)
                    if formsSubmitted.isEmpty {
                        EmptyCard(message: "No forms submitted this day.")
                    } else {
                        VStack(spacing: 10) {
                            ForEach(formsSubmitted) { submission in
                                FormSubmissionRow(submission: submission)
                                    .padding(.horizontal)
                            }
                        }
                    }

                    // MARK: - Exceptions
                    SectionHeader(title: "Exceptions Logged", count: exceptionsForDay.count)
                    if exceptionsForDay.isEmpty {
                        EmptyCard(message: "No exceptions logged this day.")
                    } else {
                        ForEach(exceptionsForDay) { log in
                            ExceptionLogRow(log: log)
                                .padding(.horizontal)
                        }
                    }

                    Spacer(minLength: 32)
                }
                .padding(.top)
            }
            .navigationTitle("Daily Summary")
        }
    }
}
