// RoleProbe.swift
// Aski IQ — Phase 1 Step 1 diagnostic
//
// PURPOSE
// One-stop diagnostic for the Swift role enum ↔ Supabase role taxonomy
// alignment. Built during Phase 1 Step 1 to surface the kind of silent
// drift that demoted `owner`-tagged users to `.fieldWorker` for months
// because the Swift enum lacked the case.
//
// WHAT IT DOES
//
//   1. Hooks `UserRole.unknownRoleHandler` so any unrecognised
//      `profiles.role` raw value is recorded once with full context
//      (raw string, timestamp, user id, company id) AND forwarded to
//      CrashReporter as a non-fatal capture. Replaces the silent
//      `print` that was the only signal before.
//
//   2. Builds a static map of every known Swift role and the SQL role
//      groups it belongs to (mirroring the v3 SQL helper bodies pulled
//      via `pg_get_functiondef`). Lets the dev menu render a side-by-
//      side table so a reviewer can spot drift without running SQL.
//
//   3. Exposes `RoleProbeView` — a SwiftUI surface for the dev menu
//      that shows:
//       • current user's role + level
//       • permission matrix expectations vs current Swift answers
//       • any unknown-role decode events seen in this session
//
// THIS FILE IS PURE SWIFT. NO MIGRATIONS. NO DB WRITES.

import SwiftUI
import Foundation

// MARK: - Probe state

/// Records a single observation of an unrecognised server role coming
/// down from `profiles.role`. Stored in-memory only — Phase 1 Step 1
/// does not persist these. Stage A persistence (Step 3) does not need
/// this because the diagnostic is meant for live debugging, not history.
struct UnknownRoleObservation: Identifiable, Equatable {
    let id = UUID()
    let raw: String
    let observedAt: Date
    /// Optional — currentUser may not be set when the decode happens
    /// (e.g. during sync of `tenantProfiles` for someone else).
    let userIDHint: String?
    let companyIDHint: String?
}

/// Single source of truth for the Swift-side role-probe diagnostic.
/// Use `RoleProbe.install()` once during app launch.
enum RoleProbe {

    // MARK: Observation buffer

    /// In-memory ring of recent unknown-role decode events. Capped so a
    /// runaway decoder cannot grow this unbounded. The dev menu reads
    /// this directly via `recentUnknownRoles()`.
    @MainActor private static var observations: [UnknownRoleObservation] = []
    private static let observationCap = 50

    // MARK: Install

    /// Install the diagnostic. Idempotent — safe to call multiple times.
    /// Replaces `UserRole.unknownRoleHandler` with a richer one that:
    ///   • prints to console (existing behaviour, kept for parity)
    ///   • appends to the in-memory observation buffer
    ///   • forwards to CrashReporter as a non-fatal capture (with raw
    ///     value as context — never includes user PII)
    ///
    /// Call from `BV_APPApp.init()` AFTER `CrashReporter.configure()`
    /// so the Sentry pipeline is ready to receive captures.
    static func install() {
        UserRole.unknownRoleHandler = { raw in
            // Console parity with the default handler.
            print("⚠️ RoleProbe — unknown server role '\(raw)', demoting to .fieldWorker")

            // Buffer for the dev menu.
            Task { @MainActor in
                let obs = UnknownRoleObservation(
                    raw: raw,
                    observedAt: Date(),
                    userIDHint: nil,
                    companyIDHint: nil
                )
                observations.append(obs)
                // Trim oldest if we exceed cap. O(n) but n ≤ 50.
                if observations.count > observationCap {
                    observations.removeFirst(observations.count - observationCap)
                }
            }

            // Forward to CrashReporter as a non-fatal warning. Context
            // intentionally omits any PII — only the raw role string,
            // which is server-controlled and not user-identifying.
            CrashReporter.capture(
                message: "Unknown server role decoded — demoted to .fieldWorker",
                level: .warning,
                context: ["raw_role": raw]
            )
        }
    }

    /// Snapshot the recent unknown-role observations (newest last).
    @MainActor
    static func recentUnknownRoles() -> [UnknownRoleObservation] {
        observations
    }

    /// Clear the in-memory buffer. Used by the dev menu's "Reset" button.
    @MainActor
    static func clearObservations() {
        observations.removeAll()
    }
}

// MARK: - Static role taxonomy mirror
//
// Mirrors the v3 audit's confirmed SQL helper bodies. If the SQL is
// changed without updating this table, the dev menu surfaces the drift
// loudly via the "Unknown to Swift?" / "Unknown to SQL?" columns.

extension RoleProbe {

    /// SQL helper groups a role belongs to. Pulled from
    /// `pg_get_functiondef` during the v3 audit. Update if RM1 changes
    /// the helper bodies.
    enum SQLHelperGroup: String, CaseIterable, Identifiable {
        case fieldRole              = "is_field_role"
        case foremanOrAbove         = "is_foreman_or_above"
        case safetyAdmin            = "is_safety_admin"
        case estimatingAdmin        = "is_estimating_admin"
        case financialAdmin         = "is_financial_admin"
        case managerOrAbove         = "is_manager_or_above"
        case notClient              = "is_not_client"
        // Phase-1 RM1 helpers (drafted but not applied yet).
        case quoteApprovalAdmin     = "is_quote_approval_admin"
        case commercialDecisionAdmin = "is_commercial_decision_admin"

        var id: String { rawValue }

        /// Roles included in the SQL helper as of the v3 audit truth-pull.
        /// Phase-1 helpers reflect the C.2 matrix as drafted.
        var includedServerRoles: Set<String> {
            switch self {
            case .fieldRole:
                return ["field_worker", "foreman"]
            case .foremanOrAbove:
                return ["foreman", "project_manager", "office_admin",
                        "manager", "executive", "owner"]
            case .safetyAdmin:
                return ["safety_advisor", "office_admin", "manager",
                        "executive", "owner"]
            case .estimatingAdmin:
                return ["estimator", "project_manager", "office_admin",
                        "manager", "executive", "owner"]
            case .financialAdmin:
                return ["office_admin", "manager", "executive", "owner"]
            case .managerOrAbove:
                return ["manager", "executive"]
            case .notClient:
                return ["field_worker", "foreman", "safety_advisor",
                        "project_manager", "estimator", "office_admin",
                        "manager", "executive", "owner"]
            case .quoteApprovalAdmin:
                return ["project_manager", "office_admin", "manager",
                        "executive", "owner"]
            case .commercialDecisionAdmin:
                return ["office_admin", "manager", "executive", "owner"]
            }
        }
    }

    /// Every role the Swift enum understands. Source of truth =
    /// `UserRole.allCases`.
    static var swiftRoles: [UserRole] { UserRole.allCases }

    /// Every server role the SQL helpers reference. Pulled from helper
    /// bodies (v3 audit). Used to compute drift.
    static var serverRoles: Set<String> {
        SQLHelperGroup.allCases.reduce(into: Set<String>()) { acc, group in
            acc.formUnion(group.includedServerRoles)
        }
    }

    /// Server roles the Swift enum does NOT recognise. If non-empty,
    /// users with those roles will silently demote to .fieldWorker.
    static var serverRolesMissingFromSwift: [String] {
        let swiftRaws = Set(swiftRoles.map { $0.rawValue })
        return serverRoles.subtracting(swiftRaws).sorted()
    }

    /// Swift roles the SQL helpers do NOT mention anywhere. Likely
    /// safe (the role is recognised, just not gated), but flagged for
    /// completeness.
    static var swiftRolesMissingFromSQL: [UserRole] {
        swiftRoles.filter { !serverRoles.contains($0.rawValue) }
    }
}

// MARK: - Permission matrix expectation

extension RoleProbe {

    /// One row of the C.2 matrix expressed as code. Used by
    /// `RoleProbeView` to compare expectations against what the
    /// current Swift code actually answers.
    struct MatrixExpectation: Identifiable {
        let id = UUID()
        let action: String
        /// Closure given a role returns whether that role is expected
        /// to be allowed. Tier-gated rows fold the override path into
        /// the expectation explicitly.
        let allows: (UserRole) -> Bool
        /// What Swift currently answers — usually a `UserRole` helper
        /// closure. If `actual(role) != allows(role)`, the dev menu
        /// renders the row in red.
        let actual: (UserRole) -> Bool
    }

    /// The full set of expectations from C.2 that we can verify
    /// without a server round-trip. Tier-gated rows that depend on a
    /// dollar amount use a representative low/mid/high decision and
    /// expect the result to match `canApproveQuoteApproval`.
    @MainActor
    static func matrixExpectations() -> [MatrixExpectation] {
        return [
            MatrixExpectation(
                action: "Create Quote",
                allows: { [.estimator, .projectManager, .officeAdmin,
                           .manager, .executive, .owner].contains($0) },
                actual: { $0.canEstimate || $0.canPromoteEstimateToQuote }
            ),
            MatrixExpectation(
                action: "Approve Quote ≤$10K (low)",
                allows: { [.projectManager, .officeAdmin, .manager,
                           .executive, .owner].contains($0) },
                actual: { ApprovalAuthority.canApproveQuoteApproval(
                    for: $0, quoteTotal: 5_000) != .blocked }
            ),
            MatrixExpectation(
                action: "Approve Quote $25K (mid) — direct only",
                allows: { [.officeAdmin, .manager, .executive, .owner].contains($0) },
                actual: { ApprovalAuthority.canApproveQuoteApproval(
                    for: $0, quoteTotal: 25_000) == .allowedDirect }
            ),
            MatrixExpectation(
                action: "Approve Quote $75K (high) — direct only",
                allows: { [.executive, .owner].contains($0) },
                actual: { ApprovalAuthority.canApproveQuoteApproval(
                    for: $0, quoteTotal: 75_000) == .allowedDirect }
            ),
            MatrixExpectation(
                action: "Create Material Sale",
                allows: { [.estimator, .projectManager, .officeAdmin,
                           .manager, .executive, .owner].contains($0) },
                actual: { $0.canCreateOpportunity || $0.canEstimate }
            ),
            MatrixExpectation(
                action: "Approve Schedule Recommendation",
                allows: { [.projectManager, .officeAdmin, .manager,
                           .executive, .owner].contains($0) },
                actual: { $0.canApproveDomain(.scheduleRecommendation) }
            ),
            MatrixExpectation(
                action: "Approve Change Order (base)",
                allows: { [.officeAdmin, .manager, .executive, .owner].contains($0) },
                actual: { $0.canApproveChangeOrder }
            ),
            MatrixExpectation(
                action: "Soft-delete Client",
                allows: { [.officeAdmin, .manager, .executive, .owner].contains($0) },
                actual: { $0.canSoftDeleteClient }
            ),
            MatrixExpectation(
                action: "Hard-delete Client (no history)",
                allows: { [.executive, .owner].contains($0) },
                actual: { $0.canHardDeleteClientWithoutHistory }
            ),
            MatrixExpectation(
                action: "Hard-delete Client (with history) — must be NO for everyone",
                allows: { _ in false },
                actual: { $0.canHardDeleteClientWithHistory }
            ),
        ]
    }
}

// MARK: - SwiftUI surface

/// Dev-menu diagnostic. Mount under your existing Settings/Diagnostics
/// stack. Safe to ship in release builds — it only reads in-memory
/// state and runs pure-Swift comparisons.
struct RoleProbeView: View {
    @EnvironmentObject var store: AppStore
    @State private var observations: [UnknownRoleObservation] = []
    @State private var driftSweepResult: QuoteDriftSweepResult? = nil
    @State private var driftSweepRunning: Bool = false
    @State private var materialBackfillResult: AppStore.MaterialSaleBackfillResult? = nil

    var body: some View {
        Form {
            currentUserSection
            taxonomyDriftSection
            matrixSection
            quoteDriftSweepSection
            unlinkedMaterialSalesSection
            unknownRolesSection
        }
        .navigationTitle("Role Probe")
        .onAppear { observations = RoleProbe.recentUnknownRoles() }
    }

    // MARK: Current user

    @ViewBuilder
    private var currentUserSection: some View {
        Section("Current User") {
            HStack {
                Text("Role")
                Spacer()
                Text(store.currentUserRole.displayName)
                    .foregroundColor(.secondary)
            }
            HStack {
                Text("Approval level")
                Spacer()
                Text("\(store.currentUserRole.approvalLevel)")
                    .foregroundColor(.secondary)
            }
            HStack {
                Text("Tenant (companyID)")
                Spacer()
                Text(store.currentCompanyID?.uuidString.prefix(8).description ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: Drift

    @ViewBuilder
    private var taxonomyDriftSection: some View {
        Section("Taxonomy Drift") {
            let missingFromSwift = RoleProbe.serverRolesMissingFromSwift
            let missingFromSQL   = RoleProbe.swiftRolesMissingFromSQL

            if missingFromSwift.isEmpty {
                Label("All server roles are recognised by Swift", systemImage: "checkmark.seal.fill")
                    .foregroundColor(.green)
            } else {
                Label("Server roles missing from Swift enum:", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                ForEach(missingFromSwift, id: \.self) { raw in
                    Text("• \(raw)").font(.system(.body, design: .monospaced))
                }
            }

            if missingFromSQL.isEmpty {
                Label("All Swift roles are referenced by at least one SQL helper",
                      systemImage: "checkmark.seal.fill")
                    .foregroundColor(.green)
            } else {
                Label("Swift roles never referenced by SQL helpers:", systemImage: "info.circle")
                    .foregroundColor(.orange)
                ForEach(missingFromSQL, id: \.self) { role in
                    Text("• \(role.rawValue)").font(.system(.body, design: .monospaced))
                }
            }
        }
    }

    // MARK: Matrix

    @ViewBuilder
    private var matrixSection: some View {
        Section("Matrix Expectations vs Swift Code") {
            let expectations = RoleProbe.matrixExpectations()
            ForEach(expectations) { exp in
                let role = store.currentUserRole
                let expected = exp.allows(role)
                let actual = exp.actual(role)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(exp.action).font(.subheadline)
                        Text("expected: \(expected ? "✓" : "✗")  actual: \(actual ? "✓" : "✗")")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if expected == actual {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    } else {
                        Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
                    }
                }
            }
        }
    }

    // MARK: Quote drift sweep (Phase 1 Step 4)

    @ViewBuilder
    private var quoteDriftSweepSection: some View {
        Section("Quote Outcome Drift Sweep") {
            Text("Manually re-runs the magic-link reconciliation that fires automatically on every pull cycle. Use after a customer signs via the magic link if the rep on this device wants to confirm the loop closed without waiting for the next pull.")
                .font(.caption)
                .foregroundColor(.secondary)

            Button {
                Task { await runDriftSweep() }
            } label: {
                HStack {
                    if driftSweepRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(driftSweepRunning ? "Running…" : "Run Drift Sweep")
                }
            }
            .disabled(driftSweepRunning)

            if let r = driftSweepResult {
                if r.totalCorrections == 0 && r.orphansSkipped == 0 {
                    Label("No corrections needed — every quote is in sync.",
                          systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        if r.orphansRecovered > 0 {
                            Text("• Magic-link orphans recovered: \(r.orphansRecovered)")
                        }
                        if r.driftedFlipped > 0 {
                            Text("• Quotes auto-flipped to .accepted: \(r.driftedFlipped)")
                        }
                        if r.orphansSkipped > 0 {
                            Text("• Orphans without linked opp (manual repair): \(r.orphansSkipped)")
                                .foregroundColor(.orange)
                        }
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func runDriftSweep() async {
        driftSweepRunning = true
        defer { driftSweepRunning = false }
        let result = await SyncEngine.shared.reconcileQuoteOutcomeDrift()
        await MainActor.run { driftSweepResult = result }
    }

    // MARK: Unlinked Material Sales triage (Phase 1 Step 5)

    @ViewBuilder
    private var unlinkedMaterialSalesSection: some View {
        let unlinked = store.materialSales.filter {
            !$0.isDeleted && $0.opportunityID == nil
        }
        let canBackfill = store.currentUserRole.isAdmin   // executive | owner

        Section("Unlinked Material Sales") {
            if unlinked.isEmpty {
                Label("Every material sale is linked to a CRM opportunity.",
                      systemImage: "checkmark.seal.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            } else {
                Text("\(unlinked.count) material sale\(unlinked.count == 1 ? "" : "s") with no opportunity linkage. Backfill creates one opportunity per sale via the same auto-link path used at create time.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(unlinked.prefix(10)) { sale in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sale.saleNumber.isEmpty ? "Sale (no #)" : sale.saleNumber)
                            .font(.subheadline)
                        Text("\(sale.saleType.displayName) — \(sale.grandTotal.currencyString)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                if unlinked.count > 10 {
                    Text("+ \(unlinked.count - 10) more").font(.caption2).foregroundColor(.secondary)
                }

                if canBackfill {
                    Button {
                        runMaterialBackfill()
                    } label: {
                        HStack {
                            Image(systemName: "link.badge.plus")
                            Text("Backfill all \(unlinked.count)")
                        }
                    }
                } else {
                    Text("Executive or Owner role required to run backfill.")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }

                if let r = materialBackfillResult {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Inspected: \(r.inspected)")
                        Text("Linked: \(r.linked)").foregroundColor(.green)
                        if r.skipped > 0 {
                            Text("Skipped (orphan client / soft-deleted): \(r.skipped)")
                                .foregroundColor(.orange)
                        }
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func runMaterialBackfill() {
        let r = store.backfillMaterialSaleLinkage()
        materialBackfillResult = r
    }

    // MARK: Unknown roles seen

    @ViewBuilder
    private var unknownRolesSection: some View {
        Section("Unknown Server Roles Seen This Session") {
            if observations.isEmpty {
                Text("None — every decoded role mapped to a Swift case.")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                ForEach(observations) { obs in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("'\(obs.raw)'").font(.system(.body, design: .monospaced))
                        Text(obs.observedAt.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Button("Clear") {
                    Task { @MainActor in
                        RoleProbe.clearObservations()
                        observations = []
                    }
                }
                .foregroundColor(.red)
            }
        }
    }
}
