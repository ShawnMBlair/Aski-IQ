// ApprovalQueueView.swift
// Aski IQ — Unified approval queue.
//
// PURPOSE
// Single surface for everything that needs the current user's
// approval. Pre-existing approval surfaces were per-domain:
//   • TimesheetApprovalQueueView → timesheets
//   • EstimateListView "Pending My Review" filter → estimates
//   • Command Centre "AI Schedule Suggestions" → schedule recs
//
// That meant a manager with three different approval types pending
// had to remember to check three different places. This view rolls
// them all up into one queue with grouped sections.
//
// SCOPE
//   • Section: Estimates pending my review (status=internal_review,
//     reviewer=me by name match)
//   • Section: Schedule recommendations awaiting my approval
//     (PM+ only — same role gate as ScheduleRecommendation.applyXxx)
//   • Section: Timesheets awaiting my approval (existing path,
//     reused as a deep link to the dedicated queue)
//
// PRIVATE TO THIS FILE
// Each section row taps into its respective detail view; this view
// doesn't replace the per-domain detail surfaces, just aggregates
// the entry points. Tapping into an estimate opens the estimate
// detail where the existing "Approve & Send to Client" CTA lives.

import SwiftUI

struct ApprovalQueueView: View {
    @EnvironmentObject var store: AppStore

    /// Estimates assigned to the current user as reviewer.
    /// Match by `internalReviewBy` name — that's the existing
    /// pre-RA-1 storage convention used by EstimateListView.
    ///
    /// 2026-05 fix: name comparison is normalized (whitespace
    /// collapsed, case-folded) because the DB stores some values
    /// with double spaces (e.g. "Shawn  Blair") while
    /// `Employee.fullName` emits single-space form. Pre-fix, mid-
    /// space variation made every match silently miss and the
    /// Estimates section appeared empty.
    private var estimatesPendingReview: [Estimate] {
        guard let me = store.currentUser?.fullName, !me.isEmpty else { return [] }
        let myNormalized = ApprovalQueueView.normalizeName(me)
        return store.estimates
            .filter {
                $0.status == .internalReview
                && ApprovalQueueView.normalizeName($0.internalReviewBy ?? "") == myNormalized
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Collapse consecutive whitespace, trim, and case-fold so two
    /// human-name variants compare equal. "Shawn  Blair" matches
    /// "Shawn Blair" matches " shawn blair ".
    fileprivate static func normalizeName(_ s: String) -> String {
        let collapsed = s
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.lowercased()
    }

    /// Schedule recommendations awaiting approval. Only surface for
    /// users who can actually approve them — for everyone else the
    /// queue would be read-only noise.
    private var pendingRecommendations: [ScheduleRecommendation] {
        guard store.canPerform(action: .scheduleApproveRecommendation) else { return [] }
        return store.scheduleRecommendations
            .filter { $0.status.isInQueue }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Timesheets awaiting approval. Reuses the existing
    /// `pendingTimesheets()` aggregation used by the dedicated
    /// timesheet queue surface.
    ///
    /// Phase 1 fix: gate on `canApproveTimesheets` so non-approving
    /// roles never see this section. The matrix C.2 says foremen
    /// approve their OWN crew only; the deeper-review surface
    /// already enforces that, so for the queue card we just confirm
    /// the role has SOME approval right before surfacing the list.
    private var pendingTimesheets: [TimesheetEntry] {
        guard store.canPerform(action: .timesheetApprove) else { return [] }
        return store.pendingTimesheets()
    }

    /// Quote approvals waiting on the current user's authority.
    ///
    /// 2026-05 fix (Phase 1): migrated from the legacy
    /// `ApprovalThreshold.canApprove(tier:role:)` helper — which only
    /// allowed manager/executive — to the v3 tier-aware helper
    /// `ApprovalAuthority.canApproveQuoteApproval(for:quoteTotal:)`.
    /// Pre-fix, office_admin and project_manager users never saw any
    /// quote approvals in the queue even though the C.2 matrix grants
    /// them approval rights (PM at low tier, office_admin at low+mid).
    /// Post-fix, every role sees every approval they can act on
    /// directly OR via override; rows that are still .blocked for
    /// the current role stay hidden so the queue isn't read-only noise.
    /// The DB policy `can_decide_quote_approval(...)` is the final
    /// gate — UI is defense-in-depth.
    private var pendingQuoteApprovals: [QuoteApproval] {
        store.pendingApprovals.filter { approval in
            store.canPerform(action: .quoteApprove, amount: approval.quoteTotal)
        }
    }

    /// Change orders awaiting financial-impact approval. The CO
    /// approval gate is `canApproveChangeOrder` (manager / executive
    /// only). Submitted + under_review are the actionable states.
    private var pendingChangeOrders: [ChangeOrder] {
        guard store.canPerform(action: .changeOrderApprove) else { return [] }
        return store.changeOrders
            .filter { !$0.isDeleted }
            .filter { $0.status == .submitted || $0.status == .underReview }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Material requests awaiting approval. Routes through the central
    /// approval-domain helper so the role list lives in one place.
    /// Phase 1 fix: use canApproveDomain(.materialRequest) which already
    /// includes .owner; pre-fix the inline list omitted owner so any
    /// owner-tagged user saw zero material requests in the queue.
    private var pendingMaterialRequests: [MaterialRequest] {
        guard store.currentUserRole.canApproveDomain(.materialRequest) else {
            return []
        }
        return store.materialRequests
            .filter { !$0.isDeleted && $0.status == .submitted }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Total queue depth — drives the queue card badge on the
    /// dashboard and the empty-state copy here.
    var totalPending: Int {
        estimatesPendingReview.count
            + pendingQuoteApprovals.count
            + pendingChangeOrders.count
            + pendingMaterialRequests.count
            + pendingRecommendations.count
            + pendingTimesheets.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if totalPending == 0 {
                    EmptyApprovalState()
                } else {
                    if !estimatesPendingReview.isEmpty {
                        estimatesSection
                    }
                    if !pendingQuoteApprovals.isEmpty {
                        quoteApprovalsSection
                    }
                    if !pendingChangeOrders.isEmpty {
                        changeOrdersSection
                    }
                    if !pendingMaterialRequests.isEmpty {
                        materialRequestsSection
                    }
                    if !pendingRecommendations.isEmpty {
                        recommendationsSection
                    }
                    if !pendingTimesheets.isEmpty {
                        timesheetsSection
                    }
                }
                Spacer(minLength: 32)
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .navigationTitle("Approval Queue")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Sections

    private var estimatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                title: "Estimates",
                icon: "doc.text.magnifyingglass",
                accent: .blue,
                count: estimatesPendingReview.count,
                hint: "Estimates marked for your internal review."
            )
            VStack(spacing: 8) {
                ForEach(estimatesPendingReview) { estimate in
                    NavigationLink {
                        EstimateDetailView(estimate: estimate)
                            .environmentObject(store)
                    } label: {
                        EstimateApprovalRow(estimate: estimate)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var quoteApprovalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                title: "Quote Approvals",
                icon: "dollarsign.circle.fill",
                accent: .green,
                count: pendingQuoteApprovals.count,
                hint: "Quote totals over the auto-approve threshold need a manager or admin sign-off before they can be sent."
            )
            VStack(spacing: 8) {
                ForEach(pendingQuoteApprovals) { approval in
                    if let quote = store.quotes.first(where: { $0.id == approval.quoteID }) {
                        NavigationLink {
                            QuoteDetailView(quote: quote)
                                .environmentObject(store)
                        } label: {
                            QuoteApprovalRow(approval: approval, quote: quote)
                        }
                        .buttonStyle(.plain)
                    } else {
                        // Quote was deleted or hasn't synced yet; fall
                        // back to a passive row so we don't navigate
                        // into a missing detail.
                        QuoteApprovalRow(approval: approval, quote: nil)
                    }
                }
            }
        }
    }

    private var changeOrdersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                title: "Change Orders",
                icon: "arrow.left.arrow.right",
                accent: .pink,
                count: pendingChangeOrders.count,
                hint: "Change orders awaiting financial-impact approval. Manager or executive only."
            )
            VStack(spacing: 8) {
                ForEach(pendingChangeOrders) { co in
                    NavigationLink {
                        ChangeOrderDetailView(changeOrder: co)
                            .environmentObject(store)
                    } label: {
                        ChangeOrderApprovalRow(changeOrder: co)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var materialRequestsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                title: "Material Requests",
                icon: "shippingbox.fill",
                accent: .indigo,
                count: pendingMaterialRequests.count,
                hint: "Submitted material requests awaiting your approval before a PO can be issued."
            )
            VStack(spacing: 8) {
                ForEach(pendingMaterialRequests) { mr in
                    NavigationLink {
                        MRDetailView(request: mr)
                            .environmentObject(store)
                    } label: {
                        MaterialRequestApprovalRow(request: mr)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var recommendationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                title: "AI Schedule Plans",
                icon: "sparkles",
                accent: .purple,
                count: pendingRecommendations.count,
                hint: "AI-generated schedule plans awaiting your approval."
            )
            VStack(spacing: 8) {
                ForEach(pendingRecommendations) { rec in
                    NavigationLink {
                        ScheduleRecommendationReviewView(recommendation: rec)
                            .environmentObject(store)
                    } label: {
                        RecommendationApprovalRow(recommendation: rec)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var timesheetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                title: "Timesheets",
                icon: "clock.badge.exclamationmark",
                accent: .orange,
                count: pendingTimesheets.count,
                hint: "Field timesheet submissions awaiting your approval."
            )
            // Timesheets get a deeper review surface than a flat list —
            // route to the dedicated view rather than building a
            // duplicate flow here.
            NavigationLink {
                TimesheetApprovalQueueView()
                    .environmentObject(store)
            } label: {
                HStack {
                    Image(systemName: "list.clipboard.fill")
                        .foregroundColor(.orange)
                    Text("Open Timesheet Queue")
                        .font(.subheadline.bold())
                        .foregroundColor(.primary)
                    Spacer()
                    Text("\(pendingTimesheets.count)")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.orange)
                        .clipShape(Capsule())
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func sectionHeader(title: String,
                               icon: String,
                               accent: Color,
                               count: Int,
                               hint: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(accent)
            Text(title)
                .font(.title3.bold())
            Text("\(count)")
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(accent)
                .clipShape(Capsule())
            Spacer()
        }
        Text(hint)
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.bottom, 2)
    }
}

// MARK: - Estimate row

// MARK: - Why-this-appears label
//
// Renders the master-prompt's "Assigned to you" / "Senior override
// available" / etc. tag on each row, so an approver glancing at the
// queue understands why an item is in their list — direct duty,
// role-based queue, or a senior helping clear a junior's backlog.
private struct ApprovalReasonLabel: View {
    let mode: ApprovalMode?
    var body: some View {
        if let mode {
            Text(reason(for: mode).uppercased())
                .font(.caption2.bold())
                .foregroundColor(color(for: mode))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color(for: mode).opacity(0.12))
                .clipShape(Capsule())
        }
    }
    private func reason(for mode: ApprovalMode) -> String {
        switch mode {
        case .direct:           return "Assigned to you"
        case .roleBased:        return "Your role"
        case .seniorOverride:   return "Senior override"
        case .tierRequired:     return "Your tier"
        case .conflictOverride: return "Override"
        }
    }
    private func color(for mode: ApprovalMode) -> Color {
        switch mode {
        case .direct:           return .blue
        case .roleBased:        return .indigo
        case .seniorOverride:   return .purple
        case .tierRequired:     return .green
        case .conflictOverride: return .red
        }
    }
}

private struct EstimateApprovalRow: View {
    let estimate: Estimate
    @EnvironmentObject var store: AppStore

    private var clientName: String {
        store.clients.first(where: { $0.id == estimate.clientID })?.name ?? "Unknown client"
    }

    /// Why this row is in the current user's queue. Estimates are
    /// person-routed via `internalReviewBy` (name match) — when the
    /// reviewer matches, mode is .direct; otherwise a senior with
    /// estimate-domain authority is helping clear the backlog
    /// (.seniorOverride).
    private var reasonMode: ApprovalMode? {
        let reviewerName = ApprovalQueueView.normalizeName(estimate.internalReviewBy ?? "")
        let myName = ApprovalQueueView.normalizeName(store.currentUser?.fullName ?? "")
        if !reviewerName.isEmpty && reviewerName == myName {
            return store.approvalMode(
                for: .estimateInternalReview,
                itemCompanyID: estimate.companyID,
                assignedApproverUserID: store.currentUser?.id
            )
        }
        return store.approvalMode(
            for: .estimateInternalReview,
            itemCompanyID: estimate.companyID,
            assignedApproverRole: nil   // person-routed but no role anchor
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.blue)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(estimate.jobNumber.isEmpty ? estimate.name : "\(estimate.jobNumber) — \(estimate.name)")
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Spacer()
                    Text("PENDING REVIEW")
                        .font(.caption2.bold())
                        .foregroundColor(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12))
                        .clipShape(Capsule())
                }
                Label(clientName, systemImage: "building.2")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Label(currencyString(estimate.totalEstimated), systemImage: "dollarsign.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Updated \(estimate.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                ApprovalReasonLabel(mode: reasonMode)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 6)
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(10)
    }

    private func currencyString(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale.current
        return f.string(from: value as NSDecimalNumber) ?? "$\(value)"
    }
}

// MARK: - Recommendation row

private struct RecommendationApprovalRow: View {
    let recommendation: ScheduleRecommendation
    @EnvironmentObject var store: AppStore

    private var projectName: String {
        recommendation.projectID.flatMap { id in
            store.projects.first(where: { $0.id == id })?.name
        } ?? "Project"
    }

    private var resourceLabel: String {
        guard let first = recommendation.proposedEntries.first else { return "—" }
        switch first.assignmentMode {
        case .fixedCrew:
            return first.crewID
                .flatMap { cid in store.crews.first(where: { $0.id == cid })?.name }
                ?? "—"
        case .individualWorker:
            guard let workerID = first.assignedWorkerIDs.first,
                  let emp = store.employees.first(where: { $0.id == workerID }) else { return "—" }
            return emp.fullName
        case .customCrew:
            let n = first.assignedWorkerIDs.count
            return "\(n) worker\(n == 1 ? "" : "s")"
        }
    }

    private var dayCount: Int { recommendation.proposedEntries.count }

    private var reasonMode: ApprovalMode? {
        store.approvalMode(
            for: .scheduleRecommendation,
            itemCompanyID: recommendation.companyID
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.purple)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundColor(.purple)
                    Text(projectName)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Spacer()
                    // SR-β: revision-requested plans get the
                    // "NEEDS REVISION" badge instead of confidence,
                    // so approvers spot them at a glance in the
                    // unified queue.
                    if recommendation.status == .revisionRequested {
                        Text("NEEDS REVISION")
                            .font(.caption2.bold())
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                    } else {
                        Text("\(Int(recommendation.confidenceScore * 100))%")
                            .font(.caption2.bold())
                            .foregroundColor(.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                Text(recommendation.summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                HStack(spacing: 12) {
                    Label(resourceLabel, systemImage: "person.2.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Label("\(dayCount) day\(dayCount == 1 ? "" : "s")",
                          systemImage: "calendar")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                ApprovalReasonLabel(mode: reasonMode)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 6)
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(10)
    }
}

// MARK: - Quote approval row

private struct QuoteApprovalRow: View {
    let approval: QuoteApproval
    let quote: Quote?
    @EnvironmentObject var store: AppStore

    private var clientName: String {
        quote?.clientName ?? "Unknown client"
    }

    private var jobNumber: String {
        quote?.jobNumber ?? "Quote"
    }

    /// Quote approvals are tier-required. The label is always
    /// .tierRequired since the user matches the tier (otherwise
    /// the row wouldn't be in their queue).
    private var reasonMode: ApprovalMode? { .tierRequired }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.green)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(jobNumber)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Spacer()
                    Text(approval.thresholdTier.displayName.uppercased())
                        .font(.caption2.bold())
                        .foregroundColor(approval.thresholdTier == .admin ? .red : .orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((approval.thresholdTier == .admin ? Color.red : Color.orange).opacity(0.12))
                        .clipShape(Capsule())
                }
                Label(clientName, systemImage: "building.2")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Label(approval.quoteTotalString, systemImage: "dollarsign.circle")
                    .font(.caption)
                    .foregroundColor(.green)
                Text("Requested by \(approval.requestedByName.isEmpty ? "—" : approval.requestedByName) · \(approval.requestedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                ApprovalReasonLabel(mode: reasonMode)
            }
            if quote != nil {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 6)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(10)
    }
}

// MARK: - Change order approval row

private struct ChangeOrderApprovalRow: View {
    let changeOrder: ChangeOrder
    @EnvironmentObject var store: AppStore

    private var projectName: String {
        store.projects.first(where: { $0.id == changeOrder.projectID })?.name ?? "Unknown project"
    }

    private var costImpactString: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale.current
        return f.string(from: changeOrder.effectiveCostImpact as NSDecimalNumber) ?? "$\(changeOrder.effectiveCostImpact)"
    }

    private var reasonMode: ApprovalMode? {
        store.approvalMode(
            for: .changeOrder,
            itemCompanyID: changeOrder.companyID
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.pink)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(changeOrder.number.isEmpty ? changeOrder.title : changeOrder.number)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Spacer()
                    Text(changeOrder.status.displayName.uppercased())
                        .font(.caption2.bold())
                        .foregroundColor(.pink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.pink.opacity(0.12))
                        .clipShape(Capsule())
                }
                if !changeOrder.title.isEmpty && changeOrder.title != changeOrder.number {
                    Text(changeOrder.title)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }
                Label(projectName, systemImage: "folder.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 12) {
                    Label(costImpactString, systemImage: "dollarsign.circle")
                        .font(.caption)
                        .foregroundColor(changeOrder.effectiveCostImpact >= 0 ? .green : .red)
                    if changeOrder.scheduleImpactDays > 0 {
                        Label("+\(changeOrder.scheduleImpactDays)d", systemImage: "calendar.badge.plus")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
                ApprovalReasonLabel(mode: reasonMode)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 6)
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(10)
    }
}

// MARK: - Material request approval row

private struct MaterialRequestApprovalRow: View {
    let request: MaterialRequest
    @EnvironmentObject var store: AppStore

    private var projectName: String {
        request.projectID.flatMap { id in
            store.projects.first(where: { $0.id == id })?.name
        } ?? "No project"
    }

    private var totalLines: Int { request.lineItems.count }

    private var reasonMode: ApprovalMode? {
        store.approvalMode(
            for: .materialRequest,
            itemCompanyID: request.companyID
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.indigo)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(request.requestNumber.isEmpty ? "Material Request" : request.requestNumber)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Spacer()
                    Text("SUBMITTED")
                        .font(.caption2.bold())
                        .foregroundColor(.indigo)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.indigo.opacity(0.12))
                        .clipShape(Capsule())
                }
                Label(projectName, systemImage: "folder.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 12) {
                    Label("\(totalLines) line\(totalLines == 1 ? "" : "s")", systemImage: "list.bullet")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if let needBy = request.requiredByDate {
                        Label("Needed \(needBy.formatted(date: .abbreviated, time: .omitted))",
                              systemImage: "calendar")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                ApprovalReasonLabel(mode: reasonMode)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 6)
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(10)
    }
}

// MARK: - Empty state

private struct EmptyApprovalState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundColor(.green)
                .padding(.top, 32)
            Text("All caught up")
                .font(.title3.bold())
            Text("Nothing in your approval queue right now.\nEstimates, schedule plans, and timesheets that need your review will appear here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

// MARK: - AppStore convenience

extension AppStore {
    /// Total count of items awaiting the current user's approval —
    /// drives the dashboard badge. Composes the same six sources
    /// the queue view renders so the badge matches the queue.
    var approvalQueueCount: Int {
        var n = 0
        // Estimates routed by name to me. Normalize whitespace + case
        // so "Shawn  Blair" (double space stored) matches "Shawn Blair"
        // (single space from Employee.fullName).
        if let me = currentUser?.fullName, !me.isEmpty {
            let myNormalized = ApprovalQueueView.normalizeName(me)
            n += estimates.filter {
                $0.status == .internalReview
                && ApprovalQueueView.normalizeName($0.internalReviewBy ?? "") == myNormalized
            }.count
        }
        // Quote approvals at a tier I can satisfy. Routed through Phase 6
        // canPerform shim so the badge matches the queue view's filter.
        let role = currentUserRole
        n += pendingApprovals.filter { approval in
            canPerform(action: .quoteApprove, amount: approval.quoteTotal)
        }.count
        // Change orders awaiting financial-impact approval.
        if canPerform(action: .changeOrderApprove) {
            n += changeOrders.filter {
                !$0.isDeleted
                && ($0.status == .submitted || $0.status == .underReview)
            }.count
        }
        // Material requests submitted, gated by canApproveDomain so .owner
        // is included automatically (was hard-coded to a 4-role list pre-fix).
        // Per-row amount gating happens in the queue view; the badge surfaces
        // any submitted MR a role with approve rights might act on.
        if role.canApproveDomain(.materialRequest) {
            n += materialRequests.filter { !$0.isDeleted && $0.status == .submitted }.count
        }
        // AI schedule recommendations awaiting PM+ approval
        if canPerform(action: .scheduleApproveRecommendation) {
            n += scheduleRecommendations.filter { $0.status.isInQueue }.count
        }
        // Timesheets — gate so the badge doesn't inflate for non-approving
        // roles (matches the queue view's section visibility).
        if canPerform(action: .timesheetApprove) {
            n += pendingTimesheets().count
        }
        return n
    }
}
