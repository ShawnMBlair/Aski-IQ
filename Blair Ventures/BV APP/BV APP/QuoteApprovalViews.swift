// QuoteApprovalViews.swift
// Aski IQ — Entity-First CRM, Slice 5: Approval Threshold UI
//
// Three view types:
//   • PendingApprovalsListView   — manager/admin queue of pending quotes
//   • ApprovalDecisionSheet      — approve/reject + notes for a single approval
//   • QuoteApprovalPill          — small status indicator embedded in QuoteDetailView
//
// Behaviour gates align with ApprovalThreshold.canApprove(tier:role:):
//   • Manager-tier (10K–50K): manager OR executive can decide
//   • Admin-tier (>50K):       executive only

import SwiftUI

// MARK: - Pending list (for approvers)

struct PendingApprovalsListView: View {
    @EnvironmentObject var store: AppStore
    @State private var sheetTarget: QuoteApproval? = nil
    @State private var isLoading = false

    /// Filter the pending queue to approvals THIS user is allowed to
    /// decide. A manager won't see admin-tier approvals — those need
    /// executive sign-off.
    private var visiblePending: [QuoteApproval] {
        store.pendingApprovals.filter { approval in
            ApprovalThreshold.canApprove(tier: approval.thresholdTier,
                                          role: store.currentUserRole)
        }
    }

    /// Other pending approvals that this user can SEE but not DECIDE
    /// (e.g. a manager looking at admin-tier approvals). Surface them
    /// for awareness but disabled.
    private var visibleReadOnly: [QuoteApproval] {
        store.pendingApprovals.filter { approval in
            !ApprovalThreshold.canApprove(tier: approval.thresholdTier,
                                           role: store.currentUserRole)
        }
    }

    var body: some View {
        List {
            if visiblePending.isEmpty && visibleReadOnly.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.largeTitle)
                            .foregroundColor(.green)
                        Text("No pending approvals.")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
            }

            if !visiblePending.isEmpty {
                Section {
                    ForEach(visiblePending) { approval in
                        Button { sheetTarget = approval } label: {
                            ApprovalRow(approval: approval, canDecide: true)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("AWAITING YOUR DECISION").font(.caption.bold())
                } footer: {
                    Text("Tap a row to approve or reject. Manager-tier approvals can be decided by either manager or executive; admin-tier requires executive.")
                        .font(.caption)
                }
            }

            if !visibleReadOnly.isEmpty {
                Section {
                    ForEach(visibleReadOnly) { approval in
                        ApprovalRow(approval: approval, canDecide: false)
                    }
                } header: {
                    Text("REQUIRES HIGHER APPROVAL").font(.caption.bold())
                } footer: {
                    Text("Admin-tier approvals (above $\(Int(NSDecimalNumber(decimal: ApprovalThreshold.managerCeilingUSD).doubleValue))) need executive sign-off.")
                        .font(.caption)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Pending Approvals")
        .navigationBarTitleDisplayMode(.large)
        .task {
            isLoading = true
            await SyncEngine.shared.pullQuoteApprovals()
            isLoading = false
        }
        .refreshable {
            await SyncEngine.shared.pullQuoteApprovals()
        }
        .sheet(item: $sheetTarget) { approval in
            ApprovalDecisionSheet(approval: approval)
                .environmentObject(store)
        }
    }
}

private struct ApprovalRow: View {
    let approval: QuoteApproval
    let canDecide: Bool
    @EnvironmentObject var store: AppStore

    private var quote: Quote? {
        store.quotes.first { $0.id == approval.quoteID }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: approval.thresholdTier == .admin
                  ? "crown.fill" : "person.crop.circle.badge.checkmark")
                .foregroundColor(approval.thresholdTier == .admin ? .purple : .blue)
                .font(.title2)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(quote?.jobNumber ?? "Unknown quote")
                        .font(.subheadline).bold()
                        .fontDesign(.monospaced)
                        .foregroundColor(.purple)
                    Spacer()
                    Text(approval.quoteTotalString)
                        .font(.subheadline.bold())
                        .foregroundColor(.green)
                }
                Text(quote?.clientName ?? "—")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(approval.thresholdTier.displayName)
                        .font(.caption2.bold())
                        .foregroundColor(approval.thresholdTier == .admin ? .purple : .blue)
                    Text("·").foregroundColor(.secondary)
                    Text("Requested by \(approval.requestedByName.isEmpty ? "—" : approval.requestedByName)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if !canDecide {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(canDecide ? 1 : 0.6)
    }
}

// MARK: - Decision sheet

struct ApprovalDecisionSheet: View {
    let approval: QuoteApproval
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var notes: String = ""
    @State private var errorMessage: String? = nil

    private var quote: Quote? {
        store.quotes.first { $0.id == approval.quoteID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Quote") {
                    LabeledContent("Job Number", value: quote?.jobNumber ?? "—")
                    LabeledContent("Client",     value: quote?.clientName ?? "—")
                    LabeledContent("Amount",     value: approval.quoteTotalString)
                    LabeledContent("Tier",       value: approval.thresholdTier.displayName)
                }
                Section("Requested by") {
                    LabeledContent("Name", value: approval.requestedByName.isEmpty ? "—" : approval.requestedByName)
                    LabeledContent("When", value: approval.requestedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Section {
                    TextEditor(text: $notes).frame(minHeight: 90)
                } header: {
                    Text("Decision Notes")
                } footer: {
                    Text("Captured in the audit log + visible to the requester. Required for rejections.")
                        .font(.caption)
                }
                if let err = errorMessage {
                    Section {
                        Text(err).foregroundColor(.red).font(.caption)
                    }
                }
            }
            .navigationTitle("Decide Approval")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { decide(approve: false) } label: {
                        Text("Reject")
                            .foregroundColor(.red)
                    }
                    Button { decide(approve: true) } label: {
                        Text("Approve")
                            .bold()
                            .foregroundColor(.green)
                    }
                }
            }
        }
    }

    private func decide(approve: Bool) {
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !approve && trimmedNotes.isEmpty {
            errorMessage = "Rejections require a note explaining the decision."
            return
        }
        let result = CommercialWorkflowService.shared.decideApproval(
            approval, approve: approve, notes: trimmedNotes
        )
        switch result {
        case .success:
            ToastService.shared.success(approve
                ? "Approval granted — requester can now send the quote."
                : "Approval rejected.")
            dismiss()
        case .failure(let err):
            errorMessage = err.userMessage
        }
    }
}

// MARK: - QuoteDetailView pill

/// Small inline indicator that surfaces approval state above the
/// action buttons in QuoteDetailView. No-op when the quote is below
/// the approval threshold.
struct QuoteApprovalPill: View {
    let quote: Quote
    @EnvironmentObject var store: AppStore

    private var tier: ApprovalThreshold.Tier {
        ApprovalThreshold.tier(forTotal: quote.grandTotal)
    }
    private var latest: QuoteApproval? {
        store.latestApproval(for: quote.id)
    }
    private var canRequest: Bool {
        // Caller must own the quote (any tenant member). Threshold
        // gate already lives in ApprovalThreshold.tier — this view
        // doesn't need to re-check role.
        tier != .none
    }

    @ViewBuilder
    var body: some View {
        if tier == .none {
            EmptyView()
        } else if let l = latest {
            existingApprovalRow(l)
        } else {
            requestPromptRow
        }
    }

    @ViewBuilder
    private func existingApprovalRow(_ l: QuoteApproval) -> some View {
        HStack(spacing: 8) {
            Image(systemName: l.status.icon).foregroundColor(l.status.color)
            existingDetails(l)
            Spacer()
            if l.status == .rejected {
                rerequestButton
            }
        }
        .padding(10)
        .background(l.status.color.opacity(0.10))
        .cornerRadius(10)
    }

    @ViewBuilder
    private func existingDetails(_ l: QuoteApproval) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(l.thresholdTier.displayName) — \(l.status.displayName)")
                .font(.caption.bold())
                .foregroundColor(l.status.color)
            if let dat = l.decidedAt {
                Text("Decided by \(l.decidedByName.isEmpty ? "—" : l.decidedByName) · \(dat.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundColor(.secondary)
            } else {
                Text("Requested by \(l.requestedByName.isEmpty ? "—" : l.requestedByName) · \(l.requestedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundColor(.secondary)
            }
            if !l.decisionNotes.isEmpty {
                Text("\"" + l.decisionNotes + "\"")
                    .font(.caption2).italic().foregroundColor(.secondary).lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var rerequestButton: some View {
        Button { handleRequest(reRequest: true) } label: {
            Text("Re-request").font(.caption.bold())
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
    }

    @ViewBuilder
    private var requestPromptRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(tier.displayName)
                    .font(.caption.bold()).foregroundColor(.orange)
                Text("This quote's total (\(quote.grandTotal.currencyString)) requires sign-off before it can be sent.")
                    .font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            Button { handleRequest(reRequest: false) } label: {
                Text("Request Approval").font(.caption.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(10)
        .background(Color.orange.opacity(0.10))
        .cornerRadius(10)
    }

    private func handleRequest(reRequest: Bool) {
        let result = CommercialWorkflowService.shared.requestApprovalForQuote(quote)
        switch result {
        case .success:
            ToastService.shared.success(reRequest ? "Re-submitted for approval." : "Approval requested.")
        case .failure(let err):
            ToastService.shared.error(err.userMessage)
        }
    }
}
