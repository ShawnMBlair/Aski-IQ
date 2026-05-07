// Estimate.swift
// AskiCommand – Estimating / Bid Module
// REPLACES existing Estimate.swift
// Key change: clientID replaces projectID — estimates now start the pipeline

import Foundation

// MARK: - Opportunity Type
// How the work came in

enum OpportunityType: String, Codable, CaseIterable {
    case rfq         = "rfq"          // Client sent a formal RFQ or ITB
    case negotiated  = "negotiated"   // Directly negotiated with client
    case renewal     = "renewal"      // Renewal of existing contract
    case unsolicited = "unsolicited"  // We proactively quoted

    var displayName: String {
        switch self {
        case .rfq:         return "RFQ / ITB"
        case .negotiated:  return "Negotiated"
        case .renewal:     return "Renewal"
        case .unsolicited: return "Unsolicited Quote"
        }
    }

    var icon: String {
        switch self {
        case .rfq:         return "doc.text"
        case .negotiated:  return "person.2"
        case .renewal:     return "arrow.clockwise"
        case .unsolicited: return "lightbulb"
        }
    }
}

// MARK: - Pricing Type

enum PricingType: String, Codable, CaseIterable {
    case lumpSum   = "lump_sum"
    case unitRate  = "unit_rate"
    case tm        = "tm"           // Time & Materials
    case mixed     = "mixed"

    var displayName: String {
        switch self {
        case .lumpSum:  return "Lump Sum"
        case .unitRate: return "Unit Rate"
        case .tm:       return "T&M (Cost Plus)"
        case .mixed:    return "Mixed"
        }
    }
}

// MARK: - Estimate Status
// Tracks position in the bid/estimate lifecycle

enum EstimateStatus: String, Codable, CaseIterable {
    case rfqReceived    = "rfq_received"    // Just came in — not started
    case estimating     = "estimating"      // Being built
    case internalReview = "internal_review" // Waiting for internal approval
    case submitted      = "submitted"       // Sent to client as a bid/quote
    case awarded        = "awarded"         // We won it
    /// Set by the Estimate→Quote conversion flow. Indicates this
    /// estimate has graduated to a quote (look in `convertedQuoteID`
    /// for the linked quote). Keeps the audit trail clear instead of
    /// leaving converted estimates stuck on `.awarded` indefinitely.
    case converted      = "converted"
    case lost           = "lost"            // We lost it
    case cancelled      = "cancelled"       // Withdrawn or cancelled

    var displayName: String {
        switch self {
        case .rfqReceived:    return "RFQ Received"
        case .estimating:     return "Estimating"
        case .internalReview: return "Internal Review"
        case .submitted:      return "Submitted"
        case .awarded:        return "Awarded"
        case .converted:      return "Converted to Quote"
        case .lost:           return "Lost"
        case .cancelled:      return "Cancelled"
        }
    }

    var isActive: Bool {
        ![.awarded, .converted, .lost, .cancelled].contains(self)
    }

    var color: String {
        switch self {
        case .rfqReceived:    return "blue"
        case .estimating:     return "orange"
        case .internalReview: return "purple"
        case .submitted:      return "teal"
        case .awarded:        return "green"
        case .converted:      return "indigo"
        case .lost:           return "red"
        case .cancelled:      return "gray"
        }
    }

    /// True when the estimate is mature enough to be picked in the
    /// Estimate→Quote conversion flow. Pre-2026-04 audit only `.awarded`
    /// could convert, which forced users to mark estimates as "Awarded"
    /// before they had actually been awarded — confusing UX. Now any
    /// status that's been internally validated is eligible.
    var isQuoteEligible: Bool {
        [.internalReview, .submitted, .awarded].contains(self)
    }
}

// MARK: - Loss Reason

enum LossReason: String, Codable, CaseIterable {
    case price       = "price"
    case competitor  = "competitor"
    case scope       = "scope"
    case timing      = "timing"
    case noAward     = "no_award"
    case relationship = "relationship"
    case other       = "other"

    var displayName: String {
        switch self {
        case .price:        return "Price — too high"
        case .competitor:   return "Competitor awarded"
        case .scope:        return "Scope mismatch"
        case .timing:       return "Timing / not ready"
        case .noAward:      return "No award made"
        case .relationship: return "Existing relationship"
        case .other:        return "Other"
        }
    }
}

// MARK: - Commercial Origin Type
/// Tracks where a commercial record was created so CRM can be updated correctly.

enum CommercialOriginType: String, Codable, CaseIterable {
    case crmOpportunity   = "crm_opportunity"    // Started in CRM → Estimate
    case project          = "project"             // Change order / project scope addition
    case directCommercial = "direct_commercial"   // More → Estimates, not via CRM first
    case materialSale     = "material_sale"       // Product/material sale, no project needed

    var displayName: String {
        switch self {
        case .crmOpportunity:   return "CRM Opportunity"
        case .project:          return "Project Work"
        case .directCommercial: return "Direct Commercial"
        case .materialSale:     return "Material Sale"
        }
    }

    var icon: String {
        switch self {
        case .crmOpportunity:   return "person.crop.rectangle.stack.fill"
        case .project:          return "folder.fill"
        case .directCommercial: return "doc.text.magnifyingglass"
        case .materialSale:     return "shippingbox.fill"
        }
    }
}

// MARK: - Cost Code Line Item (unchanged — kept compatible)

struct CostCodeItem: Codable, Identifiable {
    var id: UUID = UUID()
    var code: String
    var description: String
    var unit: String
    var estimatedQuantity: Decimal
    var unitRate: Decimal
    var estimatedTotal: Decimal { estimatedQuantity * unitRate }

    // Library back-links (nil = legacy / manual entry — fully backward-compatible)
    var productServiceID: UUID? = nil
    var category: CostCodeCategory? = nil

    // Actuals (populated from timesheets after project starts)
    var actualQuantity: Decimal?
    var actualTotal: Decimal?
    var variance: Decimal? {
        guard let actual = actualTotal else { return nil }
        return estimatedTotal - actual
    }

    init(code: String, description: String, unit: String,
         estimatedQuantity: Decimal, unitRate: Decimal,
         productServiceID: UUID? = nil, category: CostCodeCategory? = nil) {
        self.code               = code
        self.description        = description
        self.unit               = unit
        self.estimatedQuantity  = estimatedQuantity
        self.unitRate           = unitRate
        self.productServiceID   = productServiceID
        self.category           = category
    }
}

// MARK: - Estimate / Bid
// This is the single source of truth for all commercial work.
// One job number follows this record through quote to project.

struct Estimate: BaseModel {
    static func == (lhs: Estimate, rhs: Estimate) -> Bool { lhs.id == rhs.id }

    var id: UUID = UUID()
    var externalID: String?
    var companyID: UUID? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()

    // ── Job Identity ──────────────────────────────────────
    // The job number is assigned when the estimate is created.
    // It becomes the quote number and project number — same number throughout.
    var jobNumber: String                   // e.g. AKI-2024-0001

    // ── Relationships ─────────────────────────────────────
    var clientID: UUID                      // Links to Client record
    var projectID: UUID?                    // Set when quote is awarded → project created
    var siteID: UUID?                       // Which client site this is for (required in new flow)
    var primaryContactID: UUID?             // CRMContact — who to address the estimate to

    // ── CRM Link ─────────────────────────────────────────
    /// Where this estimate was created from. Determines CRM writeback behaviour.
    var originType: CommercialOriginType = .directCommercial
    /// Reverse-link to the CRM opportunity. Always set before a quote is generated.
    var opportunityID: UUID? = nil

    // ── Opportunity ───────────────────────────────────────
    var name: String                        // e.g. "Insulation Package — Phase 2"
    var opportunityType: OpportunityType = .rfq
    var pricingType: PricingType = .lumpSum
    var scopeDescription: String?           // High-level scope narrative

    // ── Bid Dates ─────────────────────────────────────────
    var rfqReceivedDate: Date?
    var bidDueDate: Date?
    var submittedDate: Date?
    var awardedDate: Date?

    // ── Status ────────────────────────────────────────────
    var status: EstimateStatus = .estimating
    var revisionNumber: Int = 1

    /// Forward-link to the Quote produced from this estimate, if any.
    /// Set by the Estimate→Quote conversion flow alongside `status =
    /// .converted`. Pairs with `Quote.estimateID` for bidirectional
    /// traceability — either side can be queried for the link.
    var convertedQuoteID: UUID? = nil

    // ── Internal Approval ─────────────────────────────────
    var estimatorID: UUID?                  // Who built it
    var internalReviewBy: String?           // Who approved it
    var internalApprovedAt: Date?
    var internalNotes: String?

    // ── Win / Loss Tracking ───────────────────────────────
    var lossReason: LossReason?
    var competitorName: String?
    var winLossNotes: String?
    var awardedValue: Decimal?              // Actual awarded value (may differ from estimate)

    // ── Pricing ───────────────────────────────────────────
    var lineItems: [CostCodeItem] = []
    var contingencyPercent: Decimal = 0
    var overheadPercent: Decimal = 0
    var profitPercent: Decimal = 0
    var notes: String?

    // ── Terms & Conditions ───────────────────────────────
    /// One-shot ledger flag — flips to true the first time defaults
    /// are auto-attached. Mirrors `Quote.termsDefaultApplied`.
    /// Subsequent edits to default-template flags don't retroactively
    /// re-attach to existing estimates.
    var termsDefaultApplied: Bool = false

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

    // ── Computed Totals ───────────────────────────────────
    var subtotal: Decimal {
        lineItems.reduce(0) { $0 + $1.estimatedTotal }
    }

    var contingencyAmount: Decimal {
        subtotal * contingencyPercent / 100
    }

    var overheadAmount: Decimal {
        subtotal * overheadPercent / 100
    }

    var profitAmount: Decimal {
        subtotal * profitPercent / 100
    }

    var totalEstimated: Decimal {
        subtotal + contingencyAmount + overheadAmount + profitAmount
    }

    var totalActual: Decimal? {
        guard lineItems.allSatisfy({ $0.actualTotal != nil }) else { return nil }
        return lineItems.reduce(0) { $0 + ($1.actualTotal ?? 0) }
    }

    // ── Flags ─────────────────────────────────────────────
    var isApproved: Bool { internalApprovedAt != nil }
    var hasProject: Bool { projectID != nil }
}

// MARK: - Sample-data tracking
extension Estimate: SampleDataTrackable {}
