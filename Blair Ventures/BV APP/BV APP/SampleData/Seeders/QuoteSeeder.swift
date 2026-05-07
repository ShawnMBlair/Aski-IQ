// QuoteSeeder.swift
// Aski IQ — Loads sample Quotes.
//
// FK consumers:
//   - estimateID_ref     → Estimates (required — EstimateSeeder runs first)
//   - clientID_ref       → Clients (required)
//   - projectID_ref      → Projects (optional — Projects seed BEFORE Quotes
//                          so won-quote links resolve)
//   - opportunityID_ref  → CRM Opportunities (optional; resolves only if
//                          OpportunitySeeder has run)
//
// Calls existing service `upsertQuote` so RLS, validation, sync,
// CRM bridge, and quote-revision tracking all run.

import Foundation

@MainActor
struct QuoteSeeder: SampleDataModuleSeeder {
    let s: SampleDataSeeder
    var tabName: String { "Quotes" }

    func run() throws {
        for row in s.rows(for: tabName) {
            guard let refKey    = row.ref,
                  let jobNumber = row.string("jobNumber") else { continue }

            // FKs — required
            guard let estimateRef = row.refField("estimateID_ref") else {
                throw SampleDataError.unresolvedReference(
                    refKey: "<missing estimateID_ref>", sourceTab: tabName)
            }
            let estimateID = try s.resolver.requireUUID(for: estimateRef, sourceTab: tabName)

            guard let clientRef = row.refField("clientID_ref") else {
                throw SampleDataError.unresolvedReference(
                    refKey: "<missing clientID_ref>", sourceTab: tabName)
            }
            let clientID = try s.resolver.requireUUID(for: clientRef, sourceTab: tabName)

            // Look up the parent estimate to get clientName for display
            let clientName = store.clients.first(where: { $0.id == clientID })?.name
                ?? "Unknown Client"

            // Build the model via Quote's explicit init
            var quote = Quote(
                jobNumber:  jobNumber,
                estimateID: estimateID,
                clientID:   clientID,
                clientName: clientName,
                preparedBy: row.string("preparedBy") ?? row.string("assignedPMName") ?? ""
            )
            quote.id        = UUID()
            quote.companyID = s.batch.companyID

            // Optional FKs
            quote.projectID     = row.refField("projectID_ref")
                .flatMap { s.resolver.uuid(for: $0) }
            quote.opportunityID = row.refField("opportunityID_ref")
                .flatMap { s.resolver.uuid(for: $0) }
            quote.assignedPMID  = row.refField("assignedPMID_ref")
                .flatMap { s.resolver.uuid(for: $0) }

            // Versioning
            quote.revision = row.int("revision") ?? 1

            // Status + people
            quote.status          = row.swiftEnum("status", type: QuoteStatus.self) ?? .draft
            quote.assignedPMName  = row.string("assignedPMName")
            quote.approvedBy      = row.string("approvedBy")

            // Dates
            let now = s.batch.createdAt
            quote.quoteDate   = try row.relativeDate("quoteDate_rel",   now: now) ?? now
            quote.expiryDate  = try row.relativeDate("expiryDate_rel",  now: now)
                ?? Calendar.current.date(byAdding: .day, value: 30, to: quote.quoteDate)
                ?? quote.quoteDate
            quote.sentAt      = try row.relativeDate("sentAt_rel",      now: now)
            quote.acceptedAt  = try row.relativeDate("acceptedAt_rel",  now: now)
            quote.approvedAt  = try row.relativeDate("approvedAt_rel",  now: now)
            quote.declinedAt  = try row.relativeDate("declinedAt_rel",  now: now)

            // Pricing — line items will be loaded by QuoteLineSeeder (Batch 2);
            // for now we set the manual subtotal so price displays sensibly.
            quote.subtotal            = row.decimal("subtotal") ?? 0
            quote.discountPercent     = row.decimal("discountPercent")    ?? 0
            quote.contingencyPercent  = row.decimal("contingencyPercent") ?? 0
            quote.taxRate             = row.decimal("taxRate")            ?? Decimal(s.dataset.manifest.taxRateDefault ?? 0.05)

            // Site + scope narrative
            quote.siteAddress  = row.string("siteAddress")
            quote.scopeSummary = row.string("scopeSummary") ?? ""
            quote.inclusions   = row.string("inclusions")   ?? ""
            quote.exclusions   = row.string("exclusions")   ?? ""
            quote.assumptions  = row.string("assumptions")  ?? ""
            quote.paymentTerms = row.string("paymentTerms") ?? "Net 30"
            quote.validityDays = row.int("validityDays")    ?? 30

            // Currency — workbook may suffix with _cad/_usd; default to manifest
            quote.currency = row.string("currency")
                ?? s.dataset.manifest.currencyDefault
                ?? "USD"

            // Loss tracking (when status == .declined)
            quote.lossReason     = row.swiftEnum("lossReason", type: LossReason.self)
            quote.competitorName = row.string("competitorName")
            quote.winLossNotes   = row.string("winLossNotes")

            // Sample-data stamp
            s.stamp(&quote)

            // Register before persisting so any later seeder (Invoices,
            // MaterialSales) that references quotes can resolve.
            s.resolver.register(refKey: refKey, uuid: quote.id, tab: tabName)

            store.upsertQuote(quote)
            s.recordInsert(tab: tabName)
        }
    }

    private var store: AppStore { s.store }
}
