// Employee.swift
// FieldOS – Crew Module

import Foundation

// MARK: - Employee

struct Employee: BaseModel {
    static func == (lhs: Employee, rhs: Employee) -> Bool {
        lhs.id == rhs.id
    }
    var id: UUID = UUID()
    var externalID: String?             // Payroll ID
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()

    // MARK: - Tenant
    /// Multi-tenant scope. Stamped on upsert from `AppStore.currentCompanyID`
    /// and enforced server-side by the `employees_company` RLS policy.
    /// Employees are HR / payroll PII — leaking them across tenants would be
    /// the most damaging cross-tenant exposure in the app.
    var companyID: UUID? = nil

    // Identity
    var firstName: String
    var lastName: String
    var email: String?
    var phone: String?

    // Role & Trade
    var role: UserRole = .foreman
    var trade: String?                  // e.g. "Insulation", "Scaffolding"
    var certifications: [String] = []

    // Payroll
    var regularRate: Decimal?
    var overtimeRate: Decimal?

    // Flags
    var isActive:  Bool    = true
    // MARK: Sample data tracking
    // Populated only by SampleDataSeeder; immutable post-insert via DB
    // trigger. Cleared along with the row when an executive runs Clear
    // Sample Data. See SampleData/SampleDataTypes.swift.
    var isSampleData:           Bool      = false
    var sampleDataBatchID:      UUID?     = nil
    var sampleDataSeedVersion:  String?   = nil
    var sampleDataCreatedAt:    Date?     = nil
    var sampleDataCreatedBy:    UUID?     = nil

    var isDeleted: Bool    = false
    var deletedAt: Date?   = nil
    var deletedBy: String? = nil

    // Computed
    var fullName: String { "\(firstName) \(lastName)" }
}

// MARK: - Crew

struct Crew: BaseModel {
    var id: UUID = UUID()
    var externalID: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var syncStatus: SyncStatus = .local
    var lastModifiedBy: String = ""
    var lastModifiedAt: Date = Date()

    /// Multi-tenant scope — same contract as `Employee.companyID`. Stamped
    /// on upsert; enforced by the `crews_company` RLS policy server-side.
    var companyID: UUID? = nil

    var name: String                    // e.g. "Insulation Crew A"
    var foremanID: UUID?
    var memberIDs: [UUID] = []          // Employee IDs
    var isActive:  Bool    = true
    var notes:     String? = nil
    // MARK: Sample data tracking
    // Populated only by SampleDataSeeder; immutable post-insert via DB
    // trigger. Cleared along with the row when an executive runs Clear
    // Sample Data. See SampleData/SampleDataTypes.swift.
    var isSampleData:           Bool      = false
    var sampleDataBatchID:      UUID?     = nil
    var sampleDataSeedVersion:  String?   = nil
    var sampleDataCreatedAt:    Date?     = nil
    var sampleDataCreatedBy:    UUID?     = nil

    var isDeleted: Bool    = false
    var deletedAt: Date?   = nil
    var deletedBy: String? = nil
}

// MARK: - Sample-data tracking
extension Crew: SampleDataTrackable {}

// MARK: - Sample-data tracking
extension Employee: SampleDataTrackable {}
