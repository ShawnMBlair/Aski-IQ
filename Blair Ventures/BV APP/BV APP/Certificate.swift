// Certificate.swift
// BV APP – Worker Certification & Compliance Model

import Foundation
import SwiftUI
import Combine

// MARK: - Certification Type

enum CertificationType: String, Codable, CaseIterable {
    case whmis           = "whmis"
    case firstAid        = "first_aid"
    case cprAed          = "cpr_aed"
    case h2sAlive        = "h2s_alive"
    case fallProtection  = "fall_protection"
    case confinedSpace   = "confined_space"
    case fireWatch       = "fire_watch"
    case liftingRigging  = "lifting_rigging"
    case electricalSafety = "electrical_safety"
    case tradeJourneyman = "trade_journeyman"
    case tradeApprentice = "trade_apprentice"
    case cdlClass1       = "cdl_class1"
    case cdlClass3       = "cdl_class3"
    case forklift        = "forklift"
    case craneOperator   = "crane_operator"
    case scaffolding     = "scaffolding"
    case other           = "other"

    var displayName: String {
        switch self {
        case .whmis:            return "WHMIS"
        case .firstAid:         return "First Aid"
        case .cprAed:           return "CPR / AED"
        case .h2sAlive:         return "H2S Alive"
        case .fallProtection:   return "Fall Protection"
        case .confinedSpace:    return "Confined Space Entry"
        case .fireWatch:        return "Fire Watch"
        case .liftingRigging:   return "Lifting & Rigging"
        case .electricalSafety: return "Electrical Safety"
        case .tradeJourneyman:  return "Journeyman Ticket"
        case .tradeApprentice:  return "Apprentice Certificate"
        case .cdlClass1:        return "CDL Class 1"
        case .cdlClass3:        return "CDL Class 3"
        case .forklift:         return "Forklift Operator"
        case .craneOperator:    return "Crane Operator"
        case .scaffolding:      return "Scaffolding"
        case .other:            return "Other"
        }
    }

    var icon: String {
        switch self {
        case .whmis:            return "hazardsign"
        case .firstAid:         return "cross.case.fill"
        case .cprAed:           return "heart.fill"
        case .h2sAlive:         return "aqi.medium"
        case .fallProtection:   return "figure.fall"
        case .confinedSpace:    return "circle.dashed"
        case .fireWatch:        return "flame.fill"
        case .liftingRigging:   return "arrow.up.and.down"
        case .electricalSafety: return "bolt.fill"
        case .tradeJourneyman:  return "wrench.and.screwdriver.fill"
        case .tradeApprentice:  return "graduationcap.fill"
        case .cdlClass1:        return "truck.box.fill"
        case .cdlClass3:        return "car.fill"
        case .forklift:         return "arrow.up.to.line.compact"
        case .craneOperator:    return "arrow.up.circle.fill"
        case .scaffolding:      return "building.columns.fill"
        case .other:            return "checkmark.seal.fill"
        }
    }

    var color: Color {
        switch self {
        case .whmis:            return .orange
        case .firstAid:         return .red
        case .cprAed:           return .pink
        case .h2sAlive:         return .yellow
        case .fallProtection:   return .blue
        case .confinedSpace:    return .purple
        case .fireWatch:        return .orange
        case .liftingRigging:   return .teal
        case .electricalSafety: return .yellow
        case .tradeJourneyman:  return .blue
        case .tradeApprentice:  return .indigo
        case .cdlClass1:        return .brown
        case .cdlClass3:        return .brown
        case .forklift:         return .orange
        case .craneOperator:    return .purple
        case .scaffolding:      return .teal
        case .other:            return .gray
        }
    }

    /// How many months this cert typically stays valid (nil = no standard expiry)
    var defaultValidityMonths: Int? {
        switch self {
        case .whmis:            return 12
        case .firstAid:         return 36
        case .cprAed:           return 24
        case .h2sAlive:         return 36
        case .fallProtection:   return 36
        case .confinedSpace:    return 36
        case .fireWatch:        return 12
        case .liftingRigging:   return 36
        case .electricalSafety: return 36
        case .tradeJourneyman:  return nil   // lifetime ticket
        case .tradeApprentice:  return nil
        case .cdlClass1:        return 60    // 5-yr licence renewal
        case .cdlClass3:        return 60
        case .forklift:         return 36
        case .craneOperator:    return 36
        case .scaffolding:      return 36
        case .other:            return nil
        }
    }
}

// MARK: - Certificate Status

enum CertificateStatus {
    case valid
    case expiringSoon   // within 30 days
    case expired
    case noExpiry

    var displayName: String {
        switch self {
        case .valid:         return "Valid"
        case .expiringSoon:  return "Expiring Soon"
        case .expired:       return "Expired"
        case .noExpiry:      return "No Expiry"
        }
    }

    var color: Color {
        switch self {
        case .valid:         return .green
        case .expiringSoon:  return .orange
        case .expired:       return .red
        case .noExpiry:      return .blue
        }
    }

    var icon: String {
        switch self {
        case .valid:         return "checkmark.seal.fill"
        case .expiringSoon:  return "exclamationmark.triangle.fill"
        case .expired:       return "xmark.seal.fill"
        case .noExpiry:      return "infinity"
        }
    }
}

// MARK: - Certificate Model

struct Certificate: BaseModel {
    var id:             UUID   = UUID()
    var externalID:     String? = nil
    var createdAt:      Date   = Date()
    var updatedAt:      Date   = Date()
    var syncStatus:     SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date   = Date()

    /// Multi-tenant scope. Certificates inherit from the owning employee's
    /// company; falls back to `currentCompanyID` when the employee lookup
    /// is unavailable on the upsert path.
    var companyID: UUID? = nil

    // Core
    var employeeID:  UUID
    var type:        CertificationType = .whmis
    var customName:  String? = nil      // used when type == .other
    var certNumber:  String? = nil      // certificate / ticket number
    var issuingBody: String? = nil      // issuing authority / provider

    // Dates
    var issuedDate:  Date? = nil
    var expiryDate:  Date? = nil        // nil → no expiry

    // Notes & Document
    var notes:        String? = nil
    var documentData: Data?   = nil     // scanned/photographed certificate

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

    var displayName: String {
        customName ?? type.displayName
    }

    var status: CertificateStatus {
        guard let expiry = expiryDate else { return .noExpiry }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
        if days < 0   { return .expired }
        if days <= 30 { return .expiringSoon }
        return .valid
    }

    var daysUntilExpiry: Int? {
        guard let expiry = expiryDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiry).day
    }
}

// MARK: - AppStore Extension

extension AppStore {

    var certificates: [Certificate] {
        guard let data = UserDefaults.standard.data(forKey: "bv_certificates"),
              let decoded = try? JSONDecoder().decode([Certificate].self, from: data)
        else { return [] }
        return decoded
    }

    func upsertCertificate(_ cert: Certificate) {
        // Stamp tenant scope: prefer the owning employee's companyID so a
        // cert inherits the employee's tenant; fall back to currentCompanyID.
        var stamped = cert
        if stamped.companyID == nil {
            stamped.companyID =
                employee(id: stamped.employeeID)?.companyID ?? currentCompanyID
        }
        var current = certificates
        if let idx = current.firstIndex(where: { $0.id == stamped.id }) {
            current[idx] = stamped
        } else {
            current.append(stamped)
        }
        saveCertificates(current)
        objectWillChange.send()
    }

    func deleteCertificate(_ cert: Certificate) {
        var deleted = cert
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        upsertCertificate(deleted)      // saves to UserDefaults + sends objectWillChange
        Task { await SyncEngine.shared.pushPending() }
    }

    func certificates(for employeeID: UUID) -> [Certificate] {
        certificates
            .filter { $0.employeeID == employeeID }
            .sorted { ($0.expiryDate ?? .distantFuture) < ($1.expiryDate ?? .distantFuture) }
    }

    /// Certs expiring within the next 30 days (not yet expired)
    var expiringCertificates: [Certificate] {
        certificates.filter { $0.status == .expiringSoon }
            .sorted { ($0.daysUntilExpiry ?? 0) < ($1.daysUntilExpiry ?? 0) }
    }

    /// Certs that have already expired
    var expiredCertificates: [Certificate] {
        certificates.filter { $0.status == .expired }
    }

    /// Combined: expired + expiring soon — used for banners
    var complianceAlerts: [Certificate] {
        (expiredCertificates + expiringCertificates)
            .sorted { ($0.daysUntilExpiry ?? Int.min) < ($1.daysUntilExpiry ?? Int.min) }
    }

    func saveCertificatesPublic(_ certs: [Certificate]) {
        if let data = try? JSONEncoder().encode(certs) {
            UserDefaults.standard.set(data, forKey: "bv_certificates")
            objectWillChange.send()
        }
    }

    private func saveCertificates(_ certs: [Certificate]) {
        saveCertificatesPublic(certs)
    }
}

// MARK: - Sample-data tracking
extension Certificate: SampleDataTrackable {}
