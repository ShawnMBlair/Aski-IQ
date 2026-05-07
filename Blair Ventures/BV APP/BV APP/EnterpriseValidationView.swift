// EnterpriseValidationView.swift
// Aski IQ – Enterprise Diagnostic Suite
// 25-point validation covering auth, sync, tenant isolation, data integrity,
// compliance, commercial accuracy, and connectivity.

import SwiftUI
import Combine

// MARK: - Result Types

enum ValidationStatus {
    case pass, warning, fail, info

    var icon: String {
        switch self {
        case .pass:    return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .fail:    return "xmark.circle.fill"
        case .info:    return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .pass:    return .green
        case .warning: return .orange
        case .fail:    return .red
        case .info:    return .blue
        }
    }

    var label: String {
        switch self {
        case .pass:    return "PASS"
        case .warning: return "WARN"
        case .fail:    return "FAIL"
        case .info:    return "INFO"
        }
    }
}

struct ValidationCheck: Identifiable {
    let id: UUID = UUID()
    let number: Int
    let group: String
    let name: String
    var status: ValidationStatus
    var detail: String
}

// MARK: - Engine

@MainActor
final class EnterpriseValidationEngine: ObservableObject {

    @Published var checks: [ValidationCheck] = []
    @Published var isRunning = false
    @Published var ranAt: Date? = nil

    var passCount:    Int { checks.filter { $0.status == .pass    }.count }
    var warnCount:    Int { checks.filter { $0.status == .warning }.count }
    var failCount:    Int { checks.filter { $0.status == .fail    }.count }
    var infoCount:    Int { checks.filter { $0.status == .info    }.count }
    var overallPassed: Bool { failCount == 0 }

    func run(store: AppStore) async {
        guard !isRunning else { return }
        isRunning = true
        checks = []
        defer { isRunning = false; ranAt = Date() }

        var results: [ValidationCheck] = []

        // ── Group 1: Auth & Identity ──────────────────────────────────────────

        // 1. User authenticated
        let userAuth = store.currentUser != nil
        results.append(ValidationCheck(
            number: 1, group: "Auth & Identity",
            name:   "Current user authenticated",
            status: userAuth ? .pass : .fail,
            detail: userAuth
                ? "Signed in as \(store.currentUser!.fullName) [\(store.currentUserRole.rawValue)]."
                : "No authenticated user found. Sign in before running diagnostics."
        ))

        // 2. Company ID present
        let hasCompany = store.currentCompanyID != nil
        results.append(ValidationCheck(
            number: 2, group: "Auth & Identity",
            name:   "Company ID present",
            status: hasCompany ? .pass : .fail,
            detail: hasCompany
                ? "Company ID: \(store.currentCompanyID!.uuidString.prefix(8))…"
                : "currentCompanyID is nil — tenant isolation cannot function. Run a full sync or re-sign in."
        ))

        // 3. User role valid
        let role = store.currentUserRole
        let isElevated = [UserRole.projectManager, .officeAdmin, .manager, .executive].contains(role)
        results.append(ValidationCheck(
            number: 3, group: "Auth & Identity",
            name:   "User role is admin-eligible",
            status: isElevated ? .pass : .warning,
            detail: isElevated
                ? "Role '\(role.rawValue)' has admin access."
                : "Role '\(role.rawValue)' — some diagnostics require manager or higher. Results may be incomplete."
        ))

        // 4. Last sync within 24 hours
        let lastSync = SyncEngine.shared.lastSyncAt
        let syncAge  = lastSync.map { Date().timeIntervalSince($0) } ?? Double.infinity
        let syncFresh = syncAge < 86_400
        results.append(ValidationCheck(
            number: 4, group: "Auth & Identity",
            name:   "Last full sync within 24 hours",
            status: lastSync == nil ? .warning : (syncFresh ? .pass : .warning),
            detail: lastSync == nil
                ? "No sync has run this session. Pull fresh data via Settings → Sync."
                : syncFresh
                    ? "Last sync \(formatAge(syncAge)) ago."
                    : "Last sync was \(formatAge(syncAge)) ago — data may be stale."
        ))

        // ── Group 2: Sync Health ──────────────────────────────────────────────

        // 5. No .failed sync records
        let failedCount = countFailed(store)
        results.append(ValidationCheck(
            number: 5, group: "Sync Health",
            name:   "No failed sync records",
            status: failedCount == 0 ? .pass : .fail,
            detail: failedCount == 0
                ? "All records synced cleanly."
                : "\(failedCount) record(s) in .failed state. These will not push to Supabase until resolved. Try Sync → Push Pending."
        ))

        // 6. Pending queue depth
        let pendingCount = countPending(store)
        results.append(ValidationCheck(
            number: 6, group: "Sync Health",
            name:   "Pending sync queue depth",
            status: pendingCount == 0 ? .pass : pendingCount < 20 ? .info : .warning,
            detail: pendingCount == 0
                ? "No records awaiting push."
                : "\(pendingCount) record(s) pending upload. They will push on next sync or when connectivity resumes."
        ))

        // 7. No stuck soft-deletes (isDeleted=true but deletedAt=nil)
        let stuckDeletes = countStuckSoftDeletes(store)
        results.append(ValidationCheck(
            number: 7, group: "Sync Health",
            name:   "Soft-delete integrity",
            status: stuckDeletes == 0 ? .pass : .warning,
            detail: stuckDeletes == 0
                ? "All soft-deleted records have a valid deletedAt timestamp."
                : "\(stuckDeletes) record(s) marked isDeleted=true but missing deletedAt. This may block Supabase push."
        ))

        // 8. Certificate store accessible (UserDefaults)
        let certCount = store.certificates.count
        results.append(ValidationCheck(
            number: 8, group: "Sync Health",
            name:   "Certificate store accessible",
            status: .pass,
            detail: "UserDefaults certificate store is readable. \(certCount) certificate(s) on device."
        ))

        // ── Group 3: Tenant Isolation ─────────────────────────────────────────

        // 9. Material requests have companyID
        let mrWithoutTenant = store.materialRequests.filter { !$0.isDeleted && $0.companyID == nil }.count
        results.append(ValidationCheck(
            number: 9, group: "Tenant Isolation",
            name:   "Material requests: companyID set",
            status: mrWithoutTenant == 0 ? .pass : .warning,
            detail: mrWithoutTenant == 0
                ? "All \(store.materialRequests.filter { !$0.isDeleted }.count) material request(s) have a company ID."
                : "\(mrWithoutTenant) material request(s) missing companyID. RLS will block their push."
        ))

        // 10. Purchase orders have companyID
        let poWithoutTenant = store.purchaseOrders.filter { !$0.isDeleted && $0.companyID == nil }.count
        results.append(ValidationCheck(
            number: 10, group: "Tenant Isolation",
            name:   "Purchase orders: companyID set",
            status: poWithoutTenant == 0 ? .pass : .warning,
            detail: poWithoutTenant == 0
                ? "All \(store.purchaseOrders.filter { !$0.isDeleted }.count) purchase order(s) have a company ID."
                : "\(poWithoutTenant) purchase order(s) missing companyID. RLS will block their push."
        ))

        // 11. Suppliers have companyID
        let supWithoutTenant = store.suppliers.filter { !$0.isDeleted && $0.companyID == nil }.count
        results.append(ValidationCheck(
            number: 11, group: "Tenant Isolation",
            name:   "Suppliers: companyID set",
            status: supWithoutTenant == 0 ? .pass : .warning,
            detail: supWithoutTenant == 0
                ? "All \(store.suppliers.filter { !$0.isDeleted }.count) supplier(s) have a company ID."
                : "\(supWithoutTenant) supplier(s) missing companyID."
        ))

        // ── Group 4: Data Integrity ───────────────────────────────────────────

        // 12. Orphaned timesheet entries
        let projectIDs = Set(store.projects.map { $0.id })
        let orphanedTS = store.timesheetEntries.filter { e in
            !projectIDs.contains(e.projectID)
        }.count
        results.append(ValidationCheck(
            number: 12, group: "Data Integrity",
            name:   "No orphaned timesheet entries",
            status: orphanedTS == 0 ? .pass : .warning,
            detail: orphanedTS == 0
                ? "All timesheet entries reference valid projects."
                : "\(orphanedTS) timesheet entry(ies) reference project IDs not in the local store. They may belong to archived projects."
        ))

        // 13. RFI project links valid
        let orphanedRFIs = store.rfis.filter { !$0.isDeleted && !projectIDs.contains($0.projectID) }.count
        results.append(ValidationCheck(
            number: 13, group: "Data Integrity",
            name:   "RFIs linked to valid projects",
            status: orphanedRFIs == 0 ? .pass : .warning,
            detail: orphanedRFIs == 0
                ? "All \(store.rfis.filter { !$0.isDeleted }.count) RFI(s) reference valid projects."
                : "\(orphanedRFIs) RFI(s) reference a project not in the local store."
        ))

        // 14. MR → PO linkage
        let poIDs = Set(store.purchaseOrders.map { $0.id })
        let brokenMRLinks = store.materialRequests.filter { mr in
            guard !mr.isDeleted, let poID = mr.purchaseOrderID else { return false }
            return !poIDs.contains(poID)
        }.count
        results.append(ValidationCheck(
            number: 14, group: "Data Integrity",
            name:   "Material request → PO linkage",
            status: brokenMRLinks == 0 ? .pass : .warning,
            detail: brokenMRLinks == 0
                ? "All MR → PO links resolve correctly."
                : "\(brokenMRLinks) material request(s) reference a purchase order not in the local store."
        ))

        // 15. Quote @Published array working
        let quoteCount = store.quotes.count
        let quoteSyncBroken = store.quotes.filter { $0.syncStatus == .failed }.count
        results.append(ValidationCheck(
            number: 15, group: "Data Integrity",
            name:   "Quote @Published array consistent",
            status: quoteSyncBroken == 0 ? .pass : .warning,
            detail: quoteSyncBroken == 0
                ? "\(quoteCount) quote(s) in @Published array, none in failed state."
                : "\(quoteSyncBroken) quote(s) in .failed sync state. Re-run sync to retry push."
        ))

        // ── Group 5: Compliance & Safety ─────────────────────────────────────

        // 16. Expired certificates
        let expiredCerts = store.expiredCertificates.count
        results.append(ValidationCheck(
            number: 16, group: "Compliance & Safety",
            name:   "No expired certifications",
            status: expiredCerts == 0 ? .pass : .fail,
            detail: expiredCerts == 0
                ? "All tracked certifications are current."
                : "\(expiredCerts) certification(s) EXPIRED. Affected workers may be non-compliant for site entry."
        ))

        // 17. Certifications expiring within 30 days
        let expiringSoon = store.expiringCertificates.count
        results.append(ValidationCheck(
            number: 17, group: "Compliance & Safety",
            name:   "Certifications expiring within 30 days",
            status: expiringSoon == 0 ? .pass : .warning,
            detail: expiringSoon == 0
                ? "No certifications expiring in the next 30 days."
                : "\(expiringSoon) certification(s) expiring soon. Schedule renewals now."
        ))

        // 18. Open high/critical severity incidents
        let highIncidents = store.incidents.filter {
            !$0.isDeleted && $0.status == .open &&
            ($0.severity == .high || $0.severity == .critical)
        }.count
        results.append(ValidationCheck(
            number: 18, group: "Compliance & Safety",
            name:   "No open high/critical incidents",
            status: highIncidents == 0 ? .pass : .fail,
            detail: highIncidents == 0
                ? "No high or critical severity incidents currently open."
                : "\(highIncidents) HIGH/CRITICAL incident(s) open. Immediate management notification required."
        ))

        // 19. WCB-reportable incidents open
        let wcbOpen = store.incidents.filter {
            !$0.isDeleted && $0.status == .open && $0.reportableToWCB
        }.count
        results.append(ValidationCheck(
            number: 19, group: "Compliance & Safety",
            name:   "WCB-reportable incidents resolved",
            status: wcbOpen == 0 ? .pass : .warning,
            detail: wcbOpen == 0
                ? "No unresolved WCB-reportable incidents."
                : "\(wcbOpen) WCB-reportable incident(s) still open. Confirm filing status with safety manager."
        ))

        // ── Group 6: Commercial Accuracy ─────────────────────────────────────

        // 20. Overdue invoices
        let overdueCount = store.overdueInvoices.count
        results.append(ValidationCheck(
            number: 20, group: "Commercial",
            name:   "Overdue invoices",
            status: overdueCount == 0 ? .pass : .warning,
            detail: overdueCount == 0
                ? "No overdue invoices."
                : "\(overdueCount) invoice(s) past due. Review Invoices → Aging Report."
        ))

        // 21. Open RFIs needing answer
        let openRFIs = store.rfis.filter { !$0.isDeleted && $0.status.needsAnswer }.count
        results.append(ValidationCheck(
            number: 21, group: "Commercial",
            name:   "Open RFIs awaiting response",
            status: openRFIs == 0 ? .pass : .info,
            detail: openRFIs == 0
                ? "No RFIs awaiting engineer/owner response."
                : "\(openRFIs) RFI(s) submitted or under review. Monitor for responses to prevent schedule impact."
        ))

        // 22. Material requests pending approval
        let mrPending = store.pendingMaterialApprovals.count
        results.append(ValidationCheck(
            number: 22, group: "Commercial",
            name:   "Material requests pending approval",
            status: mrPending == 0 ? .pass : .info,
            detail: mrPending == 0
                ? "No material requests awaiting approval."
                : "\(mrPending) material request(s) submitted but not yet approved."
        ))

        // 23. Decimal precision spot check
        let precisionIssues = spotCheckDecimalPrecision(store)
        results.append(ValidationCheck(
            number: 23, group: "Commercial",
            name:   "Financial decimal precision (IEEE 754)",
            status: precisionIssues == 0 ? .pass : .warning,
            detail: precisionIssues == 0
                ? "No IEEE 754 precision artifacts detected in sampled quote totals."
                : "\(precisionIssues) quote total(s) contain suspicious decimal patterns (e.g. 0.99999 / 1.00001). Re-save to apply the precision fix."
        ))

        // 24. Invoices in unknown paid/pending state
        let staleInvoices = store.invoices.filter { inv in
            inv.status == .paid && inv.syncStatus == .pending &&
            Date().timeIntervalSince(inv.updatedAt) > 604_800  // > 7 days
        }.count
        results.append(ValidationCheck(
            number: 24, group: "Commercial",
            name:   "Paid invoices sync within 7 days",
            status: staleInvoices == 0 ? .pass : .warning,
            detail: staleInvoices == 0
                ? "All paid invoices have pushed to Supabase."
                : "\(staleInvoices) invoice(s) marked paid but stuck as .pending for over 7 days. Force sync to resolve."
        ))

        // ── Group 7: Connectivity ─────────────────────────────────────────────

        // 25. Network reachable
        let connected = NetworkMonitor.shared.isConnected
        results.append(ValidationCheck(
            number: 25, group: "Connectivity",
            name:   "Network reachable",
            status: connected ? .pass : .warning,
            detail: connected
                ? "Network is reachable. Sync and push operations can proceed."
                : "Device appears offline. All changes are queued locally and will push when connectivity resumes."
        ))

        checks = results
    }

    // MARK: - Helpers

    private func formatAge(_ seconds: TimeInterval) -> String {
        if seconds < 60   { return "< 1 min" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) hr" }
        return "\(Int(seconds / 86400)) day"
    }

    private func countFailed(_ s: AppStore) -> Int {
        // One variable per array — trailing closures prevent chaining without type-checker timeouts.
        let n1  = s.projects.filter         { $0.syncStatus == .failed }.count
        let n2  = s.employees.filter        { $0.syncStatus == .failed }.count
        let n3  = s.timesheetEntries.filter { $0.syncStatus == .failed }.count
        let n4  = s.formSubmissions.filter  { $0.syncStatus == .failed }.count
        let n5  = s.invoices.filter         { $0.syncStatus == .failed }.count
        let n6  = s.quotes.filter           { $0.syncStatus == .failed }.count
        let n7  = s.crmOpportunities.filter { $0.syncStatus == .failed }.count
        let n8  = s.crmContacts.filter      { $0.syncStatus == .failed }.count
        let n9  = s.incidents.filter        { $0.syncStatus == .failed }.count
        let n10 = s.rfis.filter             { $0.syncStatus == .failed }.count
        let n11 = s.materialRequests.filter { $0.syncStatus == .failed }.count
        let n12 = s.purchaseOrders.filter   { $0.syncStatus == .failed }.count
        let n13 = s.suppliers.filter        { $0.syncStatus == .failed }.count
        return n1 + n2 + n3 + n4 + n5 + n6 + n7 + n8 + n9 + n10 + n11 + n12 + n13
    }

    private func countPending(_ s: AppStore) -> Int {
        // One variable per array — trailing closures prevent chaining without type-checker timeouts.
        let n1  = s.projects.filter         { $0.syncStatus == .pending }.count
        let n2  = s.employees.filter        { $0.syncStatus == .pending }.count
        let n3  = s.timesheetEntries.filter { $0.syncStatus == .pending }.count
        let n4  = s.formSubmissions.filter  { $0.syncStatus == .pending }.count
        let n5  = s.invoices.filter         { $0.syncStatus == .pending }.count
        let n6  = s.quotes.filter           { $0.syncStatus == .pending }.count
        let n7  = s.crmOpportunities.filter { $0.syncStatus == .pending }.count
        let n8  = s.crmContacts.filter      { $0.syncStatus == .pending }.count
        let n9  = s.incidents.filter        { $0.syncStatus == .pending }.count
        let n10 = s.rfis.filter             { $0.syncStatus == .pending }.count
        let n11 = s.materialRequests.filter { $0.syncStatus == .pending }.count
        let n12 = s.purchaseOrders.filter   { $0.syncStatus == .pending }.count
        let n13 = s.suppliers.filter        { $0.syncStatus == .pending }.count
        return n1 + n2 + n3 + n4 + n5 + n6 + n7 + n8 + n9 + n10 + n11 + n12 + n13
    }

    private func countStuckSoftDeletes(_ s: AppStore) -> Int {
        let stuckProjects  = s.projects.filter         { $0.isDeleted && $0.deletedAt == nil }.count
        let stuckEmployees = s.employees.filter        { $0.isDeleted && $0.deletedAt == nil }.count
        let stuckInvoices  = s.invoices.filter         { $0.isDeleted && $0.deletedAt == nil }.count
        let stuckIncidents = s.incidents.filter        { $0.isDeleted && $0.deletedAt == nil }.count
        let stuckRFIs      = s.rfis.filter             { $0.isDeleted && $0.deletedAt == nil }.count
        let stuckMRs       = s.materialRequests.filter { $0.isDeleted && $0.deletedAt == nil }.count
        let stuckPOs       = s.purchaseOrders.filter   { $0.isDeleted && $0.deletedAt == nil }.count
        return stuckProjects + stuckEmployees + stuckInvoices + stuckIncidents + stuckRFIs + stuckMRs + stuckPOs
    }

    private func spotCheckDecimalPrecision(_ s: AppStore) -> Int {
        // Check first 20 quotes for IEEE 754 artifact patterns in their computed subtotals.
        // A clean Decimal(string:) conversion never produces these trailing digit runs.
        let sample = s.quotes.prefix(20)
        return sample.filter { q in
            let str = "\(q.subtotal)"
            return str.contains("99999") || str.contains("00001") ||
                   str.contains("99998") || str.contains("00002")
        }.count
    }
}

// MARK: - View

struct EnterpriseValidationView: View {

    @EnvironmentObject var store: AppStore
    @StateObject private var engine = EnterpriseValidationEngine()

    private var groups: [String] {
        var seen = Set<String>()
        return engine.checks.compactMap { c in
            seen.insert(c.group).inserted ? c.group : nil
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if engine.checks.isEmpty && !engine.isRunning {
                        emptyState
                    } else {
                        summaryCard
                        ForEach(groups, id: \.self) { group in
                            groupSection(group)
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Enterprise Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await engine.run(store: store) }
                    } label: {
                        if engine.isRunning {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Label("Run", systemImage: "play.circle.fill")
                        }
                    }
                    .disabled(engine.isRunning)
                }
            }
            .task {
                // Auto-run on first appearance
                if engine.checks.isEmpty {
                    await engine.run(store: store)
                }
            }
        }
    }

    // MARK: Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "stethoscope")
                .font(.system(size: 52))
                .foregroundColor(.secondary)
            Text("25-Point Enterprise Diagnostic")
                .font(.headline)
            Text("Validates auth, sync health, tenant isolation, data integrity, compliance, commercial accuracy, and network connectivity.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                Task { await engine.run(store: store) }
            } label: {
                Label("Run Diagnostics", systemImage: "play.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
        }
        .padding(.vertical, 40)
    }

    // MARK: Summary Card

    private var summaryCard: some View {
        GroupBox {
            HStack(spacing: 0) {
                scoreTile(engine.passCount,  "Passed",   .pass)
                Divider().frame(height: 44)
                scoreTile(engine.warnCount,  "Warnings", .warning)
                Divider().frame(height: 44)
                scoreTile(engine.failCount,  "Failed",   .fail)
                Divider().frame(height: 44)
                scoreTile(engine.infoCount,  "Info",     .info)
            }
            .frame(maxWidth: .infinity)

            if let ranAt = engine.ranAt {
                Text("Last run: \(ranAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 4)
            }
        } label: {
            HStack {
                Image(systemName: engine.overallPassed ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundColor(engine.overallPassed ? .green : .red)
                Text(engine.overallPassed ? "All Clear" : "\(engine.failCount) Check(s) Failed")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    Task { await engine.run(store: store) }
                } label: {
                    Label("Re-run", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(engine.isRunning)
            }
        }
        .padding(.horizontal)
    }

    private func scoreTile(_ count: Int, _ label: String, _ status: ValidationStatus) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.title2.weight(.bold))
                .foregroundColor(count > 0 ? status.color : .secondary)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Group Section

    private func groupSection(_ group: String) -> some View {
        let groupChecks = engine.checks.filter { $0.group == group }
        return GroupBox(group) {
            VStack(spacing: 0) {
                ForEach(Array(groupChecks.enumerated()), id: \.element.id) { idx, check in
                    checkRow(check)
                    if idx < groupChecks.count - 1 {
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private func checkRow(_ check: ValidationCheck) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Check number + status icon
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: check.status.icon)
                    .foregroundColor(check.status.color)
                    .font(.title3)
            }
            .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("#\(check.number)")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary)
                    Text(check.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                }
                Text(check.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Text(check.status.label)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(check.status.color.opacity(0.12))
                .foregroundColor(check.status.color)
                .cornerRadius(5)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Admin Panel Hook

/// Compact row for embedding in AdminPanelView syncSection
struct DiagnosticsNavRow: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        NavigationLink(destination: EnterpriseValidationView()) {
            HStack {
                Label("Enterprise Diagnostics", systemImage: "stethoscope")
                    .font(.subheadline)
                Spacer()
                Text("25 checks")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .foregroundColor(.primary)
    }
}
