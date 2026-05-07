// ProjectSeeder.swift
// Aski IQ — Loads sample Projects.
//
// FK consumers: clientID_ref, siteID_ref. Both must already be
// registered with the resolver (Clients + ClientSites must run first).

import Foundation

@MainActor
struct ProjectSeeder: SampleDataModuleSeeder {
    let s: SampleDataSeeder
    var tabName: String { "Projects" }

    func run() throws {
        for row in s.rows(for: tabName) {
            guard let refKey = row.ref,
                  let name   = row.string("name"),
                  let clientName = row.string("clientName") else { continue }

            // FKs — required
            guard let clientRef = row.refField("clientID_ref") else {
                throw SampleDataError.unresolvedReference(refKey: "<missing clientID_ref>", sourceTab: tabName)
            }
            let clientID = try s.resolver.requireUUID(for: clientRef, sourceTab: tabName)

            // Optional site FK
            let siteID: UUID? = row.refField("siteID_ref")
                .flatMap { s.resolver.uuid(for: $0) }

            var proj = Project(name: name, clientName: clientName)
            proj.id              = UUID()
            proj.companyID       = s.batch.companyID
            proj.clientID        = clientID
            proj.siteID          = siteID
            proj.jobNumber       = row.string("jobNumber")
            proj.status          = row.swiftEnum("status", type: ProjectStatus.self) ?? .active
            proj.startDate       = try row.relativeDate("startDate_rel", now: s.batch.createdAt)
            proj.endDate         = try row.relativeDate("endDate_rel",   now: s.batch.createdAt)
            proj.siteAddress     = row.string("siteAddress")
            proj.assignedPMName  = row.string("assignedPMName")
            proj.contractValue   = row.decimal("contractValue")
            proj.estimatedBudget = row.decimal("estimatedBudget")
            proj.notes           = row.string("__notes")

            s.stamp(&proj)
            s.resolver.register(refKey: refKey, uuid: proj.id, tab: tabName)

            // Persist via the existing service so RLS, validation, sync,
            // automations, and audit logging all run identically to a
            // real user creating a project.
            store.upsertProject(proj)
            s.recordInsert(tab: tabName)
        }
    }

    private var store: AppStore { s.store }
}
