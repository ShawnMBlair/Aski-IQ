// AILimitsView.swift
// Aski IQ — Admin-only AI spending caps + member-readable usage view.
//
// One screen with two modes:
//   * Admin (owner / executive / manager / officeAdmin):
//     full editor for daily/monthly token + cost caps, pause-when-exceeded,
//     admin notification toggle. Today/month usage is shown above the
//     editor for context.
//   * Non-admin: read-only view of today/month usage and current caps.
//
// All state changes go through CompanyAILimitsService → SECURITY DEFINER
// RPC, so the server is the source of truth and a screen tap can never
// bypass the role check.

import SwiftUI

struct AILimitsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var limits: CompanyAILimitsService.CompanyAILimits? = nil
    @State private var isLoading = false
    @State private var saveError: String? = nil

    // Editable form bindings (admin only)
    @State private var dailyTokenLimitText:    String = ""
    @State private var monthlyTokenLimitText:  String = ""
    @State private var dailyCostLimitText:     String = ""   // dollars
    @State private var monthlyCostLimitText:   String = ""   // dollars
    @State private var pauseWhenExceeded:      Bool   = true
    @State private var adminNotifyEnabled:     Bool   = true

    private var isAdmin: Bool { store.currentUserRole.isAdmin }

    var body: some View {
        NavigationStack {
            Form {
                if let limits = limits {
                    usageSection(limits)
                    if isAdmin {
                        editorSection
                        actionSection
                    } else {
                        readOnlyCapsSection(limits)
                    }
                } else {
                    Section {
                        HStack {
                            ProgressView().scaleEffect(0.85)
                            Text("Loading AI usage…")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("AI Usage & Caps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await reload() }
            .refreshable { await reload() }
        }
    }

    // MARK: - Sections

    private func usageSection(_ l: CompanyAILimitsService.CompanyAILimits) -> some View {
        Section {
            usageRow(label: "Today (UTC)",
                     calls: l.todayRequestCount,
                     tokens: l.todayTokens,
                     cost: l.todayCostDollars,
                     tokenPct: l.dailyTokenPctUsed,
                     costPct: l.dailyCostPctUsed)
            usageRow(label: "This month (UTC)",
                     calls: l.monthRequestCount,
                     tokens: l.monthTokens,
                     cost: l.monthCostDollars,
                     tokenPct: l.monthlyTokenPctUsed,
                     costPct: l.monthlyCostPctUsed)
        } header: {
            Text("Usage")
        } footer: {
            // 2026-04 re-audit fix #10: clarify the UTC window so a
            // PST/EST user understands "today" doesn't mean their
            // local day. The Edge Function's `monthStartUTC()` /
            // `todayUTC()` helpers count usage by UTC calendar day,
            // and the cap rolls at UTC midnight (4pm Pacific / 7pm
            // Eastern). Without this label users were filing tickets
            // when "today's cap" appeared to reset mid-day.
            VStack(alignment: .leading, spacing: 6) {
                if l.anyCapBreached {
                    Label("A spending cap is at or above 100%. AI calls are paused for everyone in your company until the cap rolls over or is raised.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                } else {
                    Text("Usage refreshes after each AI call. Pull down to refresh.")
                        .font(.caption)
                }
                Text("Daily window resets at \(Self.utcMidnightInLocalTime()) (UTC midnight in your timezone). Monthly window resets the 1st of each UTC month.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Renders "today's UTC midnight" in the user's local time so
    /// they understand when the daily cap rolls. e.g. for a Vancouver
    /// user the cap rolls at "16:00 today" or "17:00 (DST)" — clearer
    /// than just "midnight UTC" which most users have to mentally
    /// translate.
    private static func utcMidnightInLocalTime() -> String {
        let cal = Calendar(identifier: .gregorian)
        var utcCal = cal
        utcCal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        // Tomorrow at 00:00 UTC = today's window-end.
        guard let tomorrow = utcCal.date(byAdding: .day, value: 1,
                                          to: utcCal.startOfDay(for: Date()))
        else { return "midnight UTC" }
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: tomorrow)
    }

    private func usageRow(
        label: String,
        calls: Int64,
        tokens: Int64,
        cost: Decimal,
        tokenPct: Double?,
        costPct: Double?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.subheadline.weight(.semibold))
                Spacer()
                Text(cost.formatted(.currency(code: "USD")))
                    .font(.subheadline.monospacedDigit())
            }
            HStack(spacing: 12) {
                Label("\(calls) calls", systemImage: "bolt.fill")
                    .font(.caption).foregroundColor(.secondary)
                Label("\(formatTokens(tokens)) tokens", systemImage: "text.alignleft")
                    .font(.caption).foregroundColor(.secondary)
            }
            if let pct = tokenPct {
                progressBar(pct: pct, label: "tokens")
            }
            if let pct = costPct {
                progressBar(pct: pct, label: "cost")
            }
        }
        .padding(.vertical, 4)
    }

    private func progressBar(pct: Double, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: min(pct, 1.0))
                .tint(pct >= 1.0 ? .red : (pct >= 0.8 ? .orange : .blue))
            Text("\(Int(pct * 100))% of \(label) cap")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var editorSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Daily token cap").font(.caption).foregroundColor(.secondary)
                TextField("e.g. 500000  (leave blank for no cap)", text: $dailyTokenLimitText)
                    .keyboardType(.numberPad)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Monthly token cap").font(.caption).foregroundColor(.secondary)
                TextField("e.g. 5000000", text: $monthlyTokenLimitText)
                    .keyboardType(.numberPad)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Daily cost cap (USD)").font(.caption).foregroundColor(.secondary)
                TextField("e.g. 25.00", text: $dailyCostLimitText)
                    .keyboardType(.decimalPad)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Monthly cost cap (USD)").font(.caption).foregroundColor(.secondary)
                TextField("e.g. 500.00", text: $monthlyCostLimitText)
                    .keyboardType(.decimalPad)
            }
            Toggle("Pause AI when a cap is exceeded", isOn: $pauseWhenExceeded)
            Toggle("Notify admins when capped", isOn: $adminNotifyEnabled)
        } header: {
            Text("Spending Caps")
        } footer: {
            Text("Caps are enforced server-side on every AI call. Leave any field blank for no cap on that axis. Costs are estimated from token counts using current Anthropic list prices.")
        }
    }

    private func readOnlyCapsSection(_ l: CompanyAILimitsService.CompanyAILimits) -> some View {
        Section {
            capRow("Daily tokens",   value: l.dailyTokenLimit.map { "\(formatTokens($0))" })
            capRow("Monthly tokens", value: l.monthlyTokenLimit.map { "\(formatTokens($0))" })
            capRow("Daily cost",     value: l.dailyCostLimitCents.map { "$\(Decimal($0) / 100)" })
            capRow("Monthly cost",   value: l.monthlyCostLimitCents.map { "$\(Decimal($0) / 100)" })
            HStack {
                Text("Pause when exceeded")
                Spacer()
                Image(systemName: l.aiPauseWhenExceeded ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundColor(l.aiPauseWhenExceeded ? .green : .secondary)
            }
        } header: {
            Text("Current Caps")
        } footer: {
            Text("Only company admins can change these caps.")
        }
    }

    private func capRow(_ label: String, value: String?) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value ?? "No cap")
                .foregroundColor(value == nil ? .secondary : .primary)
                .font(.subheadline.monospacedDigit())
        }
    }

    private var actionSection: some View {
        Section {
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .font(.caption)
            }
            Button {
                Task { await save() }
            } label: {
                if isLoading {
                    HStack { ProgressView().scaleEffect(0.85); Text("Saving…") }
                } else {
                    Label("Save Caps", systemImage: "checkmark.seal.fill")
                }
            }
            .disabled(isLoading)
        }
    }

    // MARK: - Behavior

    private func reload() async {
        do {
            let l = try await CompanyAILimitsService.shared.fetchLimits()
            limits = l
            if let l {
                dailyTokenLimitText   = l.dailyTokenLimit.map(String.init) ?? ""
                monthlyTokenLimitText = l.monthlyTokenLimit.map(String.init) ?? ""
                dailyCostLimitText    = l.dailyCostLimitCents.map { String(format: "%.2f", Double($0) / 100) } ?? ""
                monthlyCostLimitText  = l.monthlyCostLimitCents.map { String(format: "%.2f", Double($0) / 100) } ?? ""
                pauseWhenExceeded     = l.aiPauseWhenExceeded
                adminNotifyEnabled    = l.aiAdminNotificationEnabled
            }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func save() async {
        isLoading = true
        saveError = nil
        defer { isLoading = false }

        let dt = parseInt(dailyTokenLimitText)
        let mt = parseInt(monthlyTokenLimitText)
        let dc = parseDollarsToCents(dailyCostLimitText)
        let mc = parseDollarsToCents(monthlyCostLimitText)

        do {
            try await CompanyAILimitsService.shared.setLimits(
                dailyTokenLimit:          dt,
                monthlyTokenLimit:        mt,
                dailyCostLimitCents:      dc,
                monthlyCostLimitCents:    mc,
                pauseWhenExceeded:        pauseWhenExceeded,
                adminNotificationEnabled: adminNotifyEnabled
            )
            ToastService.shared.success("AI caps updated.")
            await reload()
        } catch let err as CompanyAILimitsService.LimitsError {
            saveError = err.errorDescription
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: - Parsing helpers

    private func parseInt(_ s: String) -> Int64? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        if t.isEmpty { return nil }
        return Int64(t)
    }

    private func parseDollarsToCents(_ s: String) -> Int64? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        if t.isEmpty { return nil }
        if let dollars = Double(t) {
            return Int64((dollars * 100).rounded())
        }
        return nil
    }

    private func formatTokens(_ n: Int64) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
