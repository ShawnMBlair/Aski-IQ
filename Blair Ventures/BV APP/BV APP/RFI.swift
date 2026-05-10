// RFI.swift
// Aski IQ – Request for Information Module
// Tracks field questions to engineers / owners with response deadline and impact flags.

import Foundation

// MARK: - RFI Status

enum RFIStatus: String, Codable, CaseIterable {
    case draft       = "draft"
    case submitted   = "submitted"      // Sent to engineer/owner
    case underReview = "under_review"   // Being reviewed
    case answered    = "answered"       // Response received
    case closed      = "closed"         // Accepted and closed
    case voided      = "voided"

    var displayName: String {
        switch self {
        case .draft:       return "Draft"
        case .submitted:   return "Submitted"
        case .underReview: return "Under Review"
        case .answered:    return "Answered"
        case .closed:      return "Closed"
        case .voided:      return "Voided"
        }
    }

    var isOpen: Bool { ![.closed, .voided].contains(self) }
    var needsAnswer: Bool { [.submitted, .underReview].contains(self) }

    var icon: String {
        switch self {
        case .draft:       return "doc"
        case .submitted:   return "paperplane.fill"
        case .underReview: return "eye.circle"
        case .answered:    return "text.bubble.fill"
        case .closed:      return "checkmark.circle.fill"
        case .voided:      return "slash.circle"
        }
    }

    var color: String {
        switch self {
        case .draft:       return "gray"
        case .submitted:   return "blue"
        case .underReview: return "orange"
        case .answered:    return "purple"
        case .closed:      return "green"
        case .voided:      return "gray"
        }
    }
}

// MARK: - RFI Priority

enum RFIPriority: String, Codable, CaseIterable {
    case low    = "low"
    case normal = "normal"
    case high   = "high"
    case urgent = "urgent"

    var displayName: String {
        switch self {
        case .low:    return "Low"
        case .normal: return "Normal"
        case .high:   return "High"
        case .urgent: return "Urgent"
        }
    }

    var icon: String {
        switch self {
        case .low:    return "arrow.down.circle"
        case .normal: return "minus.circle"
        case .high:   return "exclamationmark.circle"
        case .urgent: return "exclamationmark.2"
        }
    }

    var color: String {
        switch self {
        case .low:    return "secondary"
        case .normal: return "blue"
        case .high:   return "orange"
        case .urgent: return "red"
        }
    }
}

// MARK: - RFI Category

enum RFICategory: String, Codable, CaseIterable {
    case structural   = "structural"
    case architectural = "architectural"
    case mechanical   = "mechanical"
    case electrical   = "electrical"
    case plumbing     = "plumbing"
    case civil        = "civil"
    case safety       = "safety"
    case schedule     = "schedule"
    case specification = "specification"
    case other        = "other"

    var displayName: String {
        switch self {
        case .structural:    return "Structural"
        case .architectural: return "Architectural"
        case .mechanical:    return "Mechanical"
        case .electrical:    return "Electrical"
        case .plumbing:      return "Plumbing"
        case .civil:         return "Civil"
        case .safety:        return "Safety"
        case .schedule:      return "Schedule"
        case .specification: return "Specification"
        case .other:         return "Other"
        }
    }

    var icon: String {
        switch self {
        case .structural:    return "building.columns"
        case .architectural: return "house.and.flag"
        case .mechanical:    return "gear"
        case .electrical:    return "bolt.circle"
        case .plumbing:      return "drop.circle"
        case .civil:         return "road.lanes"
        case .safety:        return "exclamationmark.shield"
        case .schedule:      return "calendar"
        case .specification: return "doc.text"
        case .other:         return "questionmark.circle"
        }
    }
}

// MARK: - RFI Model

struct RFI: BaseModel {
    var id: UUID = UUID()
    var externalID: String?
    var companyID: UUID? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()

    // Identity
    var number: String                      // e.g. "RFI-001"
    var title: String
    var projectID: UUID

    // Classification
    var status: RFIStatus = .draft
    var priority: RFIPriority = .normal
    var category: RFICategory = .other

    // Question
    var question: String = ""
    var reference: String?                  // Drawing / spec reference (e.g. "A-201 Rev B")
    var submittedByID: UUID?
    var submittedByName: String?
    var submittedDate: Date?
    var requiredByDate: Date?               // Response deadline

    // Response
    var answer: String?
    var answeredByName: String?
    var answeredDate: Date?

    // Impact flags (trigger workflow to create Change Order)
    var hasCostImpact: Bool = false
    var hasScheduleImpact: Bool = false
    var linkedChangeOrderID: UUID?          // CO created as a result of this RFI

    // Internal
    var internalNotes: String?
    var closedDate: Date?

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
    var isOverdue: Bool {
        guard let deadline = requiredByDate, status.needsAnswer else { return false }
        return Date() > deadline
    }

    var daysUntilDue: Int? {
        guard let deadline = requiredByDate, status.needsAnswer else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: deadline).day
    }
}

// MARK: - AppStore Extension

extension AppStore {

    private static let rfisKey = "bv_rfis"

    // MARK: CRUD

    func upsertRFI(_ item: RFI) {
        var updated = item
        updated.updatedAt      = Date()
        updated.lastModifiedAt = Date()
        updated.syncStatus     = .pending
        if let index = rfis.firstIndex(where: { $0.id == item.id }) {
            rfis[index] = updated
        } else {
            rfis.append(updated)
        }
        Task { await SyncEngine.shared.pushPendingRFIs() }
    }

    func deleteRFI(_ item: RFI) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive, .foreman],
                          action: "delete_rfi") else { return }
        guard let idx = rfis.firstIndex(where: { $0.id == item.id }) else { return }
        var deleted = rfis[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        rfis[idx] = deleted
        Task { await SyncEngine.shared.pushPendingRFIs() }
    }

    // MARK: Lookups

    func rfis(for projectID: UUID) -> [RFI] {
        rfis.filter { $0.projectID == projectID }
    }

    var openRFIs: [RFI] {
        rfis.filter { $0.status.isOpen }
    }

    var overdueRFIs: [RFI] {
        rfis.filter { $0.isOverdue }
    }

    /// Auto-generates a sequential RFI number scoped to the project.
    /// Phase 3: parsed-max+1 over (projectID, companyID), excluding
    /// soft-deleted. Mirrors ChangeOrder.nextCONumber. DB-side partial
    /// unique index on (project_id, number) WHERE is_deleted = false
    /// (RFI1 migration) catches cross-device races.
    func nextRFINumber(for projectID: UUID) -> String {
        let prefix = project(id: projectID)?.jobNumber ?? AppSettings.shared.companyPrefix
        let rfiPrefix = "\(prefix)-RFI-"
        let highest = rfis
            .filter {
                $0.projectID == projectID
                    && $0.companyID == currentCompanyID
                    && !$0.isDeleted
            }
            .compactMap { rfi -> Int? in
                guard rfi.number.hasPrefix(rfiPrefix) else { return nil }
                return Int(rfi.number.dropFirst(rfiPrefix.count))
            }
            .max() ?? 0
        return "\(rfiPrefix)\(String(format: "%03d", highest + 1))"
    }

    // MARK: Persistence

    // Persistence handled by Supabase. Stubs kept for call-site compatibility.
    func saveRFIs() {}
    func loadRFIs() {}

}

// MARK: - Sample-data tracking
extension RFI: SampleDataTrackable {}
