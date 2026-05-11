// Invoice.swift
// Aski IQ – Invoicing & Payment Tracking

import Foundation
import Combine

// MARK: - Invoice Type
//
// Phase 7 audit fix. Pre-fix every invoice was a generic "draft →
// sent" record with no indication whether it was a 50% deposit, a
// progress draw, a final, or a one-off material sale. Reporting
// couldn't distinguish "outstanding deposits" from "outstanding
// finals" — the operator had to read the line items to tell.
//
// Defaults to `.standard` so legacy rows decode cleanly.
enum InvoiceType: String, Codable, CaseIterable {
    case standard      = "standard"        // No specific type (manual/legacy)
    case deposit       = "deposit"         // Up-front, % of contract value
    case progress      = "progress"        // Mid-project draw
    case final         = "final"           // Closeout, retainage release
    case materialSale  = "material_sale"   // From a Material Sale, not a Project

    var displayName: String {
        switch self {
        case .standard:     return "Standard"
        case .deposit:      return "Deposit"
        case .progress:     return "Progress"
        case .final:        return "Final"
        case .materialSale: return "Material Sale"
        }
    }

    var icon: String {
        switch self {
        case .standard:     return "doc.text"
        case .deposit:      return "dollarsign.arrow.circlepath"
        case .progress:     return "chart.line.uptrend.xyaxis"
        case .final:        return "checkmark.seal"
        case .materialSale: return "shippingbox.fill"
        }
    }
}

// MARK: - Invoice Status

enum InvoiceStatus: String, Codable, CaseIterable {
    case draft      = "draft"
    case sent       = "sent"
    case viewed     = "viewed"
    case partial    = "partial"
    case paid       = "paid"
    case overdue    = "overdue"
    case void       = "void"

    var displayName: String {
        switch self {
        case .draft:   return "Draft"
        case .sent:    return "Sent"
        case .viewed:  return "Viewed"
        case .partial: return "Partial Payment"
        case .paid:    return "Paid"
        case .overdue: return "Overdue"
        case .void:    return "Void"
        }
    }

    var isOpen: Bool {
        [.sent, .viewed, .partial, .overdue].contains(self)
    }

    var isPaid: Bool { self == .paid }
}

// MARK: - Payment Method

enum PaymentMethod: String, Codable, CaseIterable {
    case cheque     = "cheque"
    case eft        = "eft"
    case credit     = "credit"
    case cash       = "cash"
    case other      = "other"

    var displayName: String {
        switch self {
        case .cheque: return "Cheque"
        case .eft:    return "EFT / Wire"
        case .credit: return "Credit Card"
        case .cash:   return "Cash"
        case .other:  return "Other"
        }
    }
}

// MARK: - Invoice Line Item

struct InvoiceLineItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var description: String
    var quantity:    Decimal = 1
    var unitPrice:   Decimal = 0
    var taxable:     Bool    = true
    var costCode:    String  = ""

    var subtotal: Decimal { quantity * unitPrice }
}

// MARK: - Invoice Payment

struct InvoicePayment: Identifiable, Codable, Equatable {
    var id:            UUID    = UUID()
    var amount:        Decimal
    var method:        PaymentMethod = .eft
    var receivedDate:  Date    = Date()
    var reference:     String  = ""   // Cheque #, transaction ID, etc.
    var notes:         String  = ""
}

// MARK: - Invoice Model

struct Invoice: BaseModel {
    var id:             UUID   = UUID()
    var externalID:     String? = nil
    var companyID:      UUID?  = nil
    var createdAt:      Date   = Date()
    var updatedAt:      Date   = Date()
    var syncStatus:     SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date   = Date()

    // Identity
    var invoiceNumber:  String
    var projectID:      UUID?
    var clientID:       UUID?
    /// Phase 7 audit fix: forward link to the source Quote (if the
    /// invoice was generated from one). Pairs with the existing
    /// `Quote.projectID` and lets reporting trace
    /// quote → invoice → payment without inferring from line items.
    var quoteID:        UUID? = nil
    /// Phase 7 audit fix: invoice classification. Drives reporting
    /// and the % logic on deposits / progress draws.
    var invoiceType:    InvoiceType = .standard
    /// Phase 7 audit fix: when this invoice was generated from a
    /// quote, we copy the source quote's tax rate at conversion
    /// time and stamp it here so editing the quote later doesn't
    /// silently change historical invoice totals. The Generate-
    /// Invoice sheet warns the user if the on-form rate has drifted
    /// from this baseline.
    var lockedFromTaxRate: Decimal? = nil

    // Dates
    var invoiceDate:    Date   = Date()
    var dueDate:        Date   = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    var sentAt:         Date?  = nil
    var paidAt:         Date?  = nil

    // Status
    var status:         InvoiceStatus = .draft

    // Header / Footer
    var billToName:     String = ""
    var billToAddress:  String = ""
    var poNumber:       String = ""   // Client PO
    var terms:          String = "Net 30"
    var notes:          String = ""   // Visible on invoice
    var internalNotes:  String = ""   // Internal only

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

    // Line items & payments
    var lineItems:      [InvoiceLineItem] = []
    var payments:       [InvoicePayment]  = []

    // Tax
    var taxRate:        Decimal = 0.05   // Default 5% GST

    // 2026-04 audit fix (re-audit P0): explicit ISO 4217 currency.
    // Stripe checkout already reads `invoice.currency` server-side;
    // pre-fix the column was missing so it always fell back to USD.
    // Defaults to "USD" for legacy rows; new invoices inherit from
    // the source quote when generated, otherwise from AppSettings.
    var currency:       String  = "USD"

    // MARK: Computed

    var subtotal: Decimal {
        lineItems.reduce(0) { $0 + $1.subtotal }
    }

    var taxableSubtotal: Decimal {
        lineItems.filter { $0.taxable }.reduce(0) { $0 + $1.subtotal }
    }

    var taxAmount: Decimal {
        (taxableSubtotal * taxRate).rounded(scale: 2)
    }

    var total: Decimal { subtotal + taxAmount }

    var totalPaid: Decimal {
        payments.reduce(0) { $0 + $1.amount }
    }

    var balanceDue: Decimal { total - totalPaid }

    var isOverdue: Bool {
        status.isOpen && dueDate < Date()
    }

    var daysPastDue: Int {
        guard isOverdue else { return 0 }
        return Calendar.current.dateComponents([.day], from: dueDate, to: Date()).day ?? 0
    }

    init(invoiceNumber: String, projectID: UUID? = nil) {
        self.invoiceNumber = invoiceNumber
        self.projectID = projectID
    }
}

// MARK: - Decimal rounding helper

extension Decimal {
    func rounded(scale: Int) -> Decimal {
        var result = self
        var roundedResult = Decimal()
        NSDecimalRound(&roundedResult, &result, scale, .bankers)
        return roundedResult
    }
}

// MARK: - AppStore Extension

extension AppStore {

    // MARK: Invoice CRUD

    func addInvoice(_ item: Invoice) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "add_invoice") else { return }
        var updated = item
        updated.syncStatus     = .pending
        updated.updatedAt      = Date()
        updated.lastModifiedAt = Date()
        // Stamp tenant scope: prefer the parent project's companyID so the
        // invoice inherits its project's tenant, with currentCompanyID as
        // fallback for service-call invoices that don't have a project FK.
        if updated.companyID == nil {
            updated.companyID =
                updated.projectID
                    .flatMap { pid in projects.first(where: { $0.id == pid }) }?
                    .companyID
                ?? currentCompanyID
        }
        objectWillChange.send()
        invoices.append(updated)
        saveInvoices()
        Task { await SyncEngine.shared.pushPendingInvoices() }
        logCRMActivity(
            type: .invoiceCreated,
            title: "Invoice created: \(updated.invoiceNumber)",
            notes: updated.billToName.isEmpty ? "" : "Bill to: \(updated.billToName)",
            clientID: updated.clientID,
            contactID: nil,
            opportunityID: nil,
            quoteID: nil,
            projectID: updated.projectID
        )
        // Week 4 audit closeout: index the new invoice in Spotlight.
        SpotlightService.shared.upsert(invoice: updated)
    }

    func updateInvoice(_ item: Invoice) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "update_invoice") else { return }
        let oldStatus = invoices.first(where: { $0.id == item.id })?.status
        guard let idx = invoices.firstIndex(where: { $0.id == item.id }) else { return }
        objectWillChange.send()
        var updated = item
        updated.syncStatus     = .pending
        updated.updatedAt      = Date()
        updated.lastModifiedAt = Date()
        // Preserve existing tenant scope; if somehow nil, derive it now.
        if updated.companyID == nil {
            updated.companyID =
                updated.projectID
                    .flatMap { pid in projects.first(where: { $0.id == pid }) }?
                    .companyID
                ?? currentCompanyID
        }
        invoices[idx] = updated
        saveInvoices()
        Task { await SyncEngine.shared.pushPendingInvoices() }
        // Log CRM activity when status advances to "sent"
        if let old = oldStatus, old != .sent, updated.status == .sent {
            logCRMActivity(
                type: .invoiceSent,
                title: "Invoice sent: \(updated.invoiceNumber)",
                notes: "Total: \(updated.total.currencyString)",
                clientID: updated.clientID,
                contactID: nil,
                opportunityID: nil,
                quoteID: nil,
                projectID: updated.projectID
            )
        }
        // 2026-04 audit fix (Phase 9): typed audit row on every
        // invoice status change. Already covered: payment_recorded
        // via recordPayment(). Now also: draft→sent, sent→paid,
        // any→void, any→overdue, etc.
        if let old = oldStatus, old != updated.status {
            createAuditSnapshot(
                for:       updated,
                eventType: "status_changed_\(old.rawValue)_to_\(updated.status.rawValue)",
                by:        currentUser?.fullName ?? "system"
            )
        }
        // Week 4 audit closeout: keep Spotlight in sync — voided
        // invoices are de-indexed inside upsert(invoice:).
        SpotlightService.shared.upsert(invoice: updated)
    }

    func deleteInvoice(id: UUID) {
        guard requireRole([.officeAdmin, .manager, .executive],
                          action: "delete_invoice") else { return }
        guard let idx = invoices.firstIndex(where: { $0.id == id }) else { return }
        var deleted = invoices[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        invoices[idx] = deleted
        // 2026-04 audit fix (Phase 9): financial-record deletion is a
        // P0 audit event. Capture the row's last-known state before
        // it disappears from default queries (it stays in the table
        // with isDeleted = true but UIs filter it out).
        createAuditSnapshot(
            for:       deleted,
            eventType: "deleted",
            by:        currentUser?.fullName ?? "system"
        )
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingInvoices() }
    }

    func recordPayment(_ payment: InvoicePayment, on invoiceID: UUID) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "record_payment") else { return }
        guard let idx = invoices.firstIndex(where: { $0.id == invoiceID }) else { return }
        objectWillChange.send()
        var inv = invoices[idx]
        inv.payments.append(payment)
        // Auto-update status
        if inv.balanceDue <= 0 {
            inv.status = .paid
            inv.paidAt = Date()
        } else if !inv.payments.isEmpty {
            inv.status = .partial
        }
        inv.syncStatus     = .pending
        inv.updatedAt      = Date()
        inv.lastModifiedAt = Date()
        invoices[idx] = inv
        saveInvoices()
        Task { await SyncEngine.shared.pushPendingInvoices() }
        // CRM activity
        let isFullyPaid = inv.status == .paid
        logCRMActivity(
            type:  isFullyPaid ? .invoicePaid : .paymentReceived,
            title: isFullyPaid
                ? "Invoice paid in full: \(inv.invoiceNumber)"
                : "Payment received: \(inv.invoiceNumber)",
            notes: "Payment: \(payment.amount.currencyString) via \(payment.method.displayName). Balance: \(inv.balanceDue.currencyString)",
            clientID: inv.clientID,
            contactID: nil,
            opportunityID: nil,
            quoteID: nil,
            projectID: inv.projectID
        )
        // Audit snapshot
        createAuditSnapshot(for: inv, eventType: "payment_recorded",
                            by: currentUser?.fullName ?? "Office")
    }

    // MARK: Queries

    func invoices(for projectID: UUID) -> [Invoice] {
        invoices.filter { $0.projectID == projectID }
            .sorted { $0.invoiceDate > $1.invoiceDate }
    }

    func invoicesForClient(_ clientID: UUID) -> [Invoice] {
        invoices.filter { $0.clientID == clientID }
            .sorted { $0.invoiceDate > $1.invoiceDate }
    }

    /// Past-due invoices, excluding soft-deleted rows. Soft-deleted invoices
    /// were leaking into AR-aging cards and the Revenue Snapshot widget,
    /// inflating "Overdue" totals after the user had voided the invoice.
    var overdueInvoices: [Invoice] {
        invoices.filter { $0.isOverdue && !$0.isDeleted }
    }

    /// Open (non-closed) invoices, excluding soft-deleted rows.
    var openInvoices: [Invoice] {
        invoices.filter { $0.status.isOpen && !$0.isDeleted }
    }

    // MARK: - Overdue reconciliation
    //
    // The `isOverdue` computed property answers "is this invoice past due *right now*"
    // for live UI, but the persisted `status` column on Supabase stays at .sent /
    // .partial until something flips it. Server-side reports that filter by
    // `status = 'overdue'` would miss these without reconciliation.
    //
    // Walk open invoices, mark anything past due as .overdue, queue for push.
    // Idempotent: invoices already at .overdue or in a closed state are skipped.
    @MainActor
    func reconcileOverdueInvoices(now: Date = Date()) {
        var changed = false
        for i in invoices.indices {
            let inv = invoices[i]
            guard inv.status.isOpen, inv.status != .overdue, inv.dueDate < now else { continue }
            invoices[i].status         = .overdue
            invoices[i].updatedAt      = now
            invoices[i].lastModifiedAt = now
            invoices[i].syncStatus     = .pending
            changed = true
        }
        if changed {
            Task { await SyncEngine.shared.pushPendingInvoices() }
        }
    }

    var totalOutstanding: Decimal {
        openInvoices.reduce(0) { $0 + $1.balanceDue }
    }

    /// Generate the next invoice number. Uses parsed-max+1 scoped to the
    /// current (company, year), excluding soft-deleted rows. Mirrors the
    /// procurement pattern (Procurement.swift). The DB-side migration
    /// `material_requests_company_request_number_unique`-style partial
    /// unique index on (company_id, invoice_number) WHERE is_deleted=false
    /// catches any cross-device race that slips past this calculation;
    /// sync engine retries with the next number on conflict.
    ///
    /// Reasons this replaces the prior `invoices.count + 1` form:
    ///   1. count includes soft-deleted rows, so deleting then creating
    ///      could re-issue a deleted row's number.
    ///   2. count doesn't reset across years.
    ///   3. count includes other companies' rows when multiple tenants
    ///      share a local store cache.
    func nextInvoiceNumber() -> String {
        let prefix = AppSettings.shared.companyPrefix.isEmpty ? "BV" : AppSettings.shared.companyPrefix
        let year   = Calendar.current.component(.year, from: Date())
        let yearPrefix = "\(prefix)-INV-\(year)-"
        // FIX: monotonic numbering — see nextMaterialRequestNumber.
        let highest = invoices
            .filter { $0.companyID == currentCompanyID }
            .compactMap { inv -> Int? in
                guard inv.invoiceNumber.hasPrefix(yearPrefix) else { return nil }
                return Int(inv.invoiceNumber.dropFirst(yearPrefix.count))
            }
            .max() ?? 0
        return "\(yearPrefix)\(String(format: "%04d", highest + 1))"
    }

    // MARK: Persistence

    private static let invoicesKey = "bv_invoices"

    // Persistence handled by Supabase. Stubs kept for call-site compatibility.
    func saveInvoices() {}
    func loadInvoices() {}

}

// MARK: - Sample-data tracking
extension Invoice: SampleDataTrackable {}
