// NextActionsCard.swift
// Phase 9 v1.2 — operational refinements #5
//
// Dashboard surface that renders AskiNextActionEngine output as a
// tappable list. Each row is a small card with severity color,
// icon, title + detail, and a CTA button. Tap → resolves the
// AskiNextAction.Destination and navigates.
//
// Empty state is intentional: when there's nothing to act on, the
// card shows a "You're all caught up" message so users know the
// detection ran and produced zero results (vs. the system being
// broken).

import SwiftUI

struct NextActionsCard: View {
    @EnvironmentObject var store: AppStore

    /// Cap surfaced actions per render to avoid burying the rest of
    /// the dashboard. Tap-through to a full sheet is a v1.3 follow-up.
    private let maxShown: Int = 6

    @State private var showFailedSyncs = false
    /// v1.2 navigation parking lot. The current commit wires the
    /// failedSyncs route end-to-end; expense / opportunity / crew /
    /// project / certificate destinations land as deep-links in v1.3
    /// once each destination accepts an `initialID:` init or a
    /// `NavigationStack` path can be threaded through here.
    @State private var pendingDestination: AskiNextAction.Destination? = nil

    private var actions: [AskiNextAction] {
        AskiNextActionEngine.currentActions(in: store)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.purple)
                Text("Next Actions")
                    .font(.headline)
                Spacer()
                if !actions.isEmpty {
                    Text("\(min(actions.count, maxShown))/\(actions.count)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.15))
                        .foregroundColor(.purple)
                        .cornerRadius(5)
                }
            }

            if actions.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(actions.prefix(maxShown)) { action in
                        actionRow(action)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(14)
        .padding(.horizontal, 16)
        .sheet(isPresented: $showFailedSyncs) {
            FailedSyncDetailView().environmentObject(store)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're all caught up")
                    .font(.subheadline.weight(.semibold))
                Text("No crews, projects, certs, opportunities, or expenses need attention.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func actionRow(_ action: AskiNextAction) -> some View {
        Button {
            handle(action)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(color(for: action.severity).opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: action.icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(color(for: action.severity))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(action.detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Text(action.cta)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(color(for: action.severity).opacity(0.15))
                    .foregroundColor(color(for: action.severity))
                    .cornerRadius(6)
            }
            .padding(10)
            .background(Color(.tertiarySystemGroupedBackground))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private func color(for severity: AskiNextAction.Severity) -> Color {
        switch severity {
        case .info:     return .blue
        case .action:   return .accentColor
        case .warning:  return .orange
        case .critical: return .red
        }
    }

    private func handle(_ action: AskiNextAction) {
        switch action.destination {
        case .failedSyncs:
            showFailedSyncs = true
        case .expenseApproval, .opportunityFollowUp, .crewMembership,
             .projectBudget, .certificateExpiry:
            // v1.2 — stub. Tap is captured; full deep-linking lands in
            // v1.3 alongside the supporting initializers on each
            // destination view.
            pendingDestination = action.destination
        }
    }
}
