// EstimateTerm.swift
// Aski IQ — Terms & Conditions for Estimates (Path-A clone of QuoteTerm).
//
// Per-estimate snapshot of an attached T&C template (or a custom
// one-off term). Snapshot rule: once written, this row's
// title_snapshot and body_snapshot are NEVER read from
// terms_templates again. Edits to the master template only affect
// future estimates; submitted estimates keep the wording they were
// submitted with.
//
// Custom one-off terms live in the same table with templateID = nil
// and isCustom = true.
//
// IMPORTANT: this file is a deliberate clone of QuoteTerm.swift.
// Do not refactor into a polymorphic parent_type / parent_id model
// without aligning the master prompt — see the migration file
// header for rationale.

import Foundation
import Combine
import SwiftUI
import Supabase
import PostgREST

// MARK: - Model

struct EstimateTerm: Identifiable, Codable, Equatable {
    var id:               UUID = UUID()
    var estimateID:       UUID
    /// Back-link to the master template. Nullable for custom terms,
    /// or for legacy entries where the source template was deleted
    /// (FK is ON DELETE SET NULL on the server).
    var templateID:       UUID? = nil

    /// Frozen at attach time. Renderers always use these — never the
    /// live template text — so historical estimates don't drift when
    /// admins edit master templates.
    var titleSnapshot:    String
    var bodySnapshot:     String
    var versionSnapshot:  Int? = nil

    /// 0-indexed; renderer iterates ascending.
    var displayOrder:     Int = 0
    var isCustom:         Bool = false

    var createdAt:        Date = Date()
    var createdBy:        String = ""

    /// Local-only sync state. estimate_terms doesn't have a server-
    /// side sync_status column — we manage the queue client-side.
    var syncStatus:       SyncStatus = .local
    var pendingDelete:    Bool = false

    /// Convenience init for attaching from a master template.
    static func snapshot(of template: TermsTemplate,
                         on estimateID: UUID,
                         displayOrder: Int,
                         createdBy: String) -> EstimateTerm {
        EstimateTerm(
            id:              UUID(),
            estimateID:      estimateID,
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
                       on estimateID: UUID,
                       displayOrder: Int,
                       createdBy: String) -> EstimateTerm {
        EstimateTerm(
            id:              UUID(),
            estimateID:      estimateID,
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

    /// Memberwise init — explicit for the same reason QuoteTerm has one
    /// (static factory presence suppresses synth).
    init(id: UUID = UUID(),
         estimateID: UUID,
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
        self.estimateID = estimateID
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

extension EstimateStatus {
    /// Mirror of QuoteStatus.termsAreReadOnly — once an estimate has
    /// been submitted, won, lost, converted, or cancelled the attached
    /// terms are immutable. Drafts (.estimating, .internalReview,
    /// .rfqReceived) remain editable.
    /// IMPORTANT: opening / selecting Terms must NEVER trigger a
    /// status change — this property is read-only and only used to
    /// gate the UI. Status transitions happen only through
    /// CommercialWorkflowService and the explicit save() pipeline.
    var termsAreReadOnly: Bool {
        switch self {
        case .submitted, .awarded, .converted, .lost, .cancelled:
            return true
        default:
            return false
        }
    }
}

// MARK: - AppStore Storage

extension AppStore {

    /// All estimate terms for the current tenant, including
    /// pending-delete and pending-push. View code uses
    /// `estimateTerms(for:)` rather than reading this directly.
    var allEstimateTerms: [EstimateTerm] {
        if let cached = AppStore._estimateTermsCache { return cached }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = UserDefaults.standard.data(forKey: "ak_estimate_terms"),
              let arr  = try? decoder.decode([EstimateTerm].self, from: data) else {
            return []
        }
        AppStore._estimateTermsCache = arr
        return arr
    }

    fileprivate func writeEstimateTermsBacking(_ arr: [EstimateTerm]) {
        AppStore._estimateTermsCache = arr
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(arr) {
            UserDefaults.standard.set(data, forKey: "ak_estimate_terms")
        }
    }

    private static var _estimateTermsCache: [EstimateTerm]? = nil

    // MARK: - Public accessors

    /// Returns the visible (non-pending-delete) terms for an estimate
    /// in display order.
    func estimateTerms(for estimateID: UUID) -> [EstimateTerm] {
        allEstimateTerms
            .filter { $0.estimateID == estimateID && !$0.pendingDelete }
            .sorted { $0.displayOrder < $1.displayOrder }
    }

    // MARK: - Mutations

    /// Insert or update. Stamps pending and triggers a push pass.
    /// Calling this NEVER changes the parent estimate's status — it
    /// only writes the terms row.
    func upsertEstimateTerm(_ term: EstimateTerm) {
        var copy = term
        if copy.syncStatus == .synced { copy.syncStatus = .pending }
        if copy.syncStatus == .local  { copy.syncStatus = .pending }

        var current = allEstimateTerms
        if let i = current.firstIndex(where: { $0.id == copy.id }) {
            current[i] = copy
        } else {
            current.append(copy)
        }
        writeEstimateTermsBacking(current)
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingEstimateTerms() }
    }

    /// Soft-delete locally + queue a server delete.
    func deleteEstimateTerm(_ term: EstimateTerm) {
        var current = allEstimateTerms
        if let i = current.firstIndex(where: { $0.id == term.id }) {
            current[i].pendingDelete = true
            current[i].syncStatus = .pending
        }
        writeEstimateTermsBacking(current)
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingEstimateTerms() }
    }

    /// Reorder the supplied list — array index becomes the new
    /// display_order for each term.
    func reorderEstimateTerms(_ ordered: [EstimateTerm]) {
        var current = allEstimateTerms
        for (newOrder, term) in ordered.enumerated() {
            guard let i = current.firstIndex(where: { $0.id == term.id }) else { continue }
            if current[i].displayOrder != newOrder {
                current[i].displayOrder = newOrder
                current[i].syncStatus   = .pending
            }
        }
        writeEstimateTermsBacking(current)
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingEstimateTerms() }
    }

    /// Convenience: snapshot a master template onto an estimate.
    func attachTermsTemplateToEstimate(_ template: TermsTemplate, estimateID: UUID) {
        let nextOrder = (estimateTerms(for: estimateID).map { $0.displayOrder }.max() ?? -1) + 1
        let term = EstimateTerm.snapshot(
            of:           template,
            on:           estimateID,
            displayOrder: nextOrder,
            createdBy:    currentUser?.fullName ?? ""
        )
        upsertEstimateTerm(term)
    }

    /// Convenience: append a custom one-off term.
    func addCustomEstimateTerm(estimateID: UUID, title: String, body: String) {
        let nextOrder = (estimateTerms(for: estimateID).map { $0.displayOrder }.max() ?? -1) + 1
        let term = EstimateTerm.custom(
            title:        title,
            body:         body,
            on:           estimateID,
            displayOrder: nextOrder,
            createdBy:    currentUser?.fullName ?? ""
        )
        upsertEstimateTerm(term)
    }

    /// Default-attachment rule: when called on an estimate with
    /// `termsDefaultApplied = false`, snapshots all default templates
    /// at the next display_order slots and flips the ledger flag.
    /// Subsequent calls are no-ops. Caller is responsible for
    /// upserting the mutated estimate.
    func applyDefaultTermsIfNeeded(to estimate: inout Estimate) {
        guard !estimate.termsDefaultApplied else { return }
        let defaults = activeTermsTemplates.filter { $0.isDefault }
        guard !defaults.isEmpty else {
            estimate.termsDefaultApplied = true
            return
        }
        var nextOrder = (estimateTerms(for: estimate.id).map { $0.displayOrder }.max() ?? -1) + 1
        for tmpl in defaults
            .sorted(by: { $0.category.sortOrder < $1.category.sortOrder }) {
            let term = EstimateTerm.snapshot(
                of:           tmpl,
                on:           estimate.id,
                displayOrder: nextOrder,
                createdBy:    currentUser?.fullName ?? ""
            )
            upsertEstimateTerm(term)
            nextOrder += 1
        }
        estimate.termsDefaultApplied = true
    }

    // MARK: - Estimate → Quote conversion carry-forward

    /// When an estimate is converted into a quote, snapshot every
    /// attached estimate term onto the new quote as a quote term.
    /// Safe to call multiple times — exits early if the quote already
    /// has terms attached. Returns the count of terms carried forward.
    @discardableResult
    func carryEstimateTermsForwardToQuote(estimateID: UUID, quoteID: UUID) -> Int {
        let estTerms = estimateTerms(for: estimateID)
        guard !estTerms.isEmpty else { return 0 }
        // If the quote already has terms (e.g. defaults were applied
        // by applyDefaultTermsIfNeeded() on QuoteCreateView's onAppear),
        // skip estimate terms whose templateID is already present.
        // Custom terms (no templateID) are matched by exact title +
        // body match — same wording = same intent, no duplication.
        let existingQuoteTerms = quoteTerms(for: quoteID)
        let attachedTemplateIDs: Set<UUID> = Set(existingQuoteTerms.compactMap { $0.templateID })
        let attachedCustomKeys: Set<String> = Set(
            existingQuoteTerms
                .filter { $0.templateID == nil }
                .map { "\($0.titleSnapshot)|\($0.bodySnapshot)" }
        )
        var nextOrder = (existingQuoteTerms.map { $0.displayOrder }.max() ?? -1) + 1
        var carried = 0
        for et in estTerms.sorted(by: { $0.displayOrder < $1.displayOrder }) {
            // De-dup: template-backed terms by templateID; custom terms
            // by exact title+body match.
            if let tid = et.templateID, attachedTemplateIDs.contains(tid) {
                continue
            }
            if et.templateID == nil {
                let key = "\(et.titleSnapshot)|\(et.bodySnapshot)"
                if attachedCustomKeys.contains(key) { continue }
            }

            // Build a NEW QuoteTerm with a fresh UUID — never reuse
            // the estimate term's id (it'd violate uniqueness).
            let qt: QuoteTerm
            if et.isCustom || et.templateID == nil {
                qt = QuoteTerm.custom(
                    title:        et.titleSnapshot,
                    body:         et.bodySnapshot,
                    on:           quoteID,
                    displayOrder: nextOrder,
                    createdBy:    et.createdBy
                )
            } else if let tid = et.templateID,
                      let tpl = activeTermsTemplates.first(where: { $0.id == tid }) {
                qt = QuoteTerm.snapshot(
                    of:           tpl,
                    on:           quoteID,
                    displayOrder: nextOrder,
                    createdBy:    et.createdBy
                )
            } else {
                // Template was deleted server-side after the estimate
                // was built — fall back to copying the snapshot text
                // verbatim so historical wording survives.
                qt = QuoteTerm.custom(
                    title:        et.titleSnapshot,
                    body:         et.bodySnapshot,
                    on:           quoteID,
                    displayOrder: nextOrder,
                    createdBy:    et.createdBy
                )
            }
            upsertQuoteTerm(qt)
            nextOrder += 1
            carried += 1
        }
        return carried
    }
}

// MARK: - Sync Engine

private func parseETDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: s) { return d }
    let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
    return f2.date(from: s)
}

extension SyncEngine {

    /// Pull every estimate_terms row for the current tenant. RLS
    /// restricts to the caller's company via EXISTS-on-estimates.
    func pullEstimateTerms() async {
        guard store.currentCompanyID != nil else { return }
        do {
            struct Row: Codable {
                let id:                String
                let estimate_id:       String
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
                .from(SupabaseTable.estimateTerms)
                .select()
                .execute()
                .value

            let serverTerms: [EstimateTerm] = rows.compactMap { r in
                guard let id = UUID(uuidString: r.id),
                      let eid = UUID(uuidString: r.estimate_id) else { return nil }
                return EstimateTerm(
                    id:              id,
                    estimateID:      eid,
                    templateID:      r.terms_template_id.flatMap(UUID.init(uuidString:)),
                    titleSnapshot:   r.title_snapshot,
                    bodySnapshot:    r.body_snapshot,
                    versionSnapshot: r.version_snapshot,
                    displayOrder:    r.display_order ?? 0,
                    isCustom:        r.is_custom ?? false,
                    createdAt:       parseETDate(r.created_at) ?? Date(),
                    createdBy:       r.created_by ?? "",
                    syncStatus:      .synced
                )
            }

            // Same merge strategy as pullQuoteTerms — preserve
            // anything still pending push or pending delete.
            await MainActor.run {
                let local = store.allEstimateTerms.filter {
                    $0.syncStatus == .local
                    || $0.syncStatus == .pending
                    || $0.syncStatus == .failed
                    || $0.pendingDelete
                }
                let serverIDs = Set(serverTerms.map { $0.id })
                let kept = serverTerms.filter { st in
                    !local.contains(where: { $0.id == st.id })
                }
                let merged = kept + local.filter { !$0.pendingDelete || serverIDs.contains($0.id) }
                store.writeEstimateTermsBacking(merged)
                store.objectWillChange.send()
            }
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    /// Push one term — upsert if pendingDelete is false, delete if
    /// pendingDelete is true.
    func pushEstimateTerm(_ term: EstimateTerm) async {
        do {
            if term.pendingDelete {
                try await supabase
                    .from(SupabaseTable.estimateTerms)
                    .delete()
                    .eq("id", value: term.id.uuidString)
                    .execute()
                await MainActor.run {
                    var current = store.allEstimateTerms
                    current.removeAll { $0.id == term.id }
                    store.writeEstimateTermsBacking(current)
                    store.objectWillChange.send()
                }
                return
            }

            let isoFmt = ISO8601DateFormatter()
            isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var payload: [String: AnyJSON] = [
                "id":              .string(term.id.uuidString),
                "estimate_id":     .string(term.estimateID.uuidString),
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
                .from(SupabaseTable.estimateTerms)
                .upsert(payload)
                .execute()

            await MainActor.run {
                var current = store.allEstimateTerms
                if let i = current.firstIndex(where: { $0.id == term.id }) {
                    current[i].syncStatus = .synced
                }
                store.writeEstimateTermsBacking(current)
            }
        } catch {
            print("⚠️ \(#function) failed for term \(term.titleSnapshot): \(error)")
            CrashReporter.capture(error: error, context: [
                "operation": "\(#function)",
                "term_id":   term.id.uuidString,
            ])
            await MainActor.run {
                var current = store.allEstimateTerms
                if let i = current.firstIndex(where: { $0.id == term.id }) {
                    current[i].syncStatus = .failed
                }
                store.writeEstimateTermsBacking(current)
            }
        }
    }

    /// Drain the local queue.
    func pushPendingEstimateTerms() async {
        let pending = await MainActor.run {
            store.allEstimateTerms.filter {
                $0.syncStatus == .pending
                || $0.syncStatus == .local
                || $0.syncStatus == .failed
                || $0.pendingDelete
            }
        }
        guard !pending.isEmpty else { return }
        for t in pending {
            await pushEstimateTerm(t)
        }
    }
}
