// ExpenseApprovalService.swift
// Phase 9 / Expenses v1.1 — approval state machine + eligibility checks
//
// Locked rules (project_expenses_v1_spec.md):
// - Eligible approvers: manager, admin, executive, owner. Office Staff
//   approval is optional (gated by future user-permission toggle).
// - Self-approval is NEVER allowed. Submitter ≠ approver; expense
//   owner ≠ approver. Belt-and-braces with the DB-level
//   expenses_no_self_approval_check constraint.
// - Shared queue, first-to-approve-wins. Once approvalState moves out
//   of .pendingApproval, the row is locked. Other approvers see the
//   final state.
// - Tiered ladder:
//   - $0–$250 company-card: auto-approve if no flags
//   - Reimbursements (any amount): require Manager-tier+
//   - $250+: require Manager-tier+
//   - $5,000+: require Admin/Executive
//   - Missing receipt / duplicate / rejected: needs review
// - Rejections must include a reason.

import Foundation

enum ExpenseApprovalError: Error, LocalizedError {
    case alreadyDecided
    case selfApproval
    case insufficientRole
    case missingRejectionReason

    var errorDescription: String? {
        switch self {
        case .alreadyDecided:         return "This expense has already been approved or rejected."
        case .selfApproval:           return "You cannot approve your own expense. Ask another manager."
        case .insufficientRole:       return "Your role can't approve this expense. Need Admin or Executive for amounts over $5,000."
        case .missingRejectionReason: return "Please include a reason when rejecting an expense."
        }
    }
}

enum ExpenseApprovalService {

    // MARK: Eligibility

    /// True when the given approver (role + UUID) is allowed to approve
    /// or reject the expense per the locked rules.
    static func canApprove(
        expense: Expense,
        approverRole: UserRole,
        approverID: UUID?
    ) -> Bool {
        // First-to-approve-wins: terminal states block further approval.
        guard expense.approvalState == .pendingApproval else { return false }

        // Role gate. Manager-tier+ at minimum. $5K+ requires admin/exec.
        let baseEligible: Bool = {
            switch approverRole {
            case .manager, .executive, .owner, .officeAdmin: return true
            default: return false
            }
        }()
        guard baseEligible else { return false }

        if expense.isOverUpperThreshold {
            // $5K+ — Admin / Executive / Owner only
            switch approverRole {
            case .officeAdmin, .executive, .owner: return true
            default: return false
            }
        }

        // Self-approval block: submitter or owner cannot approve.
        if let approverID {
            if approverID == expense.submittedBy           { return false }
            if approverID == expense.expenseOwnerEmployeeID { return false }
            if approverID == expense.createdBy             { return false }
        }

        return true
    }

    // MARK: Actions

    /// Approve the expense. Mutates the passed-in copy. Caller persists
    /// via `store.upsertExpense(updated)` and emits an audit entry.
    static func approve(
        _ expense: Expense,
        by approver: Employee,
        approverRole: UserRole
    ) throws -> Expense {
        guard expense.approvalState == .pendingApproval else {
            throw ExpenseApprovalError.alreadyDecided
        }
        guard canApprove(expense: expense, approverRole: approverRole, approverID: approver.id) else {
            // Distinguish self-approval from role gate.
            if approver.id == expense.submittedBy
                || approver.id == expense.expenseOwnerEmployeeID
                || approver.id == expense.createdBy {
                throw ExpenseApprovalError.selfApproval
            }
            throw ExpenseApprovalError.insufficientRole
        }
        var updated = expense
        updated.approvalState = .approved
        updated.approvedBy    = approver.id
        updated.approvedAt    = Date()
        updated.updatedAt     = Date()
        updated.lastModifiedAt = Date()
        updated.lastModifiedBy = approver.fullName
        updated.syncStatus    = .pending
        return updated
    }

    /// Reject the expense with a required reason.
    static func reject(
        _ expense: Expense,
        by approver: Employee,
        approverRole: UserRole,
        reason: String
    ) throws -> Expense {
        guard expense.approvalState == .pendingApproval else {
            throw ExpenseApprovalError.alreadyDecided
        }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ExpenseApprovalError.missingRejectionReason
        }
        guard canApprove(expense: expense, approverRole: approverRole, approverID: approver.id) else {
            if approver.id == expense.submittedBy
                || approver.id == expense.expenseOwnerEmployeeID
                || approver.id == expense.createdBy {
                throw ExpenseApprovalError.selfApproval
            }
            throw ExpenseApprovalError.insufficientRole
        }
        var updated = expense
        updated.approvalState   = .rejected
        updated.rejectedBy      = approver.id
        updated.rejectedAt      = Date()
        updated.rejectionReason = trimmed
        updated.updatedAt       = Date()
        updated.lastModifiedAt  = Date()
        updated.lastModifiedBy  = approver.fullName
        updated.syncStatus      = .pending
        return updated
    }

    /// Mark a reimbursable approved expense as paid. Only valid when
    /// `approvalState == .approved` and `isReimbursable == true`.
    static func markPaid(
        _ expense: Expense,
        by payer: Employee,
        method: ExpensePaymentMethod
    ) throws -> Expense {
        guard expense.approvalState == .approved else {
            throw ExpenseApprovalError.alreadyDecided
        }
        var updated = expense
        updated.approvalState              = .paid
        updated.reimbursementPaidAt        = Date()
        updated.reimbursementPaidBy        = payer.id
        updated.reimbursementPaymentMethod = method
        updated.updatedAt                  = Date()
        updated.lastModifiedAt             = Date()
        updated.lastModifiedBy             = payer.fullName
        updated.syncStatus                 = .pending
        return updated
    }
}
