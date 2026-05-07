// SpotlightService.swift
// Aski IQ — Indexes Projects and Clients in Core Spotlight so users can search
// for them from the iOS Home Screen / Lock Screen / Spotlight pull-down.
//
// Tapping a Spotlight result opens the app via NSUserActivity and routes to
// the appropriate detail view — wired through AppStore.pendingSpotlightTarget
// (similar pattern to NotifRoute).
//
// Keys used:
//   - Domain identifier: "ca.askiiq.<entity>"  (allows targeted purges)
//   - Item identifier:   the entity's UUID string
//   - User activity:     "ca.askiiq.spotlight.open" with userInfo
//                        { "entity": "project"|"client", "id": "<uuid>" }

import Foundation
// `@preconcurrency` silences the Swift 6 warning that CoreSpotlight's
// types are not yet Sendable-annotated. The CSSearchableIndex APIs
// we use are documented as thread-safe; this just lets the compiler
// know we accept the older non-Sendable contract.
@preconcurrency import CoreSpotlight
import UniformTypeIdentifiers

@MainActor
final class SpotlightService {

    static let shared = SpotlightService()
    private init() {}

    // MARK: - Domain identifiers

    private let projectDomain     = "ca.askiiq.project"
    private let clientDomain      = "ca.askiiq.client"
    /// Week 4 audit closeout: indexed three more entity types so users
    /// can find opportunities, quotes, and invoices from iOS Spotlight.
    /// Pre-fix only Projects + Clients were searchable — the audit
    /// flagged this as the #7 LOW priority item ("Spotlight missing
    /// 90% of entity types") and it's cheap to close.
    private let opportunityDomain = "ca.askiiq.opportunity"
    private let quoteDomain       = "ca.askiiq.quote"
    private let invoiceDomain     = "ca.askiiq.invoice"

    /// User activity type — register the matching entry in Info.plist's
    /// NSUserActivityTypes array so iOS will hand the activity to the app on tap.
    static let openActivityType = "ca.askiiq.spotlight.open"

    // MARK: - Public API

    /// Re-index every active project and client. Call after a full pull,
    /// or after `clearAllData()` to drop stale entries.
    /// Week 4 audit closeout: opportunities, quotes, and invoices are
    /// now indexed too. Old call sites that pass only projects+clients
    /// keep working — the new params default to empty arrays.
    func reindexAll(
        projects:      [Project] = [],
        clients:       [Client] = [],
        opportunities: [CRMOpportunity] = [],
        quotes:        [Quote] = [],
        invoices:      [Invoice] = []
    ) {
        let activeProjects      = projects.filter      { !$0.isDeleted }
        let activeClients       = clients.filter       { !$0.isDeleted && $0.isActive }
        let activeOpportunities = opportunities.filter { !$0.isDeleted }
        let activeQuotes        = quotes.filter        { !$0.isDeleted }
        let activeInvoices      = invoices.filter      { !$0.isDeleted }

        let allItems =
            activeProjects.map      { makeProjectItem($0) }
          + activeClients.map       { makeClientItem($0) }
          + activeOpportunities.map { makeOpportunityItem($0) }
          + activeQuotes.map        { makeQuoteItem($0) }
          + activeInvoices.map      { makeInvoiceItem($0) }

        let allDomains = [
            projectDomain, clientDomain,
            opportunityDomain, quoteDomain, invoiceDomain
        ]

        // Replace entire index across all domains — simpler than
        // diffing, and full-reindex runs once per pull cycle.
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: allDomains) { _ in
            index.indexSearchableItems(allItems) { _ in
                // Errors here are non-fatal — Spotlight sometimes refuses
                // during low-power mode or when the index is rebuilding.
            }
        }
    }

    /// Remove all Aski IQ entries from the system index (sign out path).
    func deleteAll() {
        let allDomains = [
            projectDomain, clientDomain,
            opportunityDomain, quoteDomain, invoiceDomain
        ]
        CSSearchableIndex.default()
            .deleteSearchableItems(withDomainIdentifiers: allDomains) { _ in }
    }

    /// Update a single project. Cheap on subsequent edits — no re-index storm.
    func upsert(project: Project) {
        let item = makeProjectItem(project)
        if project.isDeleted {
            CSSearchableIndex.default()
                .deleteSearchableItems(withIdentifiers: [project.id.uuidString]) { _ in }
        } else {
            CSSearchableIndex.default().indexSearchableItems([item]) { _ in }
        }
    }

    /// Update a single client.
    func upsert(client: Client) {
        let item = makeClientItem(client)
        if client.isDeleted || !client.isActive {
            CSSearchableIndex.default()
                .deleteSearchableItems(withIdentifiers: [client.id.uuidString]) { _ in }
        } else {
            CSSearchableIndex.default().indexSearchableItems([item]) { _ in }
        }
    }

    /// Update a single CRM opportunity. Lost deals are removed from
    /// the index so closed pipeline doesn't clutter Spotlight
    /// results — but they remain in the app's CRM history.
    /// (`OpportunityStage` only has `.won`/`.lost` terminal states;
    /// there's no `.cancelled` stage like there is for Quote/Invoice.)
    func upsert(opportunity: CRMOpportunity) {
        if opportunity.isDeleted || opportunity.stage == .lost {
            CSSearchableIndex.default()
                .deleteSearchableItems(withIdentifiers: [opportunity.id.uuidString]) { _ in }
        } else {
            let item = makeOpportunityItem(opportunity)
            CSSearchableIndex.default().indexSearchableItems([item]) { _ in }
        }
    }

    /// Update a single Quote. Voided / declined quotes are removed
    /// from Spotlight (still queryable inside the app from
    /// QuoteListView's filter pills).
    func upsert(quote: Quote) {
        if quote.isDeleted || quote.status == .declined {
            CSSearchableIndex.default()
                .deleteSearchableItems(withIdentifiers: [quote.id.uuidString]) { _ in }
        } else {
            let item = makeQuoteItem(quote)
            CSSearchableIndex.default().indexSearchableItems([item]) { _ in }
        }
    }

    /// Update a single Invoice. Void invoices removed from Spotlight.
    func upsert(invoice: Invoice) {
        if invoice.isDeleted || invoice.status == .void {
            CSSearchableIndex.default()
                .deleteSearchableItems(withIdentifiers: [invoice.id.uuidString]) { _ in }
        } else {
            let item = makeInvoiceItem(invoice)
            CSSearchableIndex.default().indexSearchableItems([item]) { _ in }
        }
    }

    // MARK: - Item builders

    private func makeProjectItem(_ project: Project) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: UTType.text)
        attrs.title       = project.name
        attrs.contentDescription = projectSummary(project)
        attrs.keywords    = [project.clientName, project.status.rawValue,
                             project.externalID ?? ""]
            .filter { !$0.isEmpty }
        attrs.identifier  = project.id.uuidString
        attrs.relatedUniqueIdentifier = project.id.uuidString

        let item = CSSearchableItem(
            uniqueIdentifier:   project.id.uuidString,
            domainIdentifier:   projectDomain,
            attributeSet:       attrs
        )
        // Keep entries indefinitely — clear on logout via deleteAll().
        item.expirationDate = Date.distantFuture
        return item
    }

    private func makeClientItem(_ client: Client) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: UTType.contact)
        attrs.title             = client.name
        attrs.contentDescription = clientSummary(client)
        attrs.keywords          = [client.contactName ?? "",
                                   client.contactEmail ?? "",
                                   client.contactPhone ?? "",
                                   client.notes ?? ""]
            .filter { !$0.isEmpty }
        attrs.identifier         = client.id.uuidString
        attrs.relatedUniqueIdentifier = client.id.uuidString

        let item = CSSearchableItem(
            uniqueIdentifier:   client.id.uuidString,
            domainIdentifier:   clientDomain,
            attributeSet:       attrs
        )
        item.expirationDate = Date.distantFuture
        return item
    }

    // MARK: - Summaries

    private func projectSummary(_ project: Project) -> String {
        var parts: [String] = []
        if !project.clientName.isEmpty { parts.append(project.clientName) }
        parts.append(project.status.rawValue.capitalized)
        if let value = project.contractValue {
            parts.append(value.currencyString)
        }
        return parts.joined(separator: " · ")
    }

    private func clientSummary(_ client: Client) -> String {
        var parts: [String] = []
        if let contact = client.contactName, !contact.isEmpty { parts.append(contact) }
        if let email   = client.contactEmail, !email.isEmpty  { parts.append(email) }
        if let phone   = client.contactPhone, !phone.isEmpty  { parts.append(phone) }
        return parts.joined(separator: " · ")
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Opportunity / Quote / Invoice item builders
    //
    // Same shape as the Project / Client builders above. Each one
    // makes the result findable in Spotlight by name + a few
    // disambiguating keywords (client name, status, ID).
    // ─────────────────────────────────────────────────────────────────

    private func makeOpportunityItem(_ opp: CRMOpportunity) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: UTType.text)
        attrs.title              = opp.title
        // OpportunityStage uses its rawValue as its display string
        // ("Quote Sent", "Won", etc.) — there's no separate
        // displayName on the enum, unlike QuoteStatus / InvoiceStatus.
        attrs.contentDescription = "Opportunity · \(opp.stage.rawValue) · \(opp.value.currencyString)"
        attrs.keywords           = [
            opp.stage.rawValue,
            opp.title,
            // Surface the linked client name when available so
            // searching by company turns up its open deals too.
            AppStore.shared.clients.first { $0.id == opp.clientID }?.name ?? ""
        ].filter { !$0.isEmpty }
        attrs.identifier              = opp.id.uuidString
        attrs.relatedUniqueIdentifier = opp.id.uuidString

        let item = CSSearchableItem(
            uniqueIdentifier: opp.id.uuidString,
            domainIdentifier: opportunityDomain,
            attributeSet:     attrs
        )
        item.expirationDate = Date.distantFuture
        return item
    }

    private func makeQuoteItem(_ quote: Quote) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: UTType.text)
        attrs.title              = "\(quote.jobNumber) — \(quote.clientName)"
        attrs.contentDescription = "Quote · \(quote.status.rawValue.capitalized) · \(quote.grandTotal.currencyString)"
        attrs.keywords           = [
            quote.jobNumber,
            quote.clientName,
            quote.status.rawValue,
            quote.scopeSummary
        ].filter { !$0.isEmpty }
        attrs.identifier              = quote.id.uuidString
        attrs.relatedUniqueIdentifier = quote.id.uuidString

        let item = CSSearchableItem(
            uniqueIdentifier: quote.id.uuidString,
            domainIdentifier: quoteDomain,
            attributeSet:     attrs
        )
        item.expirationDate = Date.distantFuture
        return item
    }

    private func makeInvoiceItem(_ inv: Invoice) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: UTType.text)
        attrs.title              = "\(inv.invoiceNumber) — \(inv.billToName.isEmpty ? "Invoice" : inv.billToName)"
        attrs.contentDescription = "Invoice · \(inv.invoiceType.displayName) · \(inv.status.displayName) · \(inv.total.currencyString)"
        attrs.keywords           = [
            inv.invoiceNumber,
            inv.billToName,
            inv.status.rawValue,
            inv.invoiceType.rawValue,
            inv.poNumber
        ].filter { !$0.isEmpty }
        attrs.identifier              = inv.id.uuidString
        attrs.relatedUniqueIdentifier = inv.id.uuidString

        let item = CSSearchableItem(
            uniqueIdentifier: inv.id.uuidString,
            domainIdentifier: invoiceDomain,
            attributeSet:     attrs
        )
        item.expirationDate = Date.distantFuture
        return item
    }
}

// MARK: - Spotlight Tap Routing

/// What the app should open after the user taps a Spotlight result.
/// Mirrors the NotifRoute pattern — RootView observes this and reacts.
enum SpotlightTarget: Equatable {
    case project(UUID)
    case client(UUID)
    /// Week 4 audit closeout: extended to opportunities, quotes,
    /// and invoices. RootView's existing handler resolves these by
    /// looking up against the live store; falls back to project lookup
    /// when the unique identifier alone can't disambiguate.
    case opportunity(UUID)
    case quote(UUID)
    case invoice(UUID)
}

extension SpotlightService {

    /// Parse an inbound NSUserActivity from Spotlight. Returns the target if
    /// recognised, otherwise nil. Call from `.onContinueUserActivity(...)`.
    static func target(from activity: NSUserActivity) -> SpotlightTarget? {
        // 1) Standard CSSearchableItem activity — `uniqueIdentifier` on userInfo.
        if activity.activityType == CSSearchableItemActionType,
           let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
           let uuid = UUID(uuidString: id) {
            // We don't know which entity from the identifier alone — caller
            // resolves by looking up against the live store. Default to project
            // first, then client. AppStore handles the disambiguation.
            // Returning a sentinel `.project` is fine — RootView's handler
            // checks both stores.
            return .project(uuid) // resolved by RootView against both stores
        }
        // 2) Custom open activity (future: deep links from email / push).
        if activity.activityType == openActivityType,
           let info  = activity.userInfo as? [String: Any],
           let kind  = info["entity"] as? String,
           let idStr = info["id"] as? String,
           let uuid  = UUID(uuidString: idStr) {
            switch kind {
            case "project":     return .project(uuid)
            case "client":      return .client(uuid)
            case "opportunity": return .opportunity(uuid)
            case "quote":       return .quote(uuid)
            case "invoice":     return .invoice(uuid)
            default:            return nil
            }
        }
        return nil
    }
}
