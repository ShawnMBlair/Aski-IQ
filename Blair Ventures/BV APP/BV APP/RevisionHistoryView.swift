// RevisionHistoryView.swift
// Aski IQ — Reusable revision history viewer for Quote and Estimate.
//
// Loads from Supabase via RevisionService. Renders a chronological list of
// snapshots with the change summary and creator. Tapping a row opens the
// underlying JSON snapshot in a read-only viewer — useful for compliance
// review and "what did the client see at quote-sent time?" investigations.

import SwiftUI

struct QuoteRevisionHistorySheet: View {
    @Environment(\.dismiss) var dismiss
    let quoteID: UUID
    let quoteJobNumber: String

    @State private var revisions: [RevisionService.QuoteRevision] = []
    @State private var isLoading = true
    @State private var loadError: String? = nil

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Revisions — \(quoteJobNumber)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .task { await reload() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading revisions…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = loadError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle).foregroundColor(.orange)
                Text("Couldn't load revisions").font(.headline)
                Text(err).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                Button("Retry") { Task { await reload() } }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if revisions.isEmpty {
            emptyState(
                title: "No revisions yet",
                message: "Snapshots are written automatically when a quote or estimate moves through its lifecycle (sent, accepted, etc.). The first revision will appear after the next state change."
            )
        } else {
            List(revisions) { rev in
                NavigationLink {
                    RevisionDetailView(
                        title: "Quote \(quoteJobNumber) · Rev \(rev.revisionNumber)",
                        snapshot: rev.snapshotJSON,
                        createdAt: rev.createdAt,
                        createdBy: rev.createdBy,
                        summary: rev.changeSummary
                    )
                } label: {
                    revisionRow(
                        revisionNumber: rev.revisionNumber,
                        summary: rev.changeSummary,
                        createdAt: rev.createdAt,
                        createdBy: rev.createdBy
                    )
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func reload() async {
        isLoading = true
        loadError = nil
        do {
            revisions = try await RevisionService.shared.loadRevisions(forQuote: quoteID)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

struct EstimateRevisionHistorySheet: View {
    @Environment(\.dismiss) var dismiss
    let estimateID: UUID
    let estimateName: String

    @State private var revisions: [RevisionService.EstimateRevision] = []
    @State private var isLoading = true
    @State private var loadError: String? = nil

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Revisions — \(estimateName)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .task { await reload() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading revisions…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = loadError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle).foregroundColor(.orange)
                Text("Couldn't load revisions").font(.headline)
                Text(err).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                Button("Retry") { Task { await reload() } }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if revisions.isEmpty {
            emptyState(
                title: "No revisions yet",
                message: "Snapshots are written automatically when an estimate moves through its lifecycle. The first revision will appear after the next state change."
            )
        } else {
            List(revisions) { rev in
                NavigationLink {
                    RevisionDetailView(
                        title: "Estimate \(estimateName) · Rev \(rev.revisionNumber)",
                        snapshot: rev.snapshotJSON,
                        createdAt: rev.createdAt,
                        createdBy: rev.createdBy,
                        summary: rev.changeSummary
                    )
                } label: {
                    revisionRow(
                        revisionNumber: rev.revisionNumber,
                        summary: rev.changeSummary,
                        createdAt: rev.createdAt,
                        createdBy: rev.createdBy
                    )
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func reload() async {
        isLoading = true
        loadError = nil
        do {
            revisions = try await RevisionService.shared.loadRevisions(forEstimate: estimateID)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Shared row + detail + empty state

@ViewBuilder
private func emptyState(title: String, message: String) -> some View {
    VStack(spacing: 12) {
        Image(systemName: "clock.arrow.circlepath")
            .font(.system(size: 44))
            .foregroundColor(.secondary)
        Text(title).font(.headline)
        Text(message)
            .font(.subheadline)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

@ViewBuilder
private func revisionRow(
    revisionNumber: Int,
    summary: String?,
    createdAt: Date,
    createdBy: String
) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        HStack {
            Text("Revision \(revisionNumber)")
                .font(.headline)
            Spacer()
            Text(createdAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))
                .font(.caption).foregroundColor(.secondary)
        }
        if let summary, !summary.isEmpty {
            Text(summary).font(.subheadline).foregroundColor(.secondary)
        }
        if !createdBy.isEmpty {
            Text("By \(createdBy)").font(.caption2).foregroundColor(.secondary)
        }
    }
    .padding(.vertical, 4)
}

private struct RevisionDetailView: View {
    let title:      String
    let snapshot:   String
    let createdAt:  Date
    let createdBy:  String
    let summary:    String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Change summary").font(.caption).foregroundColor(.secondary)
                        Text(summary).font(.subheadline)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                }
                Text("Created \(createdAt.formatted(.dateTime)) by \(createdBy.isEmpty ? "system" : createdBy)")
                    .font(.caption).foregroundColor(.secondary)
                Divider()
                Text("Snapshot").font(.caption).foregroundColor(.secondary)
                Text(prettyPrint(snapshot))
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                    .textSelection(.enabled)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Pretty-print a JSON string for readability. Falls back to raw text.
    private func prettyPrint(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: obj,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let s = String(data: pretty, encoding: .utf8)
        else {
            return raw
        }
        return s
    }
}
