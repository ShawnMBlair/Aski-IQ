// Procurement.swift
// Aski IQ – Materials & Purchase Order Tracking

import Foundation
import Combine

// MARK: - Enums

/// Where the requested materials are headed. Drives which downstream
/// owner the MR (and any auto-generated PDF / docs) attaches to.
/// Mirrors the DB enum `material_request_destination_type` from
/// SupabaseMigration_MaterialRequestWorkflow.sql.
enum MaterialRequestDestinationType: String, Codable, CaseIterable {
    case project        = "project"
    case materialSale   = "material_sales"
    case internalUse    = "internal"   // `internal` is a Swift keyword — use `internalUse`

    var displayName: String {
        switch self {
        case .project:      return "Project"
        case .materialSale: return "Material Sale"
        case .internalUse:  return "Internal / Yard"
        }
    }
}

enum MaterialRequestStatus: String, Codable, CaseIterable {
    case draft      = "draft"
    case submitted  = "submitted"
    case pending    = "pending"     // DB-only future routing — Swift never emits
    case approved   = "approved"
    case rejected   = "rejected"   // approver declined; terminal
    case ordered    = "ordered"
    case partial    = "partial"
    case delivered  = "delivered"
    case closed     = "closed"      // DB-only future close-out — Swift never emits
    case cancelled  = "cancelled"

    var displayName: String {
        switch self {
        case .draft:     return "Draft"
        case .submitted: return "Submitted"
        case .pending:   return "Pending"
        case .approved:  return "Approved"
        case .rejected:  return "Rejected"
        case .ordered:   return "Ordered"
        case .partial:   return "Partial"
        case .delivered: return "Delivered"
        case .closed:    return "Closed"
        case .cancelled: return "Cancelled"
        }
    }

    var isOpen: Bool {
        // Rejected joins delivered/closed/cancelled in the closed set —
        // once an approver declines, the request is terminal. The requester
        // creates a new MR if they want to try again with revisions.
        // .pending is treated as open (transient routing state).
        [.submitted, .pending, .approved, .ordered, .partial].contains(self)
    }

    /// Defensive Decodable: the DB enum carries values the Swift app
    /// doesn't emit but might receive on pull (future-routing flows
    /// added in the migration's section 1). Map an unknown rawValue
    /// to .draft so a single unexpected row never fails the whole
    /// pull cycle. Logged so analytics can spot drift between Swift
    /// and the DB enum.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let known = MaterialRequestStatus(rawValue: raw) {
            self = known
        } else {
            print("⚠️ MaterialRequestStatus: unknown raw value '\(raw)' — defaulting to .draft")
            self = .draft
        }
    }
}

enum POStatus: String, Codable, CaseIterable {
    case draft      = "draft"
    case sent       = "sent"
    case confirmed  = "confirmed"
    case partial    = "partial"
    case received   = "received"
    case closed     = "closed"
    case cancelled  = "cancelled"

    var displayName: String {
        switch self {
        case .draft:     return "Draft"
        case .sent:      return "Sent"
        case .confirmed: return "Confirmed"
        case .partial:   return "Partial Receipt"
        case .received:  return "Fully Received"
        case .closed:    return "Closed"
        case .cancelled: return "Cancelled"
        }
    }

    var isOpen: Bool {
        [.sent, .confirmed, .partial].contains(self)
    }
}

enum UnitOfMeasure: String, Codable, CaseIterable {
    case each       = "ea"
    case linearFt   = "lf"
    case sqFt       = "sqft"
    case cuYd       = "cy"
    case tonne      = "tonne"
    case kg         = "kg"
    case lb         = "lb"
    case bag        = "bag"
    case pallet     = "pallet"
    case litre      = "L"
    case gallon     = "gal"
    case bundle     = "bundle"
    case sheet      = "sheet"
    case other      = "other"

    var displayName: String { rawValue }
}

// MARK: - Material Request Line Item

struct MaterialLineItem: Identifiable, Codable, Equatable {
    var id:                UUID    = UUID()
    var description:       String
    var quantity:          Decimal = 1
    var quantityReceived:  Decimal = 0   // Set by the Receive sheet on delivery
    var quantityInvoiced:  Decimal = 0   // Set by the Invoice Match sheet
    var unit:              UnitOfMeasure = .each
    var unitCost:          Decimal = 0
    var costCode:          String  = ""
    var notes:             String  = ""

    var totalCost: Decimal { (quantity * unitCost).rounded(scale: 2) }

    /// True when the receiver has marked the full quantity received. Used by
    /// the MR-level status rollup: any < requested qty → .partial, all == →
    /// .delivered.
    var isFullyReceived: Bool { quantityReceived >= quantity }

    /// True when at least some has been received but not all. Drives the
    /// "Partial Receipt" status badge on rolled-up MRs.
    var isPartiallyReceived: Bool {
        quantityReceived > 0 && quantityReceived < quantity
    }

    /// Variance between received and invoiced quantities. Positive value
    /// = supplier billed for more than was actually delivered (overcharge);
    /// negative = supplier under-billed. Drives the variance flag on the
    /// 3-way Invoice Match comparison.
    var invoiceVariance: Decimal { quantityInvoiced - quantityReceived }
}

// MARK: - Material Request

struct MaterialRequest: Identifiable, Codable, Equatable {
    var id:              UUID   = UUID()
    var companyID:       UUID?  = nil
    var createdAt:       Date   = Date()
    var updatedAt:       Date   = Date()
    var syncStatus:      SyncStatus = .local

    // Identity
    var requestNumber:   String
    var projectID:       UUID?
    var requestedByID:   UUID?
    var requestedByName: String = ""
    /// Email of the person making the request. Auto-filled from the
    /// selected employee record (Employee.email) when the picker is used,
    /// editable directly when "Other" is selected. Optional because not
    /// every employee has an email on file (field workers / subs). When
    /// present, downstream flows can CC the requester on supplier dispatch
    /// and send approval-status notifications without dragging in a
    /// separate email lookup.
    var requestedByEmail: String? = nil

    // Dates
    var requestDate:     Date   = Date()
    var requiredByDate:  Date?  = nil

    // Status
    var status:          MaterialRequestStatus = .draft

    // Destination — drives where the approved MR + PDF land.
    // `.project` requires projectID; `.materialSale` requires materialSaleID;
    // `.internalUse` leaves both nil. Enforced server-side by
    // material_requests_single_destination_check.
    var destinationType: MaterialRequestDestinationType = .internalUse
    var materialSaleID:  UUID? = nil

    // Procurement target
    var supplierID:      UUID? = nil

    // Content
    var lineItems:       [MaterialLineItem] = []
    var notes:           String = ""
    var siteLocation:    String = ""   // Where on site the materials are needed

    // Approval — audit fields mirroring SupabaseMigration_MaterialRequestWorkflow.sql
    // The DB trigger log_material_request_status_change writes these into
    // material_request_audit on every status flip.
    var submittedByID:   UUID?  = nil
    var submittedAt:     Date?  = nil
    var approvedByID:    UUID?  = nil
    var approvedByName:  String = ""
    var approvedAt:      Date?  = nil
    var approvalNote:    String = ""
    var orderedAt:       Date?  = nil
    var receivedByID:    UUID?  = nil
    var receivedAt:      Date?  = nil
    var closedAt:        Date?  = nil

    // Linked PO
    var purchaseOrderID: UUID? = nil

    // PDF generated on approval. Filename is the ProjectDocument's
    // storedFileName (UUID.pdf in app Documents/) — not a Supabase Storage
    // path. Held here so the MR audit log can show "PDF generated at …".
    // Stays in sync with the matching ProjectDocument record so deleting one
    // through the doc grid doesn't leave the MR pointing at a phantom file.
    var pdfStoragePath:  String? = nil
    var pdfGeneratedAt:  Date?   = nil

    // Delivery proof photo. Storage path inside the `contracts` bucket
    // (re-used because its RLS already scopes by company_id-leading
    // folder). Required for final .delivered status — receivers can save
    // partials without it but cannot fully close out a request without
    // photographic proof of the delivery.
    var deliveryPhotoURL: String? = nil

    // Reference document scanned at request time — supplier quote, paper
    // receipt, hand-written list. Captured via VisionKit's document
    // scanner, multi-page, saved as a single PDF in the `contracts`
    // bucket alongside delivery photos. Optional; kept as a separate
    // field from deliveryPhotoURL because the two represent different
    // moments in the workflow (creation vs receipt) and operators want
    // to see them in different sections of the detail view.
    var receiptScanPath: String? = nil

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

    // Computed
    var estimatedTotal: Decimal {
        lineItems.reduce(0) { $0 + $1.totalCost }
    }

    init(requestNumber: String, projectID: UUID? = nil) {
        self.requestNumber = requestNumber
        self.projectID     = projectID
    }
}

// MARK: - Supplier

struct Supplier: Identifiable, Codable, Equatable {
    var id:              UUID        = UUID()
    var companyID:       UUID?       = nil
    var createdAt:       Date        = Date()
    var updatedAt:       Date        = Date()
    var syncStatus:      SyncStatus  = .local
    var lastModifiedBy:  String      = ""
    var lastModifiedAt:  Date        = Date()
    var name:            String
    var contactName:     String = ""
    var phone:           String = ""
    var email:           String = ""
    var address:         String = ""
    var accountNumber:   String = ""
    var notes:           String = ""
    var isPreferred:     Bool   = false
    var categories:      [String] = []   // e.g. ["Lumber", "Concrete", "Electrical"]

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

    init(name: String) { self.name = name }
}

// MARK: - Purchase Order

struct PurchaseOrder: Identifiable, Codable, Equatable {
    var id:            UUID   = UUID()
    var companyID:     UUID?  = nil
    var createdAt:     Date   = Date()
    var updatedAt:     Date   = Date()
    var syncStatus:    SyncStatus = .local

    // Identity
    var poNumber:      String
    var projectID:     UUID?
    var supplierID:    UUID?
    var supplierName:  String = ""

    // Dates
    var issueDate:     Date   = Date()
    var requiredDate:  Date?  = nil
    var receivedDate:  Date?  = nil

    // Status
    var status:        POStatus = .draft

    // Linked request
    var materialRequestID: UUID? = nil

    // Content
    var lineItems:     [MaterialLineItem] = []
    var deliveryAddress: String = ""
    var terms:         String = ""
    var notes:         String = ""
    var internalNotes: String = ""

    // Delivery proof — Supabase Storage path inside the `contracts`
    // bucket (re-uses the same path layout as MaterialRequest deliveries).
    // Required for the final .received status; partial receives can save
    // line-item progress without one. See receivePurchaseOrder above.
    var deliveryPhotoURL: String? = nil

    // Supplier invoice tracking (Phase 3 — invoice 3-way matching).
    // Populated by AppStore.matchInvoice + the Invoice Match sheet.
    // invoiceAmount can differ from `total` when the supplier's invoice
    // includes adjustments (extra charges, rebates, partial fills).
    var invoiceNumber:    String? = nil
    var invoiceDate:      Date?   = nil
    var invoiceAmount:    Decimal? = nil
    var invoiceScanPath:  String? = nil   // Supabase Storage path
    var invoiceMatchedAt: Date?   = nil
    var invoiceMatchedBy: UUID?   = nil
    var invoiceMatchNote: String? = nil   // approver context, e.g. "approved despite +$50 freight"
    var invoiceFlagged:   Bool    = false // true when matcher flagged a variance for follow-up

    // Tax
    var taxRate:       Decimal = 0.05

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

    // Computed
    var subtotal: Decimal {
        lineItems.reduce(0) { $0 + $1.totalCost }
    }
    var taxAmount: Decimal {
        (subtotal * taxRate).rounded(scale: 2)
    }
    var total: Decimal { subtotal + taxAmount }

    init(poNumber: String, projectID: UUID? = nil) {
        self.poNumber  = poNumber
        self.projectID = projectID
    }
}

// MARK: - AppStore Extension

extension AppStore {

    // MARK: Material Request CRUD

    func addMaterialRequest(_ item: MaterialRequest) {
        guard requireRole([.fieldWorker, .foreman, .projectManager, .officeAdmin, .manager, .executive],
                          action: "add_material_request") else { return }
        var new = item
        if new.companyID == nil { new.companyID = currentCompanyID }
        new.syncStatus = .pending
        new.updatedAt  = Date()
        objectWillChange.send()
        materialRequests.append(new)
        Task { await SyncEngine.shared.pushPendingMaterialRequests() }
    }

    func updateMaterialRequest(_ item: MaterialRequest) {
        guard requireRole([.fieldWorker, .foreman, .projectManager, .officeAdmin, .manager, .executive],
                          action: "update_material_request") else { return }
        guard let idx = materialRequests.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = item
        if updated.companyID == nil { updated.companyID = currentCompanyID }
        updated.syncStatus = .pending
        updated.updatedAt  = Date()
        objectWillChange.send()
        materialRequests[idx] = updated
        Task { await SyncEngine.shared.pushPendingMaterialRequests() }
    }

    func deleteMaterialRequest(id: UUID) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "delete_material_request") else { return }
        guard let idx = materialRequests.firstIndex(where: { $0.id == id }) else { return }
        var deleted = materialRequests[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        materialRequests[idx] = deleted
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingMaterialRequests() }
    }

    /// Submit a draft request for approval. Stamps the submitting user so
    /// the audit log can show "Submitted by X on Y" and the approver knows
    /// who's behind the request when supplier instructions need clarifying.
    ///
    /// FUTURE — INVENTORY HOOK (Phase 2)
    ///   Per the procurement rebuild plan, before submission the request
    ///   should be checked against on-hand inventory. If the items exist
    ///   in stock, suggest "Use Inventory Transfer" instead of buying new.
    ///   The inventory module is intentionally not built in Phase 1 (large
    ///   separate scope: stock levels, transfers, locations, reservations).
    ///   When it lands, the suggested integration point is here — call
    ///   `InventoryService.shared.checkAvailability(for: request)` and
    ///   surface the suggestion via a toast / alert before the .submitted
    ///   transition fires. The duplicate-request warning (UI side, in
    ///   MRDetailView.attemptSubmit) is a similar pattern — model the
    ///   inventory check the same way.
    func submitMaterialRequest(_ request: MaterialRequest) {
        guard requireRole([.fieldWorker, .foreman, .projectManager, .officeAdmin, .manager, .executive],
                          action: "submit_material_request") else { return }
        guard let idx = materialRequests.firstIndex(where: { $0.id == request.id }) else { return }
        var updated = request
        updated.status         = .submitted
        updated.submittedByID  = currentUser?.id
        updated.submittedAt    = Date()
        updated.updatedAt      = Date()
        updated.syncStatus     = .pending
        objectWillChange.send()
        materialRequests[idx]  = updated
        Task { await SyncEngine.shared.pushPendingMaterialRequests() }
    }

    /// Approve a submitted request. The optional note is stored on the row
    /// (mirrors approval_note in workflow_settings — visible in audit log
    /// metadata so approvers can leave context like "approved subject to
    /// supplier confirming delivery date").
    /// Side effect: triggers MaterialRequestPDFGenerator.generateAndAttach
    /// which renders the approval PDF and registers it on the destination's
    /// document grid. Wrapped in #if canImport(UIKit) because the renderer
    /// is iOS-only.
    func approveMaterialRequest(_ request: MaterialRequest, note: String = "") {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "approve_material_request") else { return }
        guard let idx = materialRequests.firstIndex(where: { $0.id == request.id }) else { return }
        var updated = request
        updated.status         = .approved
        updated.approvedByID   = currentUser?.id
        updated.approvedByName = currentUser?.fullName ?? "Office"
        updated.approvedAt     = Date()
        updated.approvalNote   = note
        updated.updatedAt      = Date()
        updated.syncStatus     = .pending
        objectWillChange.send()
        materialRequests[idx]  = updated
        Task { await SyncEngine.shared.pushPendingMaterialRequests() }
        // Generate the approval PDF + attach to the destination doc grid.
        // The generator handles all the destination_type routing and
        // overwrites any prior auto-generated copy on re-approval.
        #if canImport(UIKit)
        MaterialRequestPDFGenerator.shared.generateAndAttach(for: updated, store: self)
        #endif

        // Auto-create a draft PO when the MR has a supplier set. The PO
        // starts in .draft so the manager reviews + sends manually — we do
        // NOT auto-dispatch to the supplier. No-ops if the MR is supplier-
        // less (caller picks one and uses the Create PO action instead).
        if let po = createPODraftFromApprovedRequest(updated) {
            ToastService.shared.success("Approved — PO \(po.poNumber) drafted for \(po.supplierName).")
        } else if updated.supplierID == nil {
            ToastService.shared.success("Approved — pick a supplier to draft a PO.")
        } else {
            ToastService.shared.success("Approved.")
        }
    }

    /// Reject a submitted request. Terminal action — once rejected, the
    /// requester creates a new MR if they want to re-pitch with changes.
    /// `reason` is stored on `approvalNote` (re-using the field; the
    /// audit row's status_changed event tells you it was a rejection).
    /// Same role gate as approve so the same set of users can do either.
    func rejectMaterialRequest(_ request: MaterialRequest, reason: String) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "reject_material_request") else { return }
        guard let idx = materialRequests.firstIndex(where: { $0.id == request.id }) else { return }
        var updated = request
        updated.status         = .rejected
        updated.approvedByID   = currentUser?.id   // who actioned, even though it's a rejection
        updated.approvedByName = currentUser?.fullName ?? "Office"
        updated.approvedAt     = Date()
        updated.approvalNote   = reason
        updated.updatedAt      = Date()
        updated.syncStatus     = .pending
        objectWillChange.send()
        materialRequests[idx]  = updated
        Task { await SyncEngine.shared.pushPendingMaterialRequests() }
    }

    /// Send a submitted request back to the requester for changes. NOT a
    /// rejection — flips status .submitted → .draft so the requester can
    /// edit and resubmit. The reviewer's notes are stored on
    /// `approvalNote` so the requester sees what to change. The audit row
    /// captures the status flip for accountability.
    func requestChangesOnMaterialRequest(_ request: MaterialRequest, notes: String) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "request_changes_material_request") else { return }
        guard let idx = materialRequests.firstIndex(where: { $0.id == request.id }) else { return }
        var updated = request
        updated.status         = .draft
        updated.approvalNote   = notes   // visible to requester on edit
        // Clear submission stamps so the audit row's old/new status flip
        // (.submitted → .draft) reads cleanly. We DON'T clear approvedAt
        // / approvedByID because there was no approval to revoke.
        updated.submittedAt    = nil
        updated.updatedAt      = Date()
        updated.syncStatus     = .pending
        objectWillChange.send()
        materialRequests[idx]  = updated
        Task { await SyncEngine.shared.pushPendingMaterialRequests() }
    }

    /// Mark a request as ordered with a supplier. Called after the PO is
    /// dispatched. Stamps `orderedAt` so the audit log can compute
    /// approve→order latency.
    func markMaterialRequestOrdered(_ request: MaterialRequest) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "order_material_request") else { return }
        guard let idx = materialRequests.firstIndex(where: { $0.id == request.id }) else { return }
        var updated = request
        updated.status      = .ordered
        updated.orderedAt   = Date()
        updated.updatedAt   = Date()
        updated.syncStatus  = .pending
        objectWillChange.send()
        materialRequests[idx] = updated
        Task { await SyncEngine.shared.pushPendingMaterialRequests() }
    }

    /// Mark a request as received on site with line-item-level granularity.
    /// `receivedQuantities` maps line item ID → quantity actually delivered.
    /// Status rolls up automatically: all items fully received → .delivered;
    /// any received but some short → .partial; none received → no status
    /// change (caller likely meant to cancel, not receive 0).
    ///
    /// `deliveryPhotoURL` is the Supabase Storage path returned by
    /// DeliveryPhotoService — stamped on the row when present, ignored when
    /// nil. Final `.delivered` status is BLOCKED without a photo (either
    /// freshly-uploaded or already on the row from a prior partial receive).
    /// Partial receives can proceed without a photo so the receiver isn't
    /// stuck on a tarmac with bad cell coverage.
    ///
    /// The field worker / foreman who physically signs for the delivery is
    /// stamped on the row so the audit log can show chain-of-custody for
    /// compliance. `receivedAt` is only stamped on the FINAL transition to
    /// .delivered so analytics can compute true ordered→delivered latency.
    ///
    /// Returns true on success, false when blocked by validation (missing
    /// photo for delivery). Caller should toast on false.
    @discardableResult
    func receiveMaterialRequest(
        _ request: MaterialRequest,
        receivedQuantities: [UUID: Decimal],
        deliveryPhotoURL: String? = nil
    ) -> Bool {
        guard requireRole([.fieldWorker, .foreman, .projectManager, .officeAdmin, .manager, .executive],
                          action: "receive_material_request") else { return false }
        guard let idx = materialRequests.firstIndex(where: { $0.id == request.id }) else { return false }
        var updated = request
        // Apply per-line received quantities. Any item missing from the map
        // keeps its existing quantityReceived — partial deliveries stack
        // additively across multiple receive events.
        updated.lineItems = updated.lineItems.map { item in
            var copy = item
            if let qty = receivedQuantities[item.id] {
                copy.quantityReceived = qty
            }
            return copy
        }
        let allReceived = !updated.lineItems.isEmpty
            && updated.lineItems.allSatisfy { $0.isFullyReceived }
        let anyReceived = updated.lineItems.contains { $0.quantityReceived > 0 }

        // Stamp the new photo URL up-front so the .delivered guard can
        // see it — covers the case where the receiver uploads + finalizes
        // in a single tap.
        if let url = deliveryPhotoURL {
            updated.deliveryPhotoURL = url
        }

        if allReceived {
            // Photo gate — block the .delivered transition without one.
            // Falls through as a partial-style update (line items are still
            // saved) so the receiver doesn't lose their entered quantities.
            guard updated.deliveryPhotoURL?.isEmpty == false else {
                ToastService.shared.error("Add a photo of the delivery before marking as Received.")
                // Save line-item progress as .partial so the qty entries
                // aren't lost — the receiver can re-open and try again
                // after capturing the photo.
                updated.status = anyReceived ? .partial : updated.status
                updated.receivedByID = currentUser?.id
                updated.updatedAt    = Date()
                updated.syncStatus   = .pending
                objectWillChange.send()
                materialRequests[idx] = updated
                Task { await SyncEngine.shared.pushPendingMaterialRequests() }
                return false
            }
            updated.status     = .delivered
            updated.receivedAt = Date()
        } else if anyReceived {
            updated.status     = .partial
            // receivedAt left unset until the final delivery rolls in
        }
        updated.receivedByID = currentUser?.id
        updated.updatedAt    = Date()
        updated.syncStatus   = .pending
        objectWillChange.send()
        materialRequests[idx] = updated
        Task { await SyncEngine.shared.pushPendingMaterialRequests() }
        // Mirror state onto the linked PO (no-op if not linked).
        propagateReceiveToLinkedPO(from: updated)
        return true
    }

    // MARK: Material Request Queries

    func materialRequests(for projectID: UUID) -> [MaterialRequest] {
        materialRequests.filter { $0.projectID == projectID }
            .sorted { $0.requestDate > $1.requestDate }
    }

    var openMaterialRequests: [MaterialRequest] {
        materialRequests.filter { $0.status.isOpen }
    }

    var pendingMaterialApprovals: [MaterialRequest] {
        materialRequests.filter { $0.status == .submitted && !$0.isDeleted }
    }

    // MARK: Procurement Hub pipeline groupings
    // Power the unified Procurement Hub dashboard. Each grouping mirrors a
    // section in the operator's mental model of the procurement pipeline:
    // Draft → Pending → Approved → Ordered → Partial → Received → Closed.
    // Filtering once here means the Hub doesn't refilter on every render.

    var draftMaterialRequests: [MaterialRequest] {
        materialRequests.filter { $0.status == .draft && !$0.isDeleted }
    }

    var approvedToOrderRequests: [MaterialRequest] {
        // Approved but no PO sent yet — these are the ones that need a
        // "Send to Supplier" or "Create PO" action.
        materialRequests.filter { $0.status == .approved && !$0.isDeleted }
    }

    var orderedMaterialRequests: [MaterialRequest] {
        materialRequests.filter { $0.status == .ordered && !$0.isDeleted }
    }

    var partiallyReceivedRequests: [MaterialRequest] {
        materialRequests.filter { $0.status == .partial && !$0.isDeleted }
    }

    var deliveredMaterialRequests: [MaterialRequest] {
        materialRequests.filter { $0.status == .delivered && !$0.isDeleted }
    }

    /// Rejected requests for the Hub's Rejected pipeline section. Kept
    /// separate from cancelled so rejected (managerial decline) can be
    /// audited differently from cancelled (requester pulled it back).
    var rejectedMaterialRequests: [MaterialRequest] {
        materialRequests.filter { $0.status == .rejected && !$0.isDeleted }
    }

    /// POs with an invoice variance flag — needs human review before the
    /// procurement record can close. Drives the Hub's Invoice Review
    /// section in Phase 3.
    var posNeedingInvoiceReview: [PurchaseOrder] {
        purchaseOrders.filter { $0.invoiceFlagged && !$0.isDeleted }
    }

    /// POs that have been received but no invoice has been matched yet.
    /// These are the natural targets for the next "Match Invoice" action.
    var posReadyForInvoiceMatch: [PurchaseOrder] {
        purchaseOrders.filter {
            ($0.status == .received || $0.status == .partial)
                && $0.invoiceNumber == nil
                && !$0.isDeleted
        }
    }

    // MARK: Duplicate detection
    //
    // CONTRACT
    //   Find OPEN requests on the same destination that share at least one
    //   line-item description with the candidate. Used by the Submit flow
    //   to warn before sending a duplicate up the approval chain.
    //
    // MATCHING RULES
    //   • Same destination (project OR material sale).
    //     Internal-use requests skip duplicate checks — they're typically
    //     yard restocks where multiple parallel requests are normal.
    //   • Active status only (.submitted, .approved, .ordered, .partial).
    //     Draft excluded — drafts are by definition not yet "in the system."
    //     Delivered / closed / cancelled excluded — already resolved.
    //   • Item match: case-insensitive, whitespace-trimmed substring match
    //     on item description. Catches "2x4 lumber" matching "lumber 2x4"
    //     without requiring exact match. Imperfect — surface only as a
    //     warning, never block.
    //   • The candidate's own row is excluded from the result.
    //
    // RETURNS
    //   Newest first so the warning shows the most recent dup at the top.
    func similarOpenRequests(to candidate: MaterialRequest) -> [MaterialRequest] {
        guard candidate.destinationType != .internalUse else { return [] }
        let activeStatuses: Set<MaterialRequestStatus> =
            [.submitted, .approved, .ordered, .partial]
        // Pre-compute the candidate's normalized item descriptions once.
        let candidateDescriptions = Set(
            candidate.lineItems.map {
                $0.description.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            .filter { !$0.isEmpty }
        )
        guard !candidateDescriptions.isEmpty else { return [] }

        return materialRequests.filter { other in
            guard !other.isDeleted else { return false }
            guard other.id != candidate.id else { return false }
            guard activeStatuses.contains(other.status) else { return false }
            // Same destination (and matching ID — switching destination
            // type doesn't count as a duplicate of a project request).
            switch candidate.destinationType {
            case .project:
                guard other.destinationType == .project,
                      candidate.projectID != nil,
                      other.projectID == candidate.projectID else { return false }
            case .materialSale:
                guard other.destinationType == .materialSale,
                      candidate.materialSaleID != nil,
                      other.materialSaleID == candidate.materialSaleID else { return false }
            case .internalUse:
                return false
            }
            // At least one item description matches (substring either way
            // so "lumber 2x4" hits "2x4 lumber" and vice versa).
            return other.lineItems.contains { otherItem in
                let normalized = otherItem.description
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty else { return false }
                return candidateDescriptions.contains { c in
                    normalized.contains(c) || c.contains(normalized)
                }
            }
        }
        .sorted { $0.requestDate > $1.requestDate }
    }

    // MARK: Budget check (Phase 2 partial — soft warning, no hard gate)
    //
    // Computes how much of a project's approved material budget is
    // already committed across procurement records, and how much
    // remains. Drives the soft-warn alert on MR submission so a
    // requester sees "this would push the project $5k over budget" but
    // can still proceed (warn-don't-block — same philosophy as the
    // duplicate-request warning).
    //
    // RULES
    //   • Budget source: ProjectBudget.totalBudgeted for the project
    //     (lines + contingency). Returns nil when no budget exists.
    //   • Committed: sum of estimatedTotal across non-cancelled,
    //     non-rejected MRs on the project, plus standalone PO totals
    //     (POs without a linked MR — those that ARE linked already
    //     count via their parent MR's estimatedTotal).
    //   • Excludes: cancelled / rejected MRs, deleted records.
    //
    // INTENTIONAL LIMITATIONS
    //   • Cost-code-level budgets aren't checked — just the rolled-up
    //     total. A request for $10k of "Concrete" against a project
    //     with $50k budget passes even if the concrete cost-code line
    //     was only budgeted at $5k.
    //   • Doesn't account for change-order budget adjustments yet —
    //     follow-up once the CO module exposes a budget delta.

    /// Sum of all in-flight material commitments against a project.
    /// Used by availableMaterialBudget below; surfaces directly on the
    /// form when an operator wants to know how much has been committed.
    func committedMaterialAmount(for projectID: UUID) -> Decimal {
        let mrTotal = materialRequests
            .filter { mr in
                mr.projectID == projectID
                    && !mr.isDeleted
                    && mr.status != .cancelled
                    && mr.status != .rejected
            }
            .reduce(Decimal(0)) { $0 + $1.estimatedTotal }

        // Standalone POs only — POs auto-created from MRs would
        // double-count if included since their parent MR's estimatedTotal
        // already covers the same line items.
        let poTotal = purchaseOrders
            .filter { po in
                po.projectID == projectID
                    && po.materialRequestID == nil
                    && !po.isDeleted
                    && po.status != .cancelled
            }
            .reduce(Decimal(0)) { $0 + $1.total }

        return mrTotal + poTotal
    }

    /// Remaining material budget for a project. Returns nil when the
    /// project has no ProjectBudget on file (treat as "no budget set —
    /// no warning"). Negative when committed exceeds budget.
    func availableMaterialBudget(for projectID: UUID) -> Decimal? {
        guard let budget = projectBudgets.first(where: {
            $0.projectID == projectID && !$0.isDeleted
        }) else { return nil }
        return budget.totalBudgeted - committedMaterialAmount(for: projectID)
    }

    /// Requests requiring the *current user's* attention. Drives the badge
    /// on the dashboard's "My Queue" tile so each user sees only what they
    /// can act on, not the whole pipeline.
    var myProcurementQueue: [MaterialRequest] {
        materialRequests.filter { mr in
            guard !mr.isDeleted else { return false }
            switch mr.status {
            case .submitted:
                // In the approval queue if the user can approve this amount.
                return canApproveMaterialRequest(amount: mr.estimatedTotal)
            case .approved:
                // Ready-to-send items show for users who can dispatch them.
                return canSendToSupplier
            case .ordered, .partial:
                // Receive-ready items show for users authorized to receive.
                return canReceiveMaterials
            default:
                return false
            }
        }
    }

    /// Generate the next MR number. Parses the highest sequence already in
    /// use within the current (company, year) namespace and increments,
    /// rather than using `materialRequests.count + 1`. Three reasons:
    ///   1. count includes soft-deleted rows, so deleting then creating a
    ///      new MR could re-issue the deleted row's number.
    ///   2. count doesn't reset across years — BV-MR-2026-0500 was once
    ///      followed by BV-MR-2027-0501, not BV-MR-2027-0001.
    ///   3. count counts other companies' rows when multiple companies
    ///      share a local store cache.
    /// Cross-device race remains possible (two offline devices both
    /// at max=10 will both emit -0011); the migration's UNIQUE
    /// constraint on (company_id, request_number) catches that at the
    /// DB layer. Sync engine retries with the next number.
    func nextMaterialRequestNumber() -> String {
        let prefix = AppSettings.shared.companyPrefix.isEmpty ? "BV" : AppSettings.shared.companyPrefix
        let year   = Calendar.current.component(.year, from: Date())
        let yearPrefix = "\(prefix)-MR-\(year)-"
        let highest = materialRequests
            .filter { $0.companyID == currentCompanyID && !$0.isDeleted }
            .compactMap { mr -> Int? in
                guard mr.requestNumber.hasPrefix(yearPrefix) else { return nil }
                return Int(mr.requestNumber.dropFirst(yearPrefix.count))
            }
            .max() ?? 0
        return "\(yearPrefix)\(String(format: "%04d", highest + 1))"
    }

    // MARK: Purchase Order CRUD

    func addPurchaseOrder(_ item: PurchaseOrder) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "add_purchase_order") else { return }
        var new = item
        if new.companyID == nil { new.companyID = currentCompanyID }
        new.syncStatus = .pending
        new.updatedAt  = Date()
        objectWillChange.send()
        purchaseOrders.append(new)
        Task { await SyncEngine.shared.pushPendingPurchaseOrders() }
    }

    func updatePurchaseOrder(_ item: PurchaseOrder) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "update_purchase_order") else { return }
        guard let idx = purchaseOrders.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = item
        if updated.companyID == nil { updated.companyID = currentCompanyID }
        updated.syncStatus = .pending
        updated.updatedAt  = Date()
        objectWillChange.send()
        purchaseOrders[idx] = updated
        Task { await SyncEngine.shared.pushPendingPurchaseOrders() }
    }

    /// Receive a PO with per-line-item granularity. Mirrors the MR
    /// receive flow: status rolls up to `.received` when all lines are
    /// satisfied and a delivery photo is on file, `.partial` when some
    /// line is short OR no photo on a fully-received attempt (the
    /// quantities are still saved so the receiver doesn't lose work).
    ///
    /// PHOTO REQUIREMENT
    ///   Final `.received` status is BLOCKED without `deliveryPhotoURL`
    ///   (either freshly uploaded or already on the row). Partial
    ///   receives proceed without one — same field-friendly behavior
    ///   as the MR side.
    ///
    /// LINKED MR
    ///   Doesn't auto-propagate to the linked Material Request — the
    ///   MR's own receive flow is independent. Rationale: PO and MR
    ///   line items can drift apart after edits, so blindly mirroring
    ///   quantities risks corrupting the source-of-truth on either
    ///   side. Operators receive against whichever record represents
    ///   the canonical delivery (typically the PO).
    ///
    /// Returns true on success, false when blocked by validation.
    @discardableResult
    func receivePurchaseOrder(
        _ po: PurchaseOrder,
        receivedQuantities: [UUID: Decimal],
        deliveryPhotoURL: String? = nil
    ) -> Bool {
        guard requireRole([.fieldWorker, .foreman, .projectManager, .officeAdmin, .manager, .executive],
                          action: "receive_purchase_order") else { return false }
        guard let idx = purchaseOrders.firstIndex(where: { $0.id == po.id }) else { return false }
        var updated = po
        updated.lineItems = updated.lineItems.map { item in
            var copy = item
            if let qty = receivedQuantities[item.id] {
                copy.quantityReceived = qty
            }
            return copy
        }
        let allReceived = !updated.lineItems.isEmpty
            && updated.lineItems.allSatisfy { $0.isFullyReceived }
        let anyReceived = updated.lineItems.contains { $0.quantityReceived > 0 }

        if let url = deliveryPhotoURL {
            updated.deliveryPhotoURL = url
        }

        if allReceived {
            // Photo gate — same as MR side. Receivers can save partial
            // progress without it but cannot finalize without proof.
            guard updated.deliveryPhotoURL?.isEmpty == false else {
                ToastService.shared.error("Add a photo of the delivery before marking as Received.")
                updated.status     = anyReceived ? .partial : updated.status
                updated.updatedAt  = Date()
                updated.syncStatus = .pending
                objectWillChange.send()
                purchaseOrders[idx] = updated
                Task { await SyncEngine.shared.pushPendingPurchaseOrders() }
                return false
            }
            updated.status       = .received
            updated.receivedDate = Date()
        } else if anyReceived {
            updated.status = .partial
        }
        updated.updatedAt  = Date()
        updated.syncStatus = .pending
        objectWillChange.send()
        purchaseOrders[idx] = updated
        Task { await SyncEngine.shared.pushPendingPurchaseOrders() }
        // Mirror state onto the linked MR (no-op if not linked).
        propagateReceiveToLinkedMR(from: updated)
        return true
    }

    // MARK: Bidirectional receive propagation
    //
    // When PO and MR are linked (PO auto-created from MR's approval, or
    // a PO was retroactively connected via materialRequestID), receiving
    // one represents the same physical delivery — both records should
    // reflect it. These helpers run after the primary receive transition
    // so the audit trail on the source record is captured first, then
    // the linked record's transition fires its own audit row.
    //
    // SAFETY
    //   • Only propagates to records that are still "open" (waiting on
    //     delivery). Refuses to touch a closed MR/PO so a late receive
    //     doesn't reopen something that was administratively closed.
    //   • Quantity propagation only happens when line item IDs match
    //     1:1 between source and target — typically true when the PO
    //     was auto-created from the MR. When line items have diverged
    //     (manual edits on either side), only status + photo propagate
    //     and the target keeps its own line-item state.
    //   • Uses internal-only `_apply…` helpers so this doesn't recurse
    //     back through the public receive methods → stack overflow.

    /// PO was just received → mirror state onto the linked MR.
    private func propagateReceiveToLinkedMR(from po: PurchaseOrder) {
        guard let mrID = po.materialRequestID,
              let mrIdx = materialRequests.firstIndex(where: { $0.id == mrID }) else { return }
        var mr = materialRequests[mrIdx]
        // .ordered and .partial are already in isOpen; the prior check
        // OR'd them in redundantly. Trust the enum's own predicate.
        guard mr.status.isOpen else { return }
        _applyLinkedReceiveState(
            sourceLineItems:  po.lineItems,
            sourcePhotoURL:   po.deliveryPhotoURL,
            targetLineItems:  &mr.lineItems
        )
        applyMRStatusRollup(&mr)
        mr.updatedAt  = Date()
        mr.syncStatus = .pending
        materialRequests[mrIdx] = mr
        Task { await SyncEngine.shared.pushPendingMaterialRequests() }
    }

    /// MR was just received → mirror state onto the linked PO.
    private func propagateReceiveToLinkedPO(from mr: MaterialRequest) {
        guard let poID = mr.purchaseOrderID,
              let poIdx = purchaseOrders.firstIndex(where: { $0.id == poID }) else { return }
        var po = purchaseOrders[poIdx]
        guard [.draft, .sent, .confirmed, .partial].contains(po.status) else { return }
        _applyLinkedReceiveState(
            sourceLineItems:  mr.lineItems,
            sourcePhotoURL:   mr.deliveryPhotoURL,
            targetLineItems:  &po.lineItems
        )
        applyPOStatusRollup(&po)
        po.updatedAt  = Date()
        po.syncStatus = .pending
        purchaseOrders[poIdx] = po
        Task { await SyncEngine.shared.pushPendingPurchaseOrders() }
    }

    /// Shared core: copy quantities + photo URL from source's line items
    /// to target's matching line items. Only mutates a target line when
    /// its ID matches a source line — preserves rows that have diverged.
    private func _applyLinkedReceiveState(
        sourceLineItems: [MaterialLineItem],
        sourcePhotoURL: String?,
        targetLineItems: inout [MaterialLineItem]
    ) {
        let bySourceID = Dictionary(uniqueKeysWithValues:
            sourceLineItems.map { ($0.id, $0.quantityReceived) }
        )
        targetLineItems = targetLineItems.map { item in
            var copy = item
            if let qty = bySourceID[item.id] {
                copy.quantityReceived = qty
            }
            return copy
        }
    }

    /// MR-side status rollup. Pulled out of receiveMaterialRequest so
    /// propagation can recompute without duplicating the rules.
    /// Photo gate matches the receive method: no photo → max .partial,
    /// never .delivered.
    private func applyMRStatusRollup(_ mr: inout MaterialRequest) {
        let allReceived = !mr.lineItems.isEmpty
            && mr.lineItems.allSatisfy { $0.isFullyReceived }
        let anyReceived = mr.lineItems.contains { $0.quantityReceived > 0 }
        if allReceived && mr.deliveryPhotoURL?.isEmpty == false {
            mr.status     = .delivered
            mr.receivedAt = mr.receivedAt ?? Date()
            mr.receivedByID = mr.receivedByID ?? currentUser?.id
        } else if anyReceived {
            mr.status = .partial
        }
    }

    /// PO-side status rollup. Same shape as MR side but uses POStatus.
    private func applyPOStatusRollup(_ po: inout PurchaseOrder) {
        let allReceived = !po.lineItems.isEmpty
            && po.lineItems.allSatisfy { $0.isFullyReceived }
        let anyReceived = po.lineItems.contains { $0.quantityReceived > 0 }
        if allReceived && po.deliveryPhotoURL?.isEmpty == false {
            po.status       = .received
            po.receivedDate = po.receivedDate ?? Date()
        } else if anyReceived {
            po.status = .partial
        }
    }

    /// Match a supplier invoice against a PO. Captures the invoice
    /// number / date / amount, scans the invoice document, records
    /// per-line invoiced quantities, and either flips status to .closed
    /// (approved without variance) or leaves it at .received with
    /// `invoiceFlagged = true` for follow-up.
    ///
    /// `outcome` controls the terminal state:
    ///   • .approve → flips to .closed (variance accepted as-is)
    ///   • .flag    → stays .received with invoiceFlagged = true so the
    ///                Hub surfaces it for review
    ///   • .hold    → stays .received with note attached, no flag
    ///                (matcher wants to verify offline before closing)
    enum InvoiceMatchOutcome { case approve, flag, hold }

    func matchInvoice(
        for po: PurchaseOrder,
        invoiceNumber: String,
        invoiceDate: Date,
        invoiceAmount: Decimal,
        invoicedQuantities: [UUID: Decimal],
        invoiceScanPath: String?,
        outcome: InvoiceMatchOutcome,
        note: String?
    ) {
        guard requireRole([.officeAdmin, .manager, .executive],
                          action: "match_purchase_order_invoice") else { return }
        guard let idx = purchaseOrders.firstIndex(where: { $0.id == po.id }) else { return }
        var updated = po
        updated.invoiceNumber    = invoiceNumber.trimmingCharacters(in: .whitespaces)
        updated.invoiceDate      = invoiceDate
        updated.invoiceAmount    = invoiceAmount
        updated.invoiceScanPath  = invoiceScanPath ?? updated.invoiceScanPath
        updated.invoiceMatchedAt = Date()
        updated.invoiceMatchedBy = currentUser?.id
        let trimmedNote = note?.trimmingCharacters(in: .whitespaces) ?? ""
        updated.invoiceMatchNote = trimmedNote.isEmpty ? nil : trimmedNote
        updated.invoiceFlagged   = outcome == .flag
        // Apply per-line invoiced quantities. Lines without a map entry
        // keep their existing value — supports incremental matching when
        // the invoice covers a partial delivery.
        updated.lineItems = updated.lineItems.map { item in
            var copy = item
            if let qty = invoicedQuantities[item.id] {
                copy.quantityInvoiced = qty
            }
            return copy
        }
        switch outcome {
        case .approve:
            updated.status = .closed
        case .flag, .hold:
            updated.status = .received   // remains received; the flag/hold lives on the row
        }
        updated.updatedAt  = Date()
        updated.syncStatus = .pending
        objectWillChange.send()
        purchaseOrders[idx] = updated
        Task { await SyncEngine.shared.pushPendingPurchaseOrders() }
    }

    /// Mark a PO as sent to the supplier. Called after the email dispatch
    /// succeeds (PurchaseOrderPDFGenerator.emailToSupplier). Just flips
    /// status so the audit trigger captures the transition; the actual
    /// dispatch happens client-side via Resend.
    func markPurchaseOrderSent(_ po: PurchaseOrder) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "send_purchase_order") else { return }
        guard let idx = purchaseOrders.firstIndex(where: { $0.id == po.id }) else { return }
        var updated = po
        updated.status     = .sent
        updated.updatedAt  = Date()
        updated.syncStatus = .pending
        objectWillChange.send()
        purchaseOrders[idx] = updated
        Task { await SyncEngine.shared.pushPendingPurchaseOrders() }
    }

    func deletePurchaseOrder(id: UUID) {
        guard requireRole([.officeAdmin, .manager, .executive],
                          action: "delete_purchase_order") else { return }
        guard let idx = purchaseOrders.firstIndex(where: { $0.id == id }) else { return }
        var deleted = purchaseOrders[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        purchaseOrders[idx] = deleted
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingPurchaseOrders() }
    }

    // MARK: PO Queries

    func purchaseOrders(for projectID: UUID) -> [PurchaseOrder] {
        purchaseOrders.filter { $0.projectID == projectID }
            .sorted { $0.issueDate > $1.issueDate }
    }

    var openPurchaseOrders: [PurchaseOrder] {
        purchaseOrders.filter { $0.status.isOpen }
    }

    // MARK: PO auto-draft from approved Material Request

    /// Create a draft Purchase Order from an approved Material Request and
    /// link the two together. Called automatically by approveMaterialRequest
    /// when the MR has a supplierID set.
    ///
    /// CONTRACT
    ///   • Idempotent — re-approval that already linked a PO is a no-op (we
    ///     don't want to litter the DB with duplicate drafts).
    ///   • Only runs when supplierID is set. Supplier-less approvals stay
    ///     in .approved status; the manager picks one and creates the PO
    ///     manually via the existing "Create Purchase Order" action.
    ///   • PO starts in .draft. The manager reviews + sends; we never
    ///     auto-dispatch to the supplier.
    ///   • Returns the new PO so the caller can navigate to it / surface a
    ///     "PO-XXXX created" toast. Returns nil when skipped.
    @discardableResult
    func createPODraftFromApprovedRequest(_ mr: MaterialRequest) -> PurchaseOrder? {
        // Guard: must have supplier, must not already be linked to a PO that
        // still exists in the local store. The store-existence check guards
        // against stale links on records whose linked PO got deleted.
        guard let supplierID = mr.supplierID else { return nil }
        if let existingID = mr.purchaseOrderID,
           purchaseOrders.contains(where: { $0.id == existingID && !$0.isDeleted }) {
            return nil
        }
        guard !mr.lineItems.isEmpty else { return nil }

        // Resolve supplier name (denormalized onto the PO so old POs render
        // even if the supplier is later renamed or deleted).
        let supplierName = suppliers.first { $0.id == supplierID }?.name ?? ""

        var po = PurchaseOrder(
            poNumber:  nextPONumber(),
            projectID: mr.destinationType == .project ? mr.projectID : nil
        )
        po.supplierID         = supplierID
        po.supplierName       = supplierName
        po.materialRequestID  = mr.id
        po.lineItems          = mr.lineItems
        po.requiredDate       = mr.requiredByDate
        // Pull delivery address from the project's site address when linked,
        // otherwise fall back to the MR's site location field.
        po.deliveryAddress = (mr.projectID
            .flatMap { pid in projects.first { $0.id == pid }?.siteAddress }
            ?? mr.siteLocation)
            ?? ""
        po.terms              = "Net 30"
        po.notes              = "Auto-drafted from Material Request \(mr.requestNumber)."
        po.status             = .draft
        po.companyID          = currentCompanyID

        // Add the PO via the standard CRUD path so role enforcement, sync
        // queueing, and audit logging all fire as normal.
        addPurchaseOrder(po)

        // Link the MR back to the new PO so the existing Linked PO section
        // on the detail view picks it up automatically.
        if let idx = materialRequests.firstIndex(where: { $0.id == mr.id }) {
            var updated = materialRequests[idx]
            updated.purchaseOrderID = po.id
            updated.updatedAt       = Date()
            updated.syncStatus      = .pending
            materialRequests[idx]   = updated
            objectWillChange.send()
            Task { await SyncEngine.shared.pushPendingMaterialRequests() }
        }

        return po
    }

    /// Generate the next PO number. Same pattern as nextMaterialRequestNumber:
    /// max-of-existing-in-(company, year) + 1, not a raw count. See that
    /// method's doc comment for the rationale.
    func nextPONumber() -> String {
        let prefix = AppSettings.shared.companyPrefix.isEmpty ? "BV" : AppSettings.shared.companyPrefix
        let year   = Calendar.current.component(.year, from: Date())
        let yearPrefix = "\(prefix)-PO-\(year)-"
        let highest = purchaseOrders
            .filter { $0.companyID == currentCompanyID && !$0.isDeleted }
            .compactMap { po -> Int? in
                guard po.poNumber.hasPrefix(yearPrefix) else { return nil }
                return Int(po.poNumber.dropFirst(yearPrefix.count))
            }
            .max() ?? 0
        return "\(yearPrefix)\(String(format: "%04d", highest + 1))"
    }

    // MARK: Supplier CRUD

    func addSupplier(_ item: Supplier) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "add_supplier") else { return }
        var updated = item
        if updated.companyID == nil { updated.companyID = currentCompanyID }
        updated.syncStatus     = .pending
        updated.updatedAt      = Date()
        updated.lastModifiedAt = Date()
        updated.lastModifiedBy = currentUser?.fullName ?? ""
        objectWillChange.send()
        suppliers.append(updated)
        Task { await SyncEngine.shared.pushPendingSuppliers() }
    }

    func updateSupplier(_ item: Supplier) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "update_supplier") else { return }
        guard let idx = suppliers.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = item
        if updated.companyID == nil { updated.companyID = currentCompanyID }
        updated.syncStatus     = .pending
        updated.updatedAt      = Date()
        updated.lastModifiedAt = Date()
        updated.lastModifiedBy = currentUser?.fullName ?? ""
        objectWillChange.send()
        suppliers[idx] = updated
        Task { await SyncEngine.shared.pushPendingSuppliers() }
    }

    func deleteSupplier(id: UUID) {
        guard requireRole([.officeAdmin, .manager, .executive],
                          action: "delete_supplier") else { return }
        guard let idx = suppliers.firstIndex(where: { $0.id == id }) else { return }
        var deleted = suppliers[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        suppliers[idx] = deleted
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingSuppliers() }
    }

    var preferredSuppliers: [Supplier] {
        suppliers.filter { $0.isPreferred }.sorted { $0.name < $1.name }
    }

    // MARK: Persistence

    private static let materialRequestsKey = "bv_material_requests"
    private static let purchaseOrdersKey   = "bv_purchase_orders"
    private static let suppliersKey        = "bv_suppliers"

    // Persistence handled by Supabase. Stubs kept for call-site compatibility.
    func saveMaterialRequests() {}
    func loadMaterialRequests() {}
    func savePurchaseOrders()   {}
    func loadPurchaseOrders()   {}
    func saveSuppliers()        {}
    func loadSuppliers()        {
    }

}

// MARK: - Sample-data tracking
extension MaterialRequest: SampleDataTrackable {}

// MARK: - Sample-data tracking
extension Supplier: SampleDataTrackable {}

// MARK: - Sample-data tracking
extension PurchaseOrder: SampleDataTrackable {}
