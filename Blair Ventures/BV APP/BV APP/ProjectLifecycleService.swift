// ProjectLifecycleService.swift
// Aski IQ — Phase 5 PMI workflow: process-aligned dashboard rollups.
//
// PURPOSE
// Pre-fix the dashboards aggregated by ad-hoc data type (Forms,
// Timesheets, Active Sites, Incidents). Owners and PMs couldn't
// answer the natural PMI question: "where is the work in our
// pipeline — initiate, plan, execute, monitor, or close?" The CRM
// dashboard answered the lead-funnel side; the management dashboard
// answered cost/utilisation; nothing tied them together.
//
// THIS FILE
// Stateless rollup that, for the current company, buckets every
// CRM opportunity / estimate / quote / project into one of the five
// PMI process groups, with count + dollar exposure. Monitoring is
// modelled as an overlay (a watch on Executing items with risk
// flags) rather than a mutually-exclusive bucket — that's how PMI
// actually defines it.
//
// PHASES
//   .initiating  — leads, estimates being built
//   .planning    — proposal sent, awaiting client decision
//   .executing   — won + active projects
//   .monitoring  — active projects with risk flags (subset of
//                  executing — over budget, margin watch, open
//                  COs/RFIs)
//   .closing     — completed projects whose closeout still has
//                  pending items, or fully closed but not yet
//                  archived
//
// NOTE
// "Lost / cancelled / declined" items are not surfaced. Owners look
// at this dashboard to see the live pipeline; lost work belongs in
// the CRM funnel (where conversion ratios live).

import Foundation

@MainActor
enum ProjectLifecyclePhase: String, CaseIterable, Identifiable {
    case initiating
    case planning
    case executing
    case monitoring
    case closing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .initiating: return "Initiating"
        case .planning:   return "Planning"
        case .executing:  return "Executing"
        case .monitoring: return "Monitoring"
        case .closing:    return "Closing"
        }
    }

    /// One-line tooltip / sub-header explaining what's in the bucket.
    var subtitle: String {
        switch self {
        case .initiating: return "Leads & estimates being built"
        case .planning:   return "Proposals sent, awaiting decision"
        case .executing:  return "Active & awarded projects"
        case .monitoring: return "Projects with risk flags"
        case .closing:    return "Closeout in progress"
        }
    }

    var icon: String {
        switch self {
        case .initiating: return "lightbulb"
        case .planning:   return "doc.text.below.ecg"
        case .executing:  return "hammer"
        case .monitoring: return "eye.trianglebadge.exclamationmark"
        case .closing:    return "checkmark.seal"
        }
    }

    /// Phase color — drives the badge tint in the UI.
    var colorName: String {
        switch self {
        case .initiating: return "blue"
        case .planning:   return "purple"
        case .executing:  return "green"
        case .monitoring: return "orange"
        case .closing:    return "indigo"
        }
    }
}

@MainActor
struct ProjectLifecycleBucket {
    let phase:        ProjectLifecyclePhase
    let count:        Int
    let totalValue:   Decimal      // Sum of contract / quoted / estimated value
    let projectIDs:   [UUID]       // Items that are projects (used by Monitoring)
    let estimateIDs:  [UUID]
    let quoteIDs:     [UUID]
    let opportunityIDs: [UUID]

    /// Single-line summary for the card subtitle when no items exist.
    var isEmpty: Bool { count == 0 }
}

@MainActor
struct ProjectLifecycleSummary {
    let buckets: [ProjectLifecyclePhase: ProjectLifecycleBucket]

    func bucket(_ phase: ProjectLifecyclePhase) -> ProjectLifecycleBucket {
        buckets[phase] ?? ProjectLifecycleBucket(
            phase: phase, count: 0, totalValue: 0,
            projectIDs: [], estimateIDs: [], quoteIDs: [], opportunityIDs: []
        )
    }

    /// Total dollar exposure across the live pipeline (executing + planning).
    /// Excludes initiating (too speculative) and closing (already booked).
    var liveBookedValue: Decimal {
        bucket(.executing).totalValue + bucket(.planning).totalValue
    }
}

@MainActor
enum ProjectLifecycleService {

    static func summary(for store: AppStore) -> ProjectLifecycleSummary {
        var out: [ProjectLifecyclePhase: ProjectLifecycleBucket] = [:]

        // Source pools — soft-delete-filtered.
        let opps      = store.crmOpportunities.filter { !$0.isDeleted }
        let estimates = store.estimates.filter        { !$0.isDeleted }
        let quotes    = store.quotes.filter           { !$0.isDeleted }
        let projects  = store.projects.filter         { !$0.isDeleted }

        // ── Initiating ──────────────────────────────────────────────
        // Early-funnel: leads being qualified + estimates not yet
        // priced or sent. Dollar value is the opp's `value` (PM
        // estimate of deal size) + the estimate's totalEstimated.
        let initiatingOpps = opps.filter {
            [.newLead, .contacted, .siteVisit, .estimateRequired].contains($0.stage)
        }
        let initiatingEstimates = estimates.filter {
            [.rfqReceived, .estimating, .internalReview].contains($0.status)
        }
        let initiatingValue = initiatingOpps.reduce(Decimal(0)) { $0 + $1.value }
            + initiatingEstimates.reduce(Decimal(0)) { $0 + $1.totalEstimated }
        out[.initiating] = ProjectLifecycleBucket(
            phase:          .initiating,
            count:          initiatingOpps.count + initiatingEstimates.count,
            totalValue:     initiatingValue,
            projectIDs:     [],
            estimateIDs:    initiatingEstimates.map(\.id),
            quoteIDs:       [],
            opportunityIDs: initiatingOpps.map(\.id)
        )

        // ── Planning ────────────────────────────────────────────────
        // Proposal-out, awaiting decision. Includes opps in
        // .quoteSent/.followUp, estimates marked .submitted, quotes
        // sent or approved (sent to client) but not yet accepted, and
        // projects in .tendering (kicked off but not yet awarded).
        let planningOpps = opps.filter {
            [.quoteSent, .followUp].contains($0.stage)
        }
        let planningEstimates = estimates.filter { $0.status == .submitted }
        let planningQuotes    = quotes.filter    { $0.status == .sent || $0.status == .approved }
        let planningProjects  = projects.filter  { $0.status == .tendering }
        let planningValue = planningOpps.reduce(Decimal(0)) { $0 + $1.value }
            + planningEstimates.reduce(Decimal(0)) { $0 + $1.totalEstimated }
            + planningQuotes.reduce(Decimal(0))    { $0 + $1.grandTotal }
            + planningProjects.reduce(Decimal(0))  { $0 + ($1.contractValue ?? 0) }
        out[.planning] = ProjectLifecycleBucket(
            phase:          .planning,
            count:          planningOpps.count + planningEstimates.count
                            + planningQuotes.count + planningProjects.count,
            totalValue:     planningValue,
            projectIDs:     planningProjects.map(\.id),
            estimateIDs:    planningEstimates.map(\.id),
            quoteIDs:       planningQuotes.map(\.id),
            opportunityIDs: planningOpps.map(\.id)
        )

        // ── Executing ───────────────────────────────────────────────
        // Won + work-in-progress. Awarded projects (signed, not yet
        // mobilised) count alongside .active projects so PMs see the
        // full backlog, not just what's billable today.
        let executingProjects = projects.filter {
            $0.status == .active || $0.status == .awarded
        }
        let executingValue = executingProjects.reduce(Decimal(0)) { $0 + ($1.contractValue ?? 0) }
        out[.executing] = ProjectLifecycleBucket(
            phase:          .executing,
            count:          executingProjects.count,
            totalValue:     executingValue,
            projectIDs:     executingProjects.map(\.id),
            estimateIDs:    [],
            quoteIDs:       [],
            opportunityIDs: []
        )

        // ── Monitoring ──────────────────────────────────────────────
        // Subset of Executing that has at least one risk flag. PMI
        // treats Monitor & Control as a parallel process group, so we
        // model it as an overlay rather than a separate exclusive
        // bucket. Dollar exposure is the sum of revised contract
        // values for the at-risk projects (revenue at risk, not actual
        // overrun amount — that's surfaced per-project on the budget
        // card).
        var atRiskProjects: [Project] = []
        var atRiskValue = Decimal(0)
        for proj in executingProjects {
            let actuals = BudgetActualService.actuals(for: proj.id, in: store)
            let openCOs = store.changeOrders(for: proj.id)
                .filter { $0.status.isOpen && !$0.isDeleted }
            let openRFIs = store.rfis.filter {
                $0.projectID == proj.id && !$0.isDeleted
                    && $0.status != .closed && $0.status != .voided
            }
            let isAtRisk = actuals.isOverBudget
                || actuals.isApproachingBudget
                || actuals.isMarginBelowTarget
                || !openCOs.isEmpty
                || !openRFIs.isEmpty
            if isAtRisk {
                atRiskProjects.append(proj)
                atRiskValue += actuals.revisedBudget
            }
        }
        out[.monitoring] = ProjectLifecycleBucket(
            phase:          .monitoring,
            count:          atRiskProjects.count,
            totalValue:     atRiskValue,
            projectIDs:     atRiskProjects.map(\.id),
            estimateIDs:    [],
            quoteIDs:       [],
            opportunityIDs: []
        )

        // ── Closing ─────────────────────────────────────────────────
        // Projects already flipped to .completed. Pending closeout
        // items remain visible until the PM has worked through the
        // checklist (final invoice, lien waiver, etc.). Projects with
        // a clean checklist still appear here briefly so they're
        // findable for archiving — the dashboard is the natural
        // launchpad for that.
        let closingProjects = projects.filter { $0.status == .completed }
        let closingValue = closingProjects.reduce(Decimal(0)) { $0 + ($1.contractValue ?? 0) }
        out[.closing] = ProjectLifecycleBucket(
            phase:          .closing,
            count:          closingProjects.count,
            totalValue:     closingValue,
            projectIDs:     closingProjects.map(\.id),
            estimateIDs:    [],
            quoteIDs:       [],
            opportunityIDs: []
        )

        return ProjectLifecycleSummary(buckets: out)
    }
}
