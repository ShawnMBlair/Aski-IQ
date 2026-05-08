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
    case approved   = "approved"
    case ordered    = "ordered"
    case partial    = "partial"
    case delivered  = "delivered"
    case cancelled  = "cancelled"

    var displayName: String {
        switch self {
        case .draft:     return "Draft"
        case .submitted: return "Submitted"
        case .approved:  return "Approved"
        case .ordered:   return "Ordered"
        case .partial:   return "Partial"
        case .delivered: return "Delivered"
        case .cancelled: return "Cancelled"
        }
    }

    var isOpen: Bool {
        [.submitted, .approved, .ordered, .partial].contains(self)
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
    var id:               UUID    = UUID()
    var description:      String
    var quantity:         Decimal = 1
    var quantityReceived: Decimal = 0   // Set by the Receive sheet on delivery
    var unit:             UnitOfMeasure = .each
    var unitCost:         Decimal = 0
    var costCode:         String  = ""
    var notes:            String  = ""

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

    func nextMaterialRequestNumber() -> String {
        let prefix = AppSettings.shared.companyPrefix.isEmpty ? "BV" : AppSettings.shared.companyPrefix
        let year   = Calendar.current.component(.year, from: Date())
        let next   = materialRequests.count + 1
        return "\(prefix)-MR-\(year)-\(String(format: "%04d", next))"
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

    func nextPONumber() -> String {
        let prefix = AppSettings.shared.companyPrefix.isEmpty ? "BV" : AppSettings.shared.companyPrefix
        let year   = Calendar.current.component(.year, from: Date())
        let next   = purchaseOrders.count + 1
        return "\(prefix)-PO-\(year)-\(String(format: "%04d", next))"
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
