// ParentPickerSheet.swift
// Aski IQ — Phase 7 / Decision 1: auto-route top-level commercial creates
//
// Three lightweight picker sheets used by list-view "+" toolbar buttons
// to force selection of a required parent (Project / Opportunity /
// Estimate) BEFORE opening the create form. Replaces the old pattern
// of opening the create form with a `UUID()` placeholder or letting
// the user save an orphan that fails on push.
//
// Each picker:
//   • Filters out soft-deleted + (where applicable) terminal-stage rows
//   • Surfaces an empty-state with a hint pointing at where to create
//     the missing parent
//   • Calls `onPick(uuid)` and dismisses itself; caller routes to the
//     create form with the preselected ID
//
// Consumer pattern — single-sheet router via Identifiable enum keeps
// SwiftUI from racing two `.sheet(isPresented:)` modifiers when the
// picker dismisses and the create form opens back-to-back:
//
//     enum Flow: Identifiable {
//         case pickParent
//         case create(UUID)
//         var id: String { ... }
//     }
//     @State private var flow: Flow? = nil
//     ...
//     Button { flow = .pickParent }
//     .sheet(item: $flow) { state in
//         switch state {
//         case .pickParent:
//             RequiredProjectPickerSheet { id in flow = .create(id) }
//         case .create(let id):
//             InvoiceCreateEditView(invoice: nil, preselectedProjectID: id)
//         }
//     }

import SwiftUI

// MARK: - Project Picker

struct RequiredProjectPickerSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    let onPick: (UUID) -> Void

    @State private var search = ""

    /// Active + on-hold projects only. Completed / cancelled projects
    /// shouldn't accept new commercial documents (the user can still
    /// reach them from Project Detail if they really need to).
    private var eligibleProjects: [Project] {
        store.projects
            .filter { !$0.isDeleted && ($0.status == .active || $0.status == .awarded || $0.status == .onHold) }
            .sorted { $0.name < $1.name }
    }

    private var filtered: [Project] {
        guard !search.isEmpty else { return eligibleProjects }
        return eligibleProjects.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.clientName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if eligibleProjects.isEmpty {
                    emptyState
                } else {
                    listContent
                }
            }
            .navigationTitle("Select Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var listContent: some View {
        List {
            Section {
                ForEach(filtered) { project in
                    Button {
                        onPick(project.id)
                    } label: {
                        ProjectPickerRow(project: project)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Active Projects (\(filtered.count))")
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Project or client name")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No active projects")
                .font(.headline)
            Text("Create a project from the Projects tab before opening this flow.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProjectPickerRow: View {
    let project: Project

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: "folder.fill")
                    .foregroundColor(.blue)
                    .font(.system(size: 14))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.subheadline).bold()
                    .foregroundColor(.primary)
                Text(project.clientName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            StatusBadge(status: project.status)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Opportunity Picker

struct RequiredOpportunityPickerSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    let onPick: (UUID) -> Void

    @State private var search = ""

    /// Open opportunities only — won/lost shouldn't anchor new work.
    private var eligibleOpportunities: [CRMOpportunity] {
        store.crmOpportunities
            .filter { !$0.isDeleted && $0.stage != .won && $0.stage != .lost }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var filtered: [CRMOpportunity] {
        guard !search.isEmpty else { return eligibleOpportunities }
        return eligibleOpportunities.filter {
            $0.title.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if eligibleOpportunities.isEmpty {
                    emptyState
                } else {
                    listContent
                }
            }
            .navigationTitle("Select Opportunity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var listContent: some View {
        List {
            Section {
                ForEach(filtered) { opp in
                    Button {
                        onPick(opp.id)
                    } label: {
                        OpportunityPickerRow(opportunity: opp)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Open Opportunities (\(filtered.count))")
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Opportunity title")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No open opportunities")
                .font(.headline)
            Text("Open the CRM tab and create a lead first — every commercial record needs a parent opportunity.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OpportunityPickerRow: View {
    let opportunity: CRMOpportunity

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 14))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(opportunity.title)
                    .font(.subheadline).bold()
                    .foregroundColor(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(opportunity.stage.rawValue.capitalized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if opportunity.value > 0 {
                        Text("· \(opportunity.value.currencyString)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Estimate Picker
//
// Used by QuoteListView to enforce the Estimate → Quote ordering. A
// Quote's FK to estimate_id is NOT NULL, so creating a quote without
// picking an estimate first would always fail on push.

struct RequiredEstimatePickerSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    let onPick: (Estimate) -> Void

    @State private var search = ""

    /// Non-deleted estimates that haven't already been converted to a
    /// quote. Converted estimates are locked and shouldn't spawn a
    /// second quote.
    private var eligibleEstimates: [Estimate] {
        store.estimates
            .filter { !$0.isDeleted && $0.status != .converted }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var filtered: [Estimate] {
        guard !search.isEmpty else { return eligibleEstimates }
        return eligibleEstimates.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.jobNumber.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if eligibleEstimates.isEmpty {
                    emptyState
                } else {
                    listContent
                }
            }
            .navigationTitle("Select Estimate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var listContent: some View {
        List {
            Section {
                ForEach(filtered) { est in
                    Button {
                        onPick(est)
                    } label: {
                        EstimatePickerRowView(estimate: est)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Available Estimates (\(filtered.count))")
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Estimate name or job #")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No estimates available")
                .font(.headline)
            Text("Quotes are generated from estimates. Create an estimate first from the Estimates tab.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EstimatePickerRowView: View {
    let estimate: Estimate

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: "doc.text.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 14))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(estimate.name)
                    .font(.subheadline).bold()
                    .foregroundColor(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("#\(estimate.jobNumber)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("· \(estimate.totalEstimated.currencyString)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}
