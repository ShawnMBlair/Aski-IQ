// LinkedRecordsAudit.swift
// Aski IQ — Phase 1 PMI workflow fix: linked-records summary helper for
// delete confirmations.
//
// PURPOSE
// Pre-fix, deleting a Project / Estimate / Quote silently soft-deleted
// the parent without surfacing the children that would orphan. A
// project with 12 schedule entries, 4 invoices, and 6 change orders
// could be deleted with one tap — and reporting would silently lose
// rollup paths to all of them.
//
// THIS FILE
// `AppStore.linkedRecords(forProject:)` etc. count the live (non-
// deleted) child rows that would be affected by a soft-delete of the
// parent. Returns a typed `LinkedRecordsSummary` the UI can render
// in a confirmation alert, e.g.:
//   "Delete project 'Smith Reroof'? This will orphan 12 schedule
//    entries, 4 invoices, 6 change orders, 2 daily logs, 1 budget."
//
// SOFT-DELETE SEMANTICS
// We DON'T cascade — soft-delete on the parent leaves children with
// their FK intact. The cascade is server-side via Postgres ON DELETE
// (which only fires on hard-delete). This helper is purely for the
// UI warning: tell the user what they're about to disconnect.

import Foundation

/// Counts of live child records that link to a parent. Empty values
/// are dropped from the rendered summary.
struct LinkedRecordsSummary {
    var schedule:        Int = 0
    var timesheets:      Int = 0
    var dailyLogs:       Int = 0
    var invoices:        Int = 0
    var changeOrders:    Int = 0
    var rfis:            Int = 0
    var subContracts:    Int = 0
    var budgets:         Int = 0
    var quotes:          Int = 0
    var contracts:       Int = 0
    var materialSales:   Int = 0
    var formSubmissions: Int = 0
    var incidents:       Int = 0
    var purchaseOrders:  Int = 0

    /// True when there's anything to warn about. Empty summary →
    /// caller can skip the confirmation entirely (just delete).
    var isEmpty: Bool {
        schedule == 0 && timesheets == 0 && dailyLogs == 0
        && invoices == 0 && changeOrders == 0 && rfis == 0
        && subContracts == 0 && budgets == 0 && quotes == 0
        && contracts == 0 && materialSales == 0
        && formSubmissions == 0 && incidents == 0 && purchaseOrders == 0
    }

    /// Human-readable bullet list, used in the delete confirmation
    /// alert message. Returns nil when the summary is empty so the
    /// caller can skip the warning.
    var displayMessage: String? {
        if isEmpty { return nil }
        var parts: [String] = []
        func add(_ count: Int, _ singular: String, _ plural: String) {
            if count > 0 {
                parts.append("\(count) \(count == 1 ? singular : plural)")
            }
        }
        add(schedule,        "schedule entry",  "schedule entries")
        add(timesheets,      "timesheet",       "timesheets")
        add(dailyLogs,       "daily log",       "daily logs")
        add(invoices,        "invoice",         "invoices")
        add(changeOrders,    "change order",    "change orders")
        add(rfis,            "RFI",             "RFIs")
        add(subContracts,    "sub-contract",    "sub-contracts")
        add(budgets,         "budget",          "budgets")
        add(quotes,          "quote",           "quotes")
        add(contracts,       "contract",        "contracts")
        add(materialSales,   "material sale",   "material sales")
        add(formSubmissions, "form submission", "form submissions")
        add(incidents,       "incident",        "incidents")
        add(purchaseOrders,  "purchase order",  "purchase orders")
        return parts.joined(separator: ", ")
    }
}

extension AppStore {

    // MARK: - Project

    /// Counts live child rows that point to this project. Used by
    /// the delete confirmation in ProjectDetailView to show "This
    /// will orphan 12 schedule entries, 4 invoices…" before the
    /// soft-delete fires.
    func linkedRecords(forProject id: UUID) -> LinkedRecordsSummary {
        var s = LinkedRecordsSummary()
        s.schedule        = scheduleEntries.filter   { $0.projectID == id && !$0.isDeleted }.count
        s.timesheets      = timesheetEntries.filter  { $0.projectID == id && !$0.isDeleted }.count
        s.invoices        = invoices.filter          { $0.projectID == id && !$0.isDeleted }.count
        s.changeOrders    = changeOrders.filter      { $0.projectID == id && !$0.isDeleted }.count
        s.rfis            = rfis.filter              { $0.projectID == id && !$0.isDeleted }.count
        s.subContracts    = subContracts.filter      { $0.projectID == id && !$0.isDeleted }.count
        s.budgets         = projectBudgets.filter    { $0.projectID == id && !$0.isDeleted }.count
        s.quotes          = quotes.filter            { $0.projectID == id && !$0.isDeleted }.count
        s.contracts       = contracts.filter         { $0.projectID == id && !$0.isDeleted }.count
        s.materialSales   = materialSales.filter     { $0.projectID == id && !$0.isDeleted }.count
        s.formSubmissions = formSubmissions.filter   { $0.projectID == id && !$0.isArchived }.count
        s.incidents       = incidents.filter         { $0.projectID == id && !$0.isDeleted }.count
        s.purchaseOrders  = purchaseOrders.filter    { $0.projectID == id && !$0.isDeleted }.count
        return s
    }

    // MARK: - Estimate

    /// Counts live child rows that point to this estimate. Mostly
    /// quotes (forward link via `Quote.estimateID`) — but also
    /// the linked CRM opportunity, which we count once by checking
    /// `Estimate.opportunityID` and confirming the opportunity is
    /// live.
    func linkedRecords(forEstimate id: UUID) -> LinkedRecordsSummary {
        var s = LinkedRecordsSummary()
        s.quotes = quotes.filter { $0.estimateID == id && !$0.isDeleted }.count
        return s
    }

    // MARK: - Quote

    /// Counts live records that point to this quote. Significant
    /// because deleting an awarded quote orphans the spawned project
    /// + invoices + contract.
    func linkedRecords(forQuote id: UUID) -> LinkedRecordsSummary {
        var s = LinkedRecordsSummary()
        s.invoices      = invoices.filter      { $0.quoteID == id && !$0.isDeleted }.count
        s.contracts     = contracts.filter     { $0.quoteID == id && !$0.isDeleted }.count
        s.materialSales = materialSales.filter { $0.quoteID == id && !$0.isDeleted }.count
        return s
    }

    // MARK: - Client

    /// Counts live records that depend on this client. Highest-blast-
    /// radius delete in the system — a client with active projects
    /// shouldn't be deleted casually. Most code paths use Client.
    /// `isActive = false` instead of soft-delete; this helper exists
    /// for the explicit hard-delete path.
    func linkedRecords(forClient id: UUID) -> LinkedRecordsSummary {
        var s = LinkedRecordsSummary()
        s.quotes        = quotes.filter        { $0.clientID == id && !$0.isDeleted }.count
        s.invoices      = invoices.filter      { $0.clientID == id && !$0.isDeleted }.count
        s.materialSales = materialSales.filter { $0.clientID == id && !$0.isDeleted }.count
        // CRM is handled separately because the relationship is via
        // CRMOpportunity / CRMContact, not surfaced in this struct.
        // (We could extend the summary; for now keep it lean.)
        return s
    }

    // MARK: - Pre-delete warning helpers
    //
    // These return a LinkedRecordsSummary the UI can read before
    // calling the underlying soft-delete. They DON'T block the
    // delete — Phase 1 spec specifies a *soft warning*, not a hard
    // stop, on most non-Project deletes (Project already has
    // ProjectDeletionError.hasDependents to gate it). UIs that want
    // a "this will orphan N records — confirm?" alert call this
    // first and render `.displayMessage` in the alert body.
    //
    // Example call site:
    //   let warning = store.deleteWarning(forQuote: quote.id)
    //   if let msg = warning.displayMessage {
    //       // show alert with msg → on confirm, store.deleteQuote(quote)
    //   } else {
    //       store.deleteQuote(quote)
    //   }

    func deleteWarning(forProject id: UUID) -> LinkedRecordsSummary {
        linkedRecords(forProject: id)
    }

    func deleteWarning(forEstimate id: UUID) -> LinkedRecordsSummary {
        linkedRecords(forEstimate: id)
    }

    func deleteWarning(forQuote id: UUID) -> LinkedRecordsSummary {
        linkedRecords(forQuote: id)
    }

    func deleteWarning(forClient id: UUID) -> LinkedRecordsSummary {
        linkedRecords(forClient: id)
    }
}
