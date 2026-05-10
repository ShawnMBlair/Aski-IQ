// MaterialRequestAudit.swift
// Aski IQ — Read-only audit history for Material Requests.
//
// Mirrors public.material_request_audit, populated server-side by the
// log_material_request_status_change trigger from
// SupabaseMigration_MaterialRequestWorkflow.sql.
//
// CONTRACT
//   Inserts happen only via the DB trigger. The Swift side never writes to
//   this table — there is no addMaterialRequestAudit / pushPendingAudits.
//   Pull-only model so we don't need conflict resolution or local pending
//   state. The trigger fires after the row is committed to material_requests,
//   so audit rows always have an authoritative source-of-truth status flip
//   to point at.

import Foundation

// MARK: - Model

struct MaterialRequestAudit: Identifiable, Codable, Equatable {
    var id:                UUID
    var companyID:         UUID
    var materialRequestID: UUID
    var action:            String     // "created" | "status_changed" | …
    var performedByID:     UUID?      // auth.users.id; nil for system actions
    var performedAt:       Date
    var oldStatus:         String?
    var newStatus:         String?
    /// Free-form context written by the trigger. For status_changed rows this
    /// includes the PDF storage path, approver/receiver IDs, etc. Stored as
    /// raw JSON (decoded into a [String: String] only for display).
    var metadataRaw:       Data       = Data()

    // MARK: Display helpers

    /// Resolve the user who performed the action by walking AppStore.employees
    /// (the only user-keyed collection we have client-side). Returns the user's
    /// fullName or "System" when the action was server-driven (no auth.uid()).
    func performerName(in store: AppStore) -> String {
        guard let uid = performedByID else { return "System" }
        if let emp = store.employees.first(where: { $0.id == uid }) {
            return emp.fullName
        }
        // Tenant profiles cover non-employee admin users (e.g. office staff
        // with no payroll record).
        if let prof = store.tenantProfiles.first(where: { $0.id == uid }) {
            return prof.fullName
        }
        return "Unknown user"
    }

    /// Plain-English label suitable for a one-line history row, e.g.
    /// "Approved by Sarah Chen on May 8" or "Created by Marcus L on May 4".
    func displayTitle(in store: AppStore) -> String {
        let who = performerName(in: store)
        switch action {
        case "created":
            return "Created by \(who)"
        case "status_changed":
            let from = oldStatus ?? "—"
            let to   = newStatus ?? "—"
            return "\(from.capitalized) → \(to.capitalized) by \(who)"
        default:
            return "\(action.capitalized) by \(who)"
        }
    }
}

// MARK: - AppStore lookups

extension AppStore {
    /// Audit rows for a single MR, newest first. Cheap because the audit
    /// collection is bounded by status flips per request — typically <10.
    func auditEvents(for materialRequestID: UUID) -> [MaterialRequestAudit] {
        materialRequestAudits
            .filter { $0.materialRequestID == materialRequestID }
            .sorted { $0.performedAt > $1.performedAt }
    }
}
