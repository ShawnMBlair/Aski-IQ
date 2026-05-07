// Procurement.swift
// Aski IQ – Materials & Purchase Order Tracking

import Foundation
import Combine

// MARK: - Enums

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
    var id:          UUID    = UUID()
    var description: String
    var quantity:    Decimal = 1
    var unit:        UnitOfMeasure = .each
    var unitCost:    Decimal = 0
    var costCode:    String  = ""
    var notes:       String  = ""

    var totalCost: Decimal { (quantity * unitCost).rounded(scale: 2) }
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

    // Content
    var lineItems:       [MaterialLineItem] = []
    var notes:           String = ""
    var siteLocation:    String = ""   // Where on site the materials are needed

    // Approval
    var approvedByName:  String = ""
    var approvedAt:      Date?  = nil

    // Linked PO
    var purchaseOrderID: UUID? = nil

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

    func approveMaterialRequest(_ request: MaterialRequest) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "approve_material_request") else { return }
        guard let idx = materialRequests.firstIndex(where: { $0.id == request.id }) else { return }
        objectWillChange.send()
        var updated = request
        updated.status = .approved
        updated.approvedByName = currentUser?.fullName ?? "Office"
        updated.approvedAt = Date()
        updated.updatedAt  = Date()
        materialRequests[idx] = updated
        saveMaterialRequests()
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
        materialRequests.filter { $0.status == .submitted }
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
