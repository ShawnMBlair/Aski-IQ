// CommercialWorkflowStateMachine.swift
// Aski IQ — Entity-First CRM, Slice 4
//
// Centralized state-transition validator for opportunities + quotes +
// estimates. Plugs into CommercialWorkflowService so every state flip
// is checked against an explicit allowed-transitions matrix before the
// mutation fires.
//
// WHY THIS EXISTS
//   Pre-Slice-4, transitions were enforced via scattered if/else
//   guards across 6+ files. A rep could (e.g.) flip a quote from
//   .draft directly to .accepted, skipping .approved + .sent. The
//   reporting + signed-PDF pipeline assume a linear lifecycle, so
//   skipped states surface as broken dashboards or silently-missing
//   audit trails.
//
//   This file makes the matrix explicit and unit-test-friendly. Forward
//   transitions are the only ones permitted by default; admins can
//   request a "force" transition that bypasses validation but writes
//   an audit row tagged `WorkflowAudit.Action.forcedTransition`.
//
// MAPPING TO THE ENTERPRISE SPEC
//   The master spec uses Lead/Discovery/Commitment/Won/Lost/Delivery/
//   Billing/Closed. The actual iOS enum uses newLead/contacted/
//   siteVisit/estimateRequired/quoteSent/followUp/won/lost. We DON'T
//   rename — that's a data migration that touches 5 sample-data rows
//   plus user expectations. Instead the validator works against the
//   live values and the displayLabel returns the mapped spec term
//   when one exists.

import Foundation

// MARK: - Opportunity stage state machine

enum OpportunityStateMachine {

    /// Allowed forward + lateral transitions per stage. Terminal
    /// stages (won, lost) require an admin "force" override to leave.
    /// Same-stage "transitions" are no-ops and always allowed.
    static let allowed: [OpportunityStage: Set<OpportunityStage>] = [
        .newLead: [
            .contacted, .siteVisit, .estimateRequired, .quoteSent,
            .followUp, .won, .lost
        ],
        .contacted: [
            .siteVisit, .estimateRequired, .quoteSent,
            .followUp, .won, .lost
        ],
        .siteVisit: [
            .estimateRequired, .quoteSent,
            .followUp, .won, .lost
        ],
        .estimateRequired: [
            .quoteSent, .followUp, .won, .lost
        ],
        .quoteSent: [
            .followUp, .won, .lost
        ],
        .followUp: [
            .quoteSent,        // reissue / new revision after follow-up
            .won, .lost
        ],
        // Terminal — leaving requires admin override.
        .won:  [],
        .lost: []
    ]

    /// True when `to` is a no-op (same stage) or in the allow-list for
    /// `from`. False for terminal-stage exits unless `force` is true.
    static func canTransition(from: OpportunityStage,
                               to:   OpportunityStage,
                               force: Bool = false) -> Bool {
        if force { return true }
        if from == to { return true }
        return allowed[from]?.contains(to) ?? false
    }

    /// User-readable description of why a transition was rejected.
    /// Empty string if the transition is fine.
    static func rejectionReason(from: OpportunityStage,
                                  to:   OpportunityStage) -> String? {
        if canTransition(from: from, to: to) { return nil }
        if from == .won {
            return "This opportunity is already Won. Use Reopen (admin only) before changing the stage."
        }
        if from == .lost {
            return "This opportunity is already Lost. Use Reopen (admin only) before changing the stage."
        }
        return "Invalid transition: \(from.rawValue) → \(to.rawValue). Allowed next stages: \(allowed[from]?.map(\.rawValue).sorted().joined(separator: ", ") ?? "(none)")."
    }
}

// MARK: - Quote status state machine

enum QuoteStateMachine {

    static let allowed: [QuoteStatus: Set<QuoteStatus>] = [
        // .draft → .sent is allowed: the in-app "Save & Send Quote"
        // button is a one-tap action that intentionally skips the
        // explicit .approved step. The approval THRESHOLD gate (Slice 5)
        // is what enforces sign-off for high-value quotes — the
        // .approved STATUS is a separate concept (an internal review
        // checkpoint) that not every workflow uses.
        .draft:    [.approved, .sent, .declined],
        .approved: [.sent, .declined],
        // .sent → .draft is allowed because magic-link revocation +
        // re-mint may flip a quote back to draft (rep modified after
        // sending, before customer accepted). Only added if needed —
        // omit until a real call site requires it.
        .sent:     [.accepted, .declined],
        // Terminal — admin override required to undo.
        .accepted: [],
        .declined: []
    ]

    static func canTransition(from: QuoteStatus,
                               to:   QuoteStatus,
                               force: Bool = false) -> Bool {
        if force { return true }
        if from == to { return true }
        return allowed[from]?.contains(to) ?? false
    }

    static func rejectionReason(from: QuoteStatus,
                                  to:   QuoteStatus) -> String? {
        if canTransition(from: from, to: to) { return nil }
        if from == .accepted {
            return "Quote is already accepted. Reopen (admin only) before changing status."
        }
        if from == .declined {
            return "Quote is already declined. Reopen (admin only) before changing status."
        }
        return "Invalid quote-status transition: \(from.rawValue) → \(to.rawValue). Allowed next states: \(allowed[from]?.map(\.rawValue).sorted().joined(separator: ", ") ?? "(none)")."
    }
}

// MARK: - Workflow audit log

/// Centralized audit record for every state change the workflow
/// service performs. Gets written to BOTH:
///   • `crm_activities` (user-visible feed) via the existing
///     `store.logCRMActivity` helper — keeps reps' timeline intact
///   • a local print() trace today; Slice 4+1 wires this to a
///     dedicated `workflow_audit` Postgres table for forensic queries
///
/// The struct is the single source of truth for what happened: who
/// did it, when, what entity, before/after state, source path. Future
/// dashboards + compliance reports read from this shape.
struct WorkflowAuditEntry {
    enum EntityType: String {
        case quote, estimate, project, opportunity, materialSale, contract, invoice
    }
    enum Action: String {
        case stateTransition
        case forcedTransition       // admin override that bypassed validation
        case create
        case archive
        case approve
        case reject
        case backfillLink
    }

    let timestamp:    Date
    let actorName:    String
    let entityType:   EntityType
    let entityID:     UUID
    let action:       Action
    let fromState:    String?       // raw value of prior state, if any
    let toState:      String?       // raw value of new state
    let source:       String        // free text — usually a WorkflowSource raw value
    let details:      [String: String]
}

/// Centralized writer. Everything that mutates workflow state in
/// CommercialWorkflowService funnels through here so future Slice 4+1
/// can tee the writes off to the durable audit table without touching
/// any call sites.
@MainActor
enum WorkflowAuditLog {

    /// Writes the entry to crm_activities (user-visible) and to
    /// stdout (forensic trace). The crm_activities row uses the
    /// `.workflowEvent` activity type so existing UIs surface it
    /// without code changes.
    static func record(_ entry: WorkflowAuditEntry,
                        opportunityID: UUID? = nil,
                        clientID:      UUID? = nil,
                        quoteID:       UUID? = nil,
                        projectID:     UUID? = nil) {
        let store = AppStore.shared
        let title: String
        switch entry.action {
        case .stateTransition, .forcedTransition:
            title = "\(entry.entityType.rawValue.capitalized) \(entry.fromState ?? "?") → \(entry.toState ?? "?")"
        case .create:
            title = "\(entry.entityType.rawValue.capitalized) created"
        case .archive:
            title = "\(entry.entityType.rawValue.capitalized) archived"
        case .approve:
            title = "\(entry.entityType.rawValue.capitalized) approved"
        case .reject:
            title = "\(entry.entityType.rawValue.capitalized) rejected"
        case .backfillLink:
            title = "\(entry.entityType.rawValue.capitalized) linked to opportunity (backfill)"
        }
        let notes = "via \(entry.source). Actor: \(entry.actorName). " +
                    entry.details.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")

        // Map entity to the appropriate CRMActivityType. We want every
        // workflow event in the activity feed but the existing enum
        // doesn't have a generic `.workflowEvent` — fall back to the
        // closest-fitting case so the timeline stays usable.
        let activityType: CRMActivityType = {
            switch entry.entityType {
            case .quote:       return .quoteSent
            case .estimate:    return .estimateCreated
            case .project:     return .projectCreated
            case .opportunity: return .stageChanged
            case .materialSale: return .stageChanged
            case .contract:    return .stageChanged
            case .invoice:     return .stageChanged
            }
        }()

        store.logCRMActivity(
            type:          activityType,
            title:         title,
            notes:         notes,
            clientID:      clientID,
            contactID:     nil,
            opportunityID: opportunityID,
            quoteID:       quoteID,
            projectID:     projectID
        )

        // Forensic trace (until Slice 4+1 lands the durable audit table)
        print("📜 WORKFLOW AUDIT \(entry.timestamp.ISO8601Format()) | \(entry.entityType.rawValue) \(entry.entityID.uuidString.prefix(8)) | \(entry.action.rawValue) | \(entry.fromState ?? "-") → \(entry.toState ?? "-") | by \(entry.actorName) via \(entry.source)")
    }
}
