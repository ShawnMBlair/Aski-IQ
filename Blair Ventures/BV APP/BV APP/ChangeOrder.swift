// ChangeOrder.swift
// Aski IQ – Change Order Module
// Tracks scope changes, cost impacts, and schedule impacts tied to active projects.

import Foundation

// MARK: - Change Order Status

enum ChangeOrderStatus: String, Codable, CaseIterable {
    case draft       = "draft"
    case submitted   = "submitted"      // Sent to owner for approval
    case underReview = "under_review"   // Owner reviewing
    case approved    = "approved"
    case rejected    = "rejected"
    case voided      = "voided"

    var displayName: String {
        switch self {
        case .draft:       return "Draft"
        case .submitted:   return "Submitted"
        case .underReview: return "Under Review"
        case .approved:    return "Approved"
        case .rejected:    return "Rejected"
        case .voided:      return "Voided"
        }
    }

    var isOpen: Bool { ![.approved, .rejected, .voided].contains(self) }

    var color: String {
        switch self {
        case .draft:       return "gray"
        case .submitted:   return "blue"
        case .underReview: return "orange"
        case .approved:    return "green"
        case .rejected:    return "red"
        case .voided:      return "gray"
        }
    }

    var icon: String {
        switch self {
        case .draft:       return "doc"
        case .submitted:   return "paperplane.fill"
        case .underReview: return "magnifyingglass.circle"
        case .approved:    return "checkmark.circle.fill"
        case .rejected:    return "xmark.circle.fill"
        case .voided:      return "slash.circle"
        }
    }
}

// MARK: - Change Order Type

enum ChangeOrderType: String, Codable, CaseIterable {
    case ownerInitiated    = "owner_initiated"
    case designChange      = "design_change"
    case siteCondition     = "site_condition"
    case scopeChange       = "scope_change"
    case weatherDelay      = "weather_delay"
    case contractualError  = "contractual_error"
    case other             = "other"

    var displayName: String {
        switch self {
        case .ownerInitiated:   return "Owner Initiated"
        case .designChange:     return "Design Change"
        case .siteCondition:    return "Unforeseen Site Condition"
        case .scopeChange:      return "Scope Change"
        case .weatherDelay:     return "Weather Delay"
        case .contractualError: return "Contractual Error / Omission"
        case .other:            return "Other"
        }
    }

    var icon: String {
        switch self {
        case .ownerInitiated:   return "person.fill.questionmark"
        case .designChange:     return "pencil.and.ruler"
        case .siteCondition:    return "exclamationmark.triangle"
        case .scopeChange:      return "arrow.left.arrow.right"
        case .weatherDelay:     return "cloud.rain.fill"
        case .contractualError: return "doc.badge.gearshape"
        case .other:            return "ellipsis.circle"
        }
    }
}

// MARK: - Change Order Line Item

struct ChangeOrderLineItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var description: String
    var quantity: Decimal = 1
    var unit: String = "LS"
    var unitPrice: Decimal = 0
    var total: Decimal { quantity * unitPrice }
}

// MARK: - Change Order

struct ChangeOrder: BaseModel {
    var id: UUID = UUID()
    var externalID: String?
    var companyID: UUID? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()

    // Identity
    var number: String                      // e.g. "AKI-2026-001-CO-001"
    var title: String
    var projectID: UUID

    // Classification
    var type: ChangeOrderType = .ownerInitiated
    var status: ChangeOrderStatus = .draft

    // Financial impact
    var costImpact: Decimal = 0             // Positive = adds cost to contract
    var scheduleImpactDays: Int = 0         // Positive = extends schedule

    // Detail
    var description: String = ""
    var reason: String?
    var notes:     String? = nil
    var lineItems: [ChangeOrderLineItem] = []

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

    // Dates
    var submittedDate: Date?
    var approvedDate: Date?
    var rejectedDate: Date?

    // People
    var createdByID: UUID?
    var approvedByName: String?
    var clientReferenceNumber: String?      // Owner's own CO reference / RFQ number

    // Computed
    var lineItemTotal: Decimal {
        lineItems.reduce(0) { $0 + $1.total }
    }

    /// The authoritative cost impact: if line items exist, use their total;
    /// otherwise fall back to the manually entered costImpact field.
    var effectiveCostImpact: Decimal {
        lineItems.isEmpty ? costImpact : lineItemTotal
    }
}

// MARK: - AppStore Extension

extension AppStore {

    private static let changeOrdersKey = "bv_change_orders"

    // MARK: CRUD

    func upsertChangeOrder(_ item: ChangeOrder) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "upsert_change_order") else { return }
        let oldStatus = changeOrders.first(where: { $0.id == item.id })?.status
        var updated = item
        updated.updatedAt      = Date()
        updated.lastModifiedAt = Date()
        updated.syncStatus     = .pending
        // Stamp tenant scope: prefer the parent project's companyID so a CO
        // inherits its project's tenant, with currentCompanyID as fallback.
        if updated.companyID == nil {
            updated.companyID =
                projects.first(where: { $0.id == updated.projectID })?.companyID
                ?? currentCompanyID
        }
        if let index = changeOrders.firstIndex(where: { $0.id == item.id }) {
            changeOrders[index] = updated
        } else {
            changeOrders.append(updated)
        }
        saveChangeOrders()
        Task { await SyncEngine.shared.pushPendingChangeOrders() }

        // ── Approval → Budget update ──────────────────────────────────────────
        // When a CO transitions to .approved, apply its cost impact to the
        // linked ProjectBudget by adding a new budget line and updating the
        // total. The original budget lines are preserved intact so diff is clear.
        if updated.status == .approved, oldStatus != .approved {
            applyChangeOrderToBudget(updated)
            logCRMActivity(
                type:          .stageChanged,
                title:         "Change Order approved: \(updated.number)",
                notes:         "Cost impact: \(updated.effectiveCostImpact.currencyString). Schedule: \(updated.scheduleImpactDays) day(s).",
                clientID:      nil,
                contactID:     nil,
                opportunityID: nil,
                quoteID:       nil,
                projectID:     updated.projectID
            )
            recordChangeOrderApprovalAudit(updated)
            warnIfChangeOrderPushesScopeCreep(updated)
        }
    }

    /// Append a durable WorkflowLog audit row when a CO is approved so
    /// the change appears in the AdminPanel audit feed alongside other
    /// system events. CRM activity logging captures the same fact in
    /// the project / opportunity timeline; the workflow log is the
    /// tenant-wide audit trail PMs reference during closeout.
    private func recordChangeOrderApprovalAudit(_ co: ChangeOrder) {
        let projectName = projects.first(where: { $0.id == co.projectID })?.name ?? "Unknown project"
        var entry = WorkflowLogEntry(
            ruleID:   co.id,
            ruleName: "Change Order Approved",
            title:    "CO \(co.number) approved on \(projectName)",
            body:     "Cost impact \(co.effectiveCostImpact.currencyString); schedule \(co.scheduleImpactDays) day(s). Revised budget refreshed."
        )
        entry.companyID  = co.companyID ?? currentCompanyID
        entry.syncStatus = .pending
        workflowLog.append(entry)
        saveWorkflowLog()
        Task { await SyncEngine.shared.pushPendingWorkflowLog() }
    }

    /// Soft warning when cumulative approved CO impact exceeds 10% of
    /// the original contract — PMI scope-creep threshold. Doesn't
    /// block the approval, just flags it so PMs notice when a project
    /// is drifting from its baseline. Threshold matches BudgetActual-
    /// Service.minMarginRatio for symmetry.
    private func warnIfChangeOrderPushesScopeCreep(_ co: ChangeOrder) {
        let original = budget(for: co.projectID)?.originalContractValue
            ?? projects.first(where: { $0.id == co.projectID })?.contractValue
            ?? 0
        guard original > 0 else { return }
        let approvedTotal = approvedCOValue(for: co.projectID)
        let ratio = NSDecimalNumber(decimal: approvedTotal / original).doubleValue
        if ratio >= 0.10 {
            ToastService.shared.warning(
                "Scope creep watch",
                body: "Approved COs now total \(Int(ratio * 100))% of original contract. Review revised budget before proceeding."
            )
        }
    }

    /// Adds the CO cost impact to the linked project budget as a dedicated budget line.
    private func applyChangeOrderToBudget(_ co: ChangeOrder) {
        guard co.effectiveCostImpact != 0 else { return }
        guard var budget = budget(for: co.projectID) else { return }
        // Add a new line representing the approved CO impact
        let coLine = ProjectBudgetLine(
            costCode:         co.number,
            description:      "CO Approved: \(co.title)",
            budgetedLabour:   0,
            budgetedMaterial: 0,
            budgetedOther:    co.effectiveCostImpact,
            sortOrder:        budget.lines.count + 100
        )
        budget.lines.append(coLine)
        budget.syncStatus     = .pending
        budget.updatedAt      = Date()
        budget.lastModifiedAt = Date()
        upsertBudget(budget)
    }

    func deleteChangeOrder(_ item: ChangeOrder) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "delete_change_order") else { return }
        guard let idx = changeOrders.firstIndex(where: { $0.id == item.id }) else { return }
        var deleted = changeOrders[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        changeOrders[idx] = deleted
        Task { await SyncEngine.shared.pushPendingChangeOrders() }
    }

    // MARK: Lookups

    func changeOrders(for projectID: UUID) -> [ChangeOrder] {
        changeOrders.filter { $0.projectID == projectID }
    }

    var openChangeOrders: [ChangeOrder] {
        changeOrders.filter { $0.status.isOpen }
    }

    /// Auto-generates a sequential CO number scoped to the project.
    func nextCONumber(for projectID: UUID) -> String {
        let prefix = project(id: projectID)?.jobNumber
            ?? AppSettings.shared.companyPrefix
        let count = changeOrders.filter { $0.projectID == projectID }.count + 1
        return "\(prefix)-CO-\(String(format: "%03d", count))"
    }

    // MARK: Persistence

    // Persistence is handled by Supabase via SyncEngineCommercial.
    // These stubs exist so existing call sites compile without changes.
    func saveChangeOrders() {}
    func loadChangeOrders() {}

}

// MARK: - Sample-data tracking
extension ChangeOrder: SampleDataTrackable {}
