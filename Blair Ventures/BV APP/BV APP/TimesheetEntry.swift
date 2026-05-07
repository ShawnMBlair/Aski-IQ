// TimesheetEntry.swift
// FieldOS – Timesheets Module

import Foundation

// MARK: - Timesheet Approval Status

enum ApprovalStatus: String, Codable {
    case draft
    case submitted
    case approved
    case rejected
    case locked         // Post-payroll, no edits allowed
}

// MARK: - Timesheet Entry

struct TimesheetEntry: BaseModel {
    var id: UUID = UUID()
    var externalID: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()

    /// Multi-tenant scope. Wage / labor data — derived from the parent
    /// project's `companyID` on upsert. Required NOT NULL server-side.
    var companyID: UUID? = nil

    // Core relationships
    var projectID: UUID
    var employeeID: UUID
    var scheduleEntryID: UUID?          // Link to the shift that was scheduled

    // Time
    var date: Date
    var startTime: Date?
    var endTime: Date?
    var regularHours: Decimal = 0
    var overtimeHours: Decimal = 0
    var breakMinutes: Int = 0

    // Work detail
    var costCode: String?
    var taskDescription: String?
    var notes: String?

    // Approval
    var approvalStatus: ApprovalStatus = .draft
    var submittedAt: Date?
    var approvedAt: Date?
    var approvedBy: String?
    var rejectionReason: String?

    // "Start Shift" smart flow
    var shiftStartedVia: String?        // "manual" | "smartFlow"

    // MARK: Sample data tracking
    // Populated only by SampleDataSeeder; immutable post-insert via DB
    // trigger. Cleared along with the row when an executive runs Clear
    // Sample Data. See SampleData/SampleDataTypes.swift.
    var isSampleData:           Bool      = false
    var sampleDataBatchID:      UUID?     = nil
    var sampleDataSeedVersion:  String?   = nil
    var sampleDataCreatedAt:    Date?     = nil
    var sampleDataCreatedBy:    UUID?     = nil

    // Soft delete
    var isDeleted: Bool    = false
    var deletedAt: Date?   = nil
    var deletedBy: String? = nil

    // Computed
    var totalHours: Decimal { regularHours + overtimeHours }
}

// MARK: - Exception Log
// Attached to a TimesheetEntry or ScheduleEntry for delays, weather, etc.

enum ExceptionType: String, Codable {
    case delay
    case weather
    case missingWorker
    case equipmentFailure
    case safetyIncident
    case other
}

struct ExceptionLog: BaseModel {
    var id: UUID = UUID()
    var externalID: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()

    /// Phase 1 Step 2: tenant stamp.
    /// Server has both an RLS policy (`company_id = get_my_company_id()`)
    /// and a BEFORE INSERT trigger (`stamp_company_id`) that fills this
    /// from `auth.uid() → profiles.company_id` if the client omits it.
    /// Stamping client-side is defense-in-depth: if the trigger is ever
    /// removed or regresses, the row still carries the correct tenant.
    /// Optional because pulled rows from older clients may not have it
    /// in the JSON payload — the pull path tolerates `nil` and re-stamps.
    var companyID: UUID? = nil

    var relatedEntryID: UUID            // TimesheetEntry or ScheduleEntry
    var type: ExceptionType
    var description: String
    var impactHours: Decimal?           // Estimated hours lost
    var photoAttachmentIDs: [UUID] = []

    // MARK: Sample data tracking
    var isSampleData:           Bool      = false
    var sampleDataBatchID:      UUID?     = nil
    var sampleDataSeedVersion:  String?   = nil
    var sampleDataCreatedAt:    Date?     = nil
    var sampleDataCreatedBy:    UUID?     = nil
}

// MARK: - Sample-data tracking
extension TimesheetEntry: SampleDataTrackable {}

// MARK: - Sample-data tracking
extension ExceptionLog: SampleDataTrackable {}
