// ApprovalAuthority.swift
// Aski IQ — SR-α Smart Scheduling Approval foundation.
//
// PURPOSE
// Centralizes the role-hierarchy + approval-domain logic so every
// approval surface (Smart Schedule plans, quotes, change orders,
// procurement, timesheets, estimates) routes through a single
// authority check.
//
// CORE RULE (master prompt):
//   • Approvals can move UPWARD — a senior role can clear a junior's
//     queue.
//   • Approvals NEVER move downward — a junior can't approve work
//     assigned to a senior.
//   • Domain-specific gates (e.g. >$50K quote = Executive only,
//     high-risk schedule override = Manager+) ALWAYS take precedence.
//   • Tenant isolation is checked first — a senior in Company A
//     cannot approve work in Company B regardless of level.
//
// SCOPE — SR-α (this file)
//   • UserRole.approvalLevel + canApproveItemsFor(role:)
//   • ApprovalDomain enum + per-domain gate
//   • ApprovalMode enum (audit-trail tag for HOW approval happened)
//   • Queue display reason calculator (drives "Assigned to you" /
//     "Senior override available" labels in ApprovalQueueView)

import Foundation

// MARK: - Role hierarchy

extension UserRole {
    /// Numeric authority level. Higher number = more authority.
    /// Lets us answer "can role A approve work assigned to role B?"
    /// with a single comparison.
    var approvalLevel: Int {
        switch self {
        case .client:         return 0
        case .fieldWorker:    return 1
        case .foreman:        return 2
        case .safetyAdvisor:  return 3
        case .estimator:      return 3
        case .projectManager: return 4
        case .officeAdmin:    return 5
        case .manager:        return 6
        case .executive:      return 7
        // Owner is a peer of executive at level 7. The +1 only applies to
        // billing/destructive ops, which use `isOwner` (UserRole helper),
        // not approvalLevel.
        case .owner:          return 7
        }
    }

    /// True when `self` is at OR above `targetRole` in the hierarchy.
    /// "Approvals move upward, never downward." A Manager (6) can
    /// approve anything assigned to a PM (4). A PM cannot approve
    /// anything assigned to a Manager.
    func canApproveItemsFor(role targetRole: UserRole) -> Bool {
        approvalLevel >= targetRole.approvalLevel
    }
}

// MARK: - Approval domain
//
// Each approvable artifact is tagged with the domain it lives in.
// Domain-specific gates layer on TOP of the role hierarchy. The
// hierarchy says "you're senior enough" but the domain says "this
// specific kind of approval has additional rules."

enum ApprovalDomain: String, Codable, Equatable {
    case scheduleRecommendation
    case timesheet
    case estimateInternalReview
    case quote
    case changeOrder
    case materialRequest
    case purchaseOrder
}

extension UserRole {
    /// Domain-level approval gate. Returns the BASE eligibility for
    /// the domain — does NOT consider per-item facts (e.g. dollar
    /// tier on a quote, high-risk flag on a schedule plan). Per-item
    /// gating happens in `ApprovalAuthority.canApprove(...)` so a
    /// Manager can approve a $5K quote but not a $75K one.
    func canApproveDomain(_ domain: ApprovalDomain) -> Bool {
        switch domain {
        case .scheduleRecommendation:
            // C.2 matrix: PM / Office Admin / Manager / Executive / Owner
            return [.projectManager, .officeAdmin, .manager, .executive, .owner].contains(self)
        case .timesheet:
            // Foreman+ (own crew); seniors can clear queue. Same set as
            // canApproveTimesheets, which already includes `.owner`.
            return canApproveTimesheets
        case .estimateInternalReview:
            // Person-routed (any non-fieldWorker can be designated),
            // but the hierarchy can override-approve from above.
            // Base eligibility = "could be a designated reviewer."
            return ![.fieldWorker, .client].contains(self)
        case .quote:
            // C.2 matrix: PM / Office Admin / Manager / Executive / Owner
            // are eligible at the DOMAIN level. The per-row tier gate
            // (≤$10K, $10K–$50K, >$50K) and override requirement live in
            // ApprovalAuthority.canApproveQuoteApproval(...) and the DB
            // policy can_decide_quote_approval(...). Returning true here
            // means "you can SEE quote approvals in the queue" — whether
            // you can ACT on a specific row is decided by the tier check.
            return canApproveQuotes
        case .changeOrder:
            // Office Admin gains tier-gated change-order rights per C.2.
            // The base set lives on UserRole.canApproveChangeOrder, which
            // now includes officeAdmin/manager/executive/owner. Per-row
            // tier check is layered at the call site (Phase 1 follow-up).
            return canApproveChangeOrder
        case .materialRequest, .purchaseOrder:
            // C.2 matrix: PM / Office Admin / Manager / Executive / Owner.
            // PO at >threshold = tier-gated for PM (call-site check).
            return [.projectManager, .officeAdmin, .manager, .executive, .owner].contains(self)
        }
    }
}

// MARK: - Quote tier
//
// Mirrors the DB-side `threshold_tier` text column on `quote_approvals`.
// Three tiers, three approval gates per the C.2 matrix:
//
//   .low  (≤$10K)    → PM, Office Admin, Manager, Executive, Owner
//   .mid  ($10K–$50K) → Office Admin, Manager, Executive, Owner
//                       (PM only with override + reason)
//   .high (>$50K)    → Executive, Owner
//                       (Manager only with override + reason)
//
// The Swift gate is defense-in-depth — DB policy
// `can_decide_quote_approval(quote_total, threshold_tier, override_used)`
// is the source of truth and will reject UPDATE attempts that bypass
// this layer.

enum QuoteTier: String, Codable, Equatable {
    case low      = "low"       // ≤ $10,000
    case mid      = "mid"       // $10,000 < total ≤ $50,000
    case high     = "high"      // > $50,000

    /// Threshold boundaries. Mirrors RM2 `can_decide_quote_approval`
    /// constants — keep these in sync if the SQL helper changes.
    static let midThreshold:  Decimal = 10_000
    static let highThreshold: Decimal = 50_000

    /// Map a raw quote total to the tier the row would carry.
    /// Used when computing tier client-side before pushing the
    /// `quote_approvals` row (server validates with the same rule).
    static func tier(for total: Decimal) -> QuoteTier {
        if total > highThreshold { return .high }
        if total > midThreshold  { return .mid }
        return .low
    }

    /// Display string for queue cards / approval sheets.
    var displayLabel: String {
        switch self {
        case .low:  return "Standard (≤$10K)"
        case .mid:  return "Mid-tier ($10K–$50K)"
        case .high: return "High-tier (>$50K)"
        }
    }
}

// MARK: - Tier-aware quote approval gate

extension ApprovalAuthority {

    /// Result of asking "can this user approve this quote_approval row?"
    /// Encodes both the boolean answer AND whether the approver must
    /// supply an override reason. The override path mirrors the DB
    /// CHECK constraint (override_used = true REQUIRES non-empty
    /// decision_notes). Treating override as a structured outcome
    /// instead of a side-channel boolean lets the UI ask for the
    /// reason up front rather than after a DB rejection.
    enum QuoteApprovalDecision: Equatable {
        /// Approver is in the role band for this tier — no override
        /// required. Push `override_used = false`.
        case allowedDirect
        /// Approver is one tier below the standard gate but is allowed
        /// to proceed if they record an override reason. UI MUST collect
        /// `decision_notes` before pushing. Push `override_used = true`.
        case allowedWithOverride
        /// Approver is below the override floor — DB policy will reject.
        /// UI must hide / disable the Approve action.
        case blocked
    }

    /// Mirrors RM2 `can_decide_quote_approval(p_total, p_tier, p_override)`.
    /// Returns whether the role can act on a quote_approval row, and if
    /// so whether an override reason is required.
    ///
    /// Tier rules (matrix C.2):
    ///   • Low  (≤$10K):    PM+ approve directly.
    ///   • Mid  ($10K–$50K): Office Admin+ approve directly. PM only
    ///                       with override + reason.
    ///   • High (>$50K):    Executive/Owner approve directly. Manager
    ///                       only with override + reason.
    ///
    /// IMPORTANT: This is the UI-side gate. The DB policy is the source
    /// of truth; if the two diverge, server wins and the UPDATE fails
    /// with an RLS denial. Call this to keep UI honest, not to bypass
    /// the DB.
    static func canApproveQuoteApproval(
        for currentUserRole: UserRole,
        quoteTotal: Decimal
    ) -> QuoteApprovalDecision {
        let tier = QuoteTier.tier(for: quoteTotal)

        switch tier {
        case .high:
            if [.executive, .owner].contains(currentUserRole) {
                return .allowedDirect
            }
            if currentUserRole == .manager {
                return .allowedWithOverride
            }
            return .blocked
        case .mid:
            if [.officeAdmin, .manager, .executive, .owner].contains(currentUserRole) {
                return .allowedDirect
            }
            if currentUserRole == .projectManager {
                return .allowedWithOverride
            }
            return .blocked
        case .low:
            if [.projectManager, .officeAdmin, .manager, .executive, .owner].contains(currentUserRole) {
                return .allowedDirect
            }
            return .blocked
        }
    }
}

// MARK: - Approval mode
//
// Tags HOW an approval happened — direct (item is mine), role-based
// (assigned to my role), senior-override (I'm above the assigned
// role and helping clear their queue), tier-required (dollar /
// schedule / risk threshold gated to my tier specifically), or
// conflict-override (I'm proceeding past a flagged risk with reason).
//
// Stored in audit_log.approval_mode + recommendation.approval_mode
// so a reviewer reading history can answer "why did this person
// approve this?" without inferring it from role + item state.

enum ApprovalMode: String, Codable, Equatable {
    case direct
    case roleBased       = "role_based"
    case seniorOverride  = "senior_override"
    case tierRequired    = "tier_required"
    case conflictOverride = "conflict_override"

    var displayLabel: String {
        switch self {
        case .direct:           return "Direct"
        case .roleBased:        return "Role-based"
        case .seniorOverride:   return "Senior override"
        case .tierRequired:     return "Tier required"
        case .conflictOverride: return "Conflict override"
        }
    }
}

// MARK: - Approval Authority — central gate

/// One place to ask "can this user approve this item?" The answer
/// is composed from: tenant scope → domain gate → hierarchy →
/// item-specific overrides (tier, conflict, etc.).
enum ApprovalAuthority {

    /// Tenant + domain + hierarchy. Per-item facts (tier, risk) are
    /// checked separately at the call site because they vary by
    /// domain. Returns the mode the approval would happen under,
    /// or nil if the user can't approve.
    static func mode(
        for currentUserRole: UserRole,
        currentUserCompanyID: UUID?,
        currentUserID: UUID?,
        domain: ApprovalDomain,
        itemCompanyID: UUID?,
        assignedApproverUserID: UUID? = nil,
        assignedApproverRole: UserRole? = nil
    ) -> ApprovalMode? {
        // 1. Tenant isolation — never cross companies.
        guard let myCompany = currentUserCompanyID,
              let itemCompany = itemCompanyID,
              myCompany == itemCompany else {
            return nil
        }
        // 2. Domain base eligibility.
        guard currentUserRole.canApproveDomain(domain) else { return nil }
        // 3. Direct assignment — fastest path.
        if let assignedID = assignedApproverUserID,
           let myID = currentUserID,
           assignedID == myID {
            return .direct
        }
        // 4. Role-based: I AM the assigned role.
        if let assignedRole = assignedApproverRole, assignedRole == currentUserRole {
            return .roleBased
        }
        // 5. Senior override: I'm strictly above the assigned role.
        if let assignedRole = assignedApproverRole,
           currentUserRole.approvalLevel > assignedRole.approvalLevel {
            return .seniorOverride
        }
        // 6. No assignee specified — fall through to domain default
        //    (any user with domain eligibility can act).
        if assignedApproverUserID == nil && assignedApproverRole == nil {
            return .roleBased
        }
        // Lower-or-equal level than assignee but not the assignee
        // themselves → cannot approve.
        return nil
    }

    /// Convenience wrapper — pure bool when the caller doesn't need
    /// to know the approval mode.
    static func canApprove(
        for currentUserRole: UserRole,
        currentUserCompanyID: UUID?,
        currentUserID: UUID?,
        domain: ApprovalDomain,
        itemCompanyID: UUID?,
        assignedApproverUserID: UUID? = nil,
        assignedApproverRole: UserRole? = nil
    ) -> Bool {
        mode(
            for: currentUserRole,
            currentUserCompanyID: currentUserCompanyID,
            currentUserID: currentUserID,
            domain: domain,
            itemCompanyID: itemCompanyID,
            assignedApproverUserID: assignedApproverUserID,
            assignedApproverRole: assignedApproverRole
        ) != nil
    }
}

// MARK: - AppStore convenience

extension AppStore {
    /// The mode the current user would approve a domain item under,
    /// given the item's tenant + assignee. nil = can't approve.
    /// Call sites: ApprovalQueueView row label, review-sheet
    /// "Approve" button visibility, audit-log stamp on approve.
    func approvalMode(
        for domain: ApprovalDomain,
        itemCompanyID: UUID?,
        assignedApproverUserID: UUID? = nil,
        assignedApproverRole: UserRole? = nil
    ) -> ApprovalMode? {
        ApprovalAuthority.mode(
            for: currentUserRole,
            currentUserCompanyID: currentCompanyID,
            currentUserID: currentUser?.id,
            domain: domain,
            itemCompanyID: itemCompanyID,
            assignedApproverUserID: assignedApproverUserID,
            assignedApproverRole: assignedApproverRole
        )
    }
}
