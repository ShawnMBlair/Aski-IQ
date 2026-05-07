import Foundation
import SwiftUI

// MARK: - Enums

enum ProjectType: String, CaseIterable, Codable {
    case shrinkWrap = "Shrink Wrap"
    case containmentEnclosure = "Containment Enclosure"
    case scaffoldWrap = "Scaffold Wrap"
    case temporaryHoarding = "Temporary Hoarding"
    case weatherProtection = "Weather Protection"
    case custom = "Custom Project"

    var icon: String {
        switch self {
        case .shrinkWrap: return "wind"
        case .containmentEnclosure: return "square.dashed"
        case .scaffoldWrap: return "building.columns"
        case .temporaryHoarding: return "rectangle.split.3x1"
        case .weatherProtection: return "cloud.rain"
        case .custom: return "wrench.and.screwdriver"
        }
    }
}

enum EstimateStatus: String, CaseIterable, Codable {
    case draft = "Draft"
    case review = "In Review"
    case sent = "Sent"
    case approved = "Approved"
    case lost = "Lost"
    case archived = "Archived"
}

enum MaterialCategory: String, CaseIterable, Codable {
    case shrinkWrap = "Shrink Wrap"
    case poly = "Poly / Film"
    case framing = "Framing"
    case hardware = "Hardware"
    case tape = "Tape & Sealants"
    case access = "Access & Doors"
    case protection = "Floor Protection"
    case equipment = "Equipment"
    case consumables = "Consumables"
    case other = "Other"
}

enum UnitType: String, CaseIterable, Codable {
    case sqft = "sq ft"
    case lnft = "ln ft"
    case each = "each"
    case roll = "roll"
    case bag = "bag"
    case hour = "hour"
    case day = "day"
    case week = "week"
    case gallon = "gallon"
    case lb = "lb"
}

enum SafetyFormType: String, CaseIterable, Codable {
    case toolboxTalk = "Toolbox Talk"
    case hazardAssessment = "Hazard Assessment"
    case incidentReport = "Incident Report"
    case inspectionForm = "Inspection"
    case jsa = "Job Safety Analysis"

    var icon: String {
        switch self {
        case .toolboxTalk: return "person.2.fill"
        case .hazardAssessment: return "exclamationmark.triangle.fill"
        case .incidentReport: return "cross.fill"
        case .inspectionForm: return "checkmark.shield.fill"
        case .jsa: return "list.clipboard.fill"
        }
    }

    var color: Color {
        switch self {
        case .toolboxTalk: return .blue
        case .hazardAssessment: return .orange
        case .incidentReport: return .red
        case .inspectionForm: return .green
        case .jsa: return .purple
        }
    }
}

enum SafetyStatus: String, CaseIterable, Codable {
    case open = "Open"
    case inProgress = "In Progress"
    case completed = "Completed"
    case requiresAction = "Requires Action"

    var color: Color {
        switch self {
        case .open: return .gray
        case .inProgress: return .orange
        case .completed: return .green
        case .requiresAction: return .red
        }
    }
}

enum ProjectStatus: String, CaseIterable, Codable {
    case active = "Active"
    case pending = "Pending"
    case completed = "Completed"
    case onHold = "On Hold"

    var color: Color {
        switch self {
        case .active: return .green
        case .pending: return .orange
        case .completed: return .blue
        case .onHold: return .red
        }
    }
}

// MARK: - Project

struct Project: Identifiable, Codable {
    var id = UUID()
    var name: String
    var client: String
    var location: String
    var status: ProjectStatus
    var startDate: String
    var endDate: String
    var notes: String
}

// MARK: - Safety Models

struct SafetyForm: Identifiable, Codable {
    var id = UUID()
    var type: SafetyFormType
    var title: String
    var site: String
    var assignedTo: String
    var date: Date
    var status: SafetyStatus
    var notes: String
    var actions: [SafetyAction] = []
    var signatures: [String] = []
}

struct SafetyAction: Identifiable, Codable {
    var id = UUID()
    var description: String
    var assignedTo: String
    var dueDate: Date
    var completed: Bool = false
}

struct WorkerOrientation: Identifiable, Codable {
    var id = UUID()
    var workerName: String
    var company: String
    var site: String
    var date: Date
    var completed: Bool = false
    var modules: [OrientationModule] = []
}

struct OrientationModule: Identifiable, Codable {
    var id = UUID()
    var title: String
    var completed: Bool = false
}

struct SafetyDocument: Identifiable, Codable {
    var id = UUID()
    var title: String
    var category: String
    var dateAdded: Date
    var notes: String
}

struct SafetyCertificate: Identifiable, Codable {
    var id = UUID()
    var workerName: String
    var certificateType: String
    var issueDate: Date
    var expiryDate: Date
    var company: String

    var isExpired: Bool { expiryDate < Date() }
    var isExpiringSoon: Bool {
        !isExpired && expiryDate < Date().addingTimeInterval(30 * 24 * 3600)
    }
}

// MARK: - Company Settings

struct CompanySettings: Codable {
    var companyName: String = "Blair Ventures"
    var contactName: String = "Shawn Blair"
    var phone: String = ""
    var email: String = ""
    var address: String = ""
    var defaultOverhead: Double = 15.0
    var defaultProfit: Double = 20.0
    var defaultContingency: Double = 5.0
    var defaultWaste: Double = 10.0
    var taxRate: Double = 5.0
    var applyTax: Bool = false
    var estimatePrefix: String = "BV"
    var nextEstimateNumber: Int = 1001
    var currency: String = "CAD"
}

// MARK: - Material & Equipment

struct MaterialItem: Identifiable, Codable {
    var id = UUID()
    var name: String
    var category: MaterialCategory
    var unit: UnitType
    var unitCost: Double
    var coverageRate: Double
    var wasteFactor: Double
    var supplier: String = ""
    var sku: String = ""
    var notes: String = ""
    var isActive: Bool = true
}

struct EquipmentItem: Identifiable, Codable {
    var id = UUID()
    var name: String
    var dailyRate: Double
    var weeklyRate: Double
    var monthlyRate: Double
    var minimumCharge: Double = 0
    var mobilizationCharge: Double = 0
    var notes: String = ""
    var isActive: Bool = true

    func bestRate(forDays days: Int) -> Double {
        guard days > 0 else { return 0 }
        let daily = dailyRate * Double(days)
        let weeks = days / 7
        let rem = days % 7
        let weekly = weeklyRate * Double(weeks) + dailyRate * Double(rem)
        if days >= 28, monthlyRate < weekly, monthlyRate < daily { return monthlyRate }
        if weekly < daily, weeks > 0 { return weekly }
        return daily
    }
}

// MARK: - Labor Config

struct LaborConfig: Codable {
    var foremanRate: Double = 65.0
    var laborRate: Double = 45.0
    var overtimeMultiplier: Double = 1.5
    var shiftHours: Double = 10.0
    var crewSize: Int = 3
    var travelFactor: Double = 1.0
    var nightShiftFactor: Double = 1.0
    var weatherFactor: Double = 1.0
    var complexityFactor: Double = 1.0
    var productivityFactor: Double = 1.0
    var shrinkWrapRatePerSqFt: Double = 0.015
    var containmentFrameRatePerLnFt: Double = 0.08
    var polyInstallRatePerSqFt: Double = 0.012
    var tearDownFactor: Double = 0.35
    var mobDemobHours: Double = 4.0
}

// MARK: - Project Dimensions
// Computed properties are excluded from Codable via CodingKeys.

struct ProjectDimensions: Codable {
    var length: Double = 0
    var width: Double = 0
    var height: Double = 0
    var numberOfLevels: Int = 1
    var numberOfSides: Int = 4
    var roofArea: Double = 0
    var openingsCount: Int = 0
    var accessPoints: Int = 1
    var complexPenetrations: Int = 0
    var irregularGeometryFactor: Double = 1.0
    var indoorOutdoor: String = "Outdoor"
    var windExposure: String = "Moderate"
    var duration: Int = 5

    // Computed — not stored, not encoded
    var wallArea: Double { (length * height * 2) + (width * height * 2) }
    var floorArea: Double { length * width }
    var totalSurfaceArea: Double { wallArea + floorArea + roofArea }
    var perimeterLength: Double { (length + width) * 2 }
    var cubicVolume: Double { length * width * height }

    enum CodingKeys: String, CodingKey {
        case length, width, height
        case numberOfLevels, numberOfSides
        case roofArea, openingsCount, accessPoints
        case complexPenetrations, irregularGeometryFactor
        case indoorOutdoor, windExposure, duration
    }
}

// MARK: - Estimate Line Item
// `total` is computed, so it is excluded via CodingKeys.

struct EstimateLineItem: Identifiable, Codable {
    var id = UUID()
    var category: String
    var description: String
    var quantity: Double
    var unit: String
    var unitCost: Double
    var notes: String = ""
    var isIncluded: Bool = true

    // Computed — not stored, not encoded
    var total: Double { quantity * unitCost }

    enum CodingKeys: String, CodingKey {
        case id, category, description
        case quantity, unit, unitCost
        case notes, isIncluded
    }
}

// MARK: - Pricing Config

struct PricingConfig: Codable {
    var overheadPercent: Double = 15.0
    var profitPercent: Double = 20.0
    var contingencyPercent: Double = 5.0
    var wastePercent: Double = 10.0
    var rushFactor: Double = 1.0
    var remoteLocationFactor: Double = 1.0
    var minimumCharge: Double = 0
    var applyTax: Bool = false
    var taxPercent: Double = 5.0
    var roundUpToNearest: Double = 100.0
}

// MARK: - Calculation Result

struct CalculationResult: Codable {
    var materialSubtotal: Double = 0
    var laborSubtotal: Double = 0
    var equipmentSubtotal: Double = 0
    var subcontractSubtotal: Double = 0
    var deliverySubtotal: Double = 0
    var miscSubtotal: Double = 0
    var wasteAllowance: Double = 0
    var contingency: Double = 0
    var overhead: Double = 0
    var profit: Double = 0
    var tax: Double = 0
    var totalCost: Double = 0
    var totalSell: Double = 0
    var grossMargin: Double = 0
    var estimatedLaborHours: Double = 0
    var crewDays: Double = 0
    var lineItems: [EstimateLineItem] = []
}

// MARK: - Estimate

struct Estimate: Identifiable, Codable {
    var id = UUID()
    var estimateNumber: String = ""
    var projectName: String = ""
    var clientName: String = ""
    var siteLocation: String = ""
    var estimatorName: String = "Shawn Blair"
    var date: Date = Date()
    var revisionNumber: Int = 0
    var projectNotes: String = ""
    var scopeSummary: String = ""
    var status: EstimateStatus = .draft
    var projectType: ProjectType = .shrinkWrap
    var dimensions: ProjectDimensions = ProjectDimensions()
    var laborConfig: LaborConfig = LaborConfig()
    var pricingConfig: PricingConfig = PricingConfig()
    var calculationResult: CalculationResult = CalculationResult()
    var customLineItems: [EstimateLineItem] = []
    var exclusions: [String] = []
    var createdDate: Date = Date()
    var modifiedDate: Date = Date()
    var company: String = "Blair Ventures"
}

// MARK: - Estimate Template

struct EstimateTemplate: Identifiable, Codable {
    var id = UUID()
    var name: String
    var projectType: ProjectType
    var description: String
    var defaultDimensions: ProjectDimensions = ProjectDimensions()
    var defaultLaborConfig: LaborConfig = LaborConfig()
    var defaultPricingConfig: PricingConfig = PricingConfig()
    var notes: String = ""
}
