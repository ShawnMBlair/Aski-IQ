// ScheduleRecommendation.swift
// Aski IQ — Phase SR-1 Smart Scheduling foundation.
//
// PURPOSE
// Data shape for "what the engine proposes" vs. "what the user
// approves to become real". The engine never mutates the live
// schedule directly; it produces recommendations, humans review
// them, and approval is what mints actual ScheduleEntries through
// the existing AppStore.upsertScheduleEntry chokepoint.
//
// LIFECYCLE
//   pending_review (engine output)
//      ↓ approve / edit-and-approve / reject
//   approved | edited_and_approved | rejected
//      ↓ apply (engine → ScheduleEntries)
//   applied (terminal)
//
// PERSISTENCE
// Round-trips to public.schedule_recommendations. proposed_entries
// is a JSONB blob — each ProposedScheduleEntry is the iOS-side
// shape we use to mint a real ScheduleEntry on approval.
//
// SCOPE — SR-1
//   • Engine is rules-based (no LLM yet).
//   • Only Quote-converted projects produce recommendations in SR-1.
//   • UI: Section in Command Centre + review screen + approve/reject.
//
// FUTURE (deferred)
//   • SR-3: extend engine to material sales, change orders, gaps
//   • SR-4: confidence scoring + alternative crew suggestions
//   • SR-5: LLM-backed scoring
//   • SR-6: planned-vs-actual learning loop

import Foundation

// MARK: - Status

enum ScheduleRecommendationStatus: String, Codable, CaseIterable, Equatable {
    case draft               = "draft"
    case pendingReview       = "pending_review"
    /// SR-β: reviewer sent the plan back with notes. The original
    /// requester can revise and resubmit. Stays in the queue so a
    /// senior can still take over the approval if needed.
    case revisionRequested   = "revision_requested"
    case approved            = "approved"
    case editedAndApproved   = "edited_and_approved"
    case rejected            = "rejected"
    case cancelled           = "cancelled"
    /// Terminal state: the recommendation's proposed entries have
    /// been minted as live ScheduleEntries. Master prompt names this
    /// "published"; we keep `.applied` as the raw value for back-
    /// compat with rows already on the server, but the user-facing
    /// label now says "Published" (`displayLabel` below).
    case applied             = "applied"

    var displayLabel: String {
        switch self {
        case .draft:             return "Draft"
        case .pendingReview:     return "Needs Approval"
        case .revisionRequested: return "Needs Revision"
        case .approved:          return "Approved"
        case .editedAndApproved: return "Edited & Approved"
        case .rejected:          return "Rejected"
        case .cancelled:         return "Cancelled"
        case .applied:           return "Published"
        }
    }

    /// True when the recommendation is still actionable from the
    /// queue. Includes `.revisionRequested` because a senior can
    /// take over an approval that's been kicked back to the
    /// original requester (master prompt's "approvals move upward"
    /// rule applies even when stuck in revision).
    var isInQueue: Bool {
        switch self {
        case .draft, .pendingReview, .revisionRequested: return true
        default: return false
        }
    }

    /// True for the terminal states. Recommendations in these states
    /// shouldn't show up in active queues.
    var isTerminal: Bool {
        self == .applied || self == .rejected || self == .cancelled
    }
}

// MARK: - Source type
//
// Mirrors NeedsSchedulingSourceType but encoded as the snake_case
// string the DB column expects. We don't reuse that enum directly
// because (a) it lives in the Command Centre service layer which
// recommendations shouldn't depend on, and (b) it has a `.internalWork`
// case the recommendation engine doesn't (yet) produce.

enum ScheduleRecommendationSourceType: String, Codable, Equatable {
    case quote          = "quote"
    case project        = "project"
    case materialSale   = "material_sale"
    case changeOrder    = "change_order"
    case manual         = "manual"
}

// MARK: - Risk

/// Single risk surfaced on the recommendation. The engine emits
/// these by mapping ScheduleConflict outputs from a probe run, so
/// the conflict types align with ConflictType raw values.
struct ScheduleRisk: Codable, Equatable, Identifiable {
    enum Severity: String, Codable, Equatable {
        case low, medium, high
    }
    /// Conflict-type raw value (e.g. "overtimeRisk", "crewDoubleBooked").
    /// Free-string so future engine versions can emit new categories
    /// without an enum migration.
    var type: String
    var severity: Severity
    var message: String

    // Identifiable for SwiftUI ForEach without an explicit id field
    // (each risk is value-equal — type + message acts as id).
    var id: String { "\(type)|\(message)" }
}

// MARK: - Alternative

/// Suggested alternative crew when the recommended crew has risks.
/// Engine produces 0–2 alternatives — the goal is "give the manager
/// a one-tap escape" not "show every option."
struct ScheduleAlternative: Codable, Equatable, Identifiable {
    var crewID: UUID
    var reason: String
    var id: UUID { crewID }
}

// MARK: - Proposed entry

/// Shape of a single shift the engine wants to create on approval.
/// Mirrors ScheduleEntry's primary fields; converted to a real
/// ScheduleEntry by ScheduleRecommendationApplyService when the
/// manager approves.
struct ProposedScheduleEntry: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var projectID: UUID
    var crewID: UUID?
    var assignedWorkerIDs: [UUID] = []
    var foremanID: UUID?
    var assignmentMode: ScheduleAssignmentMode = .fixedCrew
    var date: Date
    var shiftStart: Date?
    var shiftEnd: Date?
    var taskDescription: String?
    var costCode: String?
    var location: String?
    var requiredCertifications: [String] = []
    var estimatedHours: Double = 8
    var notes: String?

    // MARK: - Codable
    //
    // Explicit Codable instead of auto-synthesized.
    //
    // BUG THIS FIXES (2026-05): the JSONB blob in
    // schedule_recommendations.proposed_entries stores dates as ISO 8601
    // strings WITHOUT a timezone marker (e.g.
    // "2026-05-10T21:40:12.230"). Swift's default JSONDecoder uses
    // `.deferredToDate` strategy (Double secondsSince2001) and fails
    // hard on string dates — and even `.iso8601` rejects strings
    // missing the trailing Z. Result: every pull of
    // schedule_recommendations threw at the array decode, the catch
    // logged but didn't refresh `store.scheduleRecommendations`, and
    // the entire AI Schedule Plans section of the Approval Queue
    // appeared empty even when rows existed server-side.
    //
    // The hand-written init below tries multiple date formatters in
    // priority order so any reasonable variant round-trips:
    //   1. ISO 8601 with fractional seconds + Z   (canonical iOS encode)
    //   2. ISO 8601 with Z, no fractional seconds (legacy iOS encode)
    //   3. ISO 8601 with fractional seconds, no Z (Postgres jsonb default)
    //   4. ISO 8601, no fractional, no Z          (further legacy)
    //   5. ISO date only "2026-05-10"             (date-only fallback)
    //
    // Encoder always emits format 1 so future round-trips are
    // unambiguous. Old rows continue to decode via the fallbacks.

    private enum CodingKeys: String, CodingKey {
        case id, projectID, crewID, assignedWorkerIDs, foremanID
        case assignmentMode, date, shiftStart, shiftEnd
        case taskDescription, costCode, location
        case requiredCertifications, estimatedHours, notes
    }

    init(id: UUID = UUID(), projectID: UUID, crewID: UUID? = nil,
         assignedWorkerIDs: [UUID] = [], foremanID: UUID? = nil,
         assignmentMode: ScheduleAssignmentMode = .fixedCrew,
         date: Date, shiftStart: Date? = nil, shiftEnd: Date? = nil,
         taskDescription: String? = nil, costCode: String? = nil,
         location: String? = nil,
         requiredCertifications: [String] = [],
         estimatedHours: Double = 8, notes: String? = nil) {
        self.id = id
        self.projectID = projectID
        self.crewID = crewID
        self.assignedWorkerIDs = assignedWorkerIDs
        self.foremanID = foremanID
        self.assignmentMode = assignmentMode
        self.date = date
        self.shiftStart = shiftStart
        self.shiftEnd = shiftEnd
        self.taskDescription = taskDescription
        self.costCode = costCode
        self.location = location
        self.requiredCertifications = requiredCertifications
        self.estimatedHours = estimatedHours
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.projectID = try c.decode(UUID.self, forKey: .projectID)
        self.crewID = try c.decodeIfPresent(UUID.self, forKey: .crewID)
        self.assignedWorkerIDs = try c.decodeIfPresent([UUID].self, forKey: .assignedWorkerIDs) ?? []
        self.foremanID = try c.decodeIfPresent(UUID.self, forKey: .foremanID)
        self.assignmentMode = try c.decodeIfPresent(ScheduleAssignmentMode.self, forKey: .assignmentMode) ?? .fixedCrew
        self.date = try Self.decodeDate(c, key: .date) ?? Date()
        self.shiftStart = try Self.decodeDate(c, key: .shiftStart)
        self.shiftEnd = try Self.decodeDate(c, key: .shiftEnd)
        self.taskDescription = try c.decodeIfPresent(String.self, forKey: .taskDescription)
        self.costCode = try c.decodeIfPresent(String.self, forKey: .costCode)
        self.location = try c.decodeIfPresent(String.self, forKey: .location)
        self.requiredCertifications = try c.decodeIfPresent([String].self, forKey: .requiredCertifications) ?? []
        self.estimatedHours = try c.decodeIfPresent(Double.self, forKey: .estimatedHours) ?? 8
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(projectID, forKey: .projectID)
        try c.encodeIfPresent(crewID, forKey: .crewID)
        try c.encode(assignedWorkerIDs, forKey: .assignedWorkerIDs)
        try c.encodeIfPresent(foremanID, forKey: .foremanID)
        try c.encode(assignmentMode, forKey: .assignmentMode)
        try c.encode(Self.dateString(date), forKey: .date)
        try c.encodeIfPresent(shiftStart.map(Self.dateString), forKey: .shiftStart)
        try c.encodeIfPresent(shiftEnd.map(Self.dateString), forKey: .shiftEnd)
        try c.encodeIfPresent(taskDescription, forKey: .taskDescription)
        try c.encodeIfPresent(costCode, forKey: .costCode)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encode(requiredCertifications, forKey: .requiredCertifications)
        try c.encode(estimatedHours, forKey: .estimatedHours)
        try c.encodeIfPresent(notes, forKey: .notes)
    }

    /// Tolerant date decode: tries the 5 most common ISO 8601 variants
    /// the JSONB blob might contain. Returns nil if the key is absent,
    /// the value is null, or the value can't be parsed in any known
    /// format (graceful — one bad date in a row shouldn't kill the
    /// whole array decode).
    ///
    /// `try?` on a function that returns `T?` flattens to `T?` (SE-0230,
    /// Swift 5.0+), not `T??` — so `if let` here unwraps directly to
    /// `String` / `Double`, no second guard-let needed.
    private static func decodeDate(_ c: KeyedDecodingContainer<CodingKeys>,
                                   key: CodingKeys) throws -> Date? {
        // Common case: ISO 8601 string in the JSONB payload.
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            return parseDateString(s)
        }
        // Legacy fallback: numeric (.deferredToDate strategy emits
        // seconds since 2001 reference). Older recommendations pushed
        // before SR-1's ProposedScheduleEntry stabilized may have
        // landed in this shape.
        if let secs = try? c.decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSinceReferenceDate: secs)
        }
        return nil
    }

    /// Single canonical encoding format: `2026-05-10T21:40:12.230Z`.
    /// Same shape the canonical iOS push has emitted; old rows in
    /// other shapes still decode via the fallback chain.
    private static func dateString(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    private static func parseDateString(_ s: String) -> Date? {
        // Short-circuit: ISO8601DateFormatter handles the most common
        // variants. Fallbacks below cover the missing-Z edge cases.
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }

        // Postgres jsonb often serializes timestamp-without-tz as
        // "2026-05-10T21:40:12.230" (no Z). Try DateFormatter with
        // fixed format and POSIX locale.
        let posix = Locale(identifier: "en_US_POSIX")
        let utc = TimeZone(identifier: "UTC")
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd"
        ] {
            let df = DateFormatter()
            df.locale = posix
            df.timeZone = utc
            df.dateFormat = format
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
}

// MARK: - Recommendation

struct ScheduleRecommendation: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var companyID: UUID
    var sourceType: ScheduleRecommendationSourceType
    var sourceID: UUID
    var projectID: UUID?
    var recommendationType: String = "project_kickoff_schedule"
    var createdByAI: Bool = true
    var requestedByUserID: UUID?
    var status: ScheduleRecommendationStatus = .pendingReview
    var confidenceScore: Double = 0
    var summary: String = ""
    var reasoning: String = ""
    var risks: [ScheduleRisk] = []
    var alternatives: [ScheduleAlternative] = []
    var proposedEntries: [ProposedScheduleEntry] = []
    var approvedBy: UUID?
    var approvedAt: Date?
    var rejectedBy: UUID?
    var rejectedAt: Date?
    var rejectionReason: String?
    /// SR-β: free-text notes left by the reviewer when sending the
    /// plan back for revision. The original requester sees these
    /// when they re-open the recommendation. Persisted as
    /// `schedule_recommendations.review_notes`.
    var reviewNotes: String?
    /// SR-γ: free-text reason captured when a Manager or Executive
    /// approves a plan past high-severity risks. Required by the
    /// apply flow when `requiresHighRiskOverride == true`. Persisted
    /// as `schedule_recommendations.override_reason`.
    var overrideReason: String?
    /// SR-γ: HOW the approval happened (direct / role-based /
    /// senior_override / tier_required / conflict_override). Stamped
    /// at approve time so the audit trail is self-explanatory.
    /// Persisted as `schedule_recommendations.approval_mode`.
    var approvalMode: ApprovalMode?
    var appliedEntryIDs: [UUID] = []
    var appliedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// Local-only sync flag. Pre-RA-1's BaseModel pattern, but
    /// recommendations don't conform to BaseModel because they
    /// don't have lastModifiedBy / sample-data fields. Persisted to
    /// disk via its own bucket; pushed via SyncEngine.
    var syncStatus: SyncStatus = .pending

    // MARK: - Computed helpers

    /// True when the manager can still approve / edit / reject.
    /// Drives the action button visibility on the review screen.
    var isActionable: Bool {
        !status.isTerminal && status != .approved && status != .editedAndApproved
    }

    /// True when the recommendation has any high-severity risks.
    /// Used by the queue card to pulse a warning indicator.
    var hasBlockingRisks: Bool {
        risks.contains { $0.severity == .high }
    }

    /// SR-γ: count of high-severity risks. Drives the override gate
    /// — when ≥1, only Manager / Executive can approve, and they
    /// must supply an override reason.
    var highRiskCount: Int {
        risks.filter { $0.severity == .high }.count
    }

    /// SR-γ: requires Manager-or-Executive approval AND an override
    /// reason. Per the master prompt's section 16: "If the plan
    /// contains high-risk conflicts, the approver must be Manager
    /// or Executive."
    var requiresHighRiskOverride: Bool {
        highRiskCount > 0
    }

    /// Human-readable severity rollup for the queue card.
    var riskLabel: String {
        if risks.contains(where: { $0.severity == .high }) { return "High Risk" }
        if risks.contains(where: { $0.severity == .medium }) { return "Some Risk" }
        if !risks.isEmpty { return "Low Risk" }
        return "No Risk"
    }
}
