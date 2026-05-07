// ChangeOrderSeeder.swift
// Aski IQ — Loads sample Change Orders.
//
// FK consumers:
//   - projectID_ref → Projects (REQUIRED — ProjectSeeder runs in Phase B
//                     so the resolver is populated by the time we get here)
//
// Calls existing service `upsertChangeOrder` so RLS, validation, sync,
// approval-transition hooks (revised-budget propagation, scope-creep
// warning toast, audit log entry) all run identically to a real PM
// approving a CO from the UI.
//
// IMPORTANT: line items live in a separate tab (`ChangeOrder_LineItems`)
// loaded by ChangeOrderLineSeeder in a later batch. This seeder leaves
// `lineItems = []` and uses `costImpact` as the authoritative dollar
// amount via the `effectiveCostImpact` computed fallback.

import Foundation

@MainActor
struct ChangeOrderSeeder: SampleDataModuleSeeder {
    let s: SampleDataSeeder
    var tabName: String { "ChangeOrders" }

    func run() throws {
        for row in s.rows(for: tabName) {
            guard let refKey = row.ref,
                  let number = row.string("number"),
                  let title  = row.string("title") else { continue }

            // FK — required
            guard let projectRef = row.refField("projectID_ref") else {
                throw SampleDataError.unresolvedReference(
                    refKey: "<missing projectID_ref>", sourceTab: tabName)
            }
            let projectID = try s.resolver.requireUUID(for: projectRef, sourceTab: tabName)

            // Build the model — synthesized memberwise init covers
            // required identity fields.
            var co = ChangeOrder(number: number, title: title, projectID: projectID)
            co.id        = UUID()
            co.companyID = s.batch.companyID

            // Classification
            co.type   = row.swiftEnum("type",   type: ChangeOrderType.self)   ?? .ownerInitiated
            co.status = row.swiftEnum("status", type: ChangeOrderStatus.self) ?? .draft

            // Detail
            co.description = row.string("description") ?? ""
            co.reason      = row.string("reason")
            co.notes       = row.string("notes")

            // Financial impact (lineItems empty for now — Batch 2 fills them)
            co.costImpact         = row.decimal("costImpact") ?? 0
            co.scheduleImpactDays = row.int("scheduleImpactDays") ?? 0

            // Dates
            let now = s.batch.createdAt
            co.submittedDate = try row.relativeDate("submittedDate_rel", now: now)
            co.approvedDate  = try row.relativeDate("approvedDate_rel",  now: now)
            co.rejectedDate  = try row.relativeDate("rejectedDate_rel",  now: now)

            // People + client reference
            co.approvedByName        = row.string("approvedByName")
            co.clientReferenceNumber = row.string("clientReferenceNumber")

            // Sample-data stamp
            s.stamp(&co)

            // Register before persisting
            s.resolver.register(refKey: refKey, uuid: co.id, tab: tabName)

            // upsertChangeOrder runs the approval transition hook when
            // status flips to .approved, but since we're inserting a
            // fresh row here (no prior status), the trigger conditions
            // (oldStatus != .approved && newStatus == .approved) ARE
            // met for already-approved sample COs. That's the desired
            // behaviour — sample data exercises the same downstream
            // logic real approvals would (revised-budget propagation,
            // CRM activity log, scope-creep warning, etc.).
            store.upsertChangeOrder(co)
            s.recordInsert(tab: tabName)
        }
    }

    private var store: AppStore { s.store }
}
