// Project.swift
// FieldOS – Projects Module

import Foundation

// MARK: - Project Status

/// Workflow state for a Project. Raw values are the canonical wire
/// format used by Postgres + RLS policies. Defensive decoder accepts
/// the legacy camelCase `"onHold"` spelling — pre-fix the enum had
/// no explicit raw values, so iOS was serializing `.onHold` as
/// `"onHold"` (camelCase, the auto-generated raw value from the
/// case name). All other case names are single-word lowercase so
/// the auto-generated raw values matched snake_case by accident;
/// `onHold` is the only case that drifted. Production has zero
/// `"onHold"` rows at the time of this fix so the migration risk
/// is theoretical, but new writes now use `"on_hold"` and any
/// in-flight legacy reads decode correctly.
enum ProjectStatus: String, Codable, CaseIterable {
    case tendering = "tendering"   // Bid/estimate stage
    case awarded   = "awarded"     // Won, not yet started
    case active    = "active"      // Work in progress
    case onHold    = "on_hold"
    case completed = "completed"
    case cancelled = "cancelled"

    /// Defensive decoder. Accepts the legacy camelCase `"onHold"`
    /// raw value any older client device might still write, plus
    /// `"on_hold"` going forward. Any other unknown raw value
    /// degrades to `.active` rather than throwing — a corrupted
    /// status code shouldn't bring down the whole project list.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "tendering":          self = .tendering
        case "awarded":            self = .awarded
        case "active":             self = .active
        case "on_hold", "onHold":  self = .onHold
        case "completed":          self = .completed
        case "cancelled":          self = .cancelled
        default:                   self = .active
        }
    }
}

// MARK: - Project

struct Project: BaseModel {
    var id: UUID = UUID()
    var externalID: String?                 // Client PO or job number
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()

    // MARK: - Tenant
    /// Multi-tenant scope. Stamped on upsert from `AppStore.currentCompanyID`
    /// and enforced server-side by the `projects_company` RLS policy
    /// (`company_id = get_my_company_id()`). Optional in Swift so a local
    /// draft created before sign-in can still be constructed; the upsert
    /// helper refuses to push a row whose companyID is nil.
    var companyID: UUID? = nil

    // Core fields
    var name: String
    var clientName: String                  // Display name (kept for backward compat)
    var clientID: UUID?                     // FK → clients.id (structured link)
    var siteID: UUID?                       // FK → client.sites[id] (which site)
    var status: ProjectStatus = .active
    var startDate: Date?
    var endDate: Date?
    var siteAddress: String?               // Legacy free-text; prefer siteID going forward
    var notes: String?
    var jobNumber: String?
    var assignedPMID: UUID?
    var assignedPMName: String?

    /// SR-1.3 (legacy) — single-crew take-off preference.
    /// Superseded by `laborPlan.preferredCrewID` (SR-1.4).
    var preferredCrewID: UUID? = nil

    /// SR-1.4 — take-off labor requirements. Inherited from
    /// `Quote.laborPlan` on `convertQuoteToProject`. The engine
    /// reads this to satisfy the work with any valid resource
    /// combination (crew / custom crew / individual workers).
    var laborPlan: LaborRequirement = LaborRequirement()

    // Financials
    var estimatedBudget: Decimal?
    var contractValue: Decimal?

    // Relationships (IDs only – resolved via AppStore)
    var assignedCrewIDs: [UUID] = []
    /// Phase RA-1: workers assigned to this project via custom_crew or
    /// individual_worker schedule entries. Auto-synced by
    /// `syncProjectAssignedFromScheduleEntry` whenever a shift saves.
    /// Mirrors the Crew linkage behavior — additive only, never auto-
    /// removed (worker may still be on other shifts or manually added).
    var assignedWorkerIDs: [UUID] = []
    var estimateIDs: [UUID] = []
    var formIDs: [UUID] = []
    var timesheetEntryIDs: [UUID] = []
    var scheduleEntryIDs: [UUID] = []

    /// Slice 2 (Entity-First CRM): every project must roll up to a CRM
    /// opportunity for pipeline reporting. Populated automatically by
    /// `convertQuoteToProject` from the source quote's opportunityID.
    /// Optional in Swift today; the DB column will become NOT NULL in
    /// Slice 2B once iOS push always carries it.
    var opportunityID: UUID? = nil

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
extension Project: SampleDataTrackable {}
