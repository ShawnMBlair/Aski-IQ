// CommercialWorkflowService.swift
// Aski IQ — Entity-First CRM, Slice 3
//
// Centralized facade for every commercial workflow transition. This is
// THE call site for converting estimates to quotes, sending quotes,
// recording acceptance/decline, converting to projects, creating change
// orders, etc. Today it delegates to existing AppStore + CRMCommercialBridge
// methods; Slices 4 (state machine) and 5 (approval thresholds) will
// add their own logic here without changing call sites.
//
// WHY THIS EXISTS
//   Pre-Slice-3 the same workflow could fire from 3+ different code
//   paths (CreateView Save, DetailView toolbar, sync engine status-drift
//   correction, magic-link RPC). Each path duplicated audit logging,
//   permission checks, and idempotency guards — usually missing one or
//   another. This service is the chokepoint where all that logic lives
//   exactly once.
//
// MIGRATION STRATEGY
//   New code: route through this service.
//   Existing code: migrate opportunistically when touching nearby code.
//   The underlying AppStore/Bridge methods stay public for now — Slice
//   6 (UI lockdown) will remove them as call sites finish migrating.
//
// CURRENT METHODS
//   • convertQuoteToProject(quote:pmID:pmName:)   → Result<Project>
//   • acceptQuote(quote:via:)                     → Result<Void>
//   • declineQuote(quote:reason:competitor:notes:) → Result<Void>
//   • sendQuote(quote:source:)                    → Result<Void>
//
// PLANNED METHODS (Slices 4–5)
//   • promoteEstimateToQuote(estimate:) — locks estimate, snapshots prices
//   • createChangeOrder(against:project:)
//   • createInvoice(from:quote:)
//   • approval-gating wrappers around sendQuote / acceptQuote
//   • state machine validation before every transition
//
// AUDIT TRAIL
//   Every method:
//     1. Validates preconditions (returns .failure with clear error)
//     2. Calls the underlying mutation
//     3. Logs to crm_activities via existing logCRMActivity helper
//     4. (Future) Writes an audit_snapshots row capturing before/after
//   The audit hook is the seam for Slice 4's state machine to enforce
//   valid transitions (e.g. can't go from .draft directly to .accepted).

import Foundation

// MARK: - Result + Error types

/// Typed errors surfaced by every CommercialWorkflowService method.
/// Cases align with the user-facing problems we expect: permissions,
/// missing prerequisites, invalid state, transient failures.
enum CommercialWorkflowError: Error, LocalizedError {
    /// User's role doesn't permit this action. Caller should surface
    /// the message verbatim — `userMessage` already mentions the
    /// missing role.
    case notAuthorized(requiredRole: String)
    /// Workflow precondition not met (e.g. quote has no estimate).
    case preconditionFailed(String)
    /// State machine rejected the transition (Slice 4).
    case invalidTransition(from: String, to: String)
    /// Approval threshold exceeded — admin sign-off needed (Slice 5).
    case approvalRequired(threshold: String)
    /// Wrapped service / network / DB error.
    case underlying(Error)

    var errorDescription: String? { userMessage }

    var userMessage: String {
        switch self {
        case .notAuthorized(let r):
            return "You need \(r) role to perform this action."
        case .preconditionFailed(let msg):
            return msg
        case .invalidTransition(let from, let to):
            return "Can't move from \(from) to \(to) — invalid workflow transition."
        case .approvalRequired(let t):
            return "This action requires \(t) approval before it can complete."
        case .underlying(let e):
            return e.localizedDescription
        }
    }
}

/// What triggered a `sendQuote`/`acceptQuote` call. Useful for audit
/// log entries + future analytics on which paths dominate (manual rep
/// action vs in-app magic-link flow vs server-side acceptance RPC).
enum WorkflowSource: String {
    case manual            // rep tapped a button
    case magicLink         // customer-side acceptance
    case bulk              // bulk operation / import
    case automation        // workflow rule engine
}

// MARK: - Service

@MainActor
final class CommercialWorkflowService {

    static let shared = CommercialWorkflowService()
    private init() {}

    /// Convenience handle so methods don't all repeat `AppStore.shared`.
    private var store: AppStore { AppStore.shared }

    // MARK: - Quote → Project

    /// Convert an accepted (or about-to-be-accepted) quote into a
    /// Project. Wraps the existing `store.convertQuoteToProject(...)`
    /// with explicit precondition checks + a typed Result return.
    ///
    /// Idempotency: silently no-ops if the quote already has a project
    /// linked — same guard as the underlying store method.
    func convertQuoteToProject(
        _ quote: Quote,
        pmID: UUID?,
        pmName: String?
    ) -> Result<Project, CommercialWorkflowError> {
        // Slice 6 stabilization (Bug D): removed the
        // `quote.opportunityID != nil` precondition. The local Swift
        // copy may legitimately have nil — the server fills it in via
        // the Slice 2 auto-link trigger on first push, but the local
        // cache may not have re-synced yet. Failing the convert here
        // surfaces a confusing "no CRM opportunity" toast for a quote
        // that actually does have one server-side.
        //
        // The auto-link trigger ALSO covers the new project's insert,
        // so even if quote.opportunityID is nil locally, the project
        // will still get linked to the right opp via project.client_name
        // → clients lookup → opp.
        // Precondition: PM must be supplied for new project creation.
        guard pmID != nil else {
            return .failure(.preconditionFailed(
                "Pick a project manager — projects can't be created unassigned."
            ))
        }
        // Slice 8: replaced ad-hoc canEditCRM || isAdmin with the
        // intent-named canConvertQuoteToProject helper. Same set of
        // roles (projectManager / officeAdmin / manager / executive),
        // but call site now reads as a workflow permission instead of
        // a CRM-edit permission.
        guard store.currentUserRole.canConvertQuoteToProject else {
            return .failure(.notAuthorized(requiredRole: "Operations or Admin"))
        }

        // Capture the existing project link state for idempotency check.
        // store.convertQuoteToProject is itself idempotent so this is
        // belt-and-suspenders — we want the caller to know whether a
        // project was actually created vs reused.
        let preexistingProjectID = quote.projectID

        store.convertQuoteToProject(quote, pmID: pmID, pmName: pmName)

        // Look up the resulting project — either the pre-existing one
        // or the freshly-created one.
        let updatedQuote = store.quotes.first { $0.id == quote.id } ?? quote
        guard let projectID = updatedQuote.projectID,
              let project = store.projects.first(where: { $0.id == projectID }) else {
            return .failure(.preconditionFailed(
                "Conversion finished but the project couldn't be located. Refresh and try again."
            ))
        }

        // Audit log — only on the genuine create path. Idempotent
        // re-calls don't re-log because the underlying mutation no-ops.
        if preexistingProjectID == nil {
            WorkflowAuditLog.record(
                WorkflowAuditEntry(
                    timestamp:  Date(),
                    actorName:  store.currentUser?.fullName ?? "System",
                    entityType: .project,
                    entityID:   project.id,
                    action:     .create,
                    fromState:  nil,
                    toState:    project.status.rawValue,
                    source:     "quote_to_project_conversion",
                    details: [
                        "sourceQuoteJobNumber": quote.jobNumber,
                        "pmName":               pmName ?? "(unassigned)"
                    ]
                ),
                opportunityID: project.opportunityID,
                clientID:      quote.clientID,
                quoteID:       quote.id,
                projectID:     project.id
            )
        }

        return .success(project)
    }

    // MARK: - Quote acceptance / decline

    /// Mark a quote as accepted. Flows through `handleQuoteAccepted` on
    /// the CRM bridge — opportunity → won, estimate → awarded, activity
    /// log row written.
    ///
    /// Use the `via` parameter to record whether this came from a rep
    /// (`.manual`), a customer magic-link signature (`.magicLink`), or
    /// a bulk operation. Future audit filters use this.
    ///
    /// PHASE-1 VERIFIED (Step 4): every accept path lands here →
    /// `handleQuoteAccepted` → `resolveOpportunityOutcome(.won)` →
    /// CRM stage flip + project creation + handoff checklist. Magic-link
    /// flips happen server-side; client picks up via the next pull and
    /// `reconcileQuoteOutcomeDrift()` closes the loop.
    func acceptQuote(
        _ quote: Quote,
        via source: WorkflowSource
    ) -> Result<Void, CommercialWorkflowError> {
        // Slice 6 fix: removed nil-opportunity precondition. The Slice 2
        // BEFORE UPDATE trigger preserves the server-side opp_id even if
        // the local copy is stale-nil; failing here on a sync-race
        // surfaces a confusing toast for a quote that's actually fine.
        // Idempotency: already accepted is a no-op success.
        if quote.status == .accepted {
            return .success(())
        }
        // Slice 4: state-machine validation.
        if !QuoteStateMachine.canTransition(from: quote.status, to: .accepted) {
            return .failure(.invalidTransition(
                from: quote.status.rawValue,
                to:   QuoteStatus.accepted.rawValue
            ))
        }

        let prevStatus = quote.status
        var updated = quote
        updated.status     = .accepted
        updated.acceptedAt = Date()
        store.upsertQuote(updated)
        store.handleQuoteAccepted(updated)

        WorkflowAuditLog.record(
            WorkflowAuditEntry(
                timestamp:  Date(),
                actorName:  store.currentUser?.fullName ?? "System",
                entityType: .quote,
                entityID:   quote.id,
                action:     .stateTransition,
                fromState:  prevStatus.rawValue,
                toState:    QuoteStatus.accepted.rawValue,
                source:     source.rawValue,
                details:    ["jobNumber": quote.jobNumber]
            ),
            opportunityID: quote.opportunityID,
            clientID:      quote.clientID,
            quoteID:       quote.id
        )
        return .success(())
    }

    /// Decline a quote with optional loss-reason capture. Flows through
    /// `handleQuoteDeclined` so the CRM opportunity gets the same
    /// reason / competitor / notes triple.
    ///
    /// PHASE-1 VERIFIED (Step 4): every decline path lands here →
    /// `handleQuoteDeclined` → `resolveOpportunityOutcome(.lost)` →
    /// opp stage flip + estimate → `.lost` + reason/competitor/notes
    /// captured.
    func declineQuote(
        _ quote: Quote,
        reason: LossReason?,
        competitor: String?,
        notes: String?
    ) -> Result<Void, CommercialWorkflowError> {
        // Slice 6 fix: removed nil-opportunity precondition (server
        // trigger preserves opp link; local nil is a sync-race, not a
        // genuine missing-link).
        if quote.status == .declined {
            return .success(())
        }
        if !QuoteStateMachine.canTransition(from: quote.status, to: .declined) {
            return .failure(.invalidTransition(
                from: quote.status.rawValue,
                to:   QuoteStatus.declined.rawValue
            ))
        }

        let prevStatus = quote.status
        var updated = quote
        updated.status         = .declined
        updated.lossReason     = reason
        updated.competitorName = (competitor?.isEmpty == false) ? competitor : nil
        updated.winLossNotes   = (notes?.isEmpty == false)      ? notes      : nil
        updated.declinedAt     = Date()
        store.upsertQuote(updated)

        let reasonStr = reason.map {
            "\($0.displayName)\((competitor?.isEmpty == false) ? " — \(competitor!)" : "")"
        } ?? ""
        store.handleQuoteDeclined(updated, reason: reasonStr, notes: notes ?? "")

        WorkflowAuditLog.record(
            WorkflowAuditEntry(
                timestamp:  Date(),
                actorName:  store.currentUser?.fullName ?? "System",
                entityType: .quote,
                entityID:   quote.id,
                action:     .stateTransition,
                fromState:  prevStatus.rawValue,
                toState:    QuoteStatus.declined.rawValue,
                source:     "manual",
                details: [
                    "jobNumber":  quote.jobNumber,
                    "reason":     reason?.rawValue ?? "",
                    "competitor": competitor ?? ""
                ]
            ),
            opportunityID: quote.opportunityID,
            clientID:      quote.clientID,
            quoteID:       quote.id
        )
        return .success(())
    }

    // MARK: - Quote send

    /// Mark a quote as sent. Used by both the in-app email flow and
    /// the magic-link mint flow once the email actually delivers. The
    /// status transition happens on a successful EmailService send;
    /// this method ensures the audit trail is consistent regardless of
    /// which code path got here.
    ///
    /// Slice 5 will wrap this with approval-threshold gating: a $60K
    /// quote can't transition to .sent without a Manager approval. The
    /// gate lives here so call sites don't have to know about it.
    /// Pre-flight check for "can this quote be sent right now?". Call
    /// THIS before initiating any email send, not after. Validates:
    ///   • opportunityID is set (server-side requirement)
    ///   • state-machine allows current → .sent
    ///   • approval threshold (Slice 5) is satisfied for manual sends
    ///
    /// Returns .success(()) when the send is OK to proceed. The actual
    /// status flip happens via `recordQuoteSent` AFTER the email
    /// service confirms delivery — this split exists so a successful
    /// email never hits a status-flip rejection (which used to surface
    /// as "Quote sent" toast plus stale draft status — Slice 6 bug).
    func precheckCanSendQuote(
        _ quote: Quote,
        via source: WorkflowSource
    ) -> Result<Void, CommercialWorkflowError> {
        // Slice 6 fix: removed nil-opportunity precondition. The Slice 2
        // server trigger backfills opp_id on insert; local-nil is a
        // sync-race, not a genuine missing link.
        // Idempotent: already sent/accepted is a no-op success.
        if quote.status == .sent || quote.status == .accepted {
            return .success(())
        }
        if !QuoteStateMachine.canTransition(from: quote.status, to: .sent) {
            return .failure(.invalidTransition(
                from: quote.status.rawValue,
                to:   QuoteStatus.sent.rawValue
            ))
        }
        // Slice 5: approval threshold gate. Manual rep sends only —
        // magic-link/automation paths bypass (customer-side acceptance
        // is the OUTCOME the threshold gates against; double-blocking
        // would prevent legitimate signatures from completing).
        if source == .manual {
            let tier = ApprovalThreshold.tier(forTotal: quote.grandTotal)
            if tier != .none {
                let latest = store.latestApproval(for: quote.id)
                let approved = latest?.status == .approved
                if !approved {
                    return .failure(.approvalRequired(threshold: tier.displayName))
                }
            }
        }
        return .success(())
    }

    func recordQuoteSent(
        _ quote: Quote,
        via source: WorkflowSource
    ) -> Result<Void, CommercialWorkflowError> {
        // Slice 6 fix: nil-opportunity precondition relaxed (Slice 2
        // server trigger preserves the link; local-nil is a sync-race).
        if quote.status == .sent || quote.status == .accepted {
            return .success(())
        }
        if !QuoteStateMachine.canTransition(from: quote.status, to: .sent) {
            return .failure(.invalidTransition(
                from: quote.status.rawValue,
                to:   QuoteStatus.sent.rawValue
            ))
        }

        let prevStatus = quote.status
        var updated = quote
        updated.status = .sent
        updated.sentAt = Date()
        store.upsertQuote(updated)

        WorkflowAuditLog.record(
            WorkflowAuditEntry(
                timestamp:  Date(),
                actorName:  store.currentUser?.fullName ?? "System",
                entityType: .quote,
                entityID:   quote.id,
                action:     .stateTransition,
                fromState:  prevStatus.rawValue,
                toState:    QuoteStatus.sent.rawValue,
                source:     source.rawValue,
                details:    ["jobNumber": quote.jobNumber]
            ),
            opportunityID: quote.opportunityID,
            clientID:      quote.clientID,
            quoteID:       quote.id
        )
        return .success(())
    }

    // MARK: - Slice 5: Approval workflow

    /// Creates a pending QuoteApproval row for the quote when its
    /// total exceeds the sales-tier ceiling. No-op success when the
    /// quote is below the threshold (rep can send directly). Idempotent
    /// — if a pending approval already exists for this quote, returns
    /// it without creating a duplicate.
    ///
    /// Decisions on the approval flow through `decideApproval(...)`
    /// below, gated by `ApprovalThreshold.canApprove(tier:role:)`.
    func requestApprovalForQuote(
        _ quote: Quote
    ) -> Result<QuoteApproval, CommercialWorkflowError> {
        // Slice 6 fix: nil-opportunity precondition relaxed. The
        // approval row FKs to the quote, not the opp directly — opp
        // linkage is a quote-level concern handled by Slice 2 trigger.
        guard let companyID = store.currentCompanyID,
              let user = store.currentUser else {
            return .failure(.preconditionFailed(
                "Not authenticated — sign in before requesting approval."
            ))
        }

        let tier = ApprovalThreshold.tier(forTotal: quote.grandTotal)
        guard tier != .none else {
            // No approval needed — return a synthetic "approved" record
            // so callers can ignore the distinction.
            return .failure(.preconditionFailed(
                "This quote is below the approval threshold — send directly."
            ))
        }

        // Idempotency: if a live (pending or approved) approval exists,
        // return it instead of stacking duplicates.
        if let existing = store.latestApproval(for: quote.id),
           existing.status == .pending || existing.status == .approved {
            return .success(existing)
        }

        let approval = QuoteApproval(
            id:            UUID(),
            quoteID:       quote.id,
            companyID:     companyID,
            quoteTotal:    quote.grandTotal,
            thresholdTier: tier,
            currency:      quote.currency.isEmpty ? "USD" : quote.currency,
            requestedBy:   user.id,
            requestedByName: user.fullName,
            requestedAt:   Date(),
            status:        .pending,
            decidedBy:     nil,
            decidedByName: "",
            decidedAt:     nil,
            decisionNotes: ""
        )
        store.upsertApproval(approval)

        WorkflowAuditLog.record(
            WorkflowAuditEntry(
                timestamp:  Date(),
                actorName:  user.fullName,
                entityType: .quote,
                entityID:   quote.id,
                action:     .stateTransition,
                fromState:  "no_approval",
                toState:    "approval_requested",
                source:     "manual",
                details: [
                    "jobNumber": quote.jobNumber,
                    "tier":      tier.rawValue,
                    "total":     "\(quote.grandTotal)"
                ]
            ),
            opportunityID: quote.opportunityID,
            clientID:      quote.clientID,
            quoteID:       quote.id
        )

        // Notify approvers (company inbox + local push). Fire-and-forget.
        QuoteApprovalNotifier.notify(.requested(approval, quote))

        return .success(approval)
    }

    /// Approve or reject a pending approval. Caller must satisfy
    /// `ApprovalThreshold.canApprove(tier:role:)` for the approval's
    /// tier — manager-tier approvals can be decided by manager OR
    /// executive; admin-tier requires executive.
    func decideApproval(
        _ approval: QuoteApproval,
        approve: Bool,
        notes: String
    ) -> Result<Void, CommercialWorkflowError> {
        guard let user = store.currentUser else {
            return .failure(.preconditionFailed("Not authenticated."))
        }
        guard ApprovalThreshold.canApprove(tier: approval.thresholdTier,
                                            role: store.currentUserRole) else {
            let needed = approval.thresholdTier == .admin ? "executive" : "manager / executive"
            return .failure(.notAuthorized(requiredRole: needed))
        }
        guard approval.status == .pending else {
            return .failure(.preconditionFailed(
                "This approval has already been decided (\(approval.status.displayName))."
            ))
        }

        var updated = approval
        updated.status        = approve ? .approved : .rejected
        updated.decidedBy     = user.id
        updated.decidedByName = user.fullName
        updated.decidedAt     = Date()
        updated.decisionNotes = notes
        store.upsertApproval(updated)

        WorkflowAuditLog.record(
            WorkflowAuditEntry(
                timestamp:  Date(),
                actorName:  user.fullName,
                entityType: .quote,
                entityID:   approval.quoteID,
                action:     approve ? .approve : .reject,
                fromState:  QuoteApprovalStatus.pending.rawValue,
                toState:    updated.status.rawValue,
                source:     "manual",
                details: [
                    "tier":  approval.thresholdTier.rawValue,
                    "total": "\(approval.quoteTotal)",
                    "notes": notes
                ]
            ),
            opportunityID: store.quotes.first(where: { $0.id == approval.quoteID })?.opportunityID,
            clientID:      store.quotes.first(where: { $0.id == approval.quoteID })?.clientID,
            quoteID:       approval.quoteID
        )

        // Notify the team that the approval has been decided. Looks
        // up the quote so the email body can reference the job number
        // / client / total. Fire-and-forget — failures don't block the
        // decision write that already succeeded above.
        if let quote = store.quotes.first(where: { $0.id == approval.quoteID }) {
            QuoteApprovalNotifier.notify(
                approve ? .approved(updated, quote) : .rejected(updated, quote)
            )
        }

        return .success(())
    }

    // MARK: - Admin override

    /// Forces a quote-status transition that the state machine would
    /// normally reject (e.g. reopening an accepted quote). Audit-logged
    /// with `action = .forcedTransition` so reviewers can see every
    /// override. Admin-only — non-admin callers get .notAuthorized.
    ///
    /// Use sparingly. The intent is "the customer changed their mind
    /// after acceptance and we need to record it" rather than "the rep
    /// hit the wrong button" — for the latter, fix the data.
    func forceQuoteStatus(
        _ quote: Quote,
        to target: QuoteStatus,
        reason: String
    ) -> Result<Void, CommercialWorkflowError> {
        // Slice 8: aliased canOverrideLockedRecords for intent clarity.
        // Equivalent to isAdmin (executive only) — same gate, named
        // for the workflow it protects.
        guard store.currentUserRole.canOverrideLockedRecords else {
            return .failure(.notAuthorized(requiredRole: "executive"))
        }
        if quote.status == target { return .success(()) }

        let prev = quote.status
        var updated = quote
        updated.status = target
        store.upsertQuote(updated)

        WorkflowAuditLog.record(
            WorkflowAuditEntry(
                timestamp:  Date(),
                actorName:  store.currentUser?.fullName ?? "System",
                entityType: .quote,
                entityID:   quote.id,
                action:     .forcedTransition,
                fromState:  prev.rawValue,
                toState:    target.rawValue,
                source:     "admin_override",
                details: [
                    "jobNumber": quote.jobNumber,
                    "reason":    reason
                ]
            ),
            opportunityID: quote.opportunityID,
            clientID:      quote.clientID,
            quoteID:       quote.id
        )
        return .success(())
    }
}
