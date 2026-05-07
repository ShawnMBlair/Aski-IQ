// ProjectBudget.swift
// Aski IQ – Project Budget / WBS Module
// Per-project budget lines by cost code, tracking budgeted vs committed vs actual.

import Foundation

// MARK: - Budget Line

struct ProjectBudgetLine: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var costCode: String
    var description: String
    var budgetedLabour:   Decimal = 0   // $
    var budgetedMaterial: Decimal = 0   // $
    var budgetedOther:    Decimal = 0   // $
    var sortOrder:        Int     = 0

    var totalBudgeted: Decimal { budgetedLabour + budgetedMaterial + budgetedOther }
}

// MARK: - Project Budget

struct ProjectBudget: BaseModel {
    var id: UUID = UUID()
    var externalID: String?
    var companyID: UUID? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()

    var projectID: UUID

    /// Original value from signed contract (before any Change Orders).
    var originalContractValue: Decimal = 0

    /// Owner-approved contingency held in budget.
    var contingencyAmount: Decimal = 0

    /// Detailed cost-code lines.
    var lines: [ProjectBudgetLine] = []

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

    // MARK: Computed

    var totalLinesBudgeted: Decimal {
        lines.reduce(Decimal(0)) { $0 + $1.totalBudgeted }
    }

    var totalBudgeted: Decimal {
        totalLinesBudgeted + contingencyAmount
    }
}

// MARK: - AppStore Extension

extension AppStore {

    private static let projectBudgetsKey = "bv_project_budgets"

    // MARK: CRUD

    func upsertBudget(_ budget: ProjectBudget) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "upsert_project_budget") else { return }
        var updated = budget
        updated.updatedAt = Date()
        updated.syncStatus = .pending
        if let index = projectBudgets.firstIndex(where: { $0.projectID == budget.projectID }) {
            projectBudgets[index] = updated
        } else {
            projectBudgets.append(updated)
        }
        saveBudgets()
        Task { await SyncEngine.shared.pushPendingProjectBudgets() }
    }

    // MARK: Lookups

    func budget(for projectID: UUID) -> ProjectBudget? {
        projectBudgets.first { $0.projectID == projectID }
    }

    /// Sum of all approved/committed PO values for a project.
    func committedMaterialCost(for projectID: UUID) -> Decimal {
        purchaseOrders
            .filter { $0.projectID == projectID && $0.status != .draft && $0.status != .cancelled }
            .reduce(Decimal(0)) { $0 + $1.total }
    }

    /// Sum of approved Change Order cost impacts for a project.
    func approvedCOValue(for projectID: UUID) -> Decimal {
        changeOrders(for: projectID)
            .filter { $0.status == .approved }
            .reduce(Decimal(0)) { $0 + $1.effectiveCostImpact }
    }

    /// Creates a new ProjectBudget pre-populated from the project's linked estimate.
    func budgetFromEstimate(for project: Project) -> ProjectBudget {
        var budget = ProjectBudget(projectID: project.id)
        budget.originalContractValue = project.contractValue ?? project.estimatedBudget ?? 0

        // Import cost code lines from linked estimate
        let linked = estimates.first { $0.projectID == project.id }
            ?? estimates.first { project.estimateIDs.contains($0.id) }

        if let est = linked {
            budget.lines = est.lineItems.enumerated().map { idx, item in
                // Split estimated total into labour / material / other by category
                let labourTotal:   Decimal
                let materialTotal: Decimal
                let otherTotal:    Decimal
                switch item.category {
                case .labour:
                    labourTotal   = item.estimatedTotal
                    materialTotal = 0
                    otherTotal    = 0
                case .insulation, .containment, .drywall, .scaffolding:
                    labourTotal   = 0
                    materialTotal = item.estimatedTotal
                    otherTotal    = 0
                default:
                    // equipment, safety, travel, overhead, delays, nil
                    labourTotal   = 0
                    materialTotal = 0
                    otherTotal    = item.estimatedTotal
                }
                return ProjectBudgetLine(
                    costCode:         item.code,
                    description:      item.description,
                    budgetedLabour:   labourTotal,
                    budgetedMaterial: materialTotal,
                    budgetedOther:    otherTotal,
                    sortOrder:        idx
                )
            }
        }
        return budget
    }

    // MARK: Persistence

    // Persistence handled by Supabase. Stubs kept for call-site compatibility.
    func saveBudgets() {}
    func loadBudgets() {}

}

// MARK: - Sample-data tracking
extension ProjectBudget: SampleDataTrackable {}
