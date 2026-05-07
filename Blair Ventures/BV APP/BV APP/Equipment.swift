// Equipment.swift
// Aski IQ – Equipment / Asset Registry

import Foundation
import Combine

// MARK: - Equipment Category

enum EquipmentCategory: String, Codable, CaseIterable {
    case heavy      = "heavy"
    case light      = "light"
    case vehicle    = "vehicle"
    case tool       = "tool"
    case safety     = "safety"
    case other      = "other"

    var displayName: String {
        switch self {
        case .heavy:   return "Heavy Equipment"
        case .light:   return "Light Equipment"
        case .vehicle: return "Vehicles"
        case .tool:    return "Tools"
        case .safety:  return "Safety Equipment"
        case .other:   return "Other"
        }
    }

    var icon: String {
        switch self {
        case .heavy:   return "truck.box.fill"
        case .light:   return "wrench.and.screwdriver.fill"
        case .vehicle: return "car.fill"
        case .tool:    return "hammer.fill"
        case .safety:  return "shield.lefthalf.filled"
        case .other:   return "shippingbox.fill"
        }
    }
}

// MARK: - Equipment Status

enum EquipmentStatus: String, Codable, CaseIterable {
    case available  = "available"
    case assigned   = "assigned"
    case maintenance = "maintenance"
    case retired    = "retired"

    var displayName: String {
        switch self {
        case .available:    return "Available"
        case .assigned:     return "Assigned"
        case .maintenance:  return "In Maintenance"
        case .retired:      return "Retired"
        }
    }

    var isActive: Bool { self != .retired }
}

// MARK: - Ownership Type

enum EquipmentOwnership: String, Codable, CaseIterable {
    case owned  = "owned"
    case leased = "leased"
    case rented = "rented"

    var displayName: String {
        switch self {
        case .owned:  return "Owned"
        case .leased: return "Leased"
        case .rented: return "Rented"
        }
    }
}

// MARK: - Equipment Model

struct Equipment: BaseModel {
    var id: UUID = UUID()
    var externalID: String? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()

    /// Multi-tenant scope. Equipment is yard-level — derived directly from
    /// `currentCompanyID` rather than from a parent record.
    var companyID: UUID? = nil

    // Identity
    var name: String
    var category: EquipmentCategory
    var status: EquipmentStatus = .available
    var ownership: EquipmentOwnership = .owned

    // Specs
    var make: String = ""
    var model: String = ""
    var year: Int? = nil
    var serialNumber: String = ""
    var licensePlate: String = ""           // for vehicles
    var color: String = ""

    // Assignment
    var assignedProjectID: UUID? = nil
    var assignedCrewID: UUID? = nil
    var currentLocation: String = ""

    // Maintenance / tracking
    var hourMeterReading: Decimal? = nil
    var odometerKm: Decimal? = nil
    var lastServiceDate: Date? = nil
    var nextServiceDate: Date? = nil
    var lastInspectionDate: Date? = nil
    var nextInspectionDate: Date? = nil
    var insuranceExpiryDate: Date? = nil

    // Financials (hidden from field roles)
    var dailyRate: Decimal? = nil
    var purchasePrice: Decimal? = nil
    var purchaseDate: Date? = nil

    var notes:     String  = ""
    var isActive:  Bool    = true
    var isDeleted: Bool    = false
    var deletedAt: Date?   = nil
    var deletedBy: String? = nil

    // MARK: Sample data tracking
    var isSampleData:           Bool      = false
    var sampleDataBatchID:      UUID?     = nil
    var sampleDataSeedVersion:  String?   = nil
    var sampleDataCreatedAt:    Date?     = nil
    var sampleDataCreatedBy:    UUID?     = nil

    init(name: String, category: EquipmentCategory) {
        self.name     = name
        self.category = category
    }
}

// MARK: - AppStore Extension

extension AppStore {

    // MARK: Equipment CRUD

    func addEquipment(_ item: Equipment) {
        objectWillChange.send()
        // Stamp tenant scope on insert (yard-level, so currentCompanyID).
        var stamped = item
        if stamped.companyID == nil { stamped.companyID = currentCompanyID }
        equipment.append(stamped)
        saveEquipment()
    }

    func updateEquipment(_ item: Equipment) {
        objectWillChange.send()
        if let idx = equipment.firstIndex(where: { $0.id == item.id }) {
            var updated = item
            updated.updatedAt = Date()
            // Preserve existing tenant scope; if somehow nil, stamp now.
            if updated.companyID == nil { updated.companyID = currentCompanyID }
            equipment[idx] = updated
        }
        saveEquipment()
    }

    enum EquipmentDeletionError: LocalizedError {
        case notPermitted
        case notFound
        case stillAssigned(String)

        var errorDescription: String? {
            switch self {
            case .notPermitted:    return "You don't have permission to delete this equipment."
            case .notFound:        return "Equipment not found."
            case .stillAssigned(let summary):
                return "This equipment is still \(summary). Unassign it before deleting."
            }
        }
    }

    @discardableResult
    func deleteEquipment(id: UUID) -> Result<Void, EquipmentDeletionError> {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "delete_equipment") else {
            return .failure(.notPermitted)
        }
        guard let idx = equipment.firstIndex(where: { $0.id == id }) else {
            return .failure(.notFound)
        }
        // Block when the equipment is still assigned to a live project or crew.
        var blockers: [String] = []
        let item = equipment[idx]
        if let projID = item.assignedProjectID,
           let proj = projects.first(where: { $0.id == projID && !$0.isDeleted }) {
            blockers.append("assigned to project '\(proj.name)'")
        }
        if let crewID = item.assignedCrewID,
           let crew = crews.first(where: { $0.id == crewID && !$0.isDeleted && $0.isActive }) {
            blockers.append("assigned to crew '\(crew.name)'")
        }
        if !blockers.isEmpty {
            return .failure(.stillAssigned(blockers.joined(separator: " and ")))
        }
        var deleted = equipment[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        equipment[idx] = deleted
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPending() }
        return .success(())
    }

    // MARK: Queries

    func equipment(for projectID: UUID) -> [Equipment] {
        equipment.filter { $0.assignedProjectID == projectID }
    }

    var availableEquipment: [Equipment] {
        equipment.filter { $0.status == .available && $0.isActive }
    }

    var equipmentNeedingService: [Equipment] {
        let soon = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
        return equipment.filter {
            guard let next = $0.nextServiceDate else { return false }
            return next <= soon && $0.isActive
        }
    }

    var equipmentWithExpiringInspections: [Equipment] {
        let soon = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
        return equipment.filter {
            guard let next = $0.nextInspectionDate else { return false }
            return next <= soon && $0.isActive
        }
    }

    // MARK: Persistence

    private static let equipmentKey = "bv_equipment"

    // Persistence handled by Supabase. Stubs kept for call-site compatibility.
    func saveEquipment() {}
    func loadEquipment() {}

}

// MARK: - Sample-data tracking
extension Equipment: SampleDataTrackable {}
