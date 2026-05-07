// EstimateRevisionHistoryView.swift
// Aski IQ — Browseable revision history for an Estimate (Phase 9 audit fix).
//
// MIRRORS `QuoteRevisionHistoryView.swift` — same tap-row-to-view +
// multi-select-to-compare UX. Estimates already had a JSON-dump
// viewer (`EstimateRevisionHistorySheet` in `RevisionHistoryView.swift`)
// but the 2026-04 audit asked for the same decoded + diff experience
// as the Quote side.
//
// We don't delete the old sheet — it stays as a lightweight fallback
// for any caller that imports it. EstimateDetailView is migrated to
// this richer view in the same audit pass.

import SwiftUI

struct EstimateRevisionHistoryView: View {
    let estimate: Estimate
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    @State private var revisions: [RevisionService.EstimateRevision] = []
    @State private var isLoading = true
    @State private var error: String?

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
                        Text("Couldn't load history").font(.headline)
                        Text(err).font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if revisions.isEmpty {
                    ContentUnavailableView(
                        "No revision history",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Edits made after \(estimate.jobNumber) was created will appear here.")
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
                                EstimateRevisionDetailView(revision: rev)
                            } label: {
                                row(for: rev)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("\(estimate.jobNumber) History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if diffSelection.count == 2 {
                        Button("Compare") { showDiff = true }.bold()
                    }
                }
            }
            .sheet(isPresented: $showDiff) {
                let pair = revisions.filter { diffSelection.contains($0.id) }
                if pair.count == 2 {
                    EstimateRevisionDiffView(left: pair[0], right: pair[1])
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private func row(for rev: RevisionService.EstimateRevision) -> some View {
        HStack(spacing: 12) {
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
                        .font(.subheadline).lineLimit(1)
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
            revisions = try await RevisionService.shared.loadRevisions(forEstimate: estimate.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Detail (decoded)

struct EstimateRevisionDetailView: View {
    let revision: RevisionService.EstimateRevision

    private var decoded: Estimate? {
        guard let data = revision.snapshotJSON.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Estimate.self, from: data)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                if let est = decoded {
                    snapshotSummary(est)
                    if !est.lineItems.isEmpty {
                        lineItemsCard(est)
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
    private func snapshotSummary(_ est: Estimate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Snapshot").font(.subheadline).bold()
            kv("Status", est.status.displayName)
            kv("Pricing type", est.pricingType.rawValue.capitalized)
            kv("Subtotal", est.subtotal.currencyString)
            kv("Contingency", "\(est.contingencyPercent)%")
            kv("Overhead", "\(est.overheadPercent)%")
            kv("Profit", "\(est.profitPercent)%")
            kv("Total estimated", est.totalEstimated.currencyString)
            if let aw = est.awardedValue {
                kv("Awarded value", aw.currencyString)
            }
            if let lr = est.lossReason {
                kv("Loss reason", lr.displayName)
            }
            kv("Line items", "\(est.lineItems.count)")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    @ViewBuilder
    private func lineItemsCard(_ est: Estimate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Line items").font(.subheadline).bold()
            ForEach(est.lineItems) { li in
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

// MARK: - Diff

struct EstimateRevisionDiffView: View {
    let left:  RevisionService.EstimateRevision
    let right: RevisionService.EstimateRevision
    @Environment(\.dismiss) var dismiss

    private var leftEst:  Estimate? { decode(left.snapshotJSON) }
    private var rightEst: Estimate? { decode(right.snapshotJSON) }

    private func decode(_ json: String) -> Estimate? {
        guard let data = json.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Estimate.self, from: data)
    }

    private var leftIsOlder: Bool { left.revisionNumber < right.revisionNumber }
    private var older: RevisionService.EstimateRevision { leftIsOlder ? left : right }
    private var newer: RevisionService.EstimateRevision { leftIsOlder ? right : left }
    private var olderEst: Estimate? { leftIsOlder ? leftEst : rightEst }
    private var newerEst: Estimate? { leftIsOlder ? rightEst : leftEst }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let o = olderEst, let n = newerEst {
                    VStack(spacing: 12) {
                        header
                        diffRow("Status",        o.status.displayName,  n.status.displayName)
                        diffRow("Subtotal",      o.subtotal.currencyString, n.subtotal.currencyString)
                        diffRow("Contingency",   "\(o.contingencyPercent)%", "\(n.contingencyPercent)%")
                        diffRow("Overhead",      "\(o.overheadPercent)%", "\(n.overheadPercent)%")
                        diffRow("Profit",        "\(o.profitPercent)%", "\(n.profitPercent)%")
                        diffRow("Total estimated", o.totalEstimated.currencyString,
                                                   n.totalEstimated.currencyString)
                        diffRow("Line items",    "\(o.lineItems.count)", "\(n.lineItems.count)")
                        if o.awardedValue != n.awardedValue {
                            diffRow("Awarded value",
                                    o.awardedValue?.currencyString ?? "—",
                                    n.awardedValue?.currencyString ?? "—")
                        }
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
                .frame(width: 110, alignment: .leading)
            Text(before)
                .font(.caption).fontDesign(.monospaced)
                .foregroundColor(changed ? .red : .primary)
                .strikethrough(changed)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundColor(changed ? .blue : .secondary.opacity(0.4))
            Text(after)
                .font(.caption).fontDesign(.monospaced)
                .foregroundColor(changed ? .green : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(changed ? Color.yellow.opacity(0.08) : Color.clear)
        .cornerRadius(6)
    }
}
