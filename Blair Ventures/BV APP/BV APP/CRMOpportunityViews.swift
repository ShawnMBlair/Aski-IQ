// CRMOpportunityViews.swift
// BV APP – CRM Pipeline Board, Opportunity Detail, and Opportunity Create

import SwiftUI
import Foundation

// MARK: - Currency Helper

private func currency(_ d: Decimal) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.locale = .current
    return f.string(from: d as NSDecimalNumber) ?? "$0"
}

// MARK: - Relative Date Helper

private func relativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

private func estimateStatusColor(_ status: EstimateStatus) -> Color {
    switch status {
    case .rfqReceived:    return .blue
    case .estimating:     return .orange
    case .internalReview: return .purple
    case .submitted:      return .teal
    case .awarded:        return .green
    // Phase 3 audit fix added .converted; mirrors the badge color.
    case .converted:      return .indigo
    case .lost:           return .red
    case .cancelled:      return .gray
    }
}

// MARK: - CRMPipelineView (replaces stub in CRMHubView.swift)

struct CRMPipelineView: View {
    @EnvironmentObject var store: AppStore

    @State private var showNewLead: Bool = false
    @State private var selectedOpportunity: CRMOpportunity? = nil
    @State private var showActiveOnly: Bool = true
    @State private var filterMine: Bool = false

    private var visibleStages: [OpportunityStage] {
        showActiveOnly ? OpportunityStage.activeStages : OpportunityStage.allCases
    }

    var body: some View {
        VStack(spacing: 0) {
            PipelineSummaryBar(showActiveOnly: $showActiveOnly, filterMine: $filterMine)
                .environmentObject(store)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(visibleStages) { stage in
                        PipelineColumnView(
                            stage: stage,
                            showActiveOnly: showActiveOnly,
                            filterMine: filterMine,
                            selectedOpportunity: $selectedOpportunity
                        )
                        .environmentObject(store)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Pipeline")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if store.currentUserRole.canEditCRM {
                ToolbarItem(placement: .primaryAction) {
                    Button { showNewLead = true } label: {
                        Label("New Lead", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showNewLead) {
            LeadIntakeView().environmentObject(store)
        }
        .sheet(item: $selectedOpportunity) { opp in
            NavigationStack {
                CRMOpportunityDetailView(opportunity: opp).environmentObject(store)
            }
        }
    }
}

// MARK: - Pipeline Summary Bar

private struct PipelineSummaryBar: View {
    @EnvironmentObject var store: AppStore
    @Binding var showActiveOnly: Bool
    @Binding var filterMine: Bool

    private var filteredOpps: [CRMOpportunity] {
        // Show all non-deleted opps when in "All Stages" mode so counts are accurate
        var opps = showActiveOnly
            ? store.openOpportunities
            : store.crmOpportunities.filter { !$0.isDeleted }
        if filterMine, let uid = store.currentUser?.id {
            opps = opps.filter { $0.assignedToID == uid }
        }
        return opps
    }

    // Value label changes based on mode: pipeline value (active only) or total closed value
    private var displayValue: Decimal {
        if showActiveOnly {
            return filteredOpps.reduce(0) { $0 + $1.value }
        } else {
            // Show won revenue when viewing all stages
            return filteredOpps.filter { $0.stage == .won }.reduce(0) { $0 + $1.value }
        }
    }

    private var valueLabel: String { showActiveOnly ? "Pipeline" : "Won Revenue" }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(valueLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(currency(displayValue))
                        .font(.headline.weight(.semibold))
                        .foregroundColor(.primary)
                }

                Divider().frame(height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(showActiveOnly ? "Open" : "Total")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(filteredOpps.count)")
                        .font(.headline.weight(.semibold))
                        .foregroundColor(.primary)
                }

                Spacer()

                Picker("", selection: $filterMine) {
                    Text("All").tag(false)
                    Text("Mine").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
            }

            HStack(spacing: 8) {
                ForEach([(true, "Active"), (false, "All Stages")], id: \.1) { flag, label in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showActiveOnly = flag }
                    } label: {
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(showActiveOnly == flag ? Color.blue : Color(.tertiarySystemFill))
                            .foregroundColor(showActiveOnly == flag ? .white : .secondary)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Color(.secondarySystemGroupedBackground))
        .overlay(
            Rectangle().frame(height: 0.5).foregroundColor(Color(.separator)),
            alignment: .bottom
        )
    }
}

// MARK: - Pipeline Column View

private struct PipelineColumnView: View {
    @EnvironmentObject var store: AppStore

    let stage: OpportunityStage
    let showActiveOnly: Bool     // drives which dictionary we pull from
    let filterMine: Bool
    @Binding var selectedOpportunity: CRMOpportunity?

    @State private var isTargeted: Bool = false

    private var opps: [CRMOpportunity] {
        // When "All Stages" is selected, use the dictionary that includes Won/Lost.
        // When "Active" is selected, use the active-only dictionary.
        let dict = showActiveOnly ? store.opportunitiesByStage : store.allOpportunitiesByStage
        var all = dict[stage] ?? []
        if filterMine, let uid = store.currentUser?.id {
            all = all.filter { $0.assignedToID == uid }
        }
        return all
    }

    private var totalValue: Decimal { opps.reduce(0) { $0 + $1.value } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column header
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(stage.color).frame(width: 10, height: 10)
                    Text(stage.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    Text("\(opps.count)")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(stage.color.opacity(0.15))
                        .foregroundColor(stage.color)
                        .cornerRadius(8)
                }
                if !opps.isEmpty {
                    Text(currency(totalValue))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12, corners: [.topLeft, .topRight])

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(opps) { opp in
                        PipelineCardView(opp: opp, onSelect: { selectedOpportunity = opp })
                            .draggable(opp.id.uuidString)
                            .environmentObject(store)
                    }
                    if opps.isEmpty {
                        Text("No opportunities")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 520)
        }
        .frame(width: 272)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? stage.color.opacity(0.08) : Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isTargeted ? stage.color : Color(.separator), lineWidth: isTargeted ? 2 : 0.5)
        )
        .dropDestination(for: String.self) { droppedItems, _ in
            guard store.currentUserRole.canEditCRM else { return false }
            // Terminal stages must be set via Mark Won / Mark Lost, not drag-and-drop
            guard stage != .won && stage != .lost else { return false }
            guard let idString = droppedItems.first,
                  let id = UUID(uuidString: idString),
                  var opp = store.crmOpportunities.first(where: { $0.id == id }),
                  opp.stage != stage else { return false }
            // Prevent moving already-closed deals via drag
            guard opp.stage != .won && opp.stage != .lost else { return false }
            opp.stage = stage
            opp.probability = stage.defaultProbability
            opp.updatedAt = Date()
            store.upsertCRMOpportunity(opp)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}

// MARK: - Pipeline Card View

private struct PipelineCardView: View {
    @EnvironmentObject var store: AppStore
    let opp: CRMOpportunity
    let onSelect: () -> Void
    /// Long-press → context menu → Delete → confirmation. Hidden
    /// for roles that lack canDeleteCRM.
    @State private var showDeleteConfirm: Bool = false

    private var clientName: String {
        store.clients.first(where: { $0.id == opp.clientID })?.name ?? "Unknown Client"
    }
    private var openTaskCount: Int {
        store.crmTasks.filter { $0.opportunityID == opp.id && $0.status != .done }.count
    }
    private var overdueTaskCount: Int {
        store.crmTasks.filter { $0.opportunityID == opp.id && $0.isOverdue }.count
    }
    private var nextStage: OpportunityStage? {
        let active = OpportunityStage.activeStages
        guard let idx = active.firstIndex(of: opp.stage), idx + 1 < active.count else { return nil }
        return active[idx + 1]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // Title + task badge
            HStack(alignment: .top, spacing: 6) {
                Text(opp.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if overdueTaskCount > 0 {
                    TaskBadge(count: overdueTaskCount, color: .red)
                } else if openTaskCount > 0 {
                    TaskBadge(count: openTaskCount, color: .blue)
                }
            }

            // Client
            HStack(spacing: 4) {
                Image(systemName: "building.2.fill")
                    .font(.caption2).foregroundColor(.secondary)
                Text(clientName)
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }

            // Service type pill
            if !opp.serviceType.isEmpty {
                Text(opp.serviceType)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(opp.stage.color.opacity(0.1))
                    .foregroundColor(opp.stage.color)
                    .cornerRadius(6)
            }

            Divider()

            // Value + advance button
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(currency(opp.value))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.primary)
                    Text("\(opp.probability)% chance")
                        .font(.caption2)
                        .foregroundColor(opp.stage.color)
                }
                Spacer()
                if store.currentUserRole.canEditCRM, let next = nextStage {
                    Button {
                        var updated = opp
                        updated.stage = next
                        updated.probability = next.defaultProbability
                        updated.updatedAt = Date()
                        store.upsertCRMOpportunity(updated)
                    } label: {
                        HStack(spacing: 3) {
                            Text(next.rawValue).font(.caption2.weight(.semibold)).lineLimit(1)
                            Image(systemName: "arrow.right").font(.caption2.weight(.bold))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(next.color.opacity(0.12))
                        .foregroundColor(next.color)
                        .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Assignee + age
            HStack(spacing: 8) {
                if !opp.assignedToName.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "person.fill").font(.caption2).foregroundColor(.secondary)
                        Text(opp.assignedToName).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: "clock").font(.caption2).foregroundColor(.secondary)
                    Text(relativeDate(opp.createdAt)).font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(.systemBackground))
        .cornerRadius(10)
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        .onTapGesture { onSelect() }
        .contextMenu {
            Button { onSelect() } label: {
                Label("View Details", systemImage: "eye")
            }
            if store.currentUserRole.canEditCRM, let next = nextStage {
                Button {
                    var updated = opp
                    updated.stage = next
                    updated.probability = next.defaultProbability
                    updated.updatedAt = Date()
                    store.upsertCRMOpportunity(updated)
                } label: {
                    Label("Move to \(next.rawValue)", systemImage: "arrow.right.circle")
                }
            }
            if store.currentUserRole.canMarkWonLost && opp.stage.isActive {
                Divider()
                // FIX: context menu Mark Won now uses markOpportunityWon() so a project
                // is created, the handoff checklist is generated, and quoteWon is logged.
                // Previously called upsertCRMOpportunity() directly — bypassed all of that.
                Button {
                    let clientName = store.clients.first(where: { $0.id == opp.clientID })?.name ?? opp.title
                    var proj = Project(name: opp.title, clientName: clientName)
                    proj.clientID = opp.clientID
                    proj.status   = .awarded
                    proj.siteAddress = opp.siteAddress.isEmpty ? nil : opp.siteAddress
                    proj.startDate   = Date()
                    if let qid = opp.quoteID,
                       let q = store.quotes.first(where: { $0.id == qid }) {
                        proj.jobNumber     = q.jobNumber
                        proj.contractValue = q.totalBeforeTax
                    } else if let eid = opp.estimateID,
                              let e = store.estimates.first(where: { $0.id == eid }) {
                        proj.jobNumber     = e.jobNumber
                        proj.contractValue = opp.value > 0 ? opp.value : e.totalEstimated
                        proj.estimatedBudget = e.totalEstimated
                    } else {
                        proj.jobNumber     = AppSettings.shared.nextJobNumber()
                        proj.contractValue = opp.value > 0 ? opp.value : nil
                    }
                    store.upsertProject(proj)
                    store.markOpportunityWon(opp, projectID: proj.id)
                } label: {
                    Label("Mark Won", systemImage: "checkmark.seal.fill")
                }
                Button(role: .destructive) {
                    store.markOpportunityLost(opp, reason: "Unknown", competitor: "", notes: "")
                } label: {
                    Label("Mark Lost", systemImage: "xmark.circle")
                }
            }
            // Delete — separate from Mark Won/Lost. Soft-delete hides
            // the opportunity from the CRM but preserves linked
            // estimates/quotes/projects. Manager/executive only.
            // The store-level role gate is the authoritative check;
            // this UI gate just hides the item for ineligible roles.
            if store.currentUserRole.canDeleteCRM {
                Divider()
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete Opportunity", systemImage: "trash")
                }
            }
        }
        .confirmationDialog(
            "Delete \(opp.title)?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                store.deleteCRMOpportunity(opp)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This opportunity will be hidden from the CRM. Linked records (estimates, quotes, projects) are preserved.")
        }
    }
}

private struct TaskBadge: View {
    let count: Int
    let color: Color
    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.bold))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color)
            .clipShape(Capsule())
    }
}

// MARK: - RoundedRectangle Corner Helper

private extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

private struct RoundedCorner: Shape {
    var radius: CGFloat = 0
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - CRMOpportunityDetailView

struct CRMOpportunityDetailView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let opportunity: CRMOpportunity
    @State private var opp: CRMOpportunity
    @State private var showWonSheet: Bool = false
    @State private var showLostSheet: Bool = false
    @State private var showAddTask: Bool = false
    /// Soft-delete confirmation. Gated by `canDeleteCRM` —
    /// menu item is hidden for roles that can't delete.
    @State private var showDeleteConfirm: Bool = false

    init(opportunity: CRMOpportunity) {
        self.opportunity = opportunity
        _opp = State(initialValue: opportunity)
    }

    private var clientName: String {
        store.clients.first(where: { $0.id == opp.clientID })?.name ?? "Unknown Client"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                // 1. Stage stepper
                StageStepperSection(opp: $opp)
                    .environmentObject(store)

                // 2. Next Best Action
                NextBestActionCard(stage: opp.stage)

                // 3. Details
                OpportunityDetailsSection(opp: $opp)
                    .environmentObject(store)

                // 4. Links (Estimate / Quote)
                OpportunityLinksSection(opp: $opp)
                    .environmentObject(store)

                // 4b. Material Sales linked to this opportunity
                OpportunityMaterialSalesSection(opportunityID: opp.id, clientID: opp.clientID)
                    .environmentObject(store)

                // 5. Contacts
                ContactsSection(clientID: opp.clientID, opportunityID: opp.id)
                    .environmentObject(store)

                // 6. Tasks
                TasksSection(opp: opp, showAddTask: $showAddTask)
                    .environmentObject(store)

                // 7. Activity
                ActivitySection(opportunityID: opp.id)
                    .environmentObject(store)

                // 8. Won / Lost actions (manager/executive/PM/admin only)
                // FIX: was restricted to quoteSent/followUp only — any active stage
                // should allow closing the deal; the WonSheet itself enforces workflow.
                if opp.stage.isActive && store.currentUserRole.canMarkWonLost {
                    WonLostActionSection(
                        showWonSheet: $showWonSheet,
                        showLostSheet: $showLostSheet
                    )
                }

                // 9. Handoff checklist (only when won)
                if opp.stage == .won {
                    HandoffChecklistSection(opportunityID: opp.id)
                        .environmentObject(store)
                }

                // 10. AI Pre-Call Brief
                CRMCallBriefCard(opportunity: opp)
                    .environmentObject(store)
                    .padding(.horizontal, 16)

                // 11. AI Win Insight
                CRMWinInsightCard(opportunity: opp)
                    .environmentObject(store)
                    .padding(.horizontal, 16)

                // 12. Attachments
                CRMAttachmentSection(entityID: opp.id, entityType: .opportunity)
                    .environmentObject(store)
                    .padding(.vertical, 16)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(12)
                    .padding(.horizontal, 16)

                Spacer(minLength: 40)
            }
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(opp.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Trailing menu — Delete (manager/executive only). Kept
            // separate from the Save button so the destructive action
            // sits behind a deliberate menu tap rather than being one
            // tap away on the navigation bar.
            if store.currentUserRole.canDeleteCRM {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete Opportunity", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            if store.currentUserRole.canEditCRM {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = opp
                        updated.updatedAt = Date()
                        store.upsertCRMOpportunity(updated)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .confirmationDialog(
            "Delete this opportunity?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                // Soft delete — the row stays on the server with
                // is_deleted = true so reporting can still attribute
                // historical activity. The store's role gate is the
                // authoritative check; the toolbar gate just hides
                // the UI.
                store.deleteCRMOpportunity(opp)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This opportunity will be hidden from the CRM. Linked records (estimates, quotes, projects) are preserved. Only managers and executives can restore it server-side.")
        }
        .sheet(isPresented: $showWonSheet) {
            WonSheet(opp: opp, clientName: clientName)
                .environmentObject(store)
        }
        // After WonSheet closes, sync local opp from store so the toolbar Save
        // button doesn't overwrite the newly-won state with a stale copy.
        .onChange(of: showWonSheet) { _, isShowing in
            if !isShowing { refreshFromStore() }
        }
        .sheet(isPresented: $showLostSheet) {
            LostSheet(opp: opp)
                .environmentObject(store)
        }
        .onChange(of: showLostSheet) { _, isShowing in
            if !isShowing { refreshFromStore() }
        }
        .sheet(isPresented: $showAddTask) {
            CRMTaskCreateSheet(clientID: opp.clientID, opportunityID: opp.id)
                .environmentObject(store)
        }
    }

    // MARK: - Helpers

    /// Pulls the latest version of this opportunity from the store and applies it
    /// to local state. Called after any sheet that may have modified the opp in
    /// the store (WonSheet, LostSheet, QuickQuote, etc.) so that the toolbar Save
    /// button never writes a stale copy back and causes a stage reversal.
    private func refreshFromStore() {
        if let fresh = store.crmOpportunities.first(where: { $0.id == opportunity.id }) {
            opp = fresh
        }
    }
}

// MARK: - Stage Stepper Section

private struct StageStepperSection: View {
    @EnvironmentObject var store: AppStore
    @Binding var opp: CRMOpportunity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stage")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Show terminal state badge when deal is closed
                    if opp.stage == .won || opp.stage == .lost {
                        HStack(spacing: 6) {
                            Image(systemName: opp.stage == .won ? "checkmark.seal.fill" : "xmark.circle.fill")
                                .font(.caption2.weight(.semibold))
                            Text(opp.stage.rawValue)
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(opp.stage.color)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                    } else {
                        ForEach(OpportunityStage.activeStages) { stage in
                            Button {
                                guard store.currentUserRole.canEditCRM else { return }
                                // Never allow a stage button to set a terminal stage —
                                // only Mark Won / Mark Lost flows are allowed to do that
                                guard stage != .won && stage != .lost else { return }
                                opp.stage = stage
                                opp.probability = stage.defaultProbability
                                opp.updatedAt = Date()
                                store.upsertCRMOpportunity(opp)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: stage.icon)
                                        .font(.caption2.weight(.semibold))
                                    Text(stage.rawValue)
                                        .font(.caption.weight(.semibold))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    opp.stage == stage
                                    ? stage.color
                                    : stage.color.opacity(0.12)
                                )
                                .foregroundColor(
                                    opp.stage == stage
                                    ? .white
                                    : stage.color
                                )
                                .cornerRadius(20)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal, 16)
    }
}

// MARK: - Next Best Action Card

private struct NextBestActionCard: View {
    let stage: OpportunityStage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .font(.title3)
                .foregroundColor(.indigo)
            VStack(alignment: .leading, spacing: 4) {
                Text("Next Best Action")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.indigo)
                Text(stage.nextAction)
                    .font(.subheadline)
                    .foregroundColor(.primary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.indigo.opacity(0.10))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.indigo.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - Opportunity Details Section

private struct OpportunityDetailsSection: View {
    @EnvironmentObject var store: AppStore
    @Binding var opp: CRMOpportunity

    @State private var valueText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CRMOppSectionHeader(title: "Details")

            VStack(spacing: 0) {
                FormRow {
                    TextField("Title", text: $opp.title)
                        .font(.subheadline)
                }

                Divider().padding(.leading, 16)

                FormRow {
                    TextField("Service Type", text: $opp.serviceType)
                        .font(.subheadline)
                }

                Divider().padding(.leading, 16)

                FormRow {
                    HStack {
                        Text("Value")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        if store.currentUserRole.canEditOpportunityFinancials {
                            TextField("$0.00", text: $valueText)
                                .font(.subheadline)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: valueText) { _, newValue in
                                    if let d = Decimal(string: newValue) { opp.value = d }
                                }
                                .onAppear { if opp.value != 0 { valueText = "\(opp.value)" } }
                        } else {
                            Text(opp.value == 0 ? "—" : "$\(opp.value)")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                        }
                    }
                }

                Divider().padding(.leading, 16)

                FormRow {
                    HStack {
                        Text("Probability")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        if store.currentUserRole.canEditOpportunityFinancials {
                            Stepper("\(opp.probability)%", value: $opp.probability, in: 0...100, step: 5)
                                .font(.subheadline)
                                .fixedSize()
                        } else {
                            Text("\(opp.probability)%")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                        }
                    }
                }

                Divider().padding(.leading, 16)

                FormRow {
                    TextField("Site Address", text: $opp.siteAddress)
                        .font(.subheadline)
                }

                Divider().padding(.leading, 16)

                FormRow {
                    Picker("Source", selection: $opp.source) {
                        ForEach(LeadSource.allCases, id: \.self) { src in
                            Text(src.rawValue).tag(src)
                        }
                    }
                    .font(.subheadline)
                }

                Divider().padding(.leading, 16)

                if let binding = Binding($opp.estimatedStart) {
                    FormRow {
                        DatePicker(
                            "Est. Start",
                            selection: binding,
                            displayedComponents: .date
                        )
                        .font(.subheadline)
                    }
                    Divider().padding(.leading, 16)
                } else {
                    FormRow {
                        HStack {
                            Text("Est. Start")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Set Date") {
                                opp.estimatedStart = Date()
                            }
                            .font(.caption)
                            .foregroundStyle(.tint)
                        }
                    }
                    Divider().padding(.leading, 16)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Description")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    TextEditor(text: $opp.description)
                        .font(.subheadline)
                        .frame(minHeight: 80)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Opportunity Links Section

private struct OpportunityLinksSection: View {
    @EnvironmentObject var store: AppStore
    @Binding var opp: CRMOpportunity

    @State private var showCreateEstimate  = false
    @State private var showCreateQuote     = false
    @State private var showQuickQuote      = false

    private var linkedEstimate: Estimate? {
        guard let eid = opp.estimateID else { return nil }
        return store.estimates.first(where: { $0.id == eid })
    }

    private var linkedQuote: Quote? {
        guard let qid = opp.quoteID else { return nil }
        return store.quotes.first(where: { $0.id == qid })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CRMOppSectionHeader(title: "Links")

            VStack(spacing: 0) {

                // ── Estimate row ──────────────────────────────────────
                if let estimate = linkedEstimate {
                    NavigationLink(destination: EstimateDetailView(estimate: estimate).environmentObject(store)) {
                        FormRow {
                            HStack {
                                Image(systemName: "doc.text.fill")
                                    .foregroundColor(.purple)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Estimate")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(estimate.name)
                                        .font(.subheadline)
                                }
                                Spacer()
                                Text(estimate.status.displayName)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(estimateStatusColor(estimate.status).opacity(0.15))
                                    .foregroundColor(estimateStatusColor(estimate.status))
                                    .cornerRadius(6)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                } else if opp.stage.isActive && store.currentUserRole.canEditCRM {
                    FormRow {
                        Button { showCreateEstimate = true } label: {
                            HStack {
                                Image(systemName: "doc.badge.plus")
                                    .foregroundColor(.purple)
                                Text("Create Estimate")
                                    .font(.subheadline)
                                    .foregroundColor(.purple)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if linkedEstimate != nil || opp.stage.isActive {
                    Divider().padding(.leading, 16)
                }

                // ── Quote row ─────────────────────────────────────────
                if let quote = linkedQuote {
                    NavigationLink(destination: QuoteDetailView(quote: quote).environmentObject(store)) {
                        FormRow {
                            HStack {
                                Image(systemName: "paperplane.fill")
                                    .foregroundColor(.indigo)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Quote")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(quote.jobNumber)
                                        .font(.subheadline)
                                }
                                Spacer()
                                QuoteStatusBadge(status: quote.status)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                } else if linkedEstimate != nil && opp.stage.isActive && store.currentUserRole.canEditCRM {
                    FormRow {
                        Button { showCreateQuote = true } label: {
                            HStack {
                                Image(systemName: "paperplane.fill")
                                    .foregroundColor(.indigo)
                                Text("Create Quote")
                                    .font(.subheadline)
                                    .foregroundColor(.indigo)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } else if linkedEstimate == nil && opp.stage.isActive && store.currentUserRole.canEditCRM {
                    Divider().padding(.leading, 16)
                    FormRow {
                        Button { showQuickQuote = true } label: {
                            HStack {
                                Image(systemName: "paperplane.fill")
                                    .foregroundColor(.indigo)
                                Text("Quick Quote")
                                    .font(.subheadline)
                                    .foregroundColor(.indigo)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .padding(.horizontal, 16)
        }
        .sheet(isPresented: $showCreateEstimate) {
            let oppContext = CommercialContext.from(
                opportunity: opp,
                clientName:  store.client(id: opp.clientID)?.name ?? "",
                workType:    .projectWork
            )
            EstimateCreateView(
                preselectedClientID: opp.clientID,
                context: oppContext,
                onCreated: { estimate in
                    opp.estimateID = estimate.id
                    if opp.stage == .newLead || opp.stage == .contacted || opp.stage == .siteVisit {
                        opp.stage = .estimateRequired
                        opp.probability = OpportunityStage.estimateRequired.defaultProbability
                    }
                    opp.updatedAt = Date()
                    store.upsertCRMOpportunity(opp)
                    store.logCRMActivity(
                        type: .estimateCreated,
                        title: "Estimate created: \(estimate.name)",
                        notes: estimate.scopeDescription ?? "",
                        clientID: opp.clientID,
                        contactID: opp.contactID,
                        opportunityID: opp.id,
                        quoteID: nil,
                        projectID: nil
                    )
                }
            )
            .environmentObject(store)
        }
        // After estimate creation, refresh opp so the linked estimate row appears immediately
        .onChange(of: showCreateEstimate) { _, isShowing in
            if !isShowing, let fresh = store.crmOpportunities.first(where: { $0.id == opp.id }) {
                opp = fresh
            }
        }
        // Create Quote from existing estimate
        .sheet(isPresented: $showCreateQuote) {
            if let estimate = linkedEstimate {
                NavigationStack {
                    QuoteCreateView(fromEstimate: estimate)
                        .environmentObject(store)
                }
            }
        }
        // After quote creation from estimate, refresh opp so the linked quote row appears immediately
        .onChange(of: showCreateQuote) { _, isShowing in
            if !isShowing, let fresh = store.crmOpportunities.first(where: { $0.id == opp.id }) {
                opp = fresh
            }
        }
        // Quick Quote — no estimate required
        .sheet(isPresented: $showQuickQuote) {
            QuoteFromOpportunityView(opportunity: opp) { quote in
                // onCreated runs before dismiss — pre-warm local state so the link
                // shows immediately. The onChange below will also refresh from store.
                opp.quoteID    = quote.id
                opp.estimateID = quote.estimateID
                if opp.stage != .won && opp.stage != .lost {
                    opp.stage       = .quoteSent
                    opp.probability = OpportunityStage.quoteSent.defaultProbability
                }
                opp.updatedAt = Date()
            }
            .environmentObject(store)
        }
        // After quick-quote creation, sync from store (store was already updated inside save())
        .onChange(of: showQuickQuote) { _, isShowing in
            if !isShowing, let fresh = store.crmOpportunities.first(where: { $0.id == opp.id }) {
                opp = fresh
            }
        }
    }
}

// MARK: - Contacts Section

private struct ContactsSection: View {
    @EnvironmentObject var store: AppStore
    let clientID: UUID
    var opportunityID: UUID? = nil

    private var contacts: [CRMContact] {
        store.contacts(for: clientID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CRMOppSectionHeader(title: "Contacts")

            VStack(spacing: 0) {
                if contacts.isEmpty {
                    FormRow {
                        Text("No contacts on file")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ForEach(contacts) { contact in
                        ContactRowView(contact: contact, opportunityID: opportunityID)
                        if contact.id != contacts.last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .padding(.horizontal, 16)
        }
    }
}

private struct ContactRowView: View {
    @EnvironmentObject var store: AppStore
    let contact: CRMContact
    var opportunityID: UUID? = nil

    @State private var showLogCall:  Bool = false
    @State private var showLogEmail: Bool = false
    /// Long-press → context menu → Delete → this confirmation dialog.
    /// Two-step gate keeps the destructive action behind a deliberate
    /// affordance + confirmation, since contacts can be loud-typo'd
    /// from the row view.
    @State private var showDeleteConfirm: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 36, height: 36)
                Text(contact.initials)
                    .font(.caption.weight(.bold))
                    .foregroundColor(.blue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.fullName)
                    .font(.subheadline.weight(.medium))
                if !contact.title.isEmpty {
                    Text(contact.title).font(.caption).foregroundColor(.secondary)
                }
                if !contact.phone.isEmpty {
                    Text(contact.phone).font(.caption).foregroundColor(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 14) {
                if !contact.phone.isEmpty {
                    Button { showLogCall = true } label: {
                        Image(systemName: "phone.fill")
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
                }
                if !contact.email.isEmpty {
                    Button { showLogEmail = true } label: {
                        Image(systemName: "envelope.fill")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        // Long-press menu — Delete (manager/executive only). Hidden
        // for roles that can't delete so they don't see a control
        // they can't use.
        .contextMenu {
            if !contact.phone.isEmpty {
                Button { showLogCall = true } label: {
                    Label("Log Call", systemImage: "phone")
                }
            }
            if !contact.email.isEmpty {
                Button { showLogEmail = true } label: {
                    Label("Log Email", systemImage: "envelope")
                }
            }
            if store.currentUserRole.canDeleteCRM {
                Divider()
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete Contact", systemImage: "trash")
                }
            }
        }
        .sheet(isPresented: $showLogCall) {
            CRMLogActivitySheet(contact: contact, activityType: .callMade, opportunityID: opportunityID)
                .environmentObject(store)
        }
        .sheet(isPresented: $showLogEmail) {
            CRMLogActivitySheet(contact: contact, activityType: .emailSent, opportunityID: opportunityID)
                .environmentObject(store)
        }
        .confirmationDialog(
            "Delete \(contact.fullName)?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                // Soft delete — store.deleteCRMContact has its own
                // role gate; toolbar gate just hides the UI.
                store.deleteCRMContact(contact)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This contact will be hidden from the CRM. Activity history is preserved.")
        }
    }
}

// MARK: - Tasks Section

private struct TasksSection: View {
    @EnvironmentObject var store: AppStore
    let opp: CRMOpportunity
    @Binding var showAddTask: Bool

    private var tasks: [CRMTask] {
        store.crmTasks(forOpportunity: opp.id).filter { $0.status != .done }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                CRMOppSectionHeader(title: "Tasks")
                Spacer()
                if store.currentUserRole.canEditCRM {
                    Button {
                        showAddTask = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tint)
                    }
                    .padding(.trailing, 16)
                    .padding(.top, 8)
                }
            }

            VStack(spacing: 0) {
                if tasks.isEmpty {
                    FormRow {
                        Text("No open tasks")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ForEach(tasks) { task in
                        TaskRowView(task: task)
                        if task.id != tasks.last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .padding(.horizontal, 16)
        }
    }
}

private struct TaskRowView: View {
    @EnvironmentObject var store: AppStore
    let task: CRMTask

    var body: some View {
        HStack(spacing: 12) {
            Button {
                guard store.currentUserRole.canEditCRM else { return }
                var updated = task
                updated.status = .done
                updated.completedAt = Date()
                store.upsertCRMTask(updated)
            } label: {
                Image(systemName: task.status == .done
                      ? "checkmark.circle.fill"
                      : "circle")
                    .foregroundColor(task.isOverdue ? .red : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if let due = task.dueDate {
                    Text(relativeDate(due))
                        .font(.caption)
                        .foregroundColor(task.isOverdue ? .red : .secondary)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: task.priority.icon)
                    .font(.caption2)
                    .foregroundColor(task.priority.color)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Activity Section

private struct ActivitySection: View {
    @EnvironmentObject var store: AppStore
    let opportunityID: UUID

    private var activities: [CRMActivity] {
        Array(store.crmActivities(forOpportunity: opportunityID).prefix(10))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CRMOppSectionHeader(title: "Activity")

            VStack(spacing: 0) {
                if activities.isEmpty {
                    FormRow {
                        Text("No activity yet")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ForEach(activities) { activity in
                        ActivityRowView(activity: activity)
                        if activity.id != activities.last?.id {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .padding(.horizontal, 16)
        }
    }
}

private struct ActivityRowView: View {
    let activity: CRMActivity

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(activity.type.color.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: activity.type.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(activity.type.color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                Text(relativeDate(activity.date))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Won / Lost Action Section

private struct WonLostActionSection: View {
    @Binding var showWonSheet: Bool
    @Binding var showLostSheet: Bool

    var body: some View {
        VStack(spacing: 12) {
            Button {
                showWonSheet = true
            } label: {
                Label("Mark Won", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .buttonStyle(.plain)

            Button {
                showLostSheet = true
            } label: {
                Label("Mark Lost", systemImage: "xmark.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Handoff Checklist Section

private struct HandoffChecklistSection: View {
    @EnvironmentObject var store: AppStore
    let opportunityID: UUID

    private var items: [HandoffChecklistItem] {
        store.handoffChecklist(for: opportunityID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CRMOppSectionHeader(title: "Handoff Checklist")

            VStack(spacing: 0) {
                if items.isEmpty {
                    FormRow {
                        Text("No checklist items")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ForEach(items) { item in
                        ChecklistItemRow(item: item)
                            .environmentObject(store)
                        if item.id != items.last?.id {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .padding(.horizontal, 16)
        }
    }
}

private struct ChecklistItemRow: View {
    @EnvironmentObject var store: AppStore
    let item: HandoffChecklistItem

    var body: some View {
        Button {
            var updated = item
            updated.isDone.toggle()
            store.updateHandoffItem(updated)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.isDone
                      ? "checkmark.circle.fill"
                      : "circle")
                    .font(.title3)
                    .foregroundColor(item.isDone ? .green : .secondary)

                Text(item.title)
                    .font(.subheadline)
                    .foregroundColor(item.isDone ? .secondary : .primary)
                    .strikethrough(item.isDone)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - WonSheet

private struct WonSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let opp: CRMOpportunity
    let clientName: String

    @State private var projectName: String
    @State private var approvalDate: Date = Date()

    init(opp: CRMOpportunity, clientName: String) {
        self.opp = opp
        self.clientName = clientName
        _projectName = State(initialValue: opp.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                // FIX: warn user if no quote exists — award without quote is allowed
                // but flagged so they know financial data may be missing.
                if opp.quoteID == nil {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("No Quote on File")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.orange)
                                Text("This opportunity has no linked quote. Consider creating a quote first so contract value and scope are recorded.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Section("Project Details") {
                    TextField("Project Name", text: $projectName)
                        .textInputAutocapitalization(.words)

                    DatePicker(
                        "Client Approval Date",
                        selection: $approvalDate,
                        displayedComponents: .date
                    )
                }

                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text("This will create a project and generate a handoff checklist.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    Button {
                        confirmWon()
                    } label: {
                        Label("Confirm Won", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .foregroundColor(.white)
                    }
                    .listRowBackground(Color.green)
                    .disabled(projectName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Mark Opportunity Won")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func confirmWon() {
        let trimmedName = projectName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        var proj = Project(name: trimmedName, clientName: clientName)
        proj.clientID    = opp.clientID   // link project → CRM client record
        proj.status      = .awarded
        proj.siteAddress = opp.siteAddress.isEmpty ? nil : opp.siteAddress
        proj.startDate   = approvalDate

        // Pull job number and financial values from linked quote/estimate
        if let qid = opp.quoteID, let quote = store.quotes.first(where: { $0.id == qid }) {
            proj.jobNumber = quote.jobNumber
            proj.contractValue = quote.totalBeforeTax
        } else if let eid = opp.estimateID, let est = store.estimates.first(where: { $0.id == eid }) {
            proj.jobNumber = est.jobNumber
            proj.contractValue = opp.value > 0 ? opp.value : est.totalEstimated
            proj.estimatedBudget = est.totalEstimated
        } else {
            proj.jobNumber = AppSettings.shared.nextJobNumber()
            proj.contractValue = opp.value > 0 ? opp.value : nil
        }

        store.upsertProject(proj)
        store.markOpportunityWon(opp, projectID: proj.id)
        dismiss()
    }
}

// MARK: - LostSheet

private struct LostSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let opp: CRMOpportunity

    private let lossReasonOptions = [
        "Price too high",
        "Competitor selected",
        "Project cancelled",
        "No response",
        "Timing",
        "Other"
    ]

    @State private var lossReason: String = "Price too high"
    @State private var competitorName: String = ""
    @State private var notes: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Loss Details") {
                    Picker("Reason", selection: $lossReason) {
                        ForEach(lossReasonOptions, id: \.self) { reason in
                            Text(reason).tag(reason)
                        }
                    }

                    TextField("Competitor Name (optional)", text: $competitorName)
                        .textInputAutocapitalization(.words)
                }

                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                }

                Section {
                    Button {
                        confirmLost()
                    } label: {
                        Label("Confirm Lost", systemImage: "xmark.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .foregroundColor(.white)
                    }
                    .listRowBackground(Color.red)
                }
            }
            .navigationTitle("Mark Opportunity Lost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func confirmLost() {
        store.markOpportunityLost(
            opp,
            reason: lossReason,
            competitor: competitorName.trimmingCharacters(in: .whitespaces),
            notes: notes.trimmingCharacters(in: .whitespaces)
        )
        dismiss()
    }
}

// MARK: - CRMOpportunityCreateSheet

struct CRMOpportunityCreateSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let clientID: UUID

    @State private var title: String = ""
    @State private var serviceType: String = ""
    @State private var valueText: String = ""
    @State private var siteAddress: String = ""
    @State private var stage: OpportunityStage = .newLead
    @State private var source: LeadSource = .directInquiry
    @State private var notes: String = ""
    @State private var showValidationError: Bool = false

    private var client: Client? {
        store.clients.first(where: { $0.id == clientID })
    }

    private var parsedValue: Decimal {
        Decimal(string: valueText) ?? 0
    }

    var body: some View {
        NavigationStack {
            Form {
                // Client (read-only)
                Section {
                    if let client = client {
                        HStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(Color.blue.opacity(0.15))
                                    .frame(width: 36, height: 36)
                                Text(client.initials)
                                    .font(.caption.weight(.bold))
                                    .foregroundColor(.blue)
                            }
                            Text(client.name)
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                } header: {
                    Text("Client")
                }

                // Opportunity details
                Section("Opportunity Details") {
                    TextField("Title *", text: $title)
                        .textInputAutocapitalization(.sentences)

                    TextField("Service Type", text: $serviceType)
                        .textInputAutocapitalization(.words)

                    TextField("Value ($)", text: $valueText)
                        .keyboardType(.decimalPad)

                    TextField("Site Address", text: $siteAddress)
                        .textInputAutocapitalization(.words)
                        .onAppear {
                            if siteAddress.isEmpty,
                               let addr = client?.billingAddress {
                                siteAddress = addr
                            }
                        }
                }

                // Stage & Source
                Section("Classification") {
                    Picker("Stage", selection: $stage) {
                        ForEach(OpportunityStage.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }

                    Picker("Source", selection: $source) {
                        ForEach(LeadSource.allCases, id: \.self) { src in
                            Text(src.rawValue).tag(src)
                        }
                    }
                }

                // Notes
                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 70)
                }

                // Validation error
                if showValidationError {
                    Section {
                        Text("Title is required.")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("New Opportunity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else {
            showValidationError = true
            return
        }

        var opp = CRMOpportunity(clientID: clientID)
        opp.title = trimmedTitle
        opp.serviceType = serviceType.trimmingCharacters(in: .whitespaces)
        opp.value = parsedValue
        opp.siteAddress = siteAddress.trimmingCharacters(in: .whitespaces)
        opp.stage = stage
        opp.probability = stage.defaultProbability
        opp.source = source
        opp.notes = notes.trimmingCharacters(in: .whitespaces)

        store.upsertCRMOpportunity(opp)

        let activityType: CRMActivityType = (stage == .newLead) ? .leadCreated : .stageChanged
        let activityTitle = (stage == .newLead)
            ? "New lead created: \(trimmedTitle)"
            : "Opportunity created at stage \(stage.rawValue): \(trimmedTitle)"

        store.logCRMActivity(
            type: activityType,
            title: activityTitle,
            notes: opp.notes,
            clientID: clientID,
            contactID: nil,
            opportunityID: opp.id,
            quoteID: nil,
            projectID: nil
        )

        dismiss()
    }
}

// MARK: - Shared Sub-views

private struct CRMOppSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }
}

private struct FormRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }
}

// MARK: - Optional Binding Helper

private extension Binding {
    init?(_ base: Binding<Value?>) where Value: Any {
        guard base.wrappedValue != nil else { return nil }
        self.init(
            get: { base.wrappedValue! },
            set: { base.wrappedValue = $0 }
        )
    }
}

// MARK: - Opportunity → Material Sales section
//
// Material sales are auto-linked to the opportunity by CRMCommercialBridge
// when they're created. This section surfaces every active sale linked to
// the current opportunity OR (as a fallback) sales for the same client that
// don't yet have an opportunity link, with a compact tap-to-detail row.
//
// Plus a "New Material Sale" button that pre-fills client + opportunity in
// the create sheet — the canonical CRM-to-cash path.

struct OpportunityMaterialSalesSection: View {
    let opportunityID: UUID
    let clientID: UUID
    @EnvironmentObject var store: AppStore
    @State private var showCreate = false

    private var linked: [MaterialSale] {
        store.materialSales
            .filter { !$0.isDeleted && ($0.opportunityID == opportunityID) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Sales for the same client that aren't linked anywhere yet — a hint
    /// they probably belong to this opportunity. Capped to keep the UI tight.
    private var unlinkedSameClient: [MaterialSale] {
        store.materialSales
            .filter { !$0.isDeleted && $0.opportunityID == nil && $0.clientID == clientID }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AskiSpacing.md) {
            HStack {
                Image(systemName: "shippingbox.fill")
                    .foregroundColor(.orange)
                Text("Material Sales")
                    .font(.headline)
                if !linked.isEmpty {
                    Text("(\(linked.count))").font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
                if store.currentUserRole.canAccessCommercial {
                    Button { showCreate = true } label: {
                        Label("New", systemImage: "plus")
                            .font(.subheadline)
                    }
                    .accessibilityLabel("New material sale linked to this opportunity")
                }
            }

            if linked.isEmpty && unlinkedSameClient.isEmpty {
                Text("No material sales yet for this opportunity.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(linked) { sale in
                    NavigationLink {
                        MaterialSaleDetailView(sale: sale)
                    } label: {
                        OpportunityMaterialSaleRow(sale: sale, isLinked: true)
                    }
                }
                if !unlinkedSameClient.isEmpty {
                    Text("Other sales for this client (not yet linked):")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, AskiSpacing.xs)
                    ForEach(unlinkedSameClient) { sale in
                        NavigationLink {
                            MaterialSaleDetailView(sale: sale)
                        } label: {
                            OpportunityMaterialSaleRow(sale: sale, isLinked: false)
                        }
                    }
                }
            }
        }
        .padding(AskiSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: AskiRadius.card, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .padding(.horizontal, AskiSpacing.lg)
        .sheet(isPresented: $showCreate) {
            // Pre-fill the create sheet with this opportunity's context.
            let prefill = CommercialContext.from(
                opportunity: store.crmOpportunities.first(where: { $0.id == opportunityID }) ?? CRMOpportunity(clientID: clientID),
                clientName: store.client(id: clientID)?.name ?? "",
                workType: .materialSale
            )
            MaterialSaleCreateEditView(context: prefill)
                .environmentObject(store)
        }
    }
}

private struct OpportunityMaterialSaleRow: View {
    let sale: MaterialSale
    let isLinked: Bool

    var body: some View {
        HStack(spacing: AskiSpacing.md) {
            Image(systemName: isLinked ? "link.circle.fill" : "shippingbox")
                .foregroundColor(isLinked ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(sale.saleNumber.isEmpty ? "Material sale" : sale.saleNumber)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                HStack(spacing: AskiSpacing.sm) {
                    Text(sale.status.rawValue.capitalized)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.16)))
                        .foregroundColor(.orange)
                    if let due = sale.requestedDeliveryDate {
                        Label(due.shortDate, systemImage: "calendar")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            Text(sale.grandTotal.currencyString)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, AskiSpacing.xs)
    }
}
