// EmployeeSeeder.swift
// Aski IQ — Loads sample Employees.
//
// IMPORTANT (per architecture decision §2): sample employees are
// records-only. We do NOT create rows in `auth.users` for them.
// Real admin users keep their existing accounts; sample employees are
// scheduling/crew/timesheet placeholders that disappear on reset.

import Foundation

@MainActor
struct EmployeeSeeder: SampleDataModuleSeeder {
    let s: SampleDataSeeder
    var tabName: String { "Employees" }

    func run() throws {
        for row in s.rows(for: tabName) {
            guard let refKey   = row.ref,
                  let firstName = row.string("firstName"),
                  let lastName  = row.string("lastName") else { continue }

            var emp = Employee(firstName: firstName, lastName: lastName)
            emp.id           = UUID()
            emp.companyID    = s.batch.companyID
            emp.role         = row.swiftEnum("role", type: UserRole.self) ?? .fieldWorker
            emp.trade        = row.string("trade") ?? ""
            emp.email        = row.string("email") ?? ""
            emp.phone        = row.string("phone") ?? ""
            emp.regularRate  = row.decimal("regularRate")
            emp.overtimeRate = row.decimal("overtimeRate")
            emp.isActive     = row.bool("isActive") ?? true

            // Sample-data stamp
            s.stamp(&emp)

            s.resolver.register(refKey: refKey, uuid: emp.id, tab: tabName)

            store.upsertEmployee(emp)
            s.recordInsert(tab: tabName)
        }
    }

    private var store: AppStore { s.store }
}
