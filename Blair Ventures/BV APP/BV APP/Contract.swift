// Contract.swift
// Aski IQ — Contract management module (Phase 1).
//
// WHY THIS EXISTS
// Contracts are the highest-leverage record in field-ops: they govern
// every money flow from owner billing through sub payment to material
// purchases. Weak contract management is the #1 reason mid-sized
// trades shops bleed cash they could have kept. This module gives:
//
//   * A typed lifecycle: draft → review → sent → active → expiring →
//     completed/terminated/disputed
//   * AI-extractable clauses with plain-English summaries + risk flags
//   * Milestones that surface on the Schedule tab so they actually get
//     noticed (insurance renewal, retainage release, payment due)
//   * A built-in glossary so new PMs can read a contract without
//     handing it to legal first
//
// MODEL SHAPE
//   Contract            — the parent record, one row per executed
//                         agreement
//   ContractClause      — extracted clauses (1:N off Contract). Wiped
//                         and regenerated on each AI re-review
//   ContractMilestone   — calendar pins for payment-due, expiry,
//                         renewal, insurance, retainage release etc.

import Foundation

// MARK: - Contract Type

/// The major contract families a field-ops shop deals with day-to-day.
/// Stored as the snake_case raw value to match the DB CHECK constraint.
enum ContractType: String, Codable, CaseIterable, Identifiable {
    case ownerPrime       = "owner_prime"
    case subcontractor
    case materialPurchase = "material_purchase"
    case nda
    case msa
    case sow
    case jointVenture     = "joint_venture"
    case consulting
    case other

    var id: String { rawValue }

    /// Display label for filter pills and headers.
    var displayName: String {
        switch self {
        case .ownerPrime:       return "Owner / Prime"
        case .subcontractor:    return "Subcontractor"
        case .materialPurchase: return "Material Purchase"
        case .nda:              return "NDA"
        case .msa:              return "MSA"
        case .sow:              return "SOW"
        case .jointVenture:     return "Joint Venture"
        case .consulting:       return "Consulting"
        case .other:            return "Other"
        }
    }

    /// SF Symbol for list rows + filter pills.
    var icon: String {
        switch self {
        case .ownerPrime:       return "building.columns.fill"
        case .subcontractor:    return "person.2.badge.gearshape.fill"
        case .materialPurchase: return "shippingbox.fill"
        case .nda:              return "lock.shield.fill"
        case .msa:              return "doc.text.fill"
        case .sow:              return "list.bullet.rectangle.fill"
        case .jointVenture:     return "person.3.fill"
        case .consulting:       return "person.crop.rectangle.fill"
        case .other:            return "doc.fill"
        }
    }
}

// MARK: - Contract Status (lifecycle)

enum ContractStatus: String, Codable, CaseIterable, Identifiable {
    case draft
    case underReview      = "under_review"
    case sent
    case pendingSignature = "pending_signature"
    case active
    case expiring                 // computed: expiry_date < 30 days out
    case completed
    case terminated
    case disputed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .draft:            return "Draft"
        case .underReview:      return "Under Review"
        case .sent:             return "Sent"
        case .pendingSignature: return "Pending Signature"
        case .active:           return "Active"
        case .expiring:         return "Expiring Soon"
        case .completed:        return "Completed"
        case .terminated:       return "Terminated"
        case .disputed:         return "Disputed"
        }
    }

    /// True for statuses that represent a live, in-force contract.
    var isLive: Bool {
        switch self {
        case .active, .expiring, .pendingSignature, .sent: return true
        default: return false
        }
    }
}

// MARK: - Counterparty Type

enum CounterpartyType: String, Codable, CaseIterable, Identifiable {
    case client
    case subcontractor
    case supplier
    case partner
    case `internal` = "internal"
    case other

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .client:        return "Client / Owner"
        case .subcontractor: return "Subcontractor"
        case .supplier:      return "Supplier"
        case .partner:       return "Partner"
        case .internal:      return "Internal"
        case .other:         return "Other"
        }
    }
}

// MARK: - Risk

/// Overall risk score on the contract + per-clause risk on each clause.
/// Set by the AI review service, manually overridable.
enum RiskLevel: String, Codable, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case critical

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

// MARK: - AI Review Status

enum ContractAIReviewStatus: String, Codable, CaseIterable {
    case notReviewed = "not_reviewed"
    case reviewing
    case reviewed
    case failed
}

// MARK: - Contract

struct Contract: BaseModel {
    static func == (lhs: Contract, rhs: Contract) -> Bool { lhs.id == rhs.id }

    var id: UUID = UUID()
    var externalID: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()

    /// Multi-tenant scope. Stamped by `upsertContract` from
    /// `currentCompanyID`; required NOT NULL server-side.
    var companyID: UUID? = nil

    // Identity
    /// Human reference like "C-2026-001". Optional — auto-generated
    /// when blank by AppStore.nextContractNumber().
    var contractNumber: String?
    var title: String
    var contractType: ContractType
    var status: ContractStatus = .draft

    // Counterparty
    var counterpartyType: CounterpartyType?
    /// Soft FK — clients/subs/suppliers all share this column. The
    /// counterpartyType discriminator tells you which table to look in.
    var counterpartyID: UUID?
    var counterpartyName: String
    var counterpartyEmail: String?

    // Linkage
    var projectID: UUID?
    /// CRM linkage. `contracts.opportunity_id` is NOT NULL on prod
    /// (set by the auto-link trigger via project_id or quote_id).
    /// Pre-fix this field was missing from the iOS struct — every
    /// push silently failed the NOT NULL constraint. Same bug
    /// class as MR + PO + Invoice + ChangeOrder.
    var opportunityID: UUID? = nil
    /// For child SOWs sitting under an MSA — points at the parent MSA.
    var parentContractID: UUID?
    /// Optional link back to the quote that became this contract
    /// (populated by the auto-create-from-quote-acceptance hook).
    var quoteID: UUID?
    /// For version chains — the prior contract this one replaces.
    var supersedesContractID: UUID?

    // Financial
    var contractValue: Decimal?
    var currency: String = "USD"
    var retainagePercent: Decimal?

    // Dates
    var effectiveDate: Date?
    var expiryDate: Date?
    var renewalDate: Date?
    var executedDate: Date?
    var terminationDate: Date?

    // Versioning
    var version: Int = 1

    // Denormalized key terms (queryable without joining clauses)
    var paymentTerms: String?
    var warrantyPeriodDays: Int?
    var insuranceRequired: Bool = false
    var bondRequired: Bool = false
    var governingLaw: String?
    var disputeResolution: String?

    // Risk (overall)
    var riskScore: RiskLevel?
    var riskSummary: String?
    var aiReviewStatus: ContractAIReviewStatus = .notReviewed
    var aiReviewedAt: Date?

    // Document
    var primaryDocumentURL: String?
    var primaryDocumentName: String?

    // Notes + ownership
    var notes: String?
    var assignedReviewerID: UUID?
    var reviewedAt: Date?
    var approvedAt: Date?
    var approvedByID: UUID?

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
    var isDeleted: Bool = false
    var deletedAt: Date?
    var deletedBy: String?

    // MARK: - Convenience init (UI quick-create)

    init(
        title: String,
        contractType: ContractType,
        counterpartyName: String
    ) {
        self.title = title
        self.contractType = contractType
        self.counterpartyName = counterpartyName
    }

    // MARK: - Derived

    /// Days until expiry (negative if past). Used by the "Expiring Soon"
    /// pill and the renewal-reminder logic.
    var daysUntilExpiry: Int? {
        guard let expiry = expiryDate else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return cal.dateComponents([.day], from: today, to: cal.startOfDay(for: expiry)).day
    }

    /// True when the contract is active AND expiry is within 30 days.
    /// Drives the "Expiring Soon" filter pill on the list view.
    var isExpiringSoon: Bool {
        guard status.isLive, let days = daysUntilExpiry else { return false }
        return days >= 0 && days <= 30
    }

    /// Effective status for UI — promotes `.active` to `.expiring` when
    /// within 30 days of expiry, so the badge color flips automatically
    /// without us having to update every row on a cron.
    var effectiveStatus: ContractStatus {
        if status == .active && isExpiringSoon { return .expiring }
        return status
    }
}

// MARK: - Clause Kind

/// Stable taxonomy of clauses we extract / display. The DB CHECK
/// constraint mirrors this. New kinds require a coordinated DB +
/// Swift change.
enum ClauseKind: String, Codable, CaseIterable, Identifiable {
    case paymentTerms          = "payment_terms"
    case indemnity
    case disputeResolution     = "dispute_resolution"
    case warranty
    case termination
    case changeOrders          = "change_orders"
    case scope
    case insurance
    case bond
    case liquidatedDamages     = "liquidated_damages"
    case governingLaw          = "governing_law"
    case confidentiality
    case intellectualProperty  = "intellectual_property"
    case limitationOfLiability = "limitation_of_liability"
    case forceMajeure          = "force_majeure"
    case payWhenPaid           = "pay_when_paid"
    case flowDown              = "flow_down"
    case lienWaiver            = "lien_waiver"
    case retainage
    case auditRights           = "audit_rights"
    case assignment
    case notice
    case other

    var id: String { rawValue }

    /// Pretty title for the clause card header. Differs from the raw
    /// value because we want "Pay-When-Paid" not "Pay When Paid".
    var displayName: String {
        switch self {
        case .paymentTerms:          return "Payment Terms"
        case .indemnity:             return "Indemnity"
        case .disputeResolution:     return "Dispute Resolution"
        case .warranty:              return "Warranty"
        case .termination:           return "Termination"
        case .changeOrders:          return "Change Orders"
        case .scope:                 return "Scope of Work"
        case .insurance:             return "Insurance"
        case .bond:                  return "Bond"
        case .liquidatedDamages:     return "Liquidated Damages"
        case .governingLaw:          return "Governing Law"
        case .confidentiality:       return "Confidentiality"
        case .intellectualProperty:  return "Intellectual Property"
        case .limitationOfLiability: return "Limitation of Liability"
        case .forceMajeure:          return "Force Majeure"
        case .payWhenPaid:           return "Pay-When-Paid"
        case .flowDown:              return "Flow-Down"
        case .lienWaiver:            return "Lien Waiver"
        case .retainage:             return "Retainage"
        case .auditRights:           return "Audit Rights"
        case .assignment:            return "Assignment"
        case .notice:                return "Notice"
        case .other:                 return "Other"
        }
    }
}

// MARK: - Contract Clause

struct ContractClause: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var companyID: UUID? = nil
    var contractID: UUID
    var clauseKind: ClauseKind
    var title: String?
    /// Verbatim quote from the contract — useful for reviewing the
    /// exact language without paging through the PDF.
    var originalText: String?
    /// AI plain-English summary in 2-3 sentences.
    var plainEnglish: String?
    var riskLevel: RiskLevel?
    var riskExplanation: String?
    var pageReference: Int?
    var displayOrder: Int = 0
    /// 'ai' for clauses extracted by the proxy, 'manual' for user-added
    /// clauses (e.g. PM types in a custom term they negotiated).
    var source: String = "ai"
    var createdAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var isDeleted: Bool = false
}

// MARK: - Milestone Type / Status

enum MilestoneType: String, Codable, CaseIterable, Identifiable {
    case paymentDue          = "payment_due"
    case deliverable
    case renewal
    case expiryWarning       = "expiry_warning"
    case insuranceRenewal    = "insurance_renewal"
    case bondExpiry          = "bond_expiry"
    case retainageRelease    = "retainage_release"
    case milestoneInspection = "milestone_inspection"
    case lienWaiverDue       = "lien_waiver_due"
    case other

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .paymentDue:          return "Payment Due"
        case .deliverable:         return "Deliverable"
        case .renewal:             return "Renewal"
        case .expiryWarning:       return "Expiry Warning"
        case .insuranceRenewal:    return "Insurance Renewal"
        case .bondExpiry:          return "Bond Expiry"
        case .retainageRelease:    return "Retainage Release"
        case .milestoneInspection: return "Milestone Inspection"
        case .lienWaiverDue:       return "Lien Waiver Due"
        case .other:               return "Other"
        }
    }

    var icon: String {
        switch self {
        case .paymentDue:          return "dollarsign.circle.fill"
        case .deliverable:         return "checkmark.seal.fill"
        case .renewal:             return "arrow.clockwise.circle.fill"
        case .expiryWarning:       return "calendar.badge.exclamationmark"
        case .insuranceRenewal:    return "shield.lefthalf.filled"
        case .bondExpiry:          return "lock.shield"
        case .retainageRelease:    return "lock.open.fill"
        case .milestoneInspection: return "binoculars.fill"
        case .lienWaiverDue:       return "doc.badge.gearshape.fill"
        case .other:               return "calendar.badge.clock"
        }
    }
}

enum MilestoneStatus: String, Codable, CaseIterable {
    case upcoming
    case due
    case overdue
    case completed
    case waived

    var displayName: String { rawValue.capitalized }
}

// MARK: - Contract Milestone

struct ContractMilestone: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var companyID: UUID? = nil
    var contractID: UUID
    var title: String
    var description: String?
    var milestoneDate: Date
    var milestoneType: MilestoneType
    var amountDue: Decimal?
    var status: MilestoneStatus = .upcoming
    var completedAt: Date?
    var completedByID: UUID?
    var notes: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var isDeleted: Bool = false

    /// Days until / since the milestone date. Negative = overdue.
    var daysUntil: Int? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return cal.dateComponents([.day], from: today,
                                   to: cal.startOfDay(for: milestoneDate)).day
    }

    /// Computed effective status — flips to `.overdue` automatically
    /// when the date has passed and the row is still `.upcoming` /
    /// `.due`. Lets us avoid a cron job to update statuses.
    var effectiveStatus: MilestoneStatus {
        guard status == .upcoming || status == .due else { return status }
        let days = daysUntil ?? 0
        if days < 0 { return .overdue }
        if days == 0 { return .due }
        return .upcoming
    }
}

// MARK: - Sample-data tracking
extension Contract: SampleDataTrackable {}
