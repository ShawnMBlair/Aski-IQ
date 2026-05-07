// CRMReportingHelpers.swift
// Aski IQ — Canonical pipeline / win-rate helpers (Phase 9 cleanup).
//
// PRE-FIX
// The 2026-04 audit found at least three places computing win-rate
// inline from `crmOpportunities` filters:
//   * CRMDashboardView (allTimeWinRate, lines 27-29)
//   * CRMReportsView   (forecast loop)
//   * CRMCompanyViews  (per-company conversion stats)
//
// Each variant filtered slightly differently — some included
// `.lost`, some included only `.won`, some forgot `!isDeleted`.
// Result: the same metric showed three different numbers depending
// on the screen.
//
// THIS FILE
// Centralizes the math behind `wonOpportunities(in:)`, `lostOpportunities(in:)`,
// `winRate(in:)`, `wonValue(in:)`, and `lostValue(in:)`. All of them
// take an array slice so callers can scope to "this month",
// "this client", "since 2026-01-01", etc., without re-writing the
// filter logic each time.
//
// MIGRATION POLICY
// We're routing the most-visible callers (CRMDashboardView's all-time
// summary card) through these helpers in the same commit. Other
// callers can migrate opportunistically — the inline filters keep
// working, they're just no longer the source of truth.

import Foundation

extension AppStore {

    // ─────────────────────────────────────────────────────────────────
    // MARK: - All-time accessors
    // ─────────────────────────────────────────────────────────────────

    /// Every won, non-deleted opportunity for this tenant. Use this
    /// instead of `crmOpportunities.filter { $0.stage == .won }` so
    /// the deletion filter is applied consistently.
    var allWonOpportunities: [CRMOpportunity] {
        crmOpportunities.filter { $0.stage == .won && !$0.isDeleted }
    }

    /// Every lost, non-deleted opportunity. See `allWonOpportunities`
    /// for rationale.
    var allLostOpportunities: [CRMOpportunity] {
        crmOpportunities.filter { $0.stage == .lost && !$0.isDeleted }
    }

    /// All-time win rate. Returns 0 when there are no closed deals
    /// (rather than NaN, which previously broke the `>= 50%`
    /// comparison in PipelineSummaryCard).
    var allTimeWinRate: Double {
        winRate(in: crmOpportunities)
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: - Parameterized helpers
    // ─────────────────────────────────────────────────────────────────

    /// Win rate for an arbitrary slice of opportunities. The slice
    /// can be the full `crmOpportunities` or a date-bounded /
    /// client-bounded subset — the math is the same either way.
    func winRate(in slice: [CRMOpportunity]) -> Double {
        let won  = slice.filter { $0.stage == .won  && !$0.isDeleted }.count
        let lost = slice.filter { $0.stage == .lost && !$0.isDeleted }.count
        let total = won + lost
        guard total > 0 else { return 0 }
        return Double(won) / Double(total)
    }

    /// Total dollar value of won deals in `slice`.
    func wonValue(in slice: [CRMOpportunity]) -> Decimal {
        slice
            .filter { $0.stage == .won && !$0.isDeleted }
            .reduce(0) { $0 + $1.value }
    }

    /// Total dollar value of lost deals in `slice`.
    func lostValue(in slice: [CRMOpportunity]) -> Decimal {
        slice
            .filter { $0.stage == .lost && !$0.isDeleted }
            .reduce(0) { $0 + $1.value }
    }

    /// Win count + loss count tuple. Convenience for callers that
    /// want both numbers without iterating twice.
    func wonLostCounts(in slice: [CRMOpportunity]) -> (won: Int, lost: Int) {
        let won  = slice.filter { $0.stage == .won  && !$0.isDeleted }.count
        let lost = slice.filter { $0.stage == .lost && !$0.isDeleted }.count
        return (won, lost)
    }
}
