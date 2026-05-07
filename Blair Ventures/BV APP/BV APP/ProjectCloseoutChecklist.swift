// ProjectCloseoutChecklist.swift
// Aski IQ — Phase 4 PMI workflow: formal closeout checklist.
//
// PURPOSE
// Pre-fix the path to "Completed" status was a single status flip.
// PMs were closing projects without verifying any of the standard
// PMI closeout deliverables — final invoice, final lien waivers,
// remaining open RFIs, subcontract close-out, payroll lock, etc.
// Reporting then showed projects "Completed" while the office was
// still chasing $40k of unsigned waivers.
//
// THIS FILE
// One stateless service that, for any project, returns a list of
// PMI-aligned checklist items each with a `state` (.done /.pending /
// .notApplicable). UI surfaces the list as a card on ProjectDetailView
// when the project is approaching or at completion. The service does
// NOT mutate state or block status changes — it's purely advisory.
// Hard-stops (like "no open COs") still live in `upsertProject`.
//
// COVERAGE
//   1. All change orders resolved
//   2. Final invoice generated
//   3. All invoices paid in full
//   4. Final lien waiver received
//   5. Daily report on file (>= 1 approved DJR)
//   6. RFIs resolved
//   7. Subcontracts complete
//   8. Timesheets approved (no draft / submitted)
//   9. Budget reconciled (cost data exists)
//
// LIMITATIONS
//   * Lien waiver check is invoice-scoped (LienWaiver only links to
//     Invoice, not Project directly). Projects without a final
//     invoice show this item as .notApplicable.
//   * "Subcontracts complete" trusts the SubContract.status field —
//     PMs must manually flip it; the service can't infer completion.

import Foundation

@MainActor
struct CloseoutChecklistItem: Identifiable {
    enum State {
        case done
        case pending
        case notApplicable
    }

    let id:     String          // Stable key, used for ForEach
    let title:  String
    let state:  State
    let detail: String?         // Optional sub-line, e.g. "2 still open"

    var isBlocking: Bool { state == .pending }
}

@MainActor
struct ProjectCloseout {
    let projectID: UUID
    let items: [CloseoutChecklistItem]

    /// Number of items still pending. Drives the headline badge.
    var pendingCount: Int { items.filter { $0.state == .pending }.count }

    /// True when nothing is left to do (every item is .done or .NA).
    var isReadyToClose: Bool { pendingCount == 0 }

    /// Progress fraction across applicable items (excluding .notApplicable).
    /// Used to drive the card's progress bar. Returns 1.0 when no
    /// applicable items exist (a brand-new project shows "Ready" rather
    /// than "0%").
    var progress: Double {
        let applicable = items.filter { $0.state != .notApplicable }
        guard !applicable.isEmpty else { return 1 }
        let done = applicable.filter { $0.state == .done }.count
        return Double(done) / Double(applicable.count)
    }
}

@MainActor
enum ProjectCloseoutChecklist {

    /// Compute the full closeout checklist for a project. Cheap — all
    /// inputs are in-memory and the service is called only when the
    /// card body renders.
    static func checklist(for projectID: UUID, in store: AppStore) -> ProjectCloseout {
        var out: [CloseoutChecklistItem] = []

        // 1. Change orders resolved
        let openCOs = store.changeOrders(for: projectID)
            .filter { $0.status.isOpen && !$0.isDeleted }
        out.append(.init(
            id:     "change_orders",
            title:  "Change orders resolved",
            state:  openCOs.isEmpty ? .done : .pending,
            detail: openCOs.isEmpty ? nil : "\(openCOs.count) still open"
        ))

        // 2. Final invoice generated
        let projectInvoices = store.invoices.filter {
            $0.projectID == projectID && !$0.isDeleted
        }
        let finalInvoice = projectInvoices.first { $0.invoiceType == .final }
        out.append(.init(
            id:     "final_invoice",
            title:  "Final invoice generated",
            state:  finalInvoice == nil ? .pending : .done,
            detail: finalInvoice.map { "Invoice \($0.invoiceNumber)" }
        ))

        // 3. All invoices paid
        let outstanding = projectInvoices.reduce(Decimal(0)) { $0 + $1.balanceDue }
        let paidState: CloseoutChecklistItem.State
        let paidDetail: String?
        if projectInvoices.isEmpty {
            paidState = .notApplicable
            paidDetail = "No invoices on this project"
        } else if outstanding <= 0 {
            paidState = .done
            paidDetail = nil
        } else {
            paidState = .pending
            paidDetail = "\(outstanding.currencyString) outstanding"
        }
        out.append(.init(
            id:     "invoices_paid",
            title:  "Invoices paid in full",
            state:  paidState,
            detail: paidDetail
        ))

        // 4. Final lien waiver received. Only meaningful when a final
        //    invoice exists; otherwise mark NA.
        let waiverState: CloseoutChecklistItem.State
        let waiverDetail: String?
        if let inv = finalInvoice {
            let received = store.lienWaivers.contains { w in
                w.invoiceID == inv.id
                    && !w.isDeleted
                    && (w.waiverType == .finalConditional
                        || w.waiverType == .finalUnconditional)
                    && w.status == .received
            }
            waiverState  = received ? .done : .pending
            waiverDetail = received ? nil : "No final waiver on file for \(inv.invoiceNumber)"
        } else {
            waiverState  = .notApplicable
            waiverDetail = "Generate final invoice first"
        }
        out.append(.init(
            id:     "lien_waiver",
            title:  "Final lien waiver received",
            state:  waiverState,
            detail: waiverDetail
        ))

        // 5. Daily report on file
        let approvedDJRs = store.dailyJobReports(for: projectID)
            .filter { !$0.isDeleted && $0.status == .approved }
        out.append(.init(
            id:     "daily_report",
            title:  "Daily report on file",
            state:  approvedDJRs.isEmpty ? .pending : .done,
            detail: approvedDJRs.isEmpty
                ? "No approved daily reports yet"
                : "\(approvedDJRs.count) approved"
        ))

        // 6. RFIs resolved — open if any RFI is not closed/voided
        let openRFIs = store.rfis.filter { rfi in
            rfi.projectID == projectID
                && !rfi.isDeleted
                && rfi.status != .closed
                && rfi.status != .voided
        }
        let totalRFIs = store.rfis.filter { $0.projectID == projectID && !$0.isDeleted }.count
        let rfiState: CloseoutChecklistItem.State
        let rfiDetail: String?
        if totalRFIs == 0 {
            rfiState = .notApplicable
            rfiDetail = "No RFIs raised"
        } else if openRFIs.isEmpty {
            rfiState = .done
            rfiDetail = nil
        } else {
            rfiState = .pending
            rfiDetail = "\(openRFIs.count) still open"
        }
        out.append(.init(
            id:     "rfis",
            title:  "RFIs resolved",
            state:  rfiState,
            detail: rfiDetail
        ))

        // 7. Subcontracts complete
        let projectSubs = store.subContracts.filter {
            $0.projectID == projectID && !$0.isDeleted
        }
        let openSubs = projectSubs.filter { $0.status != .complete && $0.status != .terminated }
        let subState: CloseoutChecklistItem.State
        let subDetail: String?
        if projectSubs.isEmpty {
            subState = .notApplicable
            subDetail = "No subcontracts on this project"
        } else if openSubs.isEmpty {
            subState = .done
            subDetail = nil
        } else {
            subState = .pending
            subDetail = "\(openSubs.count) not yet marked complete"
        }
        out.append(.init(
            id:     "subcontracts",
            title:  "Subcontracts complete",
            state:  subState,
            detail: subDetail
        ))

        // 8. Timesheets approved
        let projectTimesheets = store.timesheetEntries.filter {
            $0.projectID == projectID && !$0.isDeleted
        }
        let pendingTS = projectTimesheets.filter {
            $0.approvalStatus == .draft || $0.approvalStatus == .submitted
        }
        let tsState: CloseoutChecklistItem.State
        let tsDetail: String?
        if projectTimesheets.isEmpty {
            tsState = .notApplicable
            tsDetail = "No timesheets logged"
        } else if pendingTS.isEmpty {
            tsState = .done
            tsDetail = nil
        } else {
            tsState = .pending
            tsDetail = "\(pendingTS.count) pending approval"
        }
        out.append(.init(
            id:     "timesheets",
            title:  "Timesheets approved",
            state:  tsState,
            detail: tsDetail
        ))

        // 9. Budget reconciled — at least some actual cost recorded so
        //    the closeout reflects real numbers, not a $0 phantom.
        let actuals = BudgetActualService.actuals(for: projectID, in: store)
        let hasActuals = actuals.actualCost > 0
        out.append(.init(
            id:     "budget_reconciled",
            title:  "Budget reconciled",
            state:  hasActuals ? .done : .pending,
            detail: hasActuals
                ? "Actual cost \(actuals.actualCost.currencyString)"
                : "No labor or material actuals recorded"
        ))

        return ProjectCloseout(projectID: projectID, items: out)
    }
}
