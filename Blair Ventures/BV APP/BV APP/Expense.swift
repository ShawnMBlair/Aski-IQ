// Expense.swift
// Aski IQ — Expenses v1
//
// Locked spec: project_expenses_v1_spec.md
// Build branch: claude/expenses-v1 (off v1.0 head 943f0a2)
//
// Scope for v1:
//   - Capture photo/PDF receipts (no OCR — that's v2)
//   - Three cost destinations: company / project / material_request
//   - Approval ladder: < $250 company-card auto-approves (no flags),
//     reimbursements always require approval, > $5K needs admin/exec
//   - Self-approval blocked regardless of role
//   - Shared queue, first-to-approve wins (audit log records actor)
//   - Office Staff can create-on-behalf with 4-field provenance
//
// Not in this file:
//   - Approval state-machine logic → ExpenseApprovalService.swift
//   - Sync push/pull → SyncEngineExpenses.swift
//   - UI → ExpenseViews.swift / ExpenseApprovalQueueView.swift
//   - PDF report → ExpensePDFRenderer.swift (audience/trigger TBD)

import Foundation

// MARK: - Category

enum ExpenseCategory: String, Codable, CaseIterable {
    case meal             = "meal"
    case fuel             = "fuel"
    case lodging          = "lodging"
    case supplies         = "supplies"
    case tools            = "tools"
    case subcontractor    = "subcontractor"
    case travel           = "travel"
    case equipmentRental  = "equipment_rental"
    case parking          = "parking"
    case other            = "other"

    var displayName: String {
        switch self {
        case .meal:             return "Meal"
        case .fuel:             return "Fuel"
        case .lodging:          return "Lodging"
        case .supplies:         return "Supplies"
        case .tools:            return "Tools"
        case .subcontractor:    return "Subcontractor"
        case .travel:           return "Travel"
        case .equipmentRental:  return "Equipment Rental"
        case .parking:          return "Parking"
        case .other:            return "Other"
        }
    }

    var icon: String {
        switch self {
        case .meal:             return "fork.knife"
        case .fuel:             return "fuelpump.fill"
        case .lodging:          return "bed.double.fill"
        case .supplies:         return "shippingbox.fill"
        case .tools:            return "hammer.fill"
        case .subcontractor:    return "person.2.fill"
        case .travel:           return "airplane"
        case .equipmentRental:  return "wrench.and.screwdriver.fill"
        case .parking:          return "parkingsign"
        case .other:            return "ellipsis.circle.fill"
        }
    }
}

// MARK: - Destination type

enum ExpenseDestination: String, Codable, CaseIterable {
    case company          = "company"           // overhead — no project link
    case project          = "project"           // job-costed against a project
    case materialRequest  = "material_request"  // tied to an MR (proxy for PO/job)

    var displayName: String {
        switch self {
        case .company:         return "Company"
        case .project:         return "Project"
        case .materialRequest: return "Material Request"
        }
    }
}

// MARK: - Payment method

enum ExpensePaymentMethod: String, Codable, CaseIterable {
    case companyCard       = "company_card"
    case personalPaid      = "personal_paid"     // employee out of pocket
    case companyCheque     = "company_cheque"
    case eTransfer         = "e_transfer"
    case cash              = "cash"
    case other             = "other"

    var displayName: String {
        switch self {
        case .companyCard:   return "Company Card"
        case .personalPaid:  return "Personal (Reimbursable)"
        case .companyCheque: return "Company Cheque"
        case .eTransfer:     return "E-Transfer"
        case .cash:          return "Cash"
        case .other:         return "Other"
        }
    }

    /// Personal-paid is the only method that requires reimbursement
    /// in v1. All other methods are already-paid by the company.
    var requiresReimbursement: Bool { self == .personalPaid }
}

// MARK: - Approval state

enum ExpenseApprovalState: String, Codable, CaseIterable {
    case draft           = "draft"
    case pendingApproval = "pending_approval"
    case autoApproved    = "auto_approved"   // < $250 company-card, no flags
    case approved        = "approved"
    case rejected        = "rejected"
    case paid            = "paid"            // reimbursements only — terminal after approved

    var displayName: String {
        switch self {
        case .draft:            return "Draft"
        case .pendingApproval:  return "Pending Approval"
        case .autoApproved:     return "Auto-Approved"
        case .approved:         return "Approved"
        case .rejected:         return "Rejected"
        case .paid:             return "Paid"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .autoApproved, .rejected, .paid: return true
        case .draft, .pendingApproval, .approved: return false
        }
    }
}

// MARK: - Expense

struct Expense: BaseModel {

    // MARK: BaseModel boilerplate
    var id: UUID = UUID()
    var externalID: String?         // imported / accounting-software external key
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()

    // MARK: Tenant scope
    var companyID: UUID? = nil

    // MARK: Identity
    /// Monotonic per-company per-year. Format: BV-EXP-2026-0001.
    /// Generated by NumberGenerationService at create time; never reused
    /// across soft-deletes (same pattern as MR / PO / Invoice numbers).
    var expenseNumber: String = ""

    // MARK: Core fields
    var vendor: String = ""
    var expenseDate: Date = Date()
    var amount: Decimal = 0
    var currency: String = "CAD"
    var memo: String = ""           // free-text description / notes
    var category: ExpenseCategory = .other
    var paymentMethod: ExpensePaymentMethod = .companyCard

    // MARK: Cost destination
    var destination: ExpenseDestination = .company
    /// Set when destination == .project.
    var projectID: UUID? = nil
    /// Set when destination == .materialRequest.
    var materialRequestID: UUID? = nil
    /// Free-text bucket name for company expenses (e.g. "Office",
    /// "Marketing", "Insurance"). Maps to accounting category later.
    var companyDestinationLabel: String = ""

    // MARK: Reimbursement
    /// True when paymentMethod == .personalPaid. Cached on the row
    /// for query convenience; equivalent to paymentMethod.requiresReimbursement.
    var isReimbursable: Bool = false
    /// When the reimbursement was paid out (separate from approval).
    var reimbursementPaidAt: Date? = nil
    var reimbursementPaidBy: UUID? = nil    // employee who marked paid
    var reimbursementPaymentMethod: ExpensePaymentMethod? = nil

    // MARK: Approval workflow
    var approvalState: ExpenseApprovalState = .draft
    var approvedBy: UUID? = nil
    var approvedAt: Date? = nil
    var rejectedBy: UUID? = nil
    var rejectedAt: Date? = nil
    var rejectionReason: String = ""

    // MARK: Submitted-on-behalf-of provenance (4-field model from spec)
    /// Employee who entered the expense into the system.
    var createdBy: UUID? = nil
    /// Employee who clicked Submit. Same as createdBy unless Office Staff
    /// is preparing the expense and someone else submits.
    var submittedBy: UUID? = nil
    /// The employee the expense belongs to / who gets reimbursed if
    /// applicable. Different from createdBy when Office Staff enters
    /// an expense for a field worker.
    var expenseOwnerEmployeeID: UUID? = nil
    /// True when createdBy != expenseOwnerEmployeeID.
    var submittedOnBehalfOf: Bool = false

    // MARK: Possible-duplicate hint (computed at submit time)
    /// Set by the duplicate-detection check when an expense matches
    /// vendor + date + amount within a 7-day window of an existing
    /// expense for the same owner. Surfaces a flag in the approval
    /// queue but doesn't block submission.
    var possibleDuplicateOf: UUID? = nil

    // MARK: Soft delete
    var isDeleted: Bool = false
    var deletedAt: Date? = nil
    var deletedBy: String? = nil

    // MARK: Sample-data tracking (matches existing pattern)
    var isSampleData: Bool = false
    var sampleDataBatchID: UUID? = nil
    var sampleDataSeedVersion: String? = nil
    var sampleDataCreatedAt: Date? = nil
    var sampleDataCreatedBy: UUID? = nil
}

// MARK: - Flag computation

extension Expense {

    /// True when no ExpenseAttachment marked isPrimaryReceipt exists
    /// for this expense. Caller passes the attachment set since the
    /// model is a pure struct.
    func isMissingReceipt(attachments: [ExpenseAttachment]) -> Bool {
        !attachments.contains { $0.expenseID == id && $0.isPrimaryReceipt && !$0.isDeleted }
    }

    /// $250 — drives "needs Manager-tier approval" path.
    static let lowerThreshold: Decimal = 250

    /// $5,000 — drives "needs Admin/Executive approval" path.
    static let upperThreshold: Decimal = 5_000

    var isOverLowerThreshold: Bool { amount > Self.lowerThreshold }
    var isOverUpperThreshold: Bool { amount > Self.upperThreshold }

    /// True when this is a personal-paid expense that needs to be
    /// reimbursed back to the employee. Always requires approval.
    var isEmployeeReimbursement: Bool { isReimbursable }

    /// Set of flags surfaced in the approval queue. The order matters
    /// for display (most-severe first).
    func flags(attachments: [ExpenseAttachment]) -> Set<ExpenseFlag> {
        var out: Set<ExpenseFlag> = []
        if isOverUpperThreshold              { out.insert(.overUpperThreshold) }
        else if isOverLowerThreshold         { out.insert(.overLowerThreshold) }
        if isMissingReceipt(attachments: attachments) { out.insert(.missingReceipt) }
        if possibleDuplicateOf != nil        { out.insert(.possibleDuplicate) }
        if isEmployeeReimbursement           { out.insert(.employeeReimbursement) }
        if submittedOnBehalfOf               { out.insert(.submittedOnBehalfOf) }
        return out
    }

    /// True when this expense qualifies for the auto-approve path
    /// per the locked spec: company-card under $250, with zero flags.
    func qualifiesForAutoApproval(attachments: [ExpenseAttachment]) -> Bool {
        guard paymentMethod == .companyCard else { return false }
        guard amount <= Self.lowerThreshold else { return false }
        return flags(attachments: attachments).isEmpty
    }
}

// MARK: - Flag enum

enum ExpenseFlag: String, Codable, CaseIterable {
    case missingReceipt        = "missing_receipt"
    case possibleDuplicate     = "possible_duplicate"
    case overLowerThreshold    = "over_lower_threshold"   // > $250
    case overUpperThreshold    = "over_upper_threshold"   // > $5,000
    case employeeReimbursement = "employee_reimbursement"
    case submittedOnBehalfOf   = "submitted_on_behalf_of"

    var displayName: String {
        switch self {
        case .missingReceipt:        return "Missing Receipt"
        case .possibleDuplicate:     return "Possible Duplicate"
        case .overLowerThreshold:    return "Over $250"
        case .overUpperThreshold:    return "Over $5,000"
        case .employeeReimbursement: return "Employee Reimbursement"
        case .submittedOnBehalfOf:   return "Submitted on Behalf"
        }
    }

    var icon: String {
        switch self {
        case .missingReceipt:        return "doc.questionmark.fill"
        case .possibleDuplicate:     return "doc.on.doc.fill"
        case .overLowerThreshold:    return "dollarsign.circle"
        case .overUpperThreshold:    return "exclamationmark.octagon.fill"
        case .employeeReimbursement: return "person.fill.badge.plus"
        case .submittedOnBehalfOf:   return "person.2.fill"
        }
    }

    /// Whether this flag should disqualify an expense from the
    /// company-card-under-$250 auto-approve path.
    var blocksAutoApproval: Bool { true }
}
