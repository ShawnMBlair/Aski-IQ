// ClientSeeder.swift
// Aski IQ — Loads sample Clients + ClientSites.
//
// Reference seeder — the pattern below is duplicated by every module
// seeder. Steps:
//   1. Read tab rows from `s.rows(for:)`
//   2. Build a domain struct from row fields
//   3. Mint a fresh UUID
//   4. Stamp tenant scope (companyID) — the upsert helper does this too
//      but we set it eagerly so the resolver record is consistent
//   5. Stamp sample-data metadata via `s.stamp(&record)`
//   6. Register __ref → UUID with the resolver BEFORE FK consumers run
//   7. Persist via the existing service (`store.upsertClient(_:)` etc.)
//   8. Bump the per-module counter

import Foundation

@MainActor
struct ClientSeeder: SampleDataModuleSeeder {
    let s: SampleDataSeeder
    var tabName: String { "Clients" }

    func run() throws {
        for row in s.rows(for: tabName) {
            guard let refKey = row.ref else {
                throw SampleDataError.unresolvedReference(refKey: "<missing __ref>", sourceTab: tabName)
            }
            guard let name = row.string("name") else { continue }

            var client = Client(name: name)
            client.id              = UUID()
            client.companyID       = s.batch.companyID
            client.code            = row.string("code") ?? ""
            client.contactName     = row.string("contactName") ?? ""
            client.contactTitle    = row.string("contactTitle") ?? ""
            client.contactEmail    = row.string("contactEmail") ?? ""
            client.contactPhone    = row.string("contactPhone") ?? ""
            client.billingAddress  = row.string("billingAddress")
            client.billingCity     = row.string("billingCity")
            client.billingProvince = row.string("billingProvince")
            client.billingPostal   = row.string("billingPostal")
            client.defaultPaymentTerms = row.string("defaultPaymentTerms")
            client.isActive        = row.bool("isActive") ?? true
            // companyType is stored by some installations; map if the
            // model has the column.
            // client.companyType = row.swiftEnum("companyType", type: ClientCompanyType.self)

            // Sample-data stamp
            s.stamp(&client)

            // Register BEFORE persisting so any concurrently-resolving
            // children see the UUID even if persistence is async.
            s.resolver.register(refKey: refKey, uuid: client.id, tab: tabName)

            store.upsertClient(client)
            s.recordInsert(tab: tabName)
        }
    }

    private var store: AppStore { s.store }
}
