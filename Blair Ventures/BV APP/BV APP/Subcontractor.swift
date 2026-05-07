// Subcontractor.swift
// Aski IQ – Subcontractor Management Module
// Companies / trades hired on a sub-contract basis (separate from direct employees).

import Foundation
import Combine

// MARK: - Subcontractor Status

enum SubcontractorStatus: String, Codable, CaseIterable {
    case active       = "active"
    case inactive     = "inactive"
    case probationary = "probationary"   // New sub, limited scope
    case suspended    = "suspended"      // Compliance issue
    case blacklisted  = "blacklisted"    // Do not use

    var displayName: String {
        switch self {
        case .active:       return "Active"
        case .inactive:     return "Inactive"
        case .probationary: return "Probationary"
        case .suspended:    return "Suspended"
        case .blacklisted:  return "Blacklisted"
        }
    }

    var icon: String {
        switch self {
        case .active:       return "checkmark.circle.fill"
        case .inactive:     return "minus.circle"
        case .probationary: return "exclamationmark.circle"
        case .suspended:    return "pause.circle.fill"
        case .blacklisted:  return "xmark.octagon.fill"
        }
    }

    var isUsable: Bool { self == .active || self == .probationary }
}

// MARK: - Sub-Contract Status

enum SubContractStatus: String, Codable, CaseIterable {
    case draft      = "draft"
    case executed   = "executed"     // Signed / in force
    case inProgress = "in_progress"
    case complete   = "complete"
    case disputed   = "disputed"
    case terminated = "terminated"

    var displayName: String {
        switch self {
        case .draft:      return "Draft"
        case .executed:   return "Executed"
        case .inProgress: return "In Progress"
        case .complete:   return "Complete"
        case .disputed:   return "Disputed"
        case .terminated: return "Terminated"
        }
    }

    var isOpen: Bool { [.executed, .inProgress, .disputed].contains(self) }

    var color: String {
        switch self {
        case .draft:      return "gray"
        case .executed:   return "blue"
        case .inProgress: return "green"
        case .complete:   return "teal"
        case .disputed:   return "red"
        case .terminated: return "gray"
        }
    }
}

// MARK: - Subcontractor

struct Subcontractor: BaseModel {
    var id: UUID = UUID()
    var externalID: String?
    var companyID: UUID? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()

    // Identity
    var companyName: String
    var trade: String?                   // Primary specialty (e.g. "Electrical")
    var status: SubcontractorStatus = .active

    // Primary contact
    var contactName: String?
    var contactTitle: String?
    var email: String?
    var phone: String?
    var address: String?

    // Compliance — Insurance
    var insurancePolicyNumber: String?
    var insuranceExpiry: Date?
    var insuranceAmount: Decimal?        // Coverage limit

    // Compliance — WCB / Workers' Comp
    var wcbAccount: String?
    var wcbExpiry: Date?
    var wcbClearanceLetterReceived: Bool = false

    // Compliance — COR / Safety Cert
    var hasCOR: Bool = false
    var corExpiry: Date?

    // Internal
    var notes: String?
    var rating: Int?                     // 1-5 internal rating

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

    var isInsuranceExpired: Bool {
        guard let exp = insuranceExpiry else { return true }
        return Date() > exp
    }

    var isInsuranceExpiringSoon: Bool {
        guard let exp = insuranceExpiry else { return false }
        let soon = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
        return !isInsuranceExpired && exp < soon
    }

    var isWCBExpired: Bool {
        guard let exp = wcbExpiry else { return true }
        return Date() > exp
    }

    var isCompliant: Bool {
        !isInsuranceExpired && !isWCBExpired
    }

    var complianceAlertCount: Int {
        var count = 0
        if isInsuranceExpired || isInsuranceExpiringSoon { count += 1 }
        if isWCBExpired { count += 1 }
        return count
    }

    var initials: String {
        let words = companyName.split(separator: " ")
        let letters = words.prefix(2).compactMap { $0.first }.map { String($0) }
        return letters.joined().uppercased()
    }
}

// MARK: - Sub-Contract

struct SubContract: BaseModel {
    var id: UUID = UUID()
    var externalID: String?
    var companyID: UUID? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()

    // Identity
    var contractNumber: String           // e.g. "BV-SC-2026-001"
    var subcontractorID: UUID
    var projectID: UUID

    // Classification
    var status: SubContractStatus = .draft
    var scope: String = ""              // Scope of work description

    // Financial
    var contractValue: Decimal = 0
    var retentionPercent: Decimal = 10  // Default 10% holdback
    var invoicedToDate: Decimal = 0
    var paidToDate: Decimal = 0

    // Schedule
    var startDate: Date?
    var endDate: Date?

    // Terms
    var paymentTerms: String?
    var notes: String?
    var executedDate: Date?

    /// Phase-2 deferred audit fix: forward link to the full Contract
    /// record this SubContract has been promoted to (if any). The
    /// SubContract stays as the lightweight money/billing tracker;
    /// the Contract holds the legal document, clauses, milestones,
    /// compliance docs. Both sides remain — the link prevents
    /// drift and lets the UI navigate between them.
    var linkedContractID: UUID? = nil

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
    var retentionAmount: Decimal { invoicedToDate * retentionPercent / 100 }
    var netPayable:      Decimal { invoicedToDate - retentionAmount - paidToDate }
    var remainingValue:  Decimal { contractValue - invoicedToDate }
    var percentComplete: Double {
        guard contractValue > 0 else { return 0 }
        return min(NSDecimalNumber(decimal: invoicedToDate / contractValue).doubleValue, 1.0)
    }
}

// MARK: - AppStore Extension

extension AppStore {

    private static let subcontractorsKey  = "bv_subcontractors"
    private static let subContractsKey    = "bv_sub_contracts"

    // MARK: CRUD — Subcontractors

    func upsertSubcontractor(_ item: Subcontractor) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "upsert_subcontractor") else { return }
        var updated = item
        updated.updatedAt = Date()
        updated.syncStatus = .pending
        if let index = subcontractors.firstIndex(where: { $0.id == item.id }) {
            subcontractors[index] = updated
        } else {
            subcontractors.append(updated)
        }
        saveSubcontractors()
        Task { await SyncEngine.shared.pushPending() }
    }

    enum SubcontractorDeletionError: LocalizedError {
        case notPermitted
        case hasActiveContracts(String)

        var errorDescription: String? {
            switch self {
            case .notPermitted:
                return "You don't have permission to delete this subcontractor."
            case .hasActiveContracts(let summary):
                return "This subcontractor still has \(summary). Close or terminate \(summary) before deleting."
            }
        }
    }

    @discardableResult
    func deleteSubcontractor(_ item: Subcontractor) -> Result<Void, SubcontractorDeletionError> {
        guard requireRole([.officeAdmin, .manager, .executive],
                          action: "delete_subcontractor") else {
            return .failure(.notPermitted)
        }
        // Block when contracts are still active (executed / in progress / disputed).
        // Draft and terminated/complete contracts are OK to cascade-remove.
        let activeContracts = subContracts.filter {
            $0.subcontractorID == item.id &&
            ($0.status == .executed || $0.status == .inProgress || $0.status == .disputed)
        }
        if !activeContracts.isEmpty {
            let n = activeContracts.count
            return .failure(.hasActiveContracts("\(n) active contract\(n == 1 ? "" : "s")"))
        }
        subcontractors.removeAll { $0.id == item.id }
        // Cascade-remove the remaining (closed / draft) contracts.
        subContracts.removeAll { $0.subcontractorID == item.id }
        saveSubcontractors()
        saveSubContracts()
        return .success(())
    }

    // MARK: CRUD — Sub-Contracts

    func upsertSubContract(_ item: SubContract) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "upsert_sub_contract") else { return }
        var updated = item
        updated.updatedAt = Date()
        updated.syncStatus = .pending
        if let index = subContracts.firstIndex(where: { $0.id == item.id }) {
            subContracts[index] = updated
        } else {
            subContracts.append(updated)
        }
        saveSubContracts()
        Task { await SyncEngine.shared.pushPending() }
    }

    func deleteSubContract(_ item: SubContract) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "delete_sub_contract") else { return }
        subContracts.removeAll { $0.id == item.id }
        saveSubContracts()
    }

    /// Phase-2 deferred audit fix: promote a SubContract into a full
    /// Contract record, copying the parties, scope, money, and dates.
    /// The SubContract stays as the active billing tracker; the new
    /// Contract is where you'd put clauses, milestones, compliance
    /// docs, e-sign workflow, etc. Both records carry the link in
    /// each direction (SubContract.linkedContractID + Contract.notes
    /// gets a marker line).
    ///
    /// Idempotent: if the SubContract is already linked to a live
    /// Contract, returns that Contract without minting a new one.
    @discardableResult
    func promoteSubContractToContract(_ sc: SubContract) -> Contract? {
        guard requireRole([.officeAdmin, .manager, .executive],
                          action: "promote_sub_contract") else { return nil }

        // Idempotency: existing link wins.
        if let existingID = sc.linkedContractID,
           let existing   = contracts.first(where: { $0.id == existingID && !$0.isDeleted }) {
            return existing
        }

        let sub = subcontractor(id: sc.subcontractorID)
        let projectName = project(id: sc.projectID)?.name ?? "project"
        let title = sub.map { "\(projectName) — \($0.companyName)" } ?? projectName

        var c = Contract(
            title:            title,
            contractType:     .subcontractor,
            counterpartyName: sub?.companyName ?? "Subcontractor"
        )
        c.id                 = UUID()
        c.companyID          = currentCompanyID
        c.contractNumber     = "C-\(Calendar.current.component(.year, from: Date()))-\(String(format: "%03d", contracts.count + 1))"
        c.counterpartyType   = .subcontractor
        c.counterpartyID     = sc.subcontractorID
        c.counterpartyEmail  = sub?.email
        c.projectID          = sc.projectID
        c.contractValue      = sc.contractValue
        c.retainagePercent   = sc.retentionPercent
        c.effectiveDate      = sc.startDate
        c.expiryDate         = sc.endDate
        c.executedDate       = sc.executedDate
        c.paymentTerms       = sc.paymentTerms
        // SubContractStatus uses .executed/.inProgress (not .active);
        // map any "in-force" SubContract status to ContractStatus.active.
        c.status             = sc.status.isOpen ? .active : .draft
        c.syncStatus         = .pending
        c.createdAt          = Date()
        c.updatedAt          = Date()
        c.lastModifiedAt     = Date()
        c.notes              = "Promoted from sub-contract \(sc.contractNumber). Scope:\n\(sc.scope.isEmpty ? "(no scope text)" : sc.scope)"

        contracts.append(c)

        // Stamp the SubContract with the back-link.
        if let idx = subContracts.firstIndex(where: { $0.id == sc.id }) {
            subContracts[idx].linkedContractID = c.id
            subContracts[idx].syncStatus       = .pending
            subContracts[idx].updatedAt        = Date()
        }

        saveSubContracts()
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPending() }

        // Audit
        createAuditSnapshot(
            for:       c,
            eventType: "promoted_from_sub_contract:\(sc.id.uuidString)",
            by:        currentUser?.fullName ?? "system"
        )

        return c
    }

    // MARK: Lookups

    func subcontractor(id: UUID) -> Subcontractor? {
        subcontractors.first { $0.id == id }
    }

    func subContracts(for projectID: UUID) -> [SubContract] {
        subContracts.filter { $0.projectID == projectID }
    }

    func subContracts(bySubcontractor subcontractorID: UUID) -> [SubContract] {
        subContracts.filter { $0.subcontractorID == subcontractorID }
    }

    var subcontractorsWithComplianceAlerts: [Subcontractor] {
        subcontractors.filter { $0.complianceAlertCount > 0 && $0.status.isUsable }
    }

    var openSubContracts: [SubContract] {
        subContracts.filter { $0.status.isOpen }
    }

    func nextSubContractNumber() -> String {
        let prefix = AppSettings.shared.companyPrefix.isEmpty ? "BV" : AppSettings.shared.companyPrefix
        let year   = Calendar.current.component(.year, from: Date())
        let count  = subContracts.count + 1
        return "\(prefix)-SC-\(year)-\(String(format: "%03d", count))"
    }

    // MARK: Persistence

    // Persistence handled by Supabase. Stubs kept for call-site compatibility.
    func saveSubcontractors() {}
    func loadSubcontractors() {}
    func saveSubContracts() {}
    func loadSubContracts() {}

}

// MARK: - Sample-data tracking
extension Subcontractor: SampleDataTrackable {}

// MARK: - Sample-data tracking
extension SubContract: SampleDataTrackable {}
