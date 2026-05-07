// ScheduleEntry.swift
// FieldOS – Scheduling Module

import Foundation

// MARK: - Schedule Entry Status

enum ScheduleEntryStatus: String, Codable {
    case scheduled
    case inProgress
    case completed
    case cancelled
    case rescheduled
}

// MARK: - Schedule Assignment Mode (Phase RA-1)
//
// Real field operations don't always work in fixed crews. The three
// modes below let scheduling express any of:
//
//   • fixedCrew        — standard "Crew A goes to job X" (legacy default)
//   • customCrew       — temporary team (e.g. "Bob + Sarah for one job")
//   • individualWorker — one person is enough (e.g. small delivery)
//
// The underlying `crewID` and `assignedWorkerIDs` fields work together;
// `assignmentMode` resolves the ambiguity when both are present (or both
// are empty) and gives the conflict service + Smart Assignment a clear
// contract to reason against. Server-side CHECK constraint enforces
// the per-mode shape so direct PostgREST writes can't bypass iOS rules.

enum ScheduleAssignmentMode: String, Codable, CaseIterable, Equatable {
    case fixedCrew        = "fixed_crew"
    case customCrew       = "custom_crew"
    case individualWorker = "individual_worker"

    var displayLabel: String {
        switch self {
        case .fixedCrew:        return "Fixed Crew"
        case .customCrew:       return "Custom Crew"
        case .individualWorker: return "Individual Worker"
        }
    }
}

// MARK: - Schedule Entry

struct ScheduleEntry: BaseModel {
    var id: UUID = UUID()
    var externalID: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()

    /// Multi-tenant scope. Stamped on upsert from the parent project's
    /// `companyID` (or `currentCompanyID` as a fallback) so RLS WITH CHECK
    /// passes server-side.
    var companyID: UUID? = nil

    // Core
    var projectID: UUID
    var crewID: UUID?
    var date: Date
    var shiftStart: Date?
    var shiftEnd: Date?
    var status: ScheduleEntryStatus = .scheduled

    // MARK: - Phase RA-1: Flexible assignment
    //
    // Default `.fixedCrew` so every existing row keeps its current
    // semantics on first decode — no behavior change until the user
    // explicitly picks customCrew or individualWorker via the editor
    // (RA-3 UI work).
    var assignmentMode: ScheduleAssignmentMode = .fixedCrew

    /// Per-shift worker roster. Snapshot at schedule time — future
    /// crew composition changes don't retroactively rewrite history.
    /// Empty for fixed_crew (workers inherited from `Crew.memberIDs`)
    /// unless the user later overrides the roster (RA-3).
    /// Populated for custom_crew and individual_worker modes.
    var assignedWorkerIDs: [UUID] = []

    /// Per-shift foreman override. Pre-RA-1 the foreman was always
    /// inherited from `Crew.foremanID` — fine for fixedCrew, breaks
    /// for customCrew where a member of the temporary group leads.
    /// nil for fixedCrew (= inherit from crew) and for individualWorker
    /// (= no foreman needed).
    var foremanID: UUID? = nil

    // Work details
    var taskDescription: String?
    var costCode: String?               // Links to Estimate cost codes
    var location: String?               // Specific area within site
    var notes: String?

    /// Free-text certification names (matches `Employee.certifications`
    /// shape — also `[String]`). When populated, the conflict service
    /// flags the shift if the assigned crew has no member who carries
    /// every required cert. Empty array = no cert requirement.
    /// Phase-1 scheduling upgrade. Server column is JSONB.
    var requiredCertifications: [String] = []

    // "Copy Last Job Setup" support
    var copiedFromEntryID: UUID?        // Track template source

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
}

// MARK: - Sample-data tracking
extension ScheduleEntry: SampleDataTrackable {}

// MARK: - RA-3: Assignment display helpers
//
// Cards across the app (Dispatch Board, Command Centre, etc.) need
// to show a human label for the shift's assignment. Pre-RA-3 the
// rule was simple: crewID → crew name, else "Unassigned." That
// produces a misleading "Unassigned" for custom_crew and
// individual_worker shifts that DO have a roster — they just don't
// have a crew. These helpers centralize the logic so every card
// rendering uses the same labels.

extension ScheduleEntry {
    /// True when the shift has neither a crew nor a direct-worker
    /// assignment. The "needs scheduling" flag for dispatch boards.
    var hasNoResources: Bool {
        crewID == nil && assignedWorkerIDs.isEmpty
    }

    /// Compose a human-readable label for the assignment, given the
    /// store's crews + employees so we can resolve names. Falls back
    /// to "Unassigned" only when there genuinely is no resource on
    /// the shift.
    ///
    /// - For fixed_crew → returns the crew name (or worker count if
    ///   the optional roster override is set).
    /// - For custom_crew → "N workers" or the single worker's name.
    /// - For individual_worker → the worker's full name.
    func assignmentLabel(crews: [Crew], employees: [Employee]) -> String {
        switch assignmentMode {
        case .fixedCrew:
            if !assignedWorkerIDs.isEmpty {
                // RA-3.5 future: per-shift roster override of a crew.
                return "\(crewName(crews: crews) ?? "Crew") (partial)"
            }
            return crewName(crews: crews) ?? "Unassigned"
        case .customCrew:
            return customLabel(employees: employees)
        case .individualWorker:
            guard let workerID = assignedWorkerIDs.first,
                  let emp = employees.first(where: { $0.id == workerID }) else {
                return "Unassigned"
            }
            return emp.fullName
        }
    }

    /// Icon name suitable for accompanying the assignment label.
    var assignmentIconName: String {
        if hasNoResources { return "person.crop.circle.badge.questionmark" }
        switch assignmentMode {
        case .fixedCrew:        return "person.2.fill"
        case .customCrew:       return "person.3.sequence.fill"
        case .individualWorker: return "person.fill"
        }
    }

    private func crewName(crews: [Crew]) -> String? {
        guard let cid = crewID else { return nil }
        return crews.first(where: { $0.id == cid })?.name
    }

    private func customLabel(employees: [Employee]) -> String {
        let count = assignedWorkerIDs.count
        if count == 0 { return "Unassigned" }
        if count == 1 {
            if let id = assignedWorkerIDs.first,
               let emp = employees.first(where: { $0.id == id }) {
                return emp.fullName
            }
            return "1 worker"
        }
        return "\(count) workers"
    }
}
