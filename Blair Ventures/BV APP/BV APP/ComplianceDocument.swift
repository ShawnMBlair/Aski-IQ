// ComplianceDocument.swift
// Aski IQ — Insurance certificates + bonds tracked against contracts.
//
// WHY ONE TABLE FOR BOTH
// Insurance certs and surety bonds have nearly identical metadata —
// carrier, policy/bond number, coverage limit, effective and expiry
// dates. Splitting into two tables would duplicate every helper and
// every UI list. Instead a `kind` discriminator (`insurance | bond`)
// lets us share schema, sync, and most UI while still letting the
// detail screen branch on type.
//
// LIEN WAIVERS — DEFERRED
// Lien waivers go in their own table in Phase 2B because they're
// transactional (one per progress payment, conditional vs unconditional,
// keyed to invoice IDs) rather than a static "we hold this cert"
// record. Different lifecycle entirely.

import Foundation

// MARK: - Kind discriminator

enum ComplianceKind: String, Codable, CaseIterable, Identifiable {
    case insurance
    case bond
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

// MARK: - Document type taxonomy

/// Every kind of compliance document the iOS UI knows about. Stable
/// raw values match the DB CHECK constraint. Adding a new type means
/// updating this enum AND the DB CHECK in the migration.
enum ComplianceDocumentType: String, Codable, CaseIterable, Identifiable {
    // Insurance
    case generalLiability        = "general_liability"
    case workersComp             = "workers_comp"
    case autoLiability           = "auto_liability"
    case umbrella
    case professionalLiability   = "professional_liability"
    case pollutionLiability      = "pollution_liability"
    case buildersRisk            = "builders_risk"
    case cyberLiability          = "cyber_liability"
    case directorsOfficers       = "directors_officers"

    // Bonds
    case performanceBond         = "performance_bond"
    case paymentBond             = "payment_bond"
    case laborMaterialBond       = "labor_material_bond"
    case bidBond                 = "bid_bond"
    case maintenanceBond         = "maintenance_bond"
    case licenseBond             = "license_bond"

    case other

    var id: String { rawValue }

    /// Which top-level bucket this type belongs to. Drives form
    /// segmentation (Insurance picker only shows insurance types).
    var kind: ComplianceKind {
        switch self {
        case .performanceBond, .paymentBond, .laborMaterialBond,
             .bidBond, .maintenanceBond, .licenseBond:
            return .bond
        default:
            return .insurance
        }
    }

    var displayName: String {
        switch self {
        case .generalLiability:      return "General Liability (CGL)"
        case .workersComp:           return "Workers' Compensation"
        case .autoLiability:         return "Auto Liability"
        case .umbrella:              return "Umbrella / Excess"
        case .professionalLiability: return "Professional Liability (E&O)"
        case .pollutionLiability:    return "Pollution Liability"
        case .buildersRisk:          return "Builders Risk"
        case .cyberLiability:        return "Cyber Liability"
        case .directorsOfficers:     return "Directors & Officers"
        case .performanceBond:       return "Performance Bond"
        case .paymentBond:           return "Payment Bond"
        case .laborMaterialBond:     return "Labor & Material Bond"
        case .bidBond:               return "Bid Bond"
        case .maintenanceBond:       return "Maintenance Bond"
        case .licenseBond:           return "License Bond"
        case .other:                 return "Other"
        }
    }

    var icon: String {
        switch kind {
        case .insurance: return "shield.lefthalf.filled"
        case .bond:      return "lock.shield"
        }
    }

    /// Plain-English explanation used in the picker subtitle so a new
    /// PM sees "what is workers' comp?" without leaving the form.
    var helperText: String {
        switch self {
        case .generalLiability:      return "Covers third-party bodily injury or property damage from your operations."
        case .workersComp:           return "Pays employee medical + lost wages for on-the-job injuries. Required by most states for any payroll."
        case .autoLiability:         return "Covers accidents involving company vehicles. Specs often require $1M minimum on commercial vehicles."
        case .umbrella:              return "Excess layer that sits above your other policies. Picks up after CGL/Auto/WC limits exhaust."
        case .professionalLiability: return "Covers errors in design, advice, or specifications. Required for design-build, EPC, or any consulting work."
        case .pollutionLiability:    return "Covers spills + remediation. Required on any project with environmental risk (fuel storage, asbestos, etc.)."
        case .buildersRisk:          return "Property insurance covering the project itself during construction. Usually carried by the owner/GC."
        case .cyberLiability:        return "Covers data-breach response. Increasingly common on contracts that handle owner data."
        case .directorsOfficers:     return "Covers exec / board liability for management decisions. Rarely required on field-ops contracts."
        case .performanceBond:       return "Surety guarantees the work will be performed. If you default, the surety either finishes or pays the face value."
        case .paymentBond:           return "Surety guarantees subs + suppliers get paid. Common pair with performance bond on public work."
        case .laborMaterialBond:     return "Older term — same intent as a payment bond. Federal Miller Act requires these on most federal projects."
        case .bidBond:               return "Backs your bid — if you win and don't sign the contract, the bid bond is forfeit (typically 5-10% of bid)."
        case .maintenanceBond:       return "Guarantees you'll fix defects during the warranty period. Often 12-24 months post-substantial completion."
        case .licenseBond:           return "Statutory bond required by some jurisdictions to hold a contractor's license."
        case .other:                 return "Other compliance document."
        }
    }
}

// MARK: - Compliance Document model

struct ComplianceDocument: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var companyID: UUID? = nil
    var contractID: UUID? = nil

    var kind: ComplianceKind
    var documentType: ComplianceDocumentType

    // Identity
    var title: String
    var carrier: String?
    var policyNumber: String?
    var namedInsured: String?

    // Money
    var coverageLimit: Decimal?
    var aggregateLimit: Decimal?
    var deductible: Decimal?
    var currency: String = "USD"

    // Dates
    var effectiveDate: Date?
    /// Optional. For "we hold this cert" rows it's required (the whole
    /// point of the row is tracking renewal). For requirement-only
    /// rows (`isRequirementOnly = true`) it's nil because the actual
    /// cert hasn't been issued yet. Auto-expiry milestone synthesis
    /// only fires when this is non-nil.
    var expiryDate: Date?

    // Document
    /// Storage path inside the `contracts` bucket: `<companyID>/compliance/<docID>.<ext>`.
    /// Reads go through a signed URL since the bucket is private.
    var documentURL: String?
    var documentFilename: String?

    /// True when this row records a contract REQUIREMENT (e.g. "sub
    /// must carry $1M CGL") rather than an actual held certificate.
    /// Auto-set by AI Review when extracting requirements from clause
    /// text. UI renders these with an orange "REQUIRED" badge and no
    /// expiry countdown. When the user later receives the actual
    /// cert, they edit the row, fill in carrier/policy/expiry, and
    /// flip this flag to false.
    var isRequirementOnly: Bool = false

    // Bookkeeping
    var notes: String?
    var uploadedBy: UUID?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var isDeleted: Bool = false

    // MARK: - Derived

    /// Days until expiry. Returns nil for requirement-only rows
    /// (no actual cert → no expiry to count down to). Negative when
    /// already expired for held-cert rows.
    var daysUntilExpiry: Int? {
        guard let expiry = expiryDate else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day],
                                  from: cal.startOfDay(for: Date()),
                                  to:   cal.startOfDay(for: expiry)).day
    }

    /// `true` when expiry is within 30 days (or already past). Always
    /// false for requirement-only rows (no expiry to compare against).
    var isExpiringSoon: Bool {
        guard let d = daysUntilExpiry else { return false }
        return d <= 30
    }

    /// `true` only when already past the expiry date. Always false
    /// for requirement-only rows.
    var isExpired: Bool {
        guard let d = daysUntilExpiry else { return false }
        return d < 0
    }
}
