// SiteRevenueView.swift
// Aski IQ – Per-Site Revenue Breakdown
// Shows bid pipeline and revenue metrics grouped by site, for one client or all clients.

import SwiftUI

// MARK: - Site Revenue View

struct SiteRevenueView: View {
    @EnvironmentObject var store: AppStore

    /// Pass a clientID to scope to one company, or nil for all clients.
    var clientID: UUID? = nil

    @State private var sortMode: SortMode = .totalBid

    enum SortMode: String, CaseIterable {
        case totalBid   = "Total Bid"
        case awarded    = "Awarded"
        case winRate    = "Win Rate"
        case jobs       = "Active Jobs"
    }

    private var rows: [SiteRevenueRow] {
        buildRows().sorted(by: sortMode)
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "mappin.slash.circle")
                        .font(.system(size: 52)).foregroundColor(.secondary)
                    Text("No site data yet")
                        .font(.headline)
                    Text("Create estimates linked to sites to see revenue by location.")
                        .font(.subheadline).foregroundColor(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal)
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {

                        // ── Summary KPIs ──────────────────────────
                        let totalBid     = rows.reduce(Decimal(0)) { $0 + $1.totalBid }
                        let totalAwarded = rows.reduce(Decimal(0)) { $0 + $1.awardedValue }
                        let totalJobs    = rows.reduce(0) { $0 + $1.activeJobs }

                        HStack(spacing: 12) {
                            MiniKPICard(value: totalBid.currencyString,
                                        label: "Total Pipeline", icon: "chart.line.uptrend.xyaxis", color: .purple)
                            MiniKPICard(value: totalAwarded.currencyString,
                                        label: "Awarded", icon: "trophy.fill", color: .green)
                            MiniKPICard(value: "\(totalJobs)",
                                        label: "Active Jobs", icon: "folder.fill", color: .orange)
                        }
                        .padding(.horizontal)

                        // ── Sort Control ──────────────────────────
                        HStack {
                            Text("Sort by")
                                .font(.subheadline).foregroundColor(.secondary)
                            Picker("Sort", selection: $sortMode) {
                                ForEach(SortMode.allCases, id: \.self) { m in
                                    Text(m.rawValue).tag(m)
                                }
                            }
                            .pickerStyle(.menu)
                            Spacer()
                            Text("\(rows.count) sites")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        .padding(.horizontal)

                        // ── Site Cards ────────────────────────────
                        ForEach(rows) { row in
                            SiteRevenueCard(row: row)
                                .padding(.horizontal)
                        }

                        Spacer(minLength: 32)
                    }
                    .padding(.top)
                }
            }
        }
        .navigationTitle(clientID == nil ? "Revenue by Site" : "Site Revenue")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Build Rows

    private func buildRows() -> [SiteRevenueRow] {
        // Gather clients in scope
        let clients: [Client] = clientID == nil
            ? store.clients
            : store.clients.filter { $0.id == clientID }

        var result: [SiteRevenueRow] = []

        for client in clients {
            for site in client.sites {
                let siteEstimates = store.estimates.filter {
                    $0.clientID == client.id && $0.siteID == site.id
                }
                guard !siteEstimates.isEmpty else { continue }

                let totalBid     = siteEstimates.reduce(Decimal(0)) { $0 + $1.totalEstimated }
                let awarded      = siteEstimates.filter { $0.status == .awarded }
                let awardedValue = awarded.reduce(Decimal(0)) { $0 + ($1.awardedValue ?? $1.totalEstimated) }
                let lost         = siteEstimates.filter { $0.status == .lost }.count
                let submitted    = siteEstimates.filter { $0.status == .submitted }.count
                let closed       = awarded.count + lost
                let winRate      = closed > 0 ? Double(awarded.count) / Double(closed) * 100 : 0

                let activeJobs = store.projects.filter {
                    $0.clientID == client.id && $0.siteID == site.id && $0.status == .active
                }.count

                result.append(SiteRevenueRow(
                    siteID:        site.id,
                    siteName:      site.name,
                    siteAddress:   site.formattedAddress.isEmpty ? site.address : site.formattedAddress,
                    clientName:    client.name,
                    estimateCount: siteEstimates.count,
                    totalBid:      totalBid,
                    awardedValue:  awardedValue,
                    awardedCount:  awarded.count,
                    submittedCount: submitted,
                    lostCount:     lost,
                    winRate:       winRate,
                    activeJobs:    activeJobs
                ))
            }

            // Catch estimates with no site (siteID == nil) — grouped as "No Site Assigned"
            let unsited = store.estimates.filter {
                $0.clientID == client.id && $0.siteID == nil
            }
            if !unsited.isEmpty {
                let totalBid     = unsited.reduce(Decimal(0)) { $0 + $1.totalEstimated }
                let awarded      = unsited.filter { $0.status == .awarded }
                let awardedValue = awarded.reduce(Decimal(0)) { $0 + ($1.awardedValue ?? $1.totalEstimated) }
                let lost         = unsited.filter { $0.status == .lost }.count
                let submitted    = unsited.filter { $0.status == .submitted }.count
                let closed       = awarded.count + lost
                let winRate      = closed > 0 ? Double(awarded.count) / Double(closed) * 100 : 0

                result.append(SiteRevenueRow(
                    siteID:        nil,
                    siteName:      "No Site Assigned",
                    siteAddress:   "",
                    clientName:    client.name,
                    estimateCount: unsited.count,
                    totalBid:      totalBid,
                    awardedValue:  awardedValue,
                    awardedCount:  awarded.count,
                    submittedCount: submitted,
                    lostCount:     lost,
                    winRate:       winRate,
                    activeJobs:    0
                ))
            }
        }

        return result
    }
}

// MARK: - Site Revenue Row (data model)

struct SiteRevenueRow: Identifiable {
    let siteID:         UUID?
    let siteName:       String
    let siteAddress:    String
    let clientName:     String
    let estimateCount:  Int
    let totalBid:       Decimal
    let awardedValue:   Decimal
    let awardedCount:   Int
    let submittedCount: Int
    let lostCount:      Int
    let winRate:        Double   // 0–100
    let activeJobs:     Int

    var id: String { "\(clientName)-\(siteName)" }

    var pendingCount: Int { estimateCount - awardedCount - lostCount - submittedCount }
}

private extension Array where Element == SiteRevenueRow {
    func sorted(by mode: SiteRevenueView.SortMode) -> [SiteRevenueRow] {
        switch mode {
        case .totalBid:  return sorted { $0.totalBid     > $1.totalBid }
        case .awarded:   return sorted { $0.awardedValue > $1.awardedValue }
        case .winRate:   return sorted { $0.winRate       > $1.winRate }
        case .jobs:      return sorted { $0.activeJobs    > $1.activeJobs }
        }
    }
}

// MARK: - Site Revenue Card

struct SiteRevenueCard: View {
    let row: SiteRevenueRow

    private var winRateColor: Color {
        row.winRate >= 60 ? .green : row.winRate >= 30 ? .orange : .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ── Header ────────────────────────────────────────
            HStack(spacing: 10) {
                Image(systemName: row.siteID == nil ? "mappin.slash.circle.fill" : "mappin.circle.fill")
                    .font(.title2)
                    .foregroundColor(row.siteID == nil ? .secondary : .orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.siteName).font(.headline)
                    if !row.siteAddress.isEmpty {
                        Text(row.siteAddress)
                            .font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                    Text(row.clientName)
                        .font(.caption2).foregroundColor(.blue)
                }

                Spacer()

                if row.activeJobs > 0 {
                    Text("\(row.activeJobs) active")
                        .font(.caption2).bold()
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.green.opacity(0.12))
                        .foregroundColor(.green)
                        .cornerRadius(5)
                }
            }

            Divider()

            // ── Metrics Grid ──────────────────────────────────
            HStack(spacing: 0) {
                revenueMetric(label: "Total Bid",
                              value: row.totalBid.currencyString,
                              color: .purple)
                Divider().frame(height: 36)
                revenueMetric(label: "Awarded",
                              value: row.awardedValue.currencyString,
                              color: .green)
                Divider().frame(height: 36)
                revenueMetric(label: "Win Rate",
                              value: String(format: "%.0f%%", row.winRate),
                              color: winRateColor)
            }

            // ── Pipeline Bar ──────────────────────────────────
            if row.estimateCount > 0 {
                EstimatePipelineBar(row: row)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }

    @ViewBuilder
    private func revenueMetric(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline).bold().foregroundColor(color)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Estimate Pipeline Bar

private struct EstimatePipelineBar: View {
    let row: SiteRevenueRow

    private var total: Int { max(row.estimateCount, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Stacked bar
            GeometryReader { geo in
                HStack(spacing: 2) {
                    if row.awardedCount > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.green)
                            .frame(width: geo.size.width * CGFloat(row.awardedCount) / CGFloat(total))
                    }
                    if row.submittedCount > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.teal)
                            .frame(width: geo.size.width * CGFloat(row.submittedCount) / CGFloat(total))
                    }
                    if row.pendingCount > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.orange.opacity(0.6))
                            .frame(width: geo.size.width * CGFloat(row.pendingCount) / CGFloat(total))
                    }
                    if row.lostCount > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.red.opacity(0.4))
                            .frame(width: geo.size.width * CGFloat(row.lostCount) / CGFloat(total))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 8)
            .background(Color(.systemFill)).cornerRadius(4)

            // Legend
            HStack(spacing: 10) {
                legendItem(color: .green,             label: "Won (\(row.awardedCount))")
                legendItem(color: .teal,              label: "Submitted (\(row.submittedCount))")
                legendItem(color: .orange.opacity(0.8),label: "Active (\(row.pendingCount))")
                legendItem(color: .red.opacity(0.6),  label: "Lost (\(row.lostCount))")
            }
        }
    }

    @ViewBuilder
    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
    }
}
