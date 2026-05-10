// DailyJobReport.swift
// Aski IQ – Daily Job Report Module

#if canImport(UIKit)
import Foundation
import UIKit
import Combine

// MARK: - Weather Condition

enum WeatherCondition: String, Codable, CaseIterable {
    case sunny          = "sunny"
    case partlyCloudy   = "partly_cloudy"
    case overcast       = "overcast"
    case lightRain      = "light_rain"
    case heavyRain      = "heavy_rain"
    case snow           = "snow"
    case freezingRain   = "freezing_rain"
    case fog            = "fog"
    case windy          = "windy"

    var displayName: String {
        switch self {
        case .sunny:        return "Sunny"
        case .partlyCloudy: return "Partly Cloudy"
        case .overcast:     return "Overcast"
        case .lightRain:    return "Light Rain"
        case .heavyRain:    return "Heavy Rain"
        case .snow:         return "Snow"
        case .freezingRain: return "Freezing Rain"
        case .fog:          return "Fog"
        case .windy:        return "Windy"
        }
    }

    var icon: String {
        switch self {
        case .sunny:        return "sun.max.fill"
        case .partlyCloudy: return "cloud.sun.fill"
        case .overcast:     return "cloud.fill"
        case .lightRain:    return "cloud.drizzle.fill"
        case .heavyRain:    return "cloud.heavyrain.fill"
        case .snow:         return "cloud.snow.fill"
        case .freezingRain: return "cloud.sleet.fill"
        case .fog:          return "cloud.fog.fill"
        case .windy:        return "wind"
        }
    }
}

// MARK: - DJR Status

enum DJRStatus: String, Codable, CaseIterable {
    case draft      = "draft"
    case submitted  = "submitted"
    case approved   = "approved"
    case rejected   = "rejected"

    var displayName: String {
        switch self {
        case .draft:     return "Draft"
        case .submitted: return "Submitted"
        case .approved:  return "Approved"
        case .rejected:  return "Rejected"
        }
    }

    var color: String {
        switch self {
        case .draft:     return "gray"
        case .submitted: return "blue"
        case .approved:  return "green"
        case .rejected:  return "red"
        }
    }
}

// MARK: - Crew Entry

struct DJRCrewEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var employeeID: UUID?
    var name: String
    var trade: String
    var hoursWorked: Double
    var overtime: Double = 0
}

// MARK: - Equipment Entry

struct DJREquipmentEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var description: String
    var hours: Double
    var notes: String = ""
}

// MARK: - Material Delivery

struct DJRMaterialDelivery: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var material: String
    var quantity: String
    var supplier: String = ""
    var notes: String = ""
}

// MARK: - Visitor / Inspection Entry

struct DJRVisitor: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var company: String = ""
    var purpose: String
    var timeArrived: String = ""
}

// MARK: - Delay Entry

enum DelayType: String, Codable, CaseIterable {
    case weather        = "weather"
    case material       = "material"
    case equipment      = "equipment"
    case labour         = "labour"
    case owner          = "owner"
    case design         = "design"
    case permitting     = "permitting"
    case other          = "other"

    var displayName: String {
        switch self {
        case .weather:    return "Weather"
        case .material:   return "Material"
        case .equipment:  return "Equipment"
        case .labour:     return "Labour"
        case .owner:      return "Owner / Client"
        case .design:     return "Design / Engineering"
        case .permitting: return "Permitting"
        case .other:      return "Other"
        }
    }
}

struct DJRDelay: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var type: DelayType
    var description: String
    var hoursLost: Double
    var impactDescription: String = ""
}

// MARK: - Daily Job Report

struct DailyJobReport: BaseModel {
    var id: UUID = UUID()
    var externalID: String? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()

    /// Multi-tenant scope. DJRs are project-scoped — derived from the parent
    /// project's `companyID` on upsert.
    var companyID: UUID? = nil

    // Identity
    var projectID: UUID
    var reportNumber: String          // e.g. "DJR-2025-001"
    var reportDate: Date
    var status: DJRStatus = .draft

    // Author
    var submittedByID: UUID?
    var submittedByName: String
    var submittedAt: Date?

    // Approval
    var approvedByID: UUID?
    var approvedByName: String?
    var approvedAt: Date?
    var rejectionNote: String?

    // Weather
    var weatherCondition: WeatherCondition = .sunny
    var temperatureHigh: Int?           // Celsius
    var temperatureLow: Int?
    var windSpeed: Int?                 // km/h
    var weatherNotes: String = ""

    // Workforce
    var crewEntries: [DJRCrewEntry] = []
    var totalWorkers: Int { crewEntries.count }
    var totalHoursWorked: Double { crewEntries.reduce(0) { $0 + $1.hoursWorked } }

    // Work & Site
    var workPerformed: String = ""     // Main narrative of work done
    var workAreas: [String] = []       // Zones / grid references
    var percentComplete: Int?          // Project % complete estimate

    // Equipment
    var equipmentEntries: [DJREquipmentEntry] = []

    // Materials
    var materialDeliveries: [DJRMaterialDelivery] = []

    // Site Activity
    var visitors: [DJRVisitor] = []
    var inspectionsPassed: Bool = false
    var inspectionNotes: String = ""

    // Delays
    var delays: [DJRDelay] = []
    var totalHoursLost: Double { delays.reduce(0) { $0 + $1.hoursLost } }

    // Safety
    var safetyMeetingHeld: Bool = false
    var safetyMeetingTopic: String = ""
    var safetyObservations: String = ""
    var firstAidIncidents: Int = 0

    // Photos
    var photoData: [Data] = []

    // Notes
    var notes: String = ""

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

    // MARK: - Computed

    var hasDelays: Bool { !delays.isEmpty }
    var hasMaterials: Bool { !materialDeliveries.isEmpty }
    var hasVisitors: Bool { !visitors.isEmpty }
}

// MARK: - AppStore Extension

extension AppStore {

    // MARK: Persistence key
    private static let djrKey = "bv_daily_job_reports"

    // MARK: DJR accessors

    func dailyJobReports(for projectID: UUID) -> [DailyJobReport] {
        loadAllDJRs().filter { $0.projectID == projectID }
            .sorted { $0.reportDate > $1.reportDate }
    }

    func allDailyJobReports() -> [DailyJobReport] {
        loadAllDJRs().sorted { $0.reportDate > $1.reportDate }
    }

    func dailyJobReport(id: UUID) -> DailyJobReport? {
        loadAllDJRs().first { $0.id == id }
    }

    // MARK: CRUD

    func addDJR(_ report: DailyJobReport) {
        // Stamp tenant scope: prefer parent project's companyID, then currentCompanyID.
        var stamped = report
        if stamped.companyID == nil {
            stamped.companyID =
                projects.first(where: { $0.id == stamped.projectID })?.companyID
                ?? currentCompanyID
        }
        var all = loadAllDJRs()
        all.append(stamped)
        saveDJRs(all)
        objectWillChange.send()
    }

    func updateDJR(_ report: DailyJobReport) {
        var stamped = report
        if stamped.companyID == nil {
            stamped.companyID =
                projects.first(where: { $0.id == stamped.projectID })?.companyID
                ?? currentCompanyID
        }
        var all = loadAllDJRs()
        if let idx = all.firstIndex(where: { $0.id == stamped.id }) {
            all[idx] = stamped
        }
        saveDJRs(all)
        objectWillChange.send()
    }

    func deleteDJR(_ report: DailyJobReport) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "delete_djr") else { return }
        var all = loadAllDJRs()
        guard let idx = all.firstIndex(where: { $0.id == report.id }) else { return }
        var deleted = all[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        all[idx] = deleted
        saveDJRs(all)
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPending() }
    }

    // MARK: Next report number

    /// Auto-generates a sequential DJR number scoped to the project.
    /// Phase 3: parsed-max+1 over (projectID, companyID), excluding
    /// soft-deleted. Same correctness fix as the other modules.
    ///
    /// SCHEMA GAP: as of 2026-05-09, prod's `daily_job_reports` table
    /// has no `report_number` column. Swift carries the field locally
    /// but `pushPendingDJRs` doesn't include it in the upsert payload,
    /// so DJR numbers are NEVER pushed and don't survive sync round-trips.
    /// A partial unique index can't apply until the column is added to
    /// the schema. Tracked in migrations/phase3_drafts/README.md.
    func nextDJRNumber(for projectID: UUID) -> String {
        let project = projects.first { $0.id == projectID }
        let prefix = project?.jobNumber ?? "PRJ"
        let djrPrefix = "DJR-\(prefix)-"
        let highest = allDailyJobReports()
            .filter {
                $0.projectID == projectID
                    && $0.companyID == currentCompanyID
                    && !$0.isDeleted
            }
            .compactMap { djr -> Int? in
                guard djr.reportNumber.hasPrefix(djrPrefix) else { return nil }
                return Int(djr.reportNumber.dropFirst(djrPrefix.count))
            }
            .max() ?? 0
        return "\(djrPrefix)\(String(format: "%03d", highest + 1))"
    }

    // MARK: Private helpers

    private func loadAllDJRs() -> [DailyJobReport] {
        guard let data = UserDefaults.standard.data(forKey: AppStore.djrKey),
              let decoded = try? JSONDecoder().decode([DailyJobReport].self, from: data)
        else { return [] }
        return decoded
    }

    /// Stamp tenant scope on DJR rows that arrived without it. DJRs persist
    /// in UserDefaults (not @Published), so we re-encode the array after
    /// fixing. Idempotent — only walks rows where companyID is nil.
    @discardableResult
    func backfillDJRCompanyIDs() -> Int {
        guard let fallback = currentCompanyID else { return 0 }
        var all = loadAllDJRs()
        var fixed = 0
        for i in all.indices where all[i].companyID == nil {
            let parent = projects.first(where: { $0.id == all[i].projectID })
            all[i].companyID  = parent?.companyID ?? fallback
            all[i].syncStatus = .pending
            fixed += 1
        }
        if fixed > 0 {
            saveDJRs(all)
            Task { await SyncEngine.shared.pushPending() }
        }
        return fixed
    }

    private func saveDJRs(_ reports: [DailyJobReport]) {
        if let data = try? JSONEncoder().encode(reports) {
            UserDefaults.standard.set(data, forKey: AppStore.djrKey)
        }
    }

}

// MARK: - Sample-data tracking
extension DailyJobReport: SampleDataTrackable {}
#endif
