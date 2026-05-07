// MaterialSaleTerm.swift
// Aski IQ — Terms & Conditions for Material Sales (Path-A clone of QuoteTerm).
//
// Per-sale snapshot of an attached T&C template (or a custom one-off
// term). Snapshot rule matches QuoteTerm and EstimateTerm — once
// written, title_snapshot and body_snapshot are NEVER read from
// terms_templates again. Edits to the master template only affect
// future sales.
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

struct MaterialSaleTerm: Identifiable, Codable, Equatable {
    var id:               UUID = UUID()
    var materialSaleID:   UUID
    var templateID:       UUID? = nil

    var titleSnapshot:    String
    var bodySnapshot:     String
    var versionSnapshot:  Int? = nil

    var displayOrder:     Int = 0
    var isCustom:         Bool = false

    var createdAt:        Date = Date()
    var createdBy:        String = ""

    var syncStatus:       SyncStatus = .local
    var pendingDelete:    Bool = false

    /// Convenience init for attaching from a master template.
    static func snapshot(of template: TermsTemplate,
                         on materialSaleID: UUID,
                         displayOrder: Int,
                         createdBy: String) -> MaterialSaleTerm {
        MaterialSaleTerm(
            id:              UUID(),
            materialSaleID:  materialSaleID,
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
                       on materialSaleID: UUID,
                       displayOrder: Int,
                       createdBy: String) -> MaterialSaleTerm {
        MaterialSaleTerm(
            id:              UUID(),
            materialSaleID:  materialSaleID,
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

    init(id: UUID = UUID(),
         materialSaleID: UUID,
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
        self.materialSaleID = materialSaleID
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

extension MaterialSaleStatus {
    /// Once a sale is paid or cancelled the attached terms are
    /// immutable. Pre-paid statuses (.draft, .quoted, .ordered,
    /// .invoiced) remain editable. Mirrors QuoteStatus.termsAreReadOnly.
    /// IMPORTANT: opening / selecting Terms must NEVER trigger a
    /// status change.
    var termsAreReadOnly: Bool {
        switch self {
        case .paid, .cancelled: return true
        default: return false
        }
    }
}

// MARK: - AppStore Storage

extension AppStore {

    var allMaterialSaleTerms: [MaterialSaleTerm] {
        if let cached = AppStore._materialSaleTermsCache { return cached }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = UserDefaults.standard.data(forKey: "ak_material_sale_terms"),
              let arr  = try? decoder.decode([MaterialSaleTerm].self, from: data) else {
            return []
        }
        AppStore._materialSaleTermsCache = arr
        return arr
    }

    fileprivate func writeMaterialSaleTermsBacking(_ arr: [MaterialSaleTerm]) {
        AppStore._materialSaleTermsCache = arr
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(arr) {
            UserDefaults.standard.set(data, forKey: "ak_material_sale_terms")
        }
    }

    private static var _materialSaleTermsCache: [MaterialSaleTerm]? = nil

    // MARK: - Public accessors

    func materialSaleTerms(for saleID: UUID) -> [MaterialSaleTerm] {
        allMaterialSaleTerms
            .filter { $0.materialSaleID == saleID && !$0.pendingDelete }
            .sorted { $0.displayOrder < $1.displayOrder }
    }

    // MARK: - Mutations

    /// Insert or update. Stamps pending and triggers a push pass.
    /// Calling this NEVER changes the parent sale's status — it only
    /// writes the terms row.
    func upsertMaterialSaleTerm(_ term: MaterialSaleTerm) {
        var copy = term
        if copy.syncStatus == .synced { copy.syncStatus = .pending }
        if copy.syncStatus == .local  { copy.syncStatus = .pending }

        var current = allMaterialSaleTerms
        if let i = current.firstIndex(where: { $0.id == copy.id }) {
            current[i] = copy
        } else {
            current.append(copy)
        }
        writeMaterialSaleTermsBacking(current)
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingMaterialSaleTerms() }
    }

    func deleteMaterialSaleTerm(_ term: MaterialSaleTerm) {
        var current = allMaterialSaleTerms
        if let i = current.firstIndex(where: { $0.id == term.id }) {
            current[i].pendingDelete = true
            current[i].syncStatus = .pending
        }
        writeMaterialSaleTermsBacking(current)
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingMaterialSaleTerms() }
    }

    func reorderMaterialSaleTerms(_ ordered: [MaterialSaleTerm]) {
        var current = allMaterialSaleTerms
        for (newOrder, term) in ordered.enumerated() {
            guard let i = current.firstIndex(where: { $0.id == term.id }) else { continue }
            if current[i].displayOrder != newOrder {
                current[i].displayOrder = newOrder
                current[i].syncStatus   = .pending
            }
        }
        writeMaterialSaleTermsBacking(current)
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingMaterialSaleTerms() }
    }

    func attachTermsTemplateToMaterialSale(_ template: TermsTemplate, saleID: UUID) {
        let nextOrder = (materialSaleTerms(for: saleID).map { $0.displayOrder }.max() ?? -1) + 1
        let term = MaterialSaleTerm.snapshot(
            of:             template,
            on:             saleID,
            displayOrder:   nextOrder,
            createdBy:      currentUser?.fullName ?? ""
        )
        upsertMaterialSaleTerm(term)
    }

    func addCustomMaterialSaleTerm(saleID: UUID, title: String, body: String) {
        let nextOrder = (materialSaleTerms(for: saleID).map { $0.displayOrder }.max() ?? -1) + 1
        let term = MaterialSaleTerm.custom(
            title:          title,
            body:           body,
            on:             saleID,
            displayOrder:   nextOrder,
            createdBy:      currentUser?.fullName ?? ""
        )
        upsertMaterialSaleTerm(term)
    }

    /// Default-attachment rule. Caller is responsible for upserting
    /// the mutated sale.
    func applyDefaultTermsIfNeeded(to sale: inout MaterialSale) {
        guard !sale.termsDefaultApplied else { return }
        let defaults = activeTermsTemplates.filter { $0.isDefault }
        guard !defaults.isEmpty else {
            sale.termsDefaultApplied = true
            return
        }
        var nextOrder = (materialSaleTerms(for: sale.id).map { $0.displayOrder }.max() ?? -1) + 1
        for tmpl in defaults
            .sorted(by: { $0.category.sortOrder < $1.category.sortOrder }) {
            let term = MaterialSaleTerm.snapshot(
                of:           tmpl,
                on:           sale.id,
                displayOrder: nextOrder,
                createdBy:    currentUser?.fullName ?? ""
            )
            upsertMaterialSaleTerm(term)
            nextOrder += 1
        }
        sale.termsDefaultApplied = true
    }
}

// MARK: - Sync Engine

private func parseMSTDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: s) { return d }
    let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
    return f2.date(from: s)
}

extension SyncEngine {

    /// Pull every material_sale_terms row for the current tenant.
    func pullMaterialSaleTerms() async {
        guard store.currentCompanyID != nil else { return }
        do {
            struct Row: Codable {
                let id:                String
                let material_sale_id:  String
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
                .from(SupabaseTable.materialSaleTerms)
                .select()
                .execute()
                .value

            let serverTerms: [MaterialSaleTerm] = rows.compactMap { r in
                guard let id = UUID(uuidString: r.id),
                      let sid = UUID(uuidString: r.material_sale_id) else { return nil }
                return MaterialSaleTerm(
                    id:              id,
                    materialSaleID:  sid,
                    templateID:      r.terms_template_id.flatMap(UUID.init(uuidString:)),
                    titleSnapshot:   r.title_snapshot,
                    bodySnapshot:    r.body_snapshot,
                    versionSnapshot: r.version_snapshot,
                    displayOrder:    r.display_order ?? 0,
                    isCustom:        r.is_custom ?? false,
                    createdAt:       parseMSTDate(r.created_at) ?? Date(),
                    createdBy:       r.created_by ?? "",
                    syncStatus:      .synced
                )
            }

            await MainActor.run {
                let local = store.allMaterialSaleTerms.filter {
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
                store.writeMaterialSaleTermsBacking(merged)
                store.objectWillChange.send()
            }
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushMaterialSaleTerm(_ term: MaterialSaleTerm) async {
        do {
            if term.pendingDelete {
                try await supabase
                    .from(SupabaseTable.materialSaleTerms)
                    .delete()
                    .eq("id", value: term.id.uuidString)
                    .execute()
                await MainActor.run {
                    var current = store.allMaterialSaleTerms
                    current.removeAll { $0.id == term.id }
                    store.writeMaterialSaleTermsBacking(current)
                    store.objectWillChange.send()
                }
                return
            }

            let isoFmt = ISO8601DateFormatter()
            isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var payload: [String: AnyJSON] = [
                "id":                .string(term.id.uuidString),
                "material_sale_id":  .string(term.materialSaleID.uuidString),
                "title_snapshot":    .string(term.titleSnapshot),
                "body_snapshot":     .string(term.bodySnapshot),
                "display_order":     .integer(term.displayOrder),
                "is_custom":         .bool(term.isCustom),
                "created_at":        .string(isoFmt.string(from: term.createdAt)),
                "created_by":        .string(term.createdBy),
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
                .from(SupabaseTable.materialSaleTerms)
                .upsert(payload)
                .execute()

            await MainActor.run {
                var current = store.allMaterialSaleTerms
                if let i = current.firstIndex(where: { $0.id == term.id }) {
                    current[i].syncStatus = .synced
                }
                store.writeMaterialSaleTermsBacking(current)
            }
        } catch {
            print("⚠️ \(#function) failed for term \(term.titleSnapshot): \(error)")
            CrashReporter.capture(error: error, context: [
                "operation": "\(#function)",
                "term_id":   term.id.uuidString,
            ])
            await MainActor.run {
                var current = store.allMaterialSaleTerms
                if let i = current.firstIndex(where: { $0.id == term.id }) {
                    current[i].syncStatus = .failed
                }
                store.writeMaterialSaleTermsBacking(current)
            }
        }
    }

    func pushPendingMaterialSaleTerms() async {
        let pending = await MainActor.run {
            store.allMaterialSaleTerms.filter {
                $0.syncStatus == .pending
                || $0.syncStatus == .local
                || $0.syncStatus == .failed
                || $0.pendingDelete
            }
        }
        guard !pending.isEmpty else { return }
        for t in pending {
            await pushMaterialSaleTerm(t)
        }
    }
}
