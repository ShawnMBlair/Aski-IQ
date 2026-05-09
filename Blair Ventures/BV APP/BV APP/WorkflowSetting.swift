// WorkflowSetting.swift
// Aski IQ — Approval limits & workflow permissions per role.
//
// Mirrors the public.workflow_settings table seeded by
// SupabaseMigration_MaterialRequestWorkflow.sql. One row per (company, role).
//
// CONTRACT
//   role_key matches Swift's UserRole.rawValue (BaseModel.swift). The DB seed
//   populates one row per role per company so a missing row indicates either
//   (a) the migration hasn't run, or (b) a role was added in Swift after the
//   seed. Either way, lookups fall back to a deny-by-default permission set
//   so the worst case is "user must be explicitly granted" rather than
//   "user has unintended access."

import Foundation
import Combine

// MARK: - Model

struct WorkflowSetting: Identifiable, Codable, Equatable {
    var id:                            UUID = UUID()
    var companyID:                     UUID
    var roleKey:                       String   // matches UserRole.rawValue
    var approvalLimitAmount:           Decimal  = 0
    var canSelfApprove:                Bool     = false
    var canCreateMaterialRequest:      Bool     = true
    var canApproveMaterialRequest:     Bool     = false
    var canSendToSupplier:             Bool     = false
    var canReceiveMaterials:           Bool     = false
    var isActive:                      Bool     = true
    var updatedAt:                     Date     = Date()

    /// Convenience role-typed view of `roleKey`. Returns nil if the DB row's
    /// role string doesn't map to a known Swift UserRole — possible when the
    /// DB has been seeded with a role the app doesn't know about yet.
    var role: UserRole? { UserRole(rawValue: roleKey) }
}

// MARK: - Deny-by-default fallback

extension WorkflowSetting {
    /// Returned by AppStore.workflowSetting(for:) when no row exists for the
    /// requested role. Deny-by-default so a missing row never silently grants
    /// approval rights.
    static func denyAll(role: UserRole, companyID: UUID) -> WorkflowSetting {
        WorkflowSetting(
            companyID:                     companyID,
            roleKey:                       role.rawValue,
            approvalLimitAmount:           0,
            canSelfApprove:                false,
            canCreateMaterialRequest:      false,
            canApproveMaterialRequest:     false,
            canSendToSupplier:             false,
            canReceiveMaterials:           false,
            isActive:                      true
        )
    }
}

// MARK: - AppStore lookups

extension AppStore {

    /// All known workflow settings for the current company (or empty if none
    /// have been pulled). Drives the per-role lookup helpers below.
    var workflowSettingsForCurrentCompany: [WorkflowSetting] {
        guard let cid = currentCompanyID else { return [] }
        return workflowSettings.filter { $0.companyID == cid && $0.isActive }
    }

    /// Resolve the workflow row for a specific role. Falls back to deny-all
    /// when no row exists — see WorkflowSetting.denyAll for rationale.
    func workflowSetting(for role: UserRole) -> WorkflowSetting {
        let cid = currentCompanyID ?? UUID()
        return workflowSettingsForCurrentCompany.first {
            $0.roleKey == role.rawValue
        } ?? WorkflowSetting.denyAll(role: role, companyID: cid)
    }

    /// Workflow row for the currently signed-in user.
    var currentUserWorkflowSetting: WorkflowSetting {
        workflowSetting(for: currentUserRole)
    }

    // MARK: Action gates — all read from workflow_settings, no hardcoded roles.

    /// Can the current user submit a Material Request for approval?
    var canCreateMaterialRequest: Bool {
        currentUserWorkflowSetting.canCreateMaterialRequest
    }

    /// Can the current user approve a Material Request of the given amount?
    /// Combines two gates: (1) the role has approval rights at all, and
    /// (2) the request total is within their approval limit.
    func canApproveMaterialRequest(amount: Decimal) -> Bool {
        let s = currentUserWorkflowSetting
        guard s.canApproveMaterialRequest else { return false }
        return amount <= s.approvalLimitAmount
    }

    /// True when the user can both create AND approve their own request, AND
    /// the amount is within their approval limit. Used to skip the submit →
    /// approve dance for low-value requests by trusted roles.
    func canSelfApproveMaterialRequest(amount: Decimal) -> Bool {
        let s = currentUserWorkflowSetting
        return s.canSelfApprove
            && s.canApproveMaterialRequest
            && amount <= s.approvalLimitAmount
    }

    /// Can the current user send the approved request to a supplier (i.e.
    /// trigger the email / PDF dispatch)?
    var canSendToSupplier: Bool {
        currentUserWorkflowSetting.canSendToSupplier
    }

    /// Can the current user mark items as received against a request?
    var canReceiveMaterials: Bool {
        currentUserWorkflowSetting.canReceiveMaterials
    }

    /// The first role in the company whose approval limit covers `amount`.
    /// Used by routing logic / "Needs <Role> approval" copy. Lowest-limit
    /// qualifying role wins so we don't skip past the local supervisor.
    func minimumApprovingRole(for amount: Decimal) -> UserRole? {
        workflowSettingsForCurrentCompany
            .filter { $0.canApproveMaterialRequest && $0.approvalLimitAmount >= amount }
            .sorted { $0.approvalLimitAmount < $1.approvalLimitAmount }
            .first
            .flatMap { $0.role }
    }

    // MARK: Mutation (admin only)

    /// Insert or update a workflow_settings row. Pushes through SyncEngine
    /// on the next cycle. Caller is responsible for calling this from a
    /// privileged surface — it's role-gated to executive/manager/owner here
    /// as a safety net so a misplaced call from the field UI can't mutate
    /// the company's approval limits.
    func upsertWorkflowSetting(_ setting: WorkflowSetting) {
        guard requireRole([.manager, .executive, .owner],
                          action: "upsert_workflow_setting") else { return }
        var updated = setting
        // Defense-in-depth: clamp negative limits to zero so an admin
        // cannot accidentally invert a tier (a $-1k limit silently
        // denies every approval). Validation belongs on the form too;
        // this catches the case where the form is bypassed.
        if updated.approvalLimitAmount < 0 {
            updated.approvalLimitAmount = 0
        }
        updated.updatedAt = Date()
        if let i = workflowSettings.firstIndex(where: { $0.id == setting.id }) {
            workflowSettings[i] = updated
        } else if let i = workflowSettings.firstIndex(where: {
            $0.companyID == setting.companyID && $0.roleKey == setting.roleKey
        }) {
            // Same (company, role) but different ID — merge into the existing
            // row so the unique constraint doesn't reject the upsert.
            updated.id = workflowSettings[i].id
            workflowSettings[i] = updated
        } else {
            workflowSettings.append(updated)
        }
        objectWillChange.send()
        Task { await SyncEngine.shared.pushPendingWorkflowSettings(updated) }
    }
}
