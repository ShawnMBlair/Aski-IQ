// TermsTemplate.swift
// Aski IQ — Terms & Conditions library, Slice A.
//
// Model + categories + AppStore methods + sync (pull/push). Does NOT
// touch quotes, PDFs, or any send-time validation — those land in
// Slice B and Slice C. Templates are edited in
// Settings → Terms & Conditions and persisted in the public.terms_templates
// Supabase table (see SupabaseMigration_TermsTemplates_SliceA.sql).
//
// Snapshot rule (relevant to future slices, but flagged here so the
// model design respects it): once a quote attaches a template,
// the title + body get copied into the quote_terms table. Editing a
// template here only affects FUTURE quotes — sent quotes keep the
// wording they were sent with. The version field on this model is
// what those snapshots reference back to.

import Foundation
import Combine
import SwiftUI
import Supabase
import PostgREST   // AnyJSON lives here; Supabase re-exports but explicit import keeps the build deterministic

// MARK: - Category

enum TermsCategory: String, Codable, CaseIterable, Identifiable {
    case general          = "general"
    case payment          = "payment"
    case materialSales    = "material_sales"
    case scaffolding      = "scaffolding"
    case containment      = "containment"
    case shrinkWrap       = "shrink_wrap"
    case mastLift         = "mast_lift"
    case equipmentRental  = "equipment_rental"
    case installation     = "installation"
    case safety           = "safety"
    case warranty         = "warranty"
    case exclusions       = "exclusions"

    var id: String { rawValue }

    /// Determines order in the picker. General/payment first since they
    /// apply broadly; specific service categories grouped after.
    var sortOrder: Int {
        switch self {
        case .general:         return 0
        case .payment:         return 1
        case .materialSales:   return 10
        case .scaffolding:     return 11
        case .containment:     return 12
        case .shrinkWrap:      return 13
        case .mastLift:        return 14
        case .equipmentRental: return 15
        case .installation:    return 16
        case .safety:          return 80
        case .warranty:        return 81
        case .exclusions:      return 82
        }
    }

    var displayName: String {
        switch self {
        case .general:         return "General"
        case .payment:         return "Payment"
        case .materialSales:   return "Material Sales"
        case .scaffolding:     return "Scaffolding"
        case .containment:     return "Containment"
        case .shrinkWrap:      return "Shrink Wrap"
        case .mastLift:        return "Mast Lift"
        case .equipmentRental: return "Equipment Rental"
        case .installation:    return "Installation"
        case .safety:          return "Safety"
        case .warranty:        return "Warranty"
        case .exclusions:      return "Exclusions"
        }
    }

    var icon: String {
        switch self {
        case .general:         return "doc.text.fill"
        case .payment:         return "dollarsign.circle.fill"
        case .materialSales:   return "shippingbox.fill"
        case .scaffolding:     return "square.grid.3x3.square"
        case .containment:     return "rectangle.stack.fill"
        case .shrinkWrap:      return "shippingbox.and.arrow.backward.fill"
        case .mastLift:        return "arrow.up.and.down.square.fill"
        case .equipmentRental: return "wrench.and.screwdriver.fill"
        case .installation:    return "hammer.fill"
        case .safety:          return "shield.lefthalf.filled"
        case .warranty:        return "checkmark.seal.fill"
        case .exclusions:      return "minus.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general:         return .blue
        case .payment:         return .green
        case .materialSales:   return .orange
        case .scaffolding:     return .indigo
        case .containment:     return .teal
        case .shrinkWrap:      return .cyan
        case .mastLift:        return .purple
        case .equipmentRental: return .brown
        case .installation:    return .yellow
        case .safety:          return .red
        case .warranty:        return .mint
        case .exclusions:      return .gray
        }
    }
}

// MARK: - Service Type
//
// The vocabulary used by `applies_to_service_types` on a template AND
// `service_types` on a cost code. Slice C will match these to suggest
// templates from a quote's line items.

enum ServiceType: String, Codable, CaseIterable, Identifiable {
    case general         = "general"
    case materialSales   = "material_sales"
    case scaffolding     = "scaffolding"
    case containment     = "containment"
    case shrinkWrap      = "shrink_wrap"
    case mastLift        = "mast_lift"
    case equipmentRental = "equipment_rental"
    case installation    = "installation"
    case safety          = "safety"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general:         return "General"
        case .materialSales:   return "Material Sales"
        case .scaffolding:     return "Scaffolding"
        case .containment:     return "Containment"
        case .shrinkWrap:      return "Shrink Wrap"
        case .mastLift:        return "Mast Lift"
        case .equipmentRental: return "Equipment Rental"
        case .installation:    return "Installation"
        case .safety:          return "Safety"
        }
    }
}

// MARK: - Model

struct TermsTemplate: Identifiable, Codable, Equatable {
    var id:          UUID = UUID()
    var companyID:   UUID

    var title:       String
    var category:    TermsCategory
    var description: String = ""
    var body:        String

    var appliesToServiceTypes: [ServiceType] = []
    var isDefault:             Bool = false
    var isActive:              Bool = true

    /// Bumped server-side by the `bump_terms_template_version` trigger
    /// whenever the title or body changes. Local edits send the prior
    /// value; the server returns the new one on the next pull.
    var version:     Int  = 1

    var createdAt:   Date = Date()
    var updatedAt:   Date = Date()
    var createdBy:   UUID? = nil
    var updatedBy:   UUID? = nil

    var isDeleted:   Bool = false
    var deletedAt:   Date? = nil
    var deletedBy:   String? = nil

    var syncStatus:  SyncStatus = .local

    /// Convenience initializer for new templates.
    init(companyID: UUID,
         title: String = "",
         category: TermsCategory = .general,
         body: String = "") {
        self.companyID = companyID
        self.title     = title
        self.category  = category
        self.body      = body
    }

    /// Memberwise init used by the sync engine's row-mapping pass.
    init(id: UUID,
         companyID: UUID,
         title: String,
         category: TermsCategory,
         description: String,
         body: String,
         appliesToServiceTypes: [ServiceType],
         isDefault: Bool,
         isActive: Bool,
         version: Int,
         createdAt: Date,
         updatedAt: Date,
         createdBy: UUID?,
         updatedBy: UUID?,
         isDeleted: Bool,
         syncStatus: SyncStatus) {
        self.id         = id
        self.companyID  = companyID
        self.title      = title
        self.category   = category
        self.description = description
        self.body       = body
        self.appliesToServiceTypes = appliesToServiceTypes
        self.isDefault  = isDefault
        self.isActive   = isActive
        self.version    = version
        self.createdAt  = createdAt
        self.updatedAt  = updatedAt
        self.createdBy  = createdBy
        self.updatedBy  = updatedBy
        self.isDeleted  = isDeleted
        self.syncStatus = syncStatus
    }
}

// MARK: - AppStore Storage + Methods
//
// Templates live in-memory on the store like other tenant tables.
// All write methods stamp syncStatus = .pending and let the sync
// engine drain the queue on the next push pass.

extension AppStore {

    /// All non-deleted templates for the current tenant. Sorted by
    /// category sortOrder, then title — the order the picker uses.
    var termsTemplates: [TermsTemplate] {
        _termsTemplatesBacking
            .filter { !$0.isDeleted }
            .sorted { lhs, rhs in
                if lhs.category.sortOrder != rhs.category.sortOrder {
                    return lhs.category.sortOrder < rhs.category.sortOrder
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    /// Same as termsTemplates but filtered to is_active. The list
    /// view's "Show archived" toggle flips between this and
    /// termsTemplates.
    var activeTermsTemplates: [TermsTemplate] {
        termsTemplates.filter { $0.isActive }
    }

    func termsTemplates(category: TermsCategory) -> [TermsTemplate] {
        termsTemplates.filter { $0.category == category }
    }

    /// Insert or update. Marks pending and triggers a push on the next
    /// sync pass. Mutates updatedAt locally so optimistic UI is
    /// consistent — server overrides on the next pull.
    func upsertTermsTemplate(_ template: TermsTemplate) {
        var copy = template
        copy.updatedAt  = Date()
        copy.syncStatus = (copy.syncStatus == .synced) ? .pending : copy.syncStatus
        if copy.syncStatus == .local { copy.syncStatus = .pending }

        if let i = _termsTemplatesBacking.firstIndex(where: { $0.id == copy.id }) {
            _termsTemplatesBacking[i] = copy
        } else {
            _termsTemplatesBacking.append(copy)
        }
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingTermsTemplates() }
    }

    /// Soft-delete (sets is_deleted = true). The template stays in the
    /// table for historical lookups but is hidden from list/picker.
    func archiveTermsTemplate(_ template: TermsTemplate) {
        var copy = template
        copy.isDeleted  = true
        copy.deletedAt  = Date()
        copy.deletedBy  = currentUser?.fullName ?? ""
        copy.isActive   = false
        copy.syncStatus = .pending
        upsertTermsTemplate(copy)
    }

    /// Make a fresh copy with " (Copy)" appended to the title and a
    /// new UUID. The duplicate is .local (never been to the server)
    /// until the user opens the editor and saves.
    func duplicateTermsTemplate(_ template: TermsTemplate) -> TermsTemplate {
        var copy = template
        copy.id        = UUID()
        copy.title     = "\(template.title) (Copy)"
        copy.isDefault = false
        copy.version   = 1
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.syncStatus = .local
        if let i = _termsTemplatesBacking.firstIndex(where: { $0.id == copy.id }) {
            _termsTemplatesBacking[i] = copy
        } else {
            _termsTemplatesBacking.append(copy)
        }
        objectWillChange.send()
        return copy
    }

    /// Backing storage. Held in a UserDefaults-keyed cache so a cold
    /// launch doesn't show an empty list before the first pull
    /// completes. Sync replaces wholesale on every pull.
    fileprivate var _termsTemplatesBacking: [TermsTemplate] {
        get {
            if let cached = AppStore._termsTemplatesCache { return cached }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = UserDefaults.standard.data(forKey: "ak_terms_templates"),
                  let arr  = try? decoder.decode([TermsTemplate].self, from: data)
            else { return [] }
            AppStore._termsTemplatesCache = arr
            return arr
        }
        set {
            AppStore._termsTemplatesCache = newValue
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(newValue) {
                UserDefaults.standard.set(data, forKey: "ak_terms_templates")
            }
        }
    }

    /// Static cache so repeated reads in the same render pass don't
    /// hammer the JSON decoder. Cleared by the setter above.
    /// MainActor-isolated by virtue of the enclosing @MainActor class.
    private static var _termsTemplatesCache: [TermsTemplate]? = nil
}

// MARK: - Sync Engine: Pull + Push

/// Local ISO8601 → Date helper. Other sync files have their own private
/// versions; duplicating it here keeps this file self-contained without
/// changing module-level visibility.
private func parseTermsDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: s) { return d }
    let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
    return f2.date(from: s)
}

extension SyncEngine {

    func pullTermsTemplates() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            // Inline row struct keeps the column-mapping local to this
            // function, matching the pattern used by pullCostCodes etc.
            struct Row: Codable {
                let id:          String
                let company_id:  String
                let title:       String
                let category:    String
                let description: String?
                let body:        String
                let applies_to_service_types: [String]?
                let is_default:  Bool?
                let is_active:   Bool?
                let version:     Int?
                let created_at:  String?
                let updated_at:  String?
                let created_by:  String?
                let updated_by:  String?
                let is_deleted:  Bool?
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.termsTemplates)
                .select()
                .eq("company_id", value: companyID.uuidString)
                .execute()
                .value

            let templates: [TermsTemplate] = rows.compactMap { r in
                guard let id = UUID(uuidString: r.id),
                      let cid = UUID(uuidString: r.company_id) else { return nil }
                return TermsTemplate(
                    id:          id,
                    companyID:   cid,
                    title:       r.title,
                    category:    TermsCategory(rawValue: r.category) ?? .general,
                    description: r.description ?? "",
                    body:        r.body,
                    appliesToServiceTypes: (r.applies_to_service_types ?? []).compactMap { ServiceType(rawValue: $0) },
                    isDefault:   r.is_default ?? false,
                    isActive:    r.is_active ?? true,
                    version:     r.version ?? 1,
                    createdAt:   parseTermsDate(r.created_at) ?? Date(),
                    updatedAt:   parseTermsDate(r.updated_at) ?? Date(),
                    createdBy:   r.created_by.flatMap(UUID.init(uuidString:)),
                    updatedBy:   r.updated_by.flatMap(UUID.init(uuidString:)),
                    isDeleted:   r.is_deleted ?? false,
                    syncStatus:  .synced
                )
            }
            await MainActor.run {
                store._termsTemplatesBacking = templates
                store.objectWillChange.send()
            }
        } catch {
            print("⚠️ \(#function) failed: \(error)")
            CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
        }
    }

    func pushTermsTemplate(_ template: TermsTemplate) async {
        do {
            // Build payload with company_id stamped — server-side RLS
            // enforces the same, but stamping client-side gives a
            // cleaner error if the user somehow ends up off-tenant.
            let companyID = template.companyID.uuidString

            // Convert Swift enum array → text[] for Postgres.
            let serviceTypesPayload = template.appliesToServiceTypes.map { $0.rawValue }

            // ISO8601 timestamps for created_at / updated_at. The
            // version field is server-managed via trigger — we never
            // send it. Same for is_deleted (handled via archive).
            let isoFmt = ISO8601DateFormatter()
            isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var payload: [String: AnyJSON] = [
                "id":           .string(template.id.uuidString),
                "company_id":   .string(companyID),
                "title":        .string(template.title),
                "category":     .string(template.category.rawValue),
                "description":  .string(template.description),
                "body":         .string(template.body),
                "applies_to_service_types": .array(serviceTypesPayload.map { .string($0) }),
                "is_default":   .bool(template.isDefault),
                "is_active":    .bool(template.isActive),
                "is_deleted":   .bool(template.isDeleted),
                "updated_at":   .string(isoFmt.string(from: Date())),
            ]
            if template.isDeleted {
                payload["deleted_at"] = .string(isoFmt.string(from: Date()))
                payload["deleted_by"] = .string(template.deletedBy ?? "")
            }

            try await supabase
                .from(SupabaseTable.termsTemplates)
                .upsert(payload)
                .execute()

            await MainActor.run {
                if let i = store._termsTemplatesBacking.firstIndex(where: { $0.id == template.id }) {
                    store._termsTemplatesBacking[i].syncStatus = .synced
                }
            }
        } catch {
            print("⚠️ \(#function) failed for \(template.title): \(error)")
            CrashReporter.capture(error: error, context: [
                "operation":   "\(#function)",
                "template_id": template.id.uuidString,
            ])
            await MainActor.run {
                if let i = store._termsTemplatesBacking.firstIndex(where: { $0.id == template.id }) {
                    store._termsTemplatesBacking[i].syncStatus = .failed
                }
            }
        }
    }

    func pushPendingTermsTemplates() async {
        let pending = await MainActor.run {
            store._termsTemplatesBacking.filter {
                $0.syncStatus == .pending || $0.syncStatus == .local || $0.syncStatus == .failed
            }
        }
        guard !pending.isEmpty else { return }
        for t in pending {
            await pushTermsTemplate(t)
        }
    }
}

// Both AppStore and SyncEngine extensions live in this file, so the
// fileprivate `_termsTemplatesBacking` is visible to both without
// further indirection.
