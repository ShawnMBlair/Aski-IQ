// AskiNextActionEngine.swift
// Phase 9 v1.2 — operational refinements #5: AI "next action" upgrade
//
// Locked spec: project_operational_refinements_v1_2.md (item #5).
//
// The in-app AI already detects gap conditions (empty crews, missing
// project budgets, expired certs, stalled opportunities). Today it
// emits descriptions ("crew has 0 members"). This engine emits
// **actions** — each detected condition produces a structured
// `AskiNextAction` with a deep-link destination and a one-line CTA
// the user can tap.
//
// Pure-Swift detection layer (no Claude calls). Deterministic, fast,
// and trivially testable. Mounts on the role-specific dashboards.

import Foundation

// MARK: - Action model

/// A specific next action surfaced to the user. Sorted by severity
/// then by detection order at render time.
struct AskiNextAction: Identifiable, Equatable {
    let id:        UUID
    let severity:  Severity
    let icon:      String
    let title:     String
    let detail:    String
    let cta:       String
    /// Where tapping the action card should navigate. Resolved by the
    /// hosting dashboard via switch — stored as enum so business logic
    /// stays decoupled from SwiftUI types.
    let destination: Destination

    enum Severity: Int, Comparable {
        case info     = 0
        case action   = 1
        case warning  = 2
        case critical = 3

        static func < (l: Severity, r: Severity) -> Bool { l.rawValue < r.rawValue }
    }

    enum Destination: Equatable {
        case crewMembership(crewID: UUID)
        case projectBudget(projectID: UUID)
        case opportunityFollowUp(opportunityID: UUID)
        case certificateExpiry(employeeID: UUID, certName: String)
        case expenseApproval(expenseID: UUID)
        case failedSyncs
    }
}

// MARK: - Engine

enum AskiNextActionEngine {

    /// Returns all currently-applicable next actions for the given
    /// store snapshot. Caller filters/sorts per dashboard.
    static func currentActions(in store: AppStore, now: Date = Date()) -> [AskiNextAction] {
        var out: [AskiNextAction] = []

        out.append(contentsOf: emptyCrewActions(store))
        out.append(contentsOf: missingBudgetActions(store))
        out.append(contentsOf: stalledOpportunityActions(store, now: now))
        out.append(contentsOf: expiredCertActions(store, now: now))
        out.append(contentsOf: pendingExpenseActions(store))
        out.append(contentsOf: failedSyncActions(store))

        return out.sorted { $0.severity > $1.severity }
    }

    // MARK: Rule 1 — empty crews
    //
    // Surfaces when a crew exists with zero member assignments and is
    // expected to be active. Resolves the "7 employees / 1 crew / 0
    // members" symptom flagged in the in-app AI gap analysis.

    private static func emptyCrewActions(_ store: AppStore) -> [AskiNextAction] {
        store.crews
            .filter { !$0.isDeleted && $0.isActive }
            .filter { $0.memberIDs.isEmpty }
            .map { crew in
                AskiNextAction(
                    id: UUID(),
                    severity: .warning,
                    icon: "person.2.slash",
                    title: "Crew has no workers",
                    detail: "Crew “\(crew.name)” is active but has 0 assigned members.",
                    cta: "Assign Workers",
                    destination: .crewMembership(crewID: crew.id)
                )
            }
    }

    // MARK: Rule 2 — projects without budgets
    //
    // Active project with a linked won/approved quote but no
    // ProjectBudget row. Spec: "every approved estimate or quote
    // should become the starting budget for the project."

    private static func missingBudgetActions(_ store: AppStore) -> [AskiNextAction] {
        let budgetedProjectIDs: Set<UUID> = Set(
            store.projectBudgets
                .filter { !$0.isDeleted }
                .map { $0.projectID }
        )

        func hasApprovedQuote(for projectID: UUID) -> Bool {
            store.quotes.contains { q in
                guard q.projectID == projectID else { return false }
                return q.status == .accepted || q.status == .approved
            }
        }

        let candidates: [Project] = store.projects.filter { p in
            guard !p.isDeleted else { return false }
            guard p.status != .completed && p.status != .cancelled else { return false }
            guard !budgetedProjectIDs.contains(p.id) else { return false }
            return hasApprovedQuote(for: p.id)
        }

        return Array(candidates.prefix(5)).map { proj in
            AskiNextAction(
                id: UUID(),
                severity: .action,
                icon: "dollarsign.circle",
                title: "Project needs a budget",
                detail: "“\(proj.name)” has an approved quote but no project budget yet.",
                cta: "Create From Quote",
                destination: .projectBudget(projectID: proj.id)
            )
        }
    }

    // MARK: Rule 3 — stalled opportunities
    //
    // Open opportunity with no logged activity in 14+ days AND no
    // scheduled next task. Spec: "prevent stalled opportunities."

    private static func stalledOpportunityActions(_ store: AppStore, now: Date) -> [AskiNextAction] {
        let stallThreshold = now.addingTimeInterval(-14 * 24 * 3600)

        func isStalled(_ opp: CRMOpportunity) -> Bool {
            guard !opp.isDeleted && opp.isActive else { return false }
            let hasOpenTask = store.crmTasks.contains { t in
                t.opportunityID == opp.id && t.status != .done && !t.isDeleted
            }
            if hasOpenTask { return false }
            let recentActivity = store.crmActivities.contains { a in
                a.opportunityID == opp.id && a.date > stallThreshold
            }
            return !recentActivity && opp.updatedAt < stallThreshold
        }

        let candidates: [CRMOpportunity] = store.crmOpportunities.filter(isStalled)

        return Array(candidates.prefix(5)).map { opp in
            AskiNextAction(
                id: UUID(),
                severity: .action,
                icon: "clock.badge.exclamationmark",
                title: "Opportunity is stalled",
                detail: "“\(opp.title)” has had no activity in 2+ weeks.",
                cta: "Schedule Follow-Up",
                destination: .opportunityFollowUp(opportunityID: opp.id)
            )
        }
    }

    // MARK: Rule 4 — expired / expiring certifications
    //
    // Employee certifications past expiry or expiring within 14 days.
    // Caps to the 5 most-urgent (lowest expiry date) to avoid burying
    // other actions.

    private static func expiredCertActions(_ store: AppStore, now: Date) -> [AskiNextAction] {
        let expiringWindow = now.addingTimeInterval(14 * 24 * 3600)

        struct Candidate { let cert: Certificate; let isExpired: Bool }

        let candidates: [Candidate] = store.certificates
            .filter { !$0.isDeleted && $0.expiryDate != nil }
            .compactMap { cert in
                guard let exp = cert.expiryDate else { return nil }
                if exp < now {
                    return Candidate(cert: cert, isExpired: true)
                }
                if exp < expiringWindow {
                    return Candidate(cert: cert, isExpired: false)
                }
                return nil
            }
            .sorted { ($0.cert.expiryDate ?? .distantFuture) < ($1.cert.expiryDate ?? .distantFuture) }

        return Array(candidates.prefix(5)).map { c in
            let emp = store.employees.first(where: { $0.id == c.cert.employeeID })
            let name = emp?.fullName ?? "Worker"
            let certName = c.cert.customName?.isEmpty == false
                ? c.cert.customName!
                : c.cert.type.displayName
            return AskiNextAction(
                id: UUID(),
                severity: c.isExpired ? .critical : .warning,
                icon: c.isExpired ? "exclamationmark.shield.fill" : "shield.lefthalf.filled",
                title: c.isExpired ? "Certification expired" : "Certification expiring soon",
                detail: "\(name) — \(certName)\(c.cert.expiryDate.map { " · \(shortDate($0))" } ?? "")",
                cta: c.isExpired ? "Renew Now" : "Renew",
                destination: .certificateExpiry(employeeID: c.cert.employeeID, certName: certName)
            )
        }
    }

    // MARK: Rule 5 — expenses awaiting approval
    //
    // Pending-approval expenses surfaced to managers. Critical when
    // > $5K (admin/exec required); warning otherwise.

    private static func pendingExpenseActions(_ store: AppStore) -> [AskiNextAction] {
        let pending: [Expense] = store.expenses.filter { e in
            !e.isDeleted && e.approvalState == .pendingApproval
        }
        return Array(pending.prefix(5)).map { e in
            let isCritical = e.isOverUpperThreshold
            return AskiNextAction(
                id: UUID(),
                severity: isCritical ? .critical : .action,
                icon: "checkmark.seal",
                title: isCritical ? "$5K+ expense waiting" : "Expense awaiting approval",
                detail: "\(e.vendor.isEmpty ? "(no vendor)" : e.vendor) — \(e.amount.currencyString)",
                cta: "Review",
                destination: .expenseApproval(expenseID: e.id)
            )
        }
    }

    // MARK: Rule 6 — failed syncs
    //
    // Any record in .failed state across the standard sync collections
    // surfaces as one rolled-up action pointing at the Failed Syncs
    // sheet. Uses store.totalFailedSyncCount (v1.0).

    private static func failedSyncActions(_ store: AppStore) -> [AskiNextAction] {
        let n = store.totalFailedSyncCount
        guard n > 0 else { return [] }
        return [AskiNextAction(
            id: UUID(),
            severity: .warning,
            icon: "icloud.slash",
            title: "Records didn't save to the cloud",
            detail: "\(n) record\(n == 1 ? "" : "s") failed to sync. Open Failed Syncs to retry or discard.",
            cta: "Open Failed Syncs",
            destination: .failedSyncs
        )]
    }

    // MARK: Helpers

    private static func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: d)
    }
}
