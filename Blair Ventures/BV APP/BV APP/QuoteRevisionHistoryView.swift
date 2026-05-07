// QuoteRevisionHistoryView.swift
// Aski IQ — Browseable revision history for a Quote (Phase 8 audit fix).
//
// PURPOSE
// `RevisionService` already snapshots quotes on every material change
// (status flip, line-item edit, scope rewrite). The 2026-04 audit
// flagged that there was no UI surface to BROWSE those snapshots —
// so users had no way to answer "what did v3 of this quote look
// like before we cut the markup?". This view closes that loop.
//
// SHAPE
//   * List of revisions, newest first.
//   * Each row shows revision number, change summary, who/when.
//   * Tap a row → detail showing the JSON snapshot decoded back
//     into a read-only Quote view (subtotal, tax, line items, status).
//   * Two-up diff: select two revisions → side-by-side delta of
//     what changed (status, total, line-item count).
//
// SECURITY
// `loadRevisions` is gated server-side by tenant RLS. We don't add
// extra role gates here — a member who can SEE the quote can see
// its revision history.

import SwiftUI

struct QuoteRevisionHistoryView: View {
    let quote: Quote
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    @State private var revisions: [RevisionService.QuoteRevision] = []
    @State private var isLoading = true
    @State private var error: String?

    /// Two-revision selection for diff mode. Swipe-to-pick on each
    /// row toggles entries in/out of this set.
    @State private var diffSelection: Set<UUID> = []
    @State private var showDiff = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading revisions…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.orange)
                        Text("Couldn't load history")
                            .font(.headline)
                        Text(err).font(.caption).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if revisions.isEmpty {
                    ContentUnavailableView(
                        "No revision history",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Edits made after \(quote.jobNumber) was created will appear here.")
                    )
                } else {
                    List {
                        Section {
                            Text("\(revisions.count) revision\(revisions.count == 1 ? "" : "s") on file. Tap a row to view the snapshot, or select two to compare.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        ForEach(revisions) { rev in
                            NavigationLink {
                                QuoteRevisionDetailView(revision: rev)
                            } label: {
                                row(for: rev)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("\(quote.jobNumber) History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if diffSelection.count == 2 {
                        Button("Compare") { showDiff = true }
                            .bold()
                    }
                }
            }
            .sheet(isPresented: $showDiff) {
                let pair = revisions.filter { diffSelection.contains($0.id) }
                if pair.count == 2 {
                    QuoteRevisionDiffView(left: pair[0], right: pair[1])
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private func row(for rev: RevisionService.QuoteRevision) -> some View {
        HStack(spacing: 12) {
            // Selection checkbox for diff mode. Tap toggles; max 2.
            Button {
                if diffSelection.contains(rev.id) {
                    diffSelection.remove(rev.id)
                } else if diffSelection.count < 2 {
                    diffSelection.insert(rev.id)
                }
            } label: {
                Image(systemName: diffSelection.contains(rev.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(diffSelection.contains(rev.id) ? .blue : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("v\(rev.revisionNumber)")
                        .font(.subheadline).bold()
                        .foregroundColor(.purple)
                    Text(rev.changeSummary ?? "Edit")
                        .font(.subheadline)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Image(systemName: "person.fill")
                        .font(.caption2).foregroundColor(.secondary)
                    Text(rev.createdBy.isEmpty ? "Unknown" : rev.createdBy)
                        .font(.caption2).foregroundColor(.secondary)
                    Text("·").foregroundColor(.secondary).font(.caption2)
                    Text(rev.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            revisions = try await RevisionService.shared.loadRevisions(forQuote: quote.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Detail View — single revision

struct QuoteRevisionDetailView: View {
    let revision: RevisionService.QuoteRevision

    /// Decoded snapshot, if the JSON parses cleanly. We don't crash
    /// on bad data — older snapshots may have shipped with model
    /// shapes we no longer accept; show what we can and label
    /// missing fields rather than refusing to render.
    private var decoded: Quote? {
        guard let data = revision.snapshotJSON.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Quote.self, from: data)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard

                if let q = decoded {
                    snapshotSummary(q)
                    if !q.lineItems.isEmpty {
                        lineItemsCard(q)
                    }
                } else {
                    rawJSONFallback
                }
            }
            .padding()
        }
        .navigationTitle("Revision v\(revision.revisionNumber)")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(revision.changeSummary ?? "Edit")
                .font(.headline)
            HStack(spacing: 8) {
                Label(revision.createdBy.isEmpty ? "Unknown" : revision.createdBy, systemImage: "person.fill")
                Label(revision.createdAt.formatted(date: .complete, time: .shortened),
                      systemImage: "clock")
            }
            .font(.caption).foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    @ViewBuilder
    private func snapshotSummary(_ q: Quote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Snapshot").font(.subheadline).bold()
            kv("Status", q.status.rawValue.capitalized)
            kv("Subtotal", q.lineItemsSubtotal.currencyString)
            kv("Discount", "\(q.discountPercent)%")
            kv("Contingency", "\(q.contingencyPercent)%")
            kv("Tax rate", "\(q.taxRate)%")
            kv("Grand total", q.grandTotal.currencyString)
            kv("Line items", "\(q.lineItems.count)")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    @ViewBuilder
    private func lineItemsCard(_ q: Quote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Line items").font(.subheadline).bold()
            ForEach(q.lineItems) { li in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(li.code).font(.caption.weight(.semibold))
                            .fontDesign(.monospaced).foregroundColor(.blue)
                        Spacer()
                        Text(li.estimatedTotal.currencyString)
                            .font(.caption.weight(.semibold))
                    }
                    Text(li.description).font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
                Divider()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    @ViewBuilder
    private var rawJSONFallback: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Couldn't decode snapshot — older format. Raw JSON below.")
                .font(.caption).foregroundColor(.orange)
            ScrollView(.horizontal) {
                Text(revision.snapshotJSON)
                    .font(.system(.caption, design: .monospaced))
                    .padding()
            }
            .frame(maxHeight: 320)
            .background(Color(.tertiarySystemBackground))
            .cornerRadius(8)
        }
    }

    private func kv(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).foregroundColor(.secondary)
            Spacer()
            Text(value).fontDesign(.monospaced)
        }
        .font(.caption)
    }
}

// MARK: - Diff View — compare two revisions

struct QuoteRevisionDiffView: View {
    let left:  RevisionService.QuoteRevision
    let right: RevisionService.QuoteRevision
    @Environment(\.dismiss) var dismiss

    private var leftQuote:  Quote? { decode(left.snapshotJSON) }
    private var rightQuote: Quote? { decode(right.snapshotJSON) }

    private func decode(_ json: String) -> Quote? {
        guard let data = json.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Quote.self, from: data)
    }

    /// Older revision is on the left, newer on the right. Sorted by
    /// revision number rather than which the user happened to tap
    /// first so the visual is always "before → after".
    private var leftIsOlder: Bool { left.revisionNumber < right.revisionNumber }

    private var older: RevisionService.QuoteRevision { leftIsOlder ? left : right }
    private var newer: RevisionService.QuoteRevision { leftIsOlder ? right : left }
    private var olderQuote: Quote? { leftIsOlder ? leftQuote : rightQuote }
    private var newerQuote: Quote? { leftIsOlder ? rightQuote : leftQuote }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let o = olderQuote, let n = newerQuote {
                    VStack(spacing: 12) {
                        header
                        diffRow("Status",     o.status.rawValue.capitalized,
                                              n.status.rawValue.capitalized)
                        diffRow("Subtotal",   o.lineItemsSubtotal.currencyString,
                                              n.lineItemsSubtotal.currencyString)
                        diffRow("Discount",   "\(o.discountPercent)%", "\(n.discountPercent)%")
                        diffRow("Contingency","\(o.contingencyPercent)%", "\(n.contingencyPercent)%")
                        diffRow("Tax rate",   "\(o.taxRate)%", "\(n.taxRate)%")
                        diffRow("Grand total", o.grandTotal.currencyString,
                                               n.grandTotal.currencyString)
                        diffRow("Line items", "\(o.lineItems.count)", "\(n.lineItems.count)")
                    }
                    .padding()
                } else {
                    Text("Couldn't decode one or both snapshots — older revision format.")
                        .font(.caption).foregroundColor(.orange).padding()
                }
            }
            .navigationTitle("v\(older.revisionNumber) → v\(newer.revisionNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 4) {
            Text("Comparing snapshots")
                .font(.subheadline).foregroundColor(.secondary)
            HStack {
                col("v\(older.revisionNumber)", older.changeSummary, older.createdAt)
                Image(systemName: "arrow.right").foregroundColor(.secondary)
                col("v\(newer.revisionNumber)", newer.changeSummary, newer.createdAt)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func col(_ title: String, _ summary: String?, _ date: Date) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundColor(.purple)
            Text(summary ?? "Edit").font(.caption2).lineLimit(1)
            Text(date.formatted(date: .abbreviated, time: .omitted))
                .font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func diffRow(_ label: String, _ before: String, _ after: String) -> some View {
        let changed = before != after
        return HStack(spacing: 12) {
            Text(label).font(.caption).foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(before)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundColor(changed ? .red : .primary)
                .strikethrough(changed)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundColor(changed ? .blue : .secondary.opacity(0.4))
            Text(after)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundColor(changed ? .green : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(changed ? Color.yellow.opacity(0.08) : Color.clear)
        .cornerRadius(6)
    }
}
