// UniversalSearchService.swift
// Aski IQ — Cross-entity in-memory search.
//
// WHY THIS EXISTS
// Audit §31 + Strategy §16 Phase 2.B: search exists per entity but not across
// the whole app. Power users want one box that finds a client name whether it
// sits on a client, a project, a quote, or an opportunity. This service
// provides exactly that — local, instant, debounced, with recent-search memory.
//
// SCOPE
// In-memory only. For tenants under ~5k records per entity (the realistic
// SMB ceiling) this is fast enough — <50ms even on a phone. Past that we
// switch to a Supabase RPC with full-text search; that's tracked as a future
// enhancement in the strategy report.

import Foundation

// MARK: - Result model

/// A single hit in the universal search. Generic across entity kinds.
/// `payload` carries the underlying record so callers can route to detail.
struct UniversalSearchResult: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case client          = "Client"
        case project         = "Project"
        case quote           = "Quote"
        case estimate        = "Estimate"
        case invoice         = "Invoice"
        case employee        = "Employee"
        case crmContact      = "Contact"
        case crmOpportunity  = "Opportunity"
        case formSubmission  = "Form"
        case incident        = "Incident"

        var icon: String {
            switch self {
            case .client:         return "building.2.fill"
            case .project:        return "folder.fill"
            case .quote:          return "doc.text.fill"
            case .estimate:       return "list.bullet.clipboard"
            case .invoice:        return "doc.richtext.fill"
            case .employee:       return "person.crop.circle.fill"
            case .crmContact:     return "person.fill"
            case .crmOpportunity: return "chart.line.uptrend.xyaxis"
            case .formSubmission: return "doc.badge.gearshape"
            case .incident:       return "exclamationmark.triangle.fill"
            }
        }

        var color: String {
            switch self {
            case .client:         return "blue"
            case .project:        return "indigo"
            case .quote:          return "teal"
            case .estimate:       return "purple"
            case .invoice:        return "green"
            case .employee:       return "orange"
            case .crmContact:     return "pink"
            case .crmOpportunity: return "yellow"
            case .formSubmission: return "gray"
            case .incident:       return "red"
            }
        }
    }

    let id: UUID
    let kind: Kind
    let title: String
    let subtitle: String
    let snippet: String?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.kind == rhs.kind }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(kind)
    }
}

// MARK: - Service

@MainActor
final class UniversalSearchService {

    static let shared = UniversalSearchService()
    private init() { loadRecents() }

    /// Per-entity cap on results returned. Keeps the search sheet readable
    /// and rendering snappy even for tenants with thousands of records.
    private let perKindLimit = 8

    /// Hard ceiling on how many records of any one type we'll scan. Past this
    /// the result quality degrades anyway — better to surface a hint and push
    /// users to the dedicated list view.
    private let perKindScanCap = 1000

    // MARK: - Public

    /// Synchronous in-memory search. Returns deduped, sorted-by-kind results.
    /// Caller is responsible for debouncing the input.
    func search(_ raw: String, in store: AppStore, kinds: Set<UniversalSearchResult.Kind>? = nil) -> [UniversalSearchResult] {
        let needle = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard needle.count >= 2 else { return [] }
        let allowed = kinds ?? Set(UniversalSearchResult.Kind.allCases)

        var out: [UniversalSearchResult] = []

        if allowed.contains(.client) {
            out.append(contentsOf: searchClients(needle, in: store))
        }
        if allowed.contains(.project) {
            out.append(contentsOf: searchProjects(needle, in: store))
        }
        if allowed.contains(.quote) {
            out.append(contentsOf: searchQuotes(needle, in: store))
        }
        if allowed.contains(.estimate) {
            out.append(contentsOf: searchEstimates(needle, in: store))
        }
        if allowed.contains(.invoice) {
            out.append(contentsOf: searchInvoices(needle, in: store))
        }
        if allowed.contains(.employee) {
            out.append(contentsOf: searchEmployees(needle, in: store))
        }
        if allowed.contains(.crmContact) {
            out.append(contentsOf: searchContacts(needle, in: store))
        }
        if allowed.contains(.crmOpportunity) {
            out.append(contentsOf: searchOpportunities(needle, in: store))
        }
        if allowed.contains(.formSubmission) {
            out.append(contentsOf: searchFormSubmissions(needle, in: store))
        }
        if allowed.contains(.incident) {
            out.append(contentsOf: searchIncidents(needle, in: store))
        }
        return out
    }

    /// Groups results by Kind and preserves Kind.allCases ordering for stable
    /// section rendering in the sheet.
    func grouped(_ results: [UniversalSearchResult]) -> [(UniversalSearchResult.Kind, [UniversalSearchResult])] {
        let dict = Dictionary(grouping: results, by: { $0.kind })
        return UniversalSearchResult.Kind.allCases
            .compactMap { kind -> (UniversalSearchResult.Kind, [UniversalSearchResult])? in
                guard let arr = dict[kind], !arr.isEmpty else { return nil }
                return (kind, arr)
            }
    }

    // MARK: - Recent searches

    private static let recentsKey = "aski_universal_recents"
    private(set) var recents: [String] = []

    func recordRecent(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return }
        recents.removeAll { $0.lowercased() == trimmed.lowercased() }
        recents.insert(trimmed, at: 0)
        recents = Array(recents.prefix(10))
        UserDefaults.standard.set(recents, forKey: Self.recentsKey)
    }

    func clearRecents() {
        recents = []
        UserDefaults.standard.removeObject(forKey: Self.recentsKey)
    }

    private func loadRecents() {
        recents = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
    }

    // MARK: - Per-entity searchers

    private func searchClients(_ q: String, in store: AppStore) -> [UniversalSearchResult] {
        store.clients
            .prefix(perKindScanCap)
            .filter { client in
                guard !client.isDeleted else { return false }
                if client.name.lowercased().contains(q) { return true }
                if let s = client.code,         s.lowercased().contains(q) { return true }
                if let s = client.contactName,  s.lowercased().contains(q) { return true }
                if let s = client.contactEmail, s.lowercased().contains(q) { return true }
                if let s = client.contactPhone, s.lowercased().contains(q) { return true }
                if let s = client.notes,        s.lowercased().contains(q) { return true }
                return false
            }
            .prefix(perKindLimit)
            .map { client in
                UniversalSearchResult(
                    id:       client.id,
                    kind:     .client,
                    title:    client.name,
                    subtitle: client.contactName ?? client.contactEmail ?? "Client",
                    snippet:  client.notes
                )
            }
    }

    private func searchProjects(_ q: String, in store: AppStore) -> [UniversalSearchResult] {
        store.projects
            .prefix(perKindScanCap)
            .filter { p in
                guard !p.isDeleted else { return false }
                if p.name.lowercased().contains(q) { return true }
                if p.clientName.lowercased().contains(q) { return true }
                if let id = p.externalID, id.lowercased().contains(q) { return true }
                if let addr = p.siteAddress, addr.lowercased().contains(q) { return true }
                if let n = p.notes, n.lowercased().contains(q) { return true }
                return false
            }
            .prefix(perKindLimit)
            .map { p in
                UniversalSearchResult(
                    id:       p.id,
                    kind:     .project,
                    title:    p.name,
                    subtitle: "\(p.clientName) · \(p.status.rawValue.capitalized)",
                    snippet:  p.siteAddress
                )
            }
    }

    private func searchQuotes(_ q: String, in store: AppStore) -> [UniversalSearchResult] {
        store.quotes
            .prefix(perKindScanCap)
            .filter { quote in
                guard !quote.isDeleted else { return false }
                if quote.jobNumber.lowercased().contains(q) { return true }
                if quote.clientName.lowercased().contains(q) { return true }
                if quote.scopeSummary.lowercased().contains(q) { return true }
                return false
            }
            .prefix(perKindLimit)
            .map { quote in
                UniversalSearchResult(
                    id:       quote.id,
                    kind:     .quote,
                    title:    quote.jobNumber,
                    subtitle: "\(quote.clientName) · \(quote.grandTotal.currencyString)",
                    snippet:  quote.scopeSummary.isEmpty ? nil : quote.scopeSummary
                )
            }
    }

    private func searchEstimates(_ q: String, in store: AppStore) -> [UniversalSearchResult] {
        store.estimates
            .prefix(perKindScanCap)
            .filter { e in
                if e.name.lowercased().contains(q) { return true }
                if e.jobNumber.lowercased().contains(q) { return true }
                if let s = e.scopeDescription, s.lowercased().contains(q) { return true }
                return false
            }
            .prefix(perKindLimit)
            .map { e in
                UniversalSearchResult(
                    id:       e.id,
                    kind:     .estimate,
                    title:    e.name,
                    subtitle: "\(e.jobNumber) · \(e.totalEstimated.currencyString)",
                    snippet:  e.scopeDescription
                )
            }
    }

    private func searchInvoices(_ q: String, in store: AppStore) -> [UniversalSearchResult] {
        store.invoices
            .prefix(perKindScanCap)
            .filter { inv in
                guard !inv.isDeleted else { return false }
                if inv.invoiceNumber.lowercased().contains(q) { return true }
                if inv.billToName.lowercased().contains(q) { return true }
                if inv.poNumber.lowercased().contains(q) { return true }
                return false
            }
            .prefix(perKindLimit)
            .map { inv in
                UniversalSearchResult(
                    id:       inv.id,
                    kind:     .invoice,
                    title:    inv.invoiceNumber,
                    subtitle: "\(inv.billToName) · \(inv.total.currencyString) · \(inv.status.rawValue)",
                    snippet:  inv.poNumber.isEmpty ? nil : "PO \(inv.poNumber)"
                )
            }
    }

    private func searchEmployees(_ q: String, in store: AppStore) -> [UniversalSearchResult] {
        store.employees
            .prefix(perKindScanCap)
            .filter { emp in
                guard !emp.isDeleted else { return false }
                if emp.fullName.lowercased().contains(q) { return true }
                if let s = emp.email, s.lowercased().contains(q) { return true }
                if let s = emp.phone, s.lowercased().contains(q) { return true }
                if let s = emp.trade, s.lowercased().contains(q) { return true }
                if let id = emp.externalID, id.lowercased().contains(q) { return true }
                return false
            }
            .prefix(perKindLimit)
            .map { emp in
                let trade = emp.trade ?? ""
                let subtitle = trade.isEmpty
                    ? emp.role.displayName
                    : "\(trade) · \(emp.role.displayName)"
                return UniversalSearchResult(
                    id:       emp.id,
                    kind:     .employee,
                    title:    emp.fullName,
                    subtitle: subtitle,
                    snippet:  emp.email ?? emp.phone
                )
            }
    }

    private func searchContacts(_ q: String, in store: AppStore) -> [UniversalSearchResult] {
        store.crmContacts
            .prefix(perKindScanCap)
            .filter { c in
                guard !c.isDeleted else { return false }
                if c.fullName.lowercased().contains(q) { return true }
                if c.email.lowercased().contains(q)    { return true }
                if c.phone.lowercased().contains(q)    { return true }
                if c.title.lowercased().contains(q)    { return true }
                if c.notes.lowercased().contains(q)    { return true }
                return false
            }
            .prefix(perKindLimit)
            .map { c in
                let clientName = store.client(id: c.clientID)?.name ?? "Contact"
                return UniversalSearchResult(
                    id:       c.id,
                    kind:     .crmContact,
                    title:    c.fullName,
                    subtitle: "\(c.title.isEmpty ? clientName : c.title) · \(clientName)",
                    snippet:  c.email.isEmpty ? c.phone : c.email
                )
            }
    }

    private func searchOpportunities(_ q: String, in store: AppStore) -> [UniversalSearchResult] {
        store.crmOpportunities
            .prefix(perKindScanCap)
            .filter { opp in
                guard !opp.isDeleted else { return false }
                if opp.title.lowercased().contains(q) { return true }
                if opp.serviceType.lowercased().contains(q) { return true }
                if opp.notes.lowercased().contains(q) { return true }
                return false
            }
            .prefix(perKindLimit)
            .map { opp in
                let clientName = store.client(id: opp.clientID)?.name ?? "Opportunity"
                return UniversalSearchResult(
                    id:       opp.id,
                    kind:     .crmOpportunity,
                    title:    opp.title,
                    subtitle: "\(clientName) · \(opp.stage.rawValue) · \(opp.value.currencyString)",
                    snippet:  opp.notes.isEmpty ? nil : opp.notes
                )
            }
    }

    private func searchFormSubmissions(_ q: String, in store: AppStore) -> [UniversalSearchResult] {
        store.formSubmissions
            .prefix(perKindScanCap)
            .filter { sub in
                guard !sub.isDeleted else { return false }
                let templateName = store.formTemplates.first { $0.id == sub.templateID }?.name ?? ""
                if templateName.lowercased().contains(q) { return true }
                if sub.submittedBy.lowercased().contains(q) { return true }
                if let n = sub.linkedName, n.lowercased().contains(q) { return true }
                return false
            }
            .prefix(perKindLimit)
            .map { sub in
                let templateName = store.formTemplates.first { $0.id == sub.templateID }?.name ?? "Form"
                return UniversalSearchResult(
                    id:       sub.id,
                    kind:     .formSubmission,
                    title:    templateName,
                    subtitle: "\(sub.submittedBy) · \(sub.submittedAt?.shortDate ?? "Draft")",
                    snippet:  sub.linkedName
                )
            }
    }

    private func searchIncidents(_ q: String, in store: AppStore) -> [UniversalSearchResult] {
        store.incidents
            .prefix(perKindScanCap)
            .filter { inc in
                guard !inc.isDeleted else { return false }
                if inc.title.lowercased().contains(q) { return true }
                if inc.description.lowercased().contains(q) { return true }
                if inc.reportedByName.lowercased().contains(q) { return true }
                return false
            }
            .prefix(perKindLimit)
            .map { inc in
                UniversalSearchResult(
                    id:       inc.id,
                    kind:     .incident,
                    title:    inc.title,
                    subtitle: "\(inc.severity.rawValue) · \(inc.status.rawValue) · \(inc.reportedByName)",
                    snippet:  inc.description.isEmpty ? nil : inc.description
                )
            }
    }
}
