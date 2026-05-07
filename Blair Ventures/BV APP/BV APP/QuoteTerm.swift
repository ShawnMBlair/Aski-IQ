// QuoteTerm.swift
// Aski IQ — Terms & Conditions library, Slice B.
//
// Per-quote snapshot of an attached T&C template (or a custom one-off
// term). The snapshot rule: once written, this row's title_snapshot
// and body_snapshot are NEVER read from terms_templates again. Edits
// to the master template only affect future quotes; sent quotes keep
// the wording they were sent with.
//
// Custom one-off terms live in the same table with templateID = nil
// and isCustom = true.

import Foundation
import Combine
import SwiftUI
import Supabase
import PostgREST   // AnyJSON lives here; Supabase re-exports but explicit import keeps the build deterministic

// MARK: - Model

struct QuoteTerm: Identifiable, Codable, Equatable {
    var id:               UUID = UUID()
    var quoteID:          UUID
    /// Back-link to the master template. Nullable for custom terms,
    /// or for legacy entries where the source template was deleted
    /// (FK is ON DELETE SET NULL on the server).
    var templateID:       UUID? = nil

    /// Frozen at attach time. Renderers always use these — never the
    /// live template text — so historical quotes don't drift when
    /// admins edit master templates.
    var titleSnapshot:    String
    var bodySnapshot:     String
    var versionSnapshot:  Int? = nil

    /// 0-indexed; renderer iterates ascending.
    var displayOrder:     Int = 0
    var isCustom:         Bool = false

    var createdAt:        Date = Date()
    var createdBy:        String = ""

    /// Local-only sync state. quote_terms doesn't have a server-side
    /// sync_status column — we manage the queue client-side.
    var syncStatus:       SyncStatus = .local
    var pendingDelete:    Bool = false

    /// Convenience init for attaching from a master template.
    static func snapshot(of template: TermsTemplate,
                         on quoteID: UUID,
                         displayOrder: Int,
                         createdBy: String) -> QuoteTerm {
        QuoteTerm(
            id:              UUID(),
            quoteID:         quoteID,
            templateID:      template.id,
            titleSnapshot:   template.title,
            bodySnapshot:    template.body,
            versionSnapshot: template.version,
            displayOrder:    displayOrder,
            isCustom:        false,
            createdAt:       Date(),
            createdBy:       createdBy,
            syncStatus:      .local
        )
    }

    /// Convenience init for a custom one-off term.
    static func custom(title: String,
                       body: String,
                       on quoteID: UUID,
                       displayOrder: Int,
                       createdBy: String) -> QuoteTerm {
        QuoteTerm(
            id:              UUID(),
            quoteID:         quoteID,
            templateID:      nil,
            titleSnapshot:   title,
            bodySnapshot:    body,
            versionSnapshot: nil,
            displayOrder:    displayOrder,
            isCustom:        true,
            createdAt:       Date(),
            createdBy:       createdBy,
            syncStatus:      .local
        )
    }

    /// Memberwise init — needed because adding a `static func snapshot`
    /// alongside the synthesized memberwise init makes Swift suppress
    /// the synth. Explicit init keeps both sync engine call sites and
    /// the static factories happy.
    init(id: UUID = UUID(),
         quoteID: UUID,
         templateID: UUID? = nil,
         titleSnapshot: String,
         bodySnapshot: String,
         versionSnapshot: Int? = nil,
         displayOrder: Int = 0,
         isCustom: Bool = false,
         createdAt: Date = Date(),
         createdBy: String = "",
         syncStatus: SyncStatus = .local,
         pendingDelete: Bool = false) {
        self.id = id
        self.quoteID = quoteID
        self.templateID = templateID
        self.titleSnapshot = titleSnapshot
        self.bodySnapshot = bodySnapshot
        self.versionSnapshot = versionSnapshot
        self.displayOrder = displayOrder
        self.isCustom = isCustom
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.syncStatus = syncStatus
        self.pendingDelete = pendingDelete
    }
}

// MARK: - Read-only gate

extension QuoteStatus {
    /// Slice B rule: once a quote has been sent or reached a terminal
    /// state, attached T&C are immutable — preview only. Drafts and
    /// approved quotes are still editable.
    var termsAreReadOnly: Bool {
        switch self {
        case .draft, .approved: return false
        case .sent, .accepted, .declined: return true
        }
    }
}

// MARK: - AppStore Storage

extension AppStore {

    /// All terms for the current tenant, including pending-delete and
    /// pending-push. View code uses `quoteTerms(for:)` rather than
    /// reading this directly.
    var allQuoteTerms: [QuoteTerm] {
        if let cached = AppStore._quoteTermsCache { return cached }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = UserDefaults.standard.data(forKey: "ak_quote_terms"),
              let arr  = try? decoder.decode([QuoteTerm].self, from: data) else {
            return []
        }
        AppStore._quoteTermsCache = arr
        return arr
    }

    fileprivate func writeQuoteTermsBacking(_ arr: [QuoteTerm]) {
        AppStore._quoteTermsCache = arr
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(arr) {
            UserDefaults.standard.set(data, forKey: "ak_quote_terms")
        }
    }

    private static var _quoteTermsCache: [QuoteTerm]? = nil

    // MARK: - Public accessors

    /// Returns the visible (non-pending-delete) terms for a quote in
    /// display order. The order is what the picker, list view, and
    /// PDF renderer all consume.
    func quoteTerms(for quoteID: UUID) -> [QuoteTerm] {
        allQuoteTerms
            .filter { $0.quoteID == quoteID && !$0.pendingDelete }
            .sorted { $0.displayOrder < $1.displayOrder }
    }

    // MARK: - Mutations

    /// Insert or update. Stamps pending and triggers a push pass.
    func upsertQuoteTerm(_ term: QuoteTerm) {
        var copy = term
        if copy.syncStatus == .synced { copy.syncStatus = .pending }
        if copy.syncStatus == .local  { copy.syncStatus = .pending }

        var current = allQuoteTerms
        if let i = current.firstIndex(where: { $0.id == copy.id }) {
            current[i] = copy
        } else {
            current.append(copy)
        }
        writeQuoteTermsBacking(current)
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingQuoteTerms() }
    }

    /// Soft-delete locally + queue a server delete. The row stays in
    /// the cache with pendingDelete = true until the sync engine
    /// confirms removal, at which point it's purged.
    func deleteQuoteTerm(_ term: QuoteTerm) {
        var current = allQuoteTerms
        if let i = current.firstIndex(where: { $0.id == term.id }) {
            current[i].pendingDelete = true
            current[i].syncStatus = .pending
        }
        writeQuoteTermsBacking(current)
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingQuoteTerms() }
    }

    /// Reorder the supplied list — the array's index becomes the new
    /// display_order for each term. Caller passes the post-reorder
    /// list (e.g. from SwiftUI's .onMove).
    func reorderQuoteTerms(_ ordered: [QuoteTerm]) {
        var current = allQuoteTerms
        for (newOrder, term) in ordered.enumerated() {
            guard let i = current.firstIndex(where: { $0.id == term.id }) else { continue }
            if current[i].displayOrder != newOrder {
                current[i].displayOrder = newOrder
                current[i].syncStatus   = .pending
            }
        }
        writeQuoteTermsBacking(current)
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingQuoteTerms() }
    }

    /// Convenience: snapshot a master template onto a quote at the
    /// next display_order slot. Used by the picker.
    func attachTermsTemplateToQuote(_ template: TermsTemplate, quoteID: UUID) {
        let nextOrder = (quoteTerms(for: quoteID).map { $0.displayOrder }.max() ?? -1) + 1
        let term = QuoteTerm.snapshot(
            of:           template,
            on:           quoteID,
            displayOrder: nextOrder,
            createdBy:    currentUser?.fullName ?? ""
        )
        upsertQuoteTerm(term)
    }

    /// Convenience: append a custom one-off term.
    func addCustomQuoteTerm(quoteID: UUID, title: String, body: String) {
        let nextOrder = (quoteTerms(for: quoteID).map { $0.displayOrder }.max() ?? -1) + 1
        let term = QuoteTerm.custom(
            title:        title,
            body:         body,
            on:           quoteID,
            displayOrder: nextOrder,
            createdBy:    currentUser?.fullName ?? ""
        )
        upsertQuoteTerm(term)
    }

    /// Slice B default-attachment rule: when called on a quote with
    /// `termsDefaultApplied = false`, snapshots all default templates
    /// (active + is_default) at the next available display_order
    /// slots and flips the ledger flag. Subsequent calls are no-ops.
    /// Caller is responsible for upserting the mutated quote.
    func applyDefaultTermsIfNeeded(to quote: inout Quote) {
        guard !quote.termsDefaultApplied else { return }
        let defaults = activeTermsTemplates.filter { $0.isDefault }
        guard !defaults.isEmpty else {
            // No defaults configured — still flip the flag so a future
            // admin enabling a default doesn't retroactively attach
            // it to old quotes.
            quote.termsDefaultApplied = true
            return
        }
        var nextOrder = (quoteTerms(for: quote.id).map { $0.displayOrder }.max() ?? -1) + 1
        for tmpl in defaults
            .sorted(by: { $0.category.sortOrder < $1.category.sortOrder }) {
            let term = QuoteTerm.snapshot(
                of:           tmpl,
                on:           quote.id,
                displayOrder: nextOrder,
                createdBy:    currentUser?.fullName ?? ""
            )
            upsertQuoteTerm(term)
            nextOrder += 1
        }
        quote.termsDefaultApplied = true
    }
}

// MARK: - Slice C: Auto-suggestion resolver
//
// Walks quote line items → CompanyCostCode (matched by `code`) →
// service_types tags → set of distinct ServiceTypes the quote covers.
// The picker uses this to pin a "Suggested for this quote" section
// at the top; the send-time validator uses it to detect missing
// matching templates ("you have scaffolding work but no Scaffolding
// Terms attached").
//
// Empty result is the common case for line items whose cost codes
// haven't been tagged yet — the suggester just stays empty for that
// quote and admins can tag the codes later via Settings → Cost Codes.

extension AppStore {

    /// Distinct service types covered by the supplied line items, based
    /// on the admin-assigned `serviceTypes` on each matching
    /// CompanyCostCode. Line items whose cost code has no tags or
    /// doesn't match any code are silently skipped.
    func serviceTypes(forLineItems items: [CostCodeItem]) -> Set<ServiceType> {
        guard !items.isEmpty else { return [] }
        // Index cost codes once for O(1) lookup. Duplicate codes
        // (shouldn't happen in practice) collapse to last-wins, which
        // is fine for the suggestion side of the feature.
        var lookup: [String: CompanyCostCode] = [:]
        for c in companyCostCodes { lookup[c.code] = c }
        var out: Set<ServiceType> = []
        for item in items {
            guard let code = lookup[item.code] else { continue }
            for st in code.serviceTypes { out.insert(st) }
        }
        return out
    }

    /// Active templates whose `appliesToServiceTypes` overlaps with any
    /// of the supplied service types. Used by QuoteTermsPickerSheet's
    /// Suggested section. Already-attached templates are excluded
    /// (the caller passes them via `excludingTemplateIDs`) so the
    /// Suggested section doesn't double-list things the user already
    /// picked.
    func suggestedTermsTemplates(
        forServiceTypes serviceTypes: Set<ServiceType>,
        excludingTemplateIDs excluded: Set<UUID> = []
    ) -> [TermsTemplate] {
        guard !serviceTypes.isEmpty else { return [] }
        return activeTermsTemplates.filter { t in
            guard !excluded.contains(t.id) else { return false }
            return !Set(t.appliesToServiceTypes).isDisjoint(with: serviceTypes)
        }
    }

    /// Service types covered by the supplied line items but NOT covered
    /// by any currently-attached template's `appliesToServiceTypes`.
    /// This is the gap the send-time warning surfaces. Empty set means
    /// every service category covered by the line items already has a
    /// matching template attached. Takes lineItems + quoteID directly
    /// so it works in QuoteCreateView's pre-save path (no Quote object
    /// exists yet for new quotes).
    func unmatchedServiceTypes(forLineItems items: [CostCodeItem],
                                 quoteID: UUID) -> Set<ServiceType> {
        let needed = serviceTypes(forLineItems: items)
        guard !needed.isEmpty else { return [] }
        let attached = quoteTerms(for: quoteID)
            .compactMap { $0.templateID }
        let attachedTemplateServiceTypes: Set<ServiceType> = activeTermsTemplates
            .filter { attached.contains($0.id) }
            .reduce(into: []) { acc, t in
                for st in t.appliesToServiceTypes { acc.insert(st) }
            }
        return needed.subtracting(attachedTemplateServiceTypes)
    }
}

// MARK: - Slice C: Send-time warnings

/// A soft warning to surface in a confirmation dialog before sending a
/// quote. None of these block sending — the user can always tap "Send
/// anyway" to override.
enum QuoteSendWarning: Identifiable {
    case noTermsAttached
    case missingServiceTypes(Set<ServiceType>)

    var id: String {
        switch self {
        case .noTermsAttached:                return "noTermsAttached"
        case .missingServiceTypes(let s):
            return "missing:" + s.map { $0.rawValue }.sorted().joined(separator: ",")
        }
    }

    /// Human-readable line for the confirmation dialog.
    var message: String {
        switch self {
        case .noTermsAttached:
            return "This quote has no Terms & Conditions attached."
        case .missingServiceTypes(let s):
            let names = s.map { $0.displayName }.sorted().joined(separator: ", ")
            return "This quote includes \(names) work but no matching Terms & Conditions are attached."
        }
    }
}

extension AppStore {
    /// Computes all soft warnings for the supplied line items + already-
    /// attached terms (looked up via quoteID). Returns empty when the
    /// quote is good to send without prompting.
    func sendTimeWarnings(forLineItems items: [CostCodeItem],
                          quoteID: UUID) -> [QuoteSendWarning] {
        var out: [QuoteSendWarning] = []
        if quoteTerms(for: quoteID).isEmpty {
            out.append(.noTermsAttached)
        }
        let unmatched = unmatchedServiceTypes(forLineItems: items, quoteID: quoteID)
        if !unmatched.isEmpty {
            out.append(.missingServiceTypes(unmatched))
        }
        return out
    }
}

// MARK: - Sync Engine

private func parseQTDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: s) { return d }
    let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
    return f2.date(from: s)
}

extension SyncEngine {

    /// Pull every quote_terms row for the current tenant. Tenant
    /// scoping happens via the EXISTS-on-quotes RLS policy — we
    /// don't filter client-side. Wholesale replace; merges any
    /// in-flight pending edits back in afterward.
    func pullQuoteTerms() async {
        guard store.currentCompanyID != nil else { return }
        do {
            struct Row: Codable {
                let id:                String
                let quote_id:          String
                let terms_template_id: String?
                let title_snapshot:    String
                let body_snapshot:     String
                let version_snapshot:  Int?
                let display_order:     Int?
                let is_custom:         Bool?
                let created_at:        String?
                let created_by:        String?
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.quoteTerms)
                .select()
                .execute()
                .value

            let serverTerms: [QuoteTerm] = rows.compactMap { r in
                guard let id = UUID(uuidString: r.id),
                      let qid = UUID(uuidString: r.quote_id) else { return nil }
                return QuoteTerm(
                    id:              id,
                    quoteID:         qid,
                    templateID:      r.terms_template_id.flatMap(UUID.init(uuidString:)),
                    titleSnapshot:   r.title_snapshot,
                    bodySnapshot:    r.body_snapshot,
                    versionSnapshot: r.version_snapshot,
                    displayOrder:    r.display_order ?? 0,
                    isCustom:        r.is_custom ?? false,
                    createdAt:       parseQTDate(r.created_at) ?? Date(),
                    createdBy:       r.created_by ?? "",
                    syncStatus:      .synced
                )
            }

            // Preserve any rows we still need to push (local edits
            // and pending deletes that haven't been confirmed yet).
            // Anything else is server-authoritative.
            await MainActor.run {
                let local = store.allQuoteTerms.filter {
                    $0.syncStatus == .local
                    || $0.syncStatus == .pending
                    || $0.syncStatus == .failed
                    || $0.pendingDelete
                }
                let serverIDs = Set(serverTerms.map { $0.id })
                // Drop server rows that we have a local-pending edit for.
                let kept = serverTerms.filter { st in
                    !local.contains(where: { $0.id == st.id })
                }
                let merged = kept + local.filter { !$0.pendingDelete || serverIDs.contains($0.id) }
                store.writeQuoteTermsBacking(merged)
                store.objectWillChange.send()
            }
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    /// Push one term — upsert if pendingDelete is false, delete if
    /// pendingDelete is true. Marks .synced on success.
    func pushQuoteTerm(_ term: QuoteTerm) async {
        do {
            if term.pendingDelete {
                try await supabase
                    .from(SupabaseTable.quoteTerms)
                    .delete()
                    .eq("id", value: term.id.uuidString)
                    .execute()
                await MainActor.run {
                    var current = store.allQuoteTerms
                    current.removeAll { $0.id == term.id }
                    store.writeQuoteTermsBacking(current)
                    store.objectWillChange.send()
                }
                return
            }

            let isoFmt = ISO8601DateFormatter()
            isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var payload: [String: AnyJSON] = [
                "id":              .string(term.id.uuidString),
                "quote_id":        .string(term.quoteID.uuidString),
                "title_snapshot":  .string(term.titleSnapshot),
                "body_snapshot":   .string(term.bodySnapshot),
                "display_order":   .integer(term.displayOrder),
                "is_custom":       .bool(term.isCustom),
                "created_at":      .string(isoFmt.string(from: term.createdAt)),
                "created_by":      .string(term.createdBy),
            ]
            if let tid = term.templateID {
                payload["terms_template_id"] = .string(tid.uuidString)
            } else {
                payload["terms_template_id"] = .null
            }
            if let v = term.versionSnapshot {
                payload["version_snapshot"] = .integer(v)
            } else {
                payload["version_snapshot"] = .null
            }

            try await supabase
                .from(SupabaseTable.quoteTerms)
                .upsert(payload)
                .execute()

            await MainActor.run {
                var current = store.allQuoteTerms
                if let i = current.firstIndex(where: { $0.id == term.id }) {
                    current[i].syncStatus = .synced
                }
                store.writeQuoteTermsBacking(current)
            }
        } catch {
            print("⚠️ \(#function) failed for term \(term.titleSnapshot): \(error)")
            CrashReporter.capture(error: error, context: [
                "operation": "\(#function)",
                "term_id":   term.id.uuidString,
            ])
            await MainActor.run {
                var current = store.allQuoteTerms
                if let i = current.firstIndex(where: { $0.id == term.id }) {
                    current[i].syncStatus = .failed
                }
                store.writeQuoteTermsBacking(current)
            }
        }
    }

    /// Drain the local queue. Called automatically by every mutation
    /// helper on AppStore, plus by the global push pass.
    func pushPendingQuoteTerms() async {
        let pending = await MainActor.run {
            store.allQuoteTerms.filter {
                $0.syncStatus == .pending
                || $0.syncStatus == .local
                || $0.syncStatus == .failed
                || $0.pendingDelete
            }
        }
        guard !pending.isEmpty else { return }
        for t in pending {
            await pushQuoteTerm(t)
        }
    }
}
