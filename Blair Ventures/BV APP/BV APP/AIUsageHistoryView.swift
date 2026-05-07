// AIUsageHistoryView.swift
// Aski IQ — Admin-facing list of AI calls (Week 4 audit closeout).
//
// PURPOSE
// Every call through `ai-proxy` writes an `audit_snapshots` row with
// `record_type = 'ai_proxy_call'` and a `snapshot_json` payload that
// includes status, model, input/output tokens, cost cents, and the
// key source (company / global / none). The Settings → AI Features
// section already shows aggregate caps + spend, but until now there
// was no way to see WHICH calls drove those numbers.
//
// THIS VIEW
//   * Pulls the 200 most-recent ai_proxy_call audit rows for the
//     current tenant (RLS already scopes by company_id).
//   * Renders each call as a row with: timestamp, who, model, status,
//     token count, cost.
//   * Filters by status (ok / error) and by the OK/error breakdown
//     in the header.
//   * Tap a row → JSON detail of the snapshot.
//
// SECURITY
// Admin-only. Non-admins might also legitimately want to see what
// they themselves used, but a future per-user filter ("my calls
// only") would solve that — for now we keep the simpler scope.

import SwiftUI
import Supabase

@MainActor
final class AIUsageHistoryService {
    static let shared = AIUsageHistoryService()
    private init() {}

    /// Decoded JSON shape from the snapshot column. Lenient — old
    /// snapshots may not have every field, so everything is optional.
    struct CallSnapshot: Decodable {
        let status:        Int?
        let model:         String?
        let input_tokens:  Int?
        let output_tokens: Int?
        let cost_cents:    Int?
        let key_source:    String?
        let streamed:      Bool?
    }

    struct Row: Identifiable, Decodable {
        let id:             UUID
        let created_at:     String
        let record_type:    String
        let event_type:     String
        let performed_by:   String?
        let snapshot_json:  String?
        let company_id:     UUID?

        var snapshot: CallSnapshot? {
            guard let raw = snapshot_json,
                  let data = raw.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(CallSnapshot.self, from: data)
        }

        var createdAtDate: Date {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return iso.date(from: created_at) ?? ISO8601DateFormatter().date(from: created_at) ?? Date()
        }

        var isError: Bool { event_type == "ai_call_error" }
    }

    /// Pulls up to 200 of the most recent ai_proxy_call rows for the
    /// caller's tenant. Server-side RLS handles tenant isolation;
    /// we don't need to pass company_id explicitly.
    func fetch() async throws -> [Row] {
        return try await supabase
            .from("audit_snapshots")
            .select()
            .eq("record_type", value: "ai_proxy_call")
            .order("created_at", ascending: false)
            .limit(200)
            .execute()
            .value
    }
}

// MARK: - View

struct AIUsageHistoryView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    @State private var rows: [AIUsageHistoryService.Row] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var statusFilter: StatusFilter = .all
    @State private var detail: AIUsageHistoryService.Row?

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all     = "All"
        case ok      = "Successful"
        case errored = "Errored"
        var id: String { rawValue }
    }

    private var filtered: [AIUsageHistoryService.Row] {
        switch statusFilter {
        case .all:     return rows
        case .ok:      return rows.filter { !$0.isError }
        case .errored: return rows.filter {  $0.isError }
        }
    }

    private var totalCostCents: Int {
        rows.compactMap { $0.snapshot?.cost_cents }.reduce(0, +)
    }
    private var totalTokens: Int {
        rows.compactMap { ($0.snapshot?.input_tokens ?? 0) + ($0.snapshot?.output_tokens ?? 0) }.reduce(0, +)
    }
    private var errorCount: Int {
        rows.filter { $0.isError }.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading recent AI calls…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40)).foregroundColor(.orange)
                        Text("Couldn't load AI history").font(.headline)
                        Text(err).font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Try again") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rows.isEmpty {
                    ContentUnavailableView(
                        "No AI calls yet",
                        systemImage: "sparkles",
                        description: Text("AI Review, Aski Chat, and CRM auto-summaries will all show up here.")
                    )
                } else {
                    listContent
                }
            }
            .navigationTitle("AI Usage History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .sheet(item: $detail) { row in
                AIUsageDetailView(row: row)
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        List {
            // Summary / filter bar
            Section {
                HStack {
                    summaryCell("Calls", "\(rows.count)")
                    summaryCell("Tokens", formatTokens(totalTokens))
                    summaryCell("Cost", "$\(String(format: "%.2f", Double(totalCostCents) / 100.0))")
                    summaryCell("Errors", "\(errorCount)",
                                color: errorCount > 0 ? .red : .secondary)
                }
                Picker("Filter", selection: $statusFilter) {
                    ForEach(StatusFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                ForEach(filtered) { row in
                    Button {
                        detail = row
                    } label: {
                        rowView(row)
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Showing \(filtered.count) of \(rows.count) most recent calls. Server stores up to 365 days of history.")
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func rowView(_ row: AIUsageHistoryService.Row) -> some View {
        let snap = row.snapshot
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: row.isError ? "xmark.octagon.fill" : "checkmark.seal.fill")
                    .foregroundColor(row.isError ? .red : .green)
                    .font(.caption)
                Text(modelLabel(snap?.model))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let cents = snap?.cost_cents {
                    Text("$\(String(format: "%.3f", Double(cents) / 100.0))")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.green)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "person.fill")
                    .font(.caption2).foregroundColor(.secondary)
                Text(row.performed_by ?? "Unknown")
                    .font(.caption2).foregroundColor(.secondary)
                    .lineLimit(1)
                Text("·").foregroundColor(.secondary).font(.caption2)
                Text(row.createdAtDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundColor(.secondary)
            }
            HStack(spacing: 12) {
                if let inT = snap?.input_tokens, let outT = snap?.output_tokens {
                    Label("\(inT)→\(outT) tok", systemImage: "arrow.left.arrow.right")
                        .font(.caption2).foregroundColor(.secondary)
                }
                if let src = snap?.key_source {
                    Label(src.capitalized, systemImage: src == "company" ? "key.fill" : "key")
                        .font(.caption2)
                        .foregroundColor(src == "company" ? .purple : .orange)
                }
                if snap?.streamed == true {
                    Label("streamed", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func summaryCell(_ label: String, _ value: String, color: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.weight(.semibold)).foregroundColor(color)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func modelLabel(_ raw: String?) -> String {
        guard let r = raw else { return "Unknown model" }
        if r.contains("haiku")  { return "Haiku" }
        if r.contains("sonnet") { return "Sonnet" }
        if r.contains("opus")   { return "Opus" }
        return r
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            rows = try await AIUsageHistoryService.shared.fetch()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Detail

struct AIUsageDetailView: View {
    let row: AIUsageHistoryService.Row
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    if let s = row.snapshot {
                        snapshotCard(s)
                    } else {
                        Text("No structured snapshot available.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    rawJSONCard
                }
                .padding()
            }
            .navigationTitle("AI Call Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: row.isError ? "xmark.octagon.fill" : "checkmark.seal.fill")
                    .foregroundColor(row.isError ? .red : .green)
                Text(row.isError ? "Errored" : "Successful")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(row.isError ? .red : .green)
            }
            Text("\(row.performed_by ?? "Unknown")  ·  \(row.createdAtDate.formatted(date: .complete, time: .shortened))")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func snapshotCard(_ s: AIUsageHistoryService.CallSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Call").font(.subheadline.weight(.semibold))
            kv("Model", s.model ?? "—")
            kv("HTTP status", s.status.map { "\($0)" } ?? "—")
            kv("Input tokens", s.input_tokens.map { "\($0)" } ?? "—")
            kv("Output tokens", s.output_tokens.map { "\($0)" } ?? "—")
            kv("Cost", s.cost_cents.map { "$\(String(format: "%.4f", Double($0) / 100.0))" } ?? "—")
            kv("Key source", s.key_source ?? "—")
            kv("Streamed", s.streamed.map { $0 ? "yes" : "no" } ?? "—")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var rawJSONCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Raw snapshot").font(.subheadline.weight(.semibold))
            ScrollView(.horizontal) {
                Text(row.snapshot_json ?? "—")
                    .font(.system(.caption2, design: .monospaced))
                    .padding()
            }
            .frame(maxHeight: 280)
            .background(Color(.tertiarySystemBackground))
            .cornerRadius(8)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
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
