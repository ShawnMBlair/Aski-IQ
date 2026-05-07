// CompanyCostCode.swift
// Aski IQ – Cost Code Model, Categories & Master List

import Foundation
import SwiftUI

// MARK: - Category

enum CostCodeCategory: String, Codable, CaseIterable, Identifiable {
    case labour      = "Labour"
    case insulation  = "Insulation"
    case scaffolding = "Scaffolding"
    case containment = "Containment"
    case drywall     = "Drywall / Interior"
    case equipment   = "Equipment & Tools"
    case safety      = "Safety & Training"
    case travel      = "Travel & Mobilization"
    case overhead    = "Overhead / Indirect"
    case delays      = "Delays & Weather"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .labour:      return "person.fill"
        case .insulation:  return "thermometer.medium"
        case .scaffolding: return "rectangle.3.group.fill"
        case .containment: return "shield.lefthalf.filled"
        case .drywall:     return "square.3.layers.3d"
        case .equipment:   return "wrench.and.screwdriver.fill"
        case .safety:      return "cross.case.fill"
        case .travel:      return "car.fill"
        case .overhead:    return "building.2.fill"
        case .delays:      return "clock.badge.exclamationmark.fill"
        }
    }

    var color: Color {
        switch self {
        case .labour:      return .blue
        case .insulation:  return .orange
        case .scaffolding: return .brown
        case .containment: return .purple
        case .drywall:     return .gray
        case .equipment:   return .indigo
        case .safety:      return .red
        case .travel:      return .teal
        case .overhead:    return .secondary
        case .delays:      return .yellow
        }
    }
}

// MARK: - Model

struct CompanyCostCode: Identifiable, Codable, Equatable, Hashable {
    var id:          UUID              = UUID()
    var companyID:   UUID?             = nil
    var code:        String
    var description: String
    var category:    CostCodeCategory
    var isEnabled:   Bool              = true
    var isCustom:    Bool              = false
    var sortOrder:   Int               = 0
    var syncStatus:  SyncStatus        = .local
    /// Slice C: service-type tags drive Terms & Conditions auto-suggestion.
    /// When a quote includes a line item using this cost code, any
    /// terms_templates with overlapping `applies_to_service_types` are
    /// surfaced in the picker's "Suggested for this quote" section and
    /// missing-category warnings fire at send time. Defaults to empty
    /// — admins assign per code via the Cost Code settings screen.
    var serviceTypes: [ServiceType]    = []

    var displayLabel: String { "\(code)  –  \(description)" }
}

// MARK: - AppStore Extension

extension AppStore {

    // Enabled codes only — what the picker shows
    var enabledCostCodes: [CompanyCostCode] {
        companyCostCodes.filter { $0.isEnabled }
    }

    // Enabled categories — only those with at least one enabled code
    var enabledCategories: [CostCodeCategory] {
        let cats = Set(enabledCostCodes.map(\.category))
        return CostCodeCategory.allCases.filter { cats.contains($0) }
    }

    func enabledCodes(in category: CostCodeCategory) -> [CompanyCostCode] {
        enabledCostCodes.filter { $0.category == category }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Returns project-specific codes (from budget lines) merged with enabled company defaults.
    func costCodes(forProjectID projectID: UUID?) -> [CompanyCostCode] {
        if let projID = projectID,
           let budget = projectBudgets.first(where: { $0.projectID == projID }),
           !budget.lines.isEmpty {
            let projectCodes = budget.lines.map {
                CompanyCostCode(code: $0.costCode,
                                description: $0.description,
                                category: .labour,   // display only — category irrelevant here
                                isEnabled: true,
                                isCustom: false,
                                sortOrder: $0.sortOrder)
            }
            return projectCodes
        }
        return enabledCostCodes.sorted { $0.sortOrder < $1.sortOrder }
    }

    func upsertCostCode(_ code: CompanyCostCode) {
        if let idx = companyCostCodes.firstIndex(where: { $0.id == code.id }) {
            companyCostCodes[idx] = code
        } else {
            companyCostCodes.append(code)
        }
        Task { await SyncEngine.shared.pushCostCode(code) }
    }

    func deleteCostCode(_ code: CompanyCostCode) {
        companyCostCodes.removeAll { $0.id == code.id }
        Task { await SyncEngine.shared.deleteCostCode(code) }
    }

    func toggleCostCode(_ code: CompanyCostCode) {
        var updated = code
        updated.isEnabled.toggle()
        updated.syncStatus = .pending
        upsertCostCode(updated)
    }

    func toggleCategory(_ category: CostCodeCategory, enabled: Bool) {
        for i in companyCostCodes.indices where companyCostCodes[i].category == category {
            companyCostCodes[i].isEnabled  = enabled
            companyCostCodes[i].syncStatus = .pending
        }
        let updated = companyCostCodes.filter { $0.category == category }
        Task {
            for code in updated { await SyncEngine.shared.pushCostCode(code) }
        }
    }

    /// Seeds master list into companyCostCodes if the company has none yet.
    func seedCostCodesIfNeeded() {
        guard companyCostCodes.isEmpty, let companyID = currentCompanyID else { return }
        companyCostCodes = CompanyCostCode.masterList.map {
            var c = $0; c.companyID = companyID; return c
        }
        Task {
            for code in companyCostCodes { await SyncEngine.shared.pushCostCode(code) }
        }
    }
}

// MARK: - Master List

extension CompanyCostCode {

    static let masterList: [CompanyCostCode] = {
        var list: [CompanyCostCode] = []
        var order = 0

        func add(_ code: String, _ desc: String, _ cat: CostCodeCategory) {
            list.append(CompanyCostCode(code: code, description: desc,
                                        category: cat, isEnabled: true,
                                        isCustom: false, sortOrder: order))
            order += 1
        }

        // Labour
        add("LAB-001", "Regular Labour",           .labour)
        add("LAB-002", "Overtime Labour",           .labour)
        add("LAB-003", "Double Time",               .labour)
        add("LAB-004", "Foreman / Lead Hand",       .labour)
        add("LAB-005", "Project Management",        .labour)
        add("LAB-006", "Standby / Waiting",         .labour)
        add("LAB-007", "Rework",                    .labour)

        // Insulation
        add("INS-001", "Mechanical Insulation",         .insulation)
        add("INS-002", "Pipe Insulation",               .insulation)
        add("INS-003", "Vessel / Equipment Insulation", .insulation)
        add("INS-004", "Duct Insulation",               .insulation)
        add("INS-005", "Cold / Cryogenic Insulation",   .insulation)
        add("INS-006", "Removable Blankets",             .insulation)
        add("INS-007", "Insulation Removal",             .insulation)

        // Scaffolding
        add("SCF-001", "Scaffold Erect",          .scaffolding)
        add("SCF-002", "Scaffold Dismantle",      .scaffolding)
        add("SCF-003", "Scaffold Modify / Alter", .scaffolding)
        add("SCF-004", "Scaffold Inspection",     .scaffolding)

        // Containment
        add("CON-001", "Containment Erect",       .containment)
        add("CON-002", "Containment Dismantle",   .containment)
        add("CON-003", "Containment Modify / Alter", .containment)
        add("CON-004", "Containment Inspection",  .containment)
        add("CON-005", "Containment Maintenance", .containment)
        add("CON-006", "Decontamination",         .containment)
        add("CON-007", "Hazmat Work",             .containment)
        add("CON-008", "Asbestos Abatement",      .containment)
        add("CON-009", "Firewatch",               .containment)

        // Drywall
        add("DRY-001", "Steel Framing",       .drywall)
        add("DRY-002", "Drywall Install",     .drywall)
        add("DRY-003", "Taping & Mudding",    .drywall)
        add("DRY-004", "Finishing / Sanding", .drywall)

        // Equipment
        add("EQP-001", "Equipment Operation",         .equipment)
        add("EQP-002", "Equipment Maintenance",       .equipment)
        add("EQP-003", "Equipment Transport",         .equipment)
        add("EQP-004", "Tool Usage / Small Tools",    .equipment)
        add("EQP-005", "Equipment Rental (3rd Party)",.equipment)

        // Safety & Training
        add("SAF-001", "Toolbox Talk / Safety Meeting", .safety)
        add("SAF-002", "Site Orientation / Induction",  .safety)
        add("SAF-003", "Incident Investigation",        .safety)
        add("SAF-004", "Safety Inspection",             .safety)
        add("SAF-005", "First Aid",                     .safety)
        add("TRN-001", "Training / Certification",      .safety)

        // Travel & Mobilization
        add("TRV-001", "Travel Time",        .travel)
        add("MOB-001", "Mobilization",       .travel)
        add("MOB-002", "Demobilization",     .travel)
        add("CAM-001", "Camp / Remote Site", .travel)
        add("PER-001", "Per Diem",           .travel)

        // Overhead
        add("OFC-001", "Office",             .overhead)
        add("SHP-001", "Shop Fabrication",   .overhead)
        add("YRD-001", "Yard",               .overhead)
        add("ADM-001", "Admin / General",    .overhead)
        add("EST-001", "Estimating",         .overhead)
        add("PRC-001", "Procurement",        .overhead)
        add("QC-001",  "Quality Control",    .overhead)

        // Delays
        add("DLY-001", "Weather Delay",       .delays)
        add("DLY-002", "Client-Caused Delay", .delays)
        add("DLY-003", "Permit / Access Delay",.delays)

        return list
    }()
}
