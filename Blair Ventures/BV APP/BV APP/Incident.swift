// Incident.swift
// BV APP – Incident / Safety Reporting Model

import Foundation
import SwiftUI
import Combine

// MARK: - Incident Type

enum IncidentType: String, Codable, CaseIterable {
    case nearMiss        = "near_miss"
    case firstAid        = "first_aid"
    case medicalAid      = "medical_aid"
    case lostTime        = "lost_time"
    case propertyDamage  = "property_damage"
    case environmental   = "environmental"
    case theft           = "theft"
    case other           = "other"

    var displayName: String {
        switch self {
        case .nearMiss:       return "Near Miss"
        case .firstAid:       return "First Aid"
        case .medicalAid:     return "Medical Aid"
        case .lostTime:       return "Lost Time Injury"
        case .propertyDamage: return "Property Damage"
        case .environmental:  return "Environmental"
        case .theft:          return "Theft / Vandalism"
        case .other:          return "Other"
        }
    }

    var icon: String {
        switch self {
        case .nearMiss:       return "exclamationmark.triangle.fill"
        case .firstAid:       return "cross.case.fill"
        case .medicalAid:     return "staroflife.fill"
        case .lostTime:       return "bed.double.fill"
        case .propertyDamage: return "wrench.and.screwdriver.fill"
        case .environmental:  return "leaf.fill"
        case .theft:          return "lock.slash.fill"
        case .other:          return "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .nearMiss:       return .yellow
        case .firstAid:       return .blue
        case .medicalAid:     return .orange
        case .lostTime:       return .red
        case .propertyDamage: return .purple
        case .environmental:  return .green
        case .theft:          return .gray
        case .other:          return .secondary
        }
    }
}

// MARK: - Incident Severity

enum IncidentSeverity: String, Codable, CaseIterable {
    case low      = "low"
    case medium   = "medium"
    case high     = "high"
    case critical = "critical"

    var displayName: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .low:      return .green
        case .medium:   return .yellow
        case .high:     return .orange
        case .critical: return .red
        }
    }

    var icon: String {
        switch self {
        case .low:      return "chevron.down.circle.fill"
        case .medium:   return "minus.circle.fill"
        case .high:     return "chevron.up.circle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    /// Notify management immediately for high/critical
    var requiresImmediateNotification: Bool {
        self == .high || self == .critical
    }
}

// MARK: - Incident Status

enum IncidentStatus: String, Codable, CaseIterable {
    case open          = "open"
    case investigating = "investigating"
    case resolved      = "resolved"
    case closed        = "closed"

    var displayName: String {
        switch self {
        case .open:          return "Open"
        case .investigating: return "Investigating"
        case .resolved:      return "Resolved"
        case .closed:        return "Closed"
        }
    }

    var color: Color {
        switch self {
        case .open:          return .red
        case .investigating: return .orange
        case .resolved:      return .blue
        case .closed:        return .green
        }
    }
}

// MARK: - Incident Document Attachment

struct IncidentDocument: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var fileName: String
    var fileData: Data
    var addedAt: Date = Date()
}

// MARK: - Incident Model

struct Incident: BaseModel {
    var id:             UUID    = UUID()
    var externalID:     String? = nil
    var createdAt:      Date    = Date()
    var updatedAt:      Date    = Date()
    var syncStatus:     SyncStatus = .local
    var lastModifiedBy: String  = ""
    var lastModifiedAt: Date    = Date()

    /// Multi-tenant scope. Workplace incidents are legally sensitive
    /// (OSHA / WCB) records — leaking them across tenants is a regulatory
    /// problem, not just a privacy one. Stamped from `currentCompanyID`
    /// (parent project may not be set for office-only incidents).
    var companyID: UUID? = nil

    // Core
    var title:        String
    var incidentType: IncidentType    = .nearMiss
    var severity:     IncidentSeverity = .medium
    var status:       IncidentStatus   = .open

    // Context
    var projectID:       UUID?   = nil
    var reportedByID:    UUID?   = nil
    var reportedByName:  String  = ""
    var incidentDate:    Date    = Date()
    var incidentTime:    Date    = Date()
    var locationDescription: String? = nil   // free-text location on site

    // Details
    var description:       String  = ""
    var immediateActions:  String? = nil     // actions taken right away
    var rootCause:         String? = nil
    var correctiveActions: String? = nil
    var witnesses:         [String] = []

    // Injury / Medical
    var injuredPersonName:  String? = nil
    var injuryDescription:  String? = nil
    var medicalTreatment:   String? = nil
    var workDaysLost:       Int?    = nil

    // Property / Financial
    var propertyDamageDesc: String?  = nil
    var estimatedCost:      Decimal? = nil

    // Photos (stored as base64 locally; stripped before sync like forms)
    var photoData: [Data] = []

    // Attached documents (PDFs, files)
    var documentAttachments: [IncidentDocument] = []

    // Regulatory
    var reportableToWCB:  Bool    = false
    var wcbClaimNumber:   String? = nil
    var reportableToOHS:  Bool    = false

    // Signature / Legal certification
    var isSigned:  Bool    = false
    var signedBy:  String? = nil
    var signedAt:  Date?   = nil
    var auditHash: String? = nil

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

// MARK: - AppStore Extension

extension AppStore {

    func upsertIncident(_ item: Incident) {
        let isNew = !incidents.contains { $0.id == item.id }
        // Stamp tenant scope from the parent project (when set) or from the
        // current company. Required NOT NULL on the server.
        var stamped = item
        if stamped.companyID == nil {
            stamped.companyID =
                stamped.projectID.flatMap { project(id: $0) }?.companyID
                ?? currentCompanyID
        }
        if let idx = incidents.firstIndex(where: { $0.id == stamped.id }) {
            incidents[idx] = stamped
        } else {
            incidents.append(stamped)
        }
        objectWillChange.send()

        let projectName = item.projectID.flatMap { project(id: $0) }?.name ?? "site"

        if item.status == .open {
            if item.severity.requiresImmediateNotification {
                NotificationManager.shared.notifyHighSeverityIncident(
                    title:    item.title,
                    severity: item.severity.displayName,
                    project:  projectName
                )
            } else if isNew {
                NotificationManager.shared.notifyIncidentOpened(
                    title:       item.title,
                    projectName: projectName
                )
            }
        }
    }

    func deleteIncident(_ item: Incident) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "delete_incident") else { return }
        guard let idx = incidents.firstIndex(where: { $0.id == item.id }) else { return }
        var deleted = incidents[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        incidents[idx] = deleted
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPending() }
    }

    func incident(id: UUID) -> Incident? {
        incidents.first { $0.id == id }
    }

    func incidents(for projectID: UUID) -> [Incident] {
        incidents.filter { $0.projectID == projectID }
            .sorted { $0.incidentDate > $1.incidentDate }
    }

    /// Open incidents (Open + Investigating), excluding soft-deleted rows.
    /// The recent-activity widget surfaces these on the Office dashboard, so
    /// we owe it a clean list — deleted rows were leaking through before.
    var openIncidents: [Incident] {
        incidents
            .filter { ($0.status == .open || $0.status == .investigating) && !$0.isDeleted }
            .sorted { $0.incidentDate > $1.incidentDate }
    }
}

// MARK: - Sample-data tracking
extension Incident: SampleDataTrackable {}
