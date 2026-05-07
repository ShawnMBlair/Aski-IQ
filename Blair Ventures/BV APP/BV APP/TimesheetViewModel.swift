// TimesheetViewModel.swift
// FieldOS – Timesheet Logic Layer

import Foundation
import SwiftUI

@MainActor
final class TimesheetViewModel {
    
    private let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Create Single Entry

    func createEntry(
        projectID: UUID,
        employeeID: UUID,
        date: Date,
        startTime: Date?,
        endTime: Date?,
        breakMinutes: Int,
        costCode: String?,
        taskDescription: String?,
        notes: String?,
        /// Phase 1 — back-link to the ScheduleEntry that was scheduled.
        /// When the timesheet is created via "Start from scheduled
        /// shift", this carries the source entry's ID so reporting
        /// can compare planned vs actual hours later.
        scheduleEntryID: UUID? = nil
    ) -> TimesheetEntry {
        var entry = TimesheetEntry(
            projectID: projectID,
            employeeID: employeeID,
            date: date
        )
        entry.startTime = startTime
        entry.endTime = endTime
        entry.breakMinutes = breakMinutes
        entry.costCode = costCode
        entry.taskDescription = taskDescription
        entry.notes = notes
        entry.scheduleEntryID = scheduleEntryID
        let total = calculateRegularHours(start: startTime, end: endTime, breakMinutes: breakMinutes)
        entry.overtimeHours = calculateOvertimeHours(total: total)
        entry.regularHours = min(total, 8)
        entry.approvalStatus = .draft
        entry.lastModifiedAt = Date()
        return entry
    }

    // MARK: - Submit

    func submit(_ entry: TimesheetEntry) {
        var updated = entry
        updated.approvalStatus = .submitted
        updated.submittedAt = Date()
        updated.syncStatus = .pending
        updated.lastModifiedAt = Date()
        store.upsertTimesheetEntry(updated)
    }

    func submitAll(_ entries: [TimesheetEntry]) {
        for entry in entries { submit(entry) }
    }

    // MARK: - Hours Calculation

    func calculateRegularHours(start: Date?, end: Date?, breakMinutes: Int) -> Decimal {
        guard let start, let end else { return 0 }
        let totalMinutes = Int(end.timeIntervalSince(start) / 60) - breakMinutes
        guard totalMinutes > 0 else { return 0 }
        let hours = Decimal(totalMinutes) / 60
        return roundToQuarter(hours)
    }

    func calculateOvertimeHours(total: Decimal) -> Decimal {
        guard total > 8 else { return 0 }
        return total - 8
    }

    func roundToQuarter(_ hours: Decimal) -> Decimal {
        let quarters = (hours * 4).rounded()
        return quarters / 4
    }

    func existingEntry(for employeeID: UUID, on date: Date) -> TimesheetEntry? {
        store.timesheetEntries.first {
            $0.employeeID == employeeID &&
            Calendar.current.isDate($0.date, inSameDayAs: date)
        }
    }
}

extension Decimal {
    func rounded() -> Decimal {
        var result = Decimal()
        var value = self
        NSDecimalRound(&result, &value, 0, .plain)
        return result
    }
}
