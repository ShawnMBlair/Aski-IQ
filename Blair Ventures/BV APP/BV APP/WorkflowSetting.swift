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

    // MARK: - Phase 6 / Wave 2: Generalized canPerform(action:amount:) API
    //
    // Public API for any gated action across the app. New gating call-sites
    // should use this helper instead of hardcoded role lists or
    // domain-specific helpers (`canApproveMaterialRequest`, etc.). The
    // existing helpers continue to exist and continue to delegate
    // through their original logic — this is a non-breaking shim.
    //
    // Implementation today: per-action switch that calls into the
    // existing helpers / role checks. Behavior is identical to pre-Phase-6.
    //
    // Implementation in Wave 3 (after WS1 migration lands on prod and
    // the Swift WorkflowSetting struct gains an `actionKey` field): the
    // switch is replaced with a `workflowSettings.first(where:)` lookup
    // by (companyID, role, actionKey). Admins can then rebalance any
    // action's role assignments + amount limits via the Workflow
    // Settings admin UI without code changes — same model procurement
    // already enjoys, extended to every other module.

    /// Generalized capability check. The single public API every gating
    /// call-site should adopt. Returns true if the current user can
    /// perform the given action; for amount-gated actions, also enforces
    /// the per-role amount limit.
    ///
    /// - Parameter action: The ActionKey identifying the gated operation.
    /// - Parameter amount: For amount-gated actions (approve / void /
    ///   etc.), the dollar amount being decided. Pass nil for binary
    ///   allow/deny actions.
    /// - Returns: true if the action is permitted; false otherwise.
    func canPerform(action: ActionKey, amount: Decimal? = nil) -> Bool {
        let role = currentUserRole
        switch action {

        // MARK: Material Requests — already on workflow_settings
        case .materialRequestCreate:
            return canCreateMaterialRequest
        case .materialRequestApprove:
            return canApproveMaterialRequest(amount: amount ?? 0)
        case .materialRequestSendToSupplier:
            return canSendToSupplier
        case .materialRequestReceive:
            return canReceiveMaterials

        // MARK: Purchase Orders — same role gates as MR for now
        case .purchaseOrderCreate:
            return [.projectManager, .officeAdmin, .manager, .executive, .owner].contains(role)
        case .purchaseOrderSend:
            return canSendToSupplier
        case .purchaseOrderReceive:
            return canReceiveMaterials
        case .purchaseOrderMatchInvoice:
            return [.officeAdmin, .manager, .executive, .owner].contains(role)

        // MARK: Quotes — delegate to existing ApprovalAuthority helpers
        // where they exist; otherwise straight role-list check.
        case .quoteApprove:
            return ApprovalAuthority.canApproveQuoteApproval(
                for: role, quoteTotal: amount ?? 0
            ) != .blocked
        case .quoteSend:
            return [.estimator, .projectManager, .officeAdmin, .manager, .executive, .owner].contains(role)
        case .quoteMarkAccepted, .quoteDecline:
            return [.projectManager, .officeAdmin, .manager, .executive, .owner].contains(role)

        // MARK: Estimates
        case .estimateReview:
            return [.projectManager, .officeAdmin, .manager, .executive, .owner].contains(role)
        case .estimateApprove:
            return [.officeAdmin, .manager, .executive, .owner].contains(role)

        // MARK: Invoices
        case .invoiceSend:
            return [.officeAdmin, .manager, .executive, .owner].contains(role)
        case .invoiceVoid:
            return [.manager, .executive, .owner].contains(role)
        case .invoiceRecordPayment:
            return [.officeAdmin, .manager, .executive, .owner].contains(role)

        // MARK: Change Orders
        case .changeOrderApprove:
            return role.canApproveChangeOrder
        case .changeOrderReject:
            return role.canApproveChangeOrder

        // MARK: Schedule
        case .scheduleEdit:
            return [.foreman, .projectManager, .officeAdmin, .manager, .executive, .owner].contains(role)
        case .scheduleOverrideConflict:
            // No project-wide canOverrideConflict helper today; the
            // SchedulingCommandCentreView uses an inline role check
            // (canOverrideHighRisk = manager+). Mirroring it here so
            // future call-sites get the same gate.
            return [.projectManager, .manager, .executive, .owner].contains(role)
        case .scheduleApproveRecommendation:
            return canApproveScheduleRecommendation

        // MARK: Timesheets
        case .timesheetApprove:
            return role.canApproveTimesheets
        case .timesheetEditSubmitted:
            return [.officeAdmin, .manager, .executive, .owner].contains(role)

        // MARK: RFIs
        case .rfiAnswer:
            return [.projectManager, .officeAdmin, .manager, .executive, .owner].contains(role)
        case .rfiClose:
            return [.projectManager, .officeAdmin, .manager, .executive, .owner].contains(role)

        // MARK: Contracts
        case .contractApprove:
            return [.officeAdmin, .manager, .executive, .owner].contains(role)
        case .contractTerminate:
            return [.manager, .executive, .owner].contains(role)
        case .subContractApprove:
            return [.officeAdmin, .manager, .executive, .owner].contains(role)

        // MARK: Material Sales
        case .materialSaleApprove:
            return [.officeAdmin, .manager, .executive, .owner].contains(role)
        case .materialSaleVoid:
            return [.manager, .executive, .owner].contains(role)
        }
    }

    /// Convenience for amount-gated actions where 0 means "no amount
    /// applicable" (e.g. you want to know whether the role CAN approve
    /// at all, regardless of tier). Equivalent to canPerform with amount = 0.
    func canPerform(action: ActionKey) -> Bool {
        canPerform(action: action, amount: nil)
    }

    /// All action keys the current user is currently allowed to perform.
    /// Drives the "My Approvals" admin views + Wave 3 inbox extension.
    /// Note: amount-gated actions appear here only if the role can
    /// perform them at ANY tier (passes the binary gate); the per-tier
    /// amount check still happens at decision time.
    var permittedActionKeys: [ActionKey] {
        ActionKey.allCases.filter { canPerform(action: $0) }
    }
}
