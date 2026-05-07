// CRMReportsView.swift
// BV APP – CRM Analytics & Reports

import SwiftUI
import Charts

// MARK: - Date Range

enum CRMReportRange: String, CaseIterable, Identifiable {
    case thisMonth   = "This Month"
    case last3Months = "Last 3 Months"
    case thisYear    = "This Year"
    case allTime     = "All Time"

    var id: String { rawValue }

    func dateInterval() -> (start: Date?, end: Date?) {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .thisMonth:
            let start = cal.date(from: cal.dateComponents([.year, .month], from: now))
            return (start, nil)
        case .last3Months:
            let start = cal.date(byAdding: .month, value: -3, to: now)
            return (start, nil)
        case .thisYear:
            let start = cal.date(from: cal.dateComponents([.year], from: now))
            return (start, nil)
        case .allTime:
            return (nil, nil)
        }
    }
}

// MARK: - Currency Helper

private func currencyShort(_ d: Decimal) -> String {
    let n = NSDecimalNumber(decimal: d).doubleValue
    if n >= 1_000_000 { return String(format: "$%.1fM", n / 1_000_000) }
    if n >= 1_000     { return String(format: "$%.0fK", n / 1_000) }
    return String(format: "$%.0f", n)
}

private func currencyFull(_ d: Decimal) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.locale = .current
    return f.string(from: d as NSDecimalNumber) ?? "$0"
}

// MARK: - View Mode

private enum ReportsViewMode: String, CaseIterable {
    case reports  = "Reports"
    case forecast = "Forecast"
}

// MARK: - CRM Reports View

struct CRMReportsView: View {
    @EnvironmentObject var store: AppStore
    @State private var viewMode: ReportsViewMode = .reports
    @State private var range:    CRMReportRange  = .thisYear

    private var dateInterval: (start: Date?, end: Date?) { range.dateInterval() }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {

                // Mode picker
                Picker("Mode", selection: $viewMode) {
                    ForEach(ReportsViewMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if viewMode == .forecast {

                    ForecastContentView()
                        .environmentObject(store)

                } else {

                    // Date range picker
                    Picker("Range", selection: $range) {
                        ForEach(CRMReportRange.allCases) { r in
                            Text(r.rawValue).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)

                    KPIRow(store: store, start: dateInterval.start, end: dateInterval.end)
                    PipelineFunnelCard(store: store)
                    WinLossCard(store: store, start: dateInterval.start, end: dateInterval.end)
                    RevenueByServiceCard(store: store, start: dateInterval.start, end: dateInterval.end)
                    LossReasonsCard(store: store, start: dateInterval.start, end: dateInterval.end)
                    LeadSourceCard(store: store, start: dateInterval.start, end: dateInterval.end)
                    CRMLossPatternsCard()
                        .environmentObject(store)
                        .padding(.horizontal, 16)
                }

                Spacer(minLength: 32)
            }
        }
        .background(Color(.systemGroupedBackground))
        // Pull-to-refresh re-runs sync + the outcome-timestamp backfill so
        // KPIs, funnel, forecast, and revenue-by-service-type cards reflect
        // the latest data — same hook the main CRM Dashboard uses.
        .refreshable {
            await store.refreshAll()
        }
        .navigationTitle(viewMode == .forecast ? "Forecast" : "Reports")
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Forecast Content View

private struct ForecastContentView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date())
    @State private var showTargetSheet = false
    @State private var targetString = ""

    private var months: [ForecastMonth] { store.forecastForYear(selectedYear) }
    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }

    private var ytdWon: Decimal {
        months.filter { $0.isPast || isCurrentMonth($0.month) }
              .reduce(0) { $0 + $1.won }
    }
    private var yearForecast: Decimal { months.reduce(0) { $0 + $1.forecast } }
    private var annualTarget: Decimal { Decimal(settings.annualRevenueTarget) }
    private var monthlyTarget: Decimal {
        annualTarget > 0 ? annualTarget / 12 : 0
    }
    private var ytdProgress: Double {
        guard annualTarget > 0 else { return 0 }
        return NSDecimalNumber(decimal: ytdWon / annualTarget).doubleValue
    }

    private func isCurrentMonth(_ date: Date) -> Bool {
        Calendar.current.isDate(date, equalTo: Date(), toGranularity: .month)
    }

    var body: some View {
        VStack(spacing: 20) {

            // ── Year selector ────────────────────────────────────────────────
            HStack(spacing: 0) {
                Button {
                    selectedYear -= 1
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.blue)
                        .frame(width: 44, height: 36)
                }
                .buttonStyle(.plain)

                Text(String(selectedYear))
                    .font(.headline)
                    .frame(maxWidth: .infinity)

                Button {
                    selectedYear += 1
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.blue)
                        .frame(width: 44, height: 36)
                }
                .buttonStyle(.plain)
            }
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .padding(.horizontal, 16)

            // ── Annual summary row ───────────────────────────────────────────
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                KPITile(value: currencyShort(ytdWon),
                        label: "Won \(selectedYear)",
                        icon: "checkmark.seal.fill",
                        color: .green)
                KPITile(value: currencyShort(yearForecast),
                        label: "Weighted Forecast",
                        icon: "chart.line.uptrend.xyaxis",
                        color: .blue)
                KPITile(value: annualTarget > 0 ? currencyShort(annualTarget) : "Set Target",
                        label: annualTarget > 0 ? "Annual Target" : "Tap to Set",
                        icon: "target",
                        color: annualTarget > 0 ? .orange : .secondary)
            }
            .padding(.horizontal, 16)
            .onTapGesture { } // prevent grid from swallowing taps below

            // Annual target progress bar (only when target is set)
            if annualTarget > 0 {
                ReportCard(title: "Target Progress", icon: "target", color: .orange) {
                    VStack(spacing: 10) {
                        HStack {
                            Text("YTD Won")
                                .font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text(currencyFull(ytdWon))
                                .font(.caption.weight(.semibold))
                            Text("/ \(currencyFull(annualTarget))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.15)).frame(height: 10)
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(ytdProgress >= 1 ? Color.green : Color.orange)
                                    .frame(width: geo.size.width * min(ytdProgress, 1.0), height: 10)
                                    .animation(.easeInOut(duration: 0.5), value: ytdProgress)
                            }
                        }
                        .frame(height: 10)
                        HStack {
                            Text("\(Int(ytdProgress * 100))% of annual target")
                                .font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            Text("Remaining: \(currencyShort(max(annualTarget - ytdWon, 0)))")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
            }

            // ── Monthly bar chart ────────────────────────────────────────────
            ReportCard(title: "Monthly Revenue", icon: "chart.bar.fill", color: .blue) {
                VStack(spacing: 12) {
                    Chart {
                        ForEach(months) { m in
                            // Won bars (green)
                            BarMark(
                                x: .value("Month", m.monthLabel),
                                y: .value("Won", NSDecimalNumber(decimal: m.won).doubleValue),
                                width: .ratio(0.4)
                            )
                            .foregroundStyle(Color.green.opacity(m.isPast || isCurrentMonth(m.month) ? 1.0 : 0.35))
                            .position(by: .value("Type", "Won"))
                            .cornerRadius(3)

                            // Forecast bars (blue)
                            if m.forecast > 0 {
                                BarMark(
                                    x: .value("Month", m.monthLabel),
                                    y: .value("Forecast", NSDecimalNumber(decimal: m.forecast).doubleValue),
                                    width: .ratio(0.4)
                                )
                                .foregroundStyle(Color.blue.opacity(m.isPast ? 0.25 : 0.8))
                                .position(by: .value("Type", "Forecast"))
                                .cornerRadius(3)
                            }
                        }

                        // Monthly target rule line
                        if monthlyTarget > 0 {
                            RuleMark(y: .value("Target", NSDecimalNumber(decimal: monthlyTarget).doubleValue))
                                .foregroundStyle(Color.orange.opacity(0.7))
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                                .annotation(position: .leading) {
                                    Text("Target")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundColor(.orange)
                                }
                        }
                    }
                    .chartYAxis {
                        AxisMarks { val in
                            AxisGridLine()
                            AxisValueLabel {
                                if let d = val.as(Double.self) {
                                    Text(currencyShort(Decimal(d))).font(.caption2)
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks { _ in AxisValueLabel().font(.caption2) }
                    }
                    .frame(height: 200)

                    // Legend
                    HStack(spacing: 16) {
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.green).frame(width: 12, height: 8)
                            Text("Won").font(.caption2).foregroundColor(.secondary)
                        }
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.blue.opacity(0.8)).frame(width: 12, height: 8)
                            Text("Weighted Forecast").font(.caption2).foregroundColor(.secondary)
                        }
                        if monthlyTarget > 0 {
                            HStack(spacing: 4) {
                                Rectangle().fill(Color.orange.opacity(0.7)).frame(width: 12, height: 2)
                                Text("Monthly Target").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
            }

            // ── Monthly breakdown table ──────────────────────────────────────
            ReportCard(title: "Monthly Breakdown", icon: "tablecells.fill", color: .indigo) {
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        Text("Month").font(.caption2.weight(.semibold)).foregroundColor(.secondary).frame(width: 36, alignment: .leading)
                        Text("Won").font(.caption2.weight(.semibold)).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                        Text("Forecast").font(.caption2.weight(.semibold)).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                        Text("Deals").font(.caption2.weight(.semibold)).foregroundColor(.secondary).frame(width: 36, alignment: .trailing)
                    }
                    .padding(.bottom, 6)

                    Divider()

                    ForEach(months) { m in
                        let isCurrent = isCurrentMonth(m.month)
                        HStack {
                            Text(m.monthLabel)
                                .font(isCurrent ? .caption.weight(.bold) : .caption)
                                .foregroundColor(isCurrent ? .primary : .secondary)
                                .frame(width: 36, alignment: .leading)
                            Text(m.won > 0 ? currencyShort(m.won) : "—")
                                .font(.caption.weight(m.won > 0 ? .semibold : .regular))
                                .foregroundColor(m.won > 0 ? .green : .secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(m.forecast > 0 ? currencyShort(m.forecast) : "—")
                                .font(.caption)
                                .foregroundColor(m.forecast > 0 ? .blue : .secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(m.scheduledOpps > 0 ? "\(m.scheduledOpps)" : "—")
                                .font(.caption)
                                .foregroundColor(m.scheduledOpps > 0 ? .primary : .secondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                        .padding(.vertical, 5)
                        .background(isCurrent ? Color.blue.opacity(0.05) : Color.clear)

                        if m.id != months.last?.id {
                            Divider()
                        }
                    }
                }
            }

            // ── Upcoming deals (next 90 days) ────────────────────────���───────
            let upcoming = store.upcomingOpportunities
            if !upcoming.isEmpty {
                ReportCard(title: "Closing in 90 Days", icon: "calendar.badge.clock", color: .purple) {
                    VStack(spacing: 0) {
                        ForEach(Array(upcoming.prefix(8).enumerated()), id: \.offset) { idx, opp in
                            UpcomingDealRow(opp: opp, store: store)
                            if idx < min(upcoming.count, 8) - 1 {
                                Divider().padding(.leading, 0)
                            }
                        }
                        if upcoming.count > 8 {
                            Text("+\(upcoming.count - 8) more")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 8)
                        }
                    }
                }
            }

            // ── Set / edit annual target ─────────────────────────────────────
            Button {
                targetString = settings.annualRevenueTarget > 0
                    ? String(format: "%.0f", settings.annualRevenueTarget)
                    : ""
                showTargetSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "target")
                        .foregroundColor(.orange)
                    Text(annualTarget > 0 ? "Edit Annual Target" : "Set Annual Revenue Target")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showTargetSheet) {
            TargetEditSheet(targetString: $targetString) { value in
                settings.annualRevenueTarget = value
            }
        }
    }
}

// MARK: - Upcoming Deal Row

private struct UpcomingDealRow: View {
    let opp:   CRMOpportunity
    let store: AppStore

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    private var clientName: String {
        store.clients.first(where: { $0.id == opp.clientID })?.name ?? ""
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(opp.stage.color.opacity(0.12)).frame(width: 32, height: 32)
                Image(systemName: opp.stage.icon).font(.caption).foregroundColor(opp.stage.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(opp.title).font(.caption.weight(.medium)).lineLimit(1)
                Text(clientName).font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(currencyShort(opp.value)).font(.caption.weight(.semibold))
                if let start = opp.estimatedStart {
                    Text(Self.dateFmt.string(from: start))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Text("\(opp.probability)%")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(opp.stage.color.opacity(0.12))
                .foregroundColor(opp.stage.color)
                .cornerRadius(5)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Target Edit Sheet

private struct TargetEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var targetString: String
    let onSave: (Double) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Annual Revenue Target") {
                    HStack {
                        Text("$")
                        TextField("0", text: $targetString)
                            .keyboardType(.numberPad)
                    }
                    Text("Sets the monthly target line on the forecast chart.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section {
                    Button("Clear Target", role: .destructive) {
                        onSave(0)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Revenue Target")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(Double(targetString) ?? 0)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - KPI Row

private struct KPIRow: View {
    let store: AppStore
    let start: Date?
    let end: Date?

    private var won:       [CRMOpportunity] { store.wonOpportunities(from: start, to: end) }
    private var wonValue:  Decimal          { store.totalWonValue(from: start, to: end) }
    private var avgSize:   Decimal          { store.avgDealSize(from: start, to: end) }
    private var avgDays:   Double           { store.avgDaysToClose(from: start, to: end) }
    private var pipeline:  Decimal          { store.pipelineValue }
    private var winRate:   Double           { store.winRate(from: start, to: end) }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            KPITile(value: currencyShort(wonValue),
                    label: "Won Revenue",
                    icon: "checkmark.seal.fill",
                    color: .green)
            KPITile(value: "\(Int(winRate * 100))%",
                    label: "Win Rate",
                    icon: "chart.line.uptrend.xyaxis",
                    color: winRate >= 0.5 ? .green : winRate >= 0.3 ? .orange : .red)
            KPITile(value: currencyShort(pipeline),
                    label: "Open Pipeline",
                    icon: "dollarsign.circle.fill",
                    color: .blue)
            KPITile(value: "\(won.count)",
                    label: "Deals Closed",
                    icon: "trophy.fill",
                    color: .yellow)
            KPITile(value: currencyShort(avgSize),
                    label: "Avg Deal Size",
                    icon: "scalemass.fill",
                    color: .purple)
            KPITile(value: avgDays > 0 ? "\(Int(avgDays))d" : "—",
                    label: "Avg Days to Close",
                    icon: "clock.fill",
                    color: .indigo)
        }
        .padding(.horizontal, 16)
    }
}

private struct KPITile: View {
    let value: String
    let label: String
    let icon:  String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundColor(.primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
}

// MARK: - Pipeline Funnel Card

private struct PipelineFunnelCard: View {
    let store: AppStore

    private var data: [(stage: OpportunityStage, count: Int, value: Decimal)] {
        store.stageFunnelData()
    }

    var body: some View {
        ReportCard(title: "Pipeline Funnel", icon: "chart.bar.fill", color: .blue) {
            if data.isEmpty {
                emptyState("No open opportunities")
            } else {
                VStack(spacing: 0) {
                    Chart {
                        ForEach(data, id: \.stage) { row in
                            BarMark(
                                x: .value("Stage", row.stage.rawValue),
                                y: .value("Count", row.count)
                            )
                            .foregroundStyle(row.stage.color)
                            .cornerRadius(5)
                            .annotation(position: .top) {
                                Text("\(row.count)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks { _ in
                            AxisValueLabel()
                                .font(.caption2)
                        }
                    }
                    .chartYAxis { AxisMarks { _ in AxisGridLine() } }
                    .frame(height: 160)
                    .padding(.bottom, 8)

                    Divider()

                    // Value breakdown
                    ForEach(data, id: \.stage) { row in
                        HStack {
                            Circle().fill(row.stage.color).frame(width: 8, height: 8)
                            Text(row.stage.rawValue)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(row.count) opp\(row.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(currencyShort(row.value))
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.primary)
                                .frame(width: 64, alignment: .trailing)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
}

// MARK: - Win / Loss Card

private struct WinLossCard: View {
    let store: AppStore
    let start: Date?
    let end:   Date?

    private var won:    [CRMOpportunity] { store.wonOpportunities(from: start, to: end) }
    private var lost:   [CRMOpportunity] { store.lostOpportunities(from: start, to: end) }
    private var rate:   Double           { store.winRate(from: start, to: end) }
    private var wonVal: Decimal          { won.reduce(0)  { $0 + $1.value } }
    private var lostVal:Decimal          { lost.reduce(0) { $0 + $1.value } }

    var body: some View {
        ReportCard(title: "Win / Loss", icon: "chart.pie.fill", color: .green) {
            HStack(spacing: 24) {
                // Donut via ZStack
                ZStack {
                    Circle()
                        .stroke(Color.red.opacity(0.2), lineWidth: 16)
                        .frame(width: 90, height: 90)
                    Circle()
                        .trim(from: 0, to: rate)
                        .stroke(Color.green, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 90, height: 90)
                        .animation(.easeInOut(duration: 0.6), value: rate)
                    VStack(spacing: 0) {
                        Text("\(Int(rate * 100))%")
                            .font(.headline.weight(.bold))
                        Text("Won")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    WinLossRow(label: "Won", count: won.count, value: wonVal, color: .green)
                    WinLossRow(label: "Lost", count: lost.count, value: lostVal, color: .red)
                    Divider()
                    HStack {
                        Text("Total closed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(won.count + lost.count)")
                            .font(.caption.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 4)
        }
    }
}

private struct WinLossRow: View {
    let label: String
    let count: Int
    let value: Decimal
    let color: Color

    var body: some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .foregroundColor(color)
                .frame(width: 24, alignment: .trailing)
            Text(currencyShort(value))
                .font(.caption.weight(.semibold))
                .foregroundColor(.primary)
                .frame(width: 60, alignment: .trailing)
        }
    }
}

// MARK: - Revenue by Service Type

private struct RevenueByServiceCard: View {
    let store: AppStore
    let start: Date?
    let end:   Date?

    private var data: [(serviceType: String, value: Decimal)] {
        store.revenueByServiceType(from: start, to: end)
    }
    private var total: Decimal { data.reduce(0) { $0 + $1.value } }

    private let barColors: [Color] = [.blue, .purple, .teal, .indigo, .cyan, .orange]

    var body: some View {
        ReportCard(title: "Revenue by Service Type", icon: "wrench.and.screwdriver.fill", color: .purple) {
            if data.isEmpty {
                emptyState("No won deals in this period")
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(data.enumerated()), id: \.offset) { idx, row in
                        let pct = total > 0 ? NSDecimalNumber(decimal: row.value / total).doubleValue : 0
                        let color = barColors[idx % barColors.count]
                        VStack(spacing: 4) {
                            HStack {
                                Text(row.serviceType)
                                    .font(.caption)
                                    .foregroundColor(.primary)
                                Spacer()
                                Text(currencyShort(row.value))
                                    .font(.caption.weight(.semibold))
                                Text("(\(Int(pct * 100))%)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(color.opacity(0.15))
                                        .frame(height: 8)
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(color)
                                        .frame(width: geo.size.width * pct, height: 8)
                                        .animation(.easeInOut(duration: 0.5), value: pct)
                                }
                            }
                            .frame(height: 8)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Loss Reasons Card

private struct LossReasonsCard: View {
    let store: AppStore
    let start: Date?
    let end:   Date?

    private var data: [(reason: String, count: Int)] {
        store.lossesByReason(from: start, to: end)
    }
    private var total: Int { data.reduce(0) { $0 + $1.count } }

    private let colors: [Color] = [.red, .orange, .yellow, .gray, .pink, .brown]

    var body: some View {
        ReportCard(title: "Loss Reasons", icon: "xmark.circle.fill", color: .red) {
            if data.isEmpty {
                emptyState("No lost deals in this period")
            } else {
                Chart {
                    ForEach(Array(data.enumerated()), id: \.offset) { idx, row in
                        SectorMark(
                            angle: .value("Count", row.count),
                            innerRadius: .ratio(0.55),
                            angularInset: 2
                        )
                        .foregroundStyle(colors[idx % colors.count])
                        .annotation(position: .overlay) {
                            if Double(row.count) / Double(total) > 0.1 {
                                Text("\(row.count)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                }
                .frame(height: 140)
                .chartBackground { _ in
                    VStack(spacing: 2) {
                        Text("\(total)")
                            .font(.title3.weight(.bold))
                        Text("Lost")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                // Legend
                VStack(spacing: 6) {
                    ForEach(Array(data.enumerated()), id: \.offset) { idx, row in
                        HStack {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(colors[idx % colors.count])
                                .frame(width: 12, height: 12)
                            Text(row.reason)
                                .font(.caption)
                                .foregroundColor(.primary)
                            Spacer()
                            Text("\(row.count)")
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Lead Source Card

private struct LeadSourceCard: View {
    let store: AppStore
    let start: Date?
    let end:   Date?

    private var data: [(source: String, count: Int, value: Decimal)] {
        store.pipelineBySource(from: start, to: end)
    }

    private let colors: [Color] = [.blue, .green, .purple, .orange, .teal, .indigo, .pink]

    var body: some View {
        ReportCard(title: "Lead Sources", icon: "antenna.radiowaves.left.and.right", color: .teal) {
            if data.isEmpty {
                emptyState("No opportunities in this period")
            } else {
                VStack(spacing: 0) {
                    Chart {
                        ForEach(Array(data.enumerated()), id: \.offset) { idx, row in
                            BarMark(
                                x: .value("Value", NSDecimalNumber(decimal: row.value).doubleValue),
                                y: .value("Source", row.source)
                            )
                            .foregroundStyle(colors[idx % colors.count])
                            .cornerRadius(4)
                            .annotation(position: .trailing) {
                                Text("\(row.count)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks { val in
                            AxisValueLabel {
                                if let d = val.as(Double.self) {
                                    Text(currencyShort(Decimal(d)))
                                        .font(.caption2)
                                }
                            }
                            AxisGridLine()
                        }
                    }
                    .frame(height: CGFloat(data.count) * 38 + 20)
                }
            }
        }
    }
}

// MARK: - Reusable Report Card Shell

private struct ReportCard<Content: View>: View {
    let title:   String
    let icon:    String
    let color:   Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(color)
                Text(title)
                    .font(.headline)
            }
            content()
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(14)
        .padding(.horizontal, 16)
    }
}

private func emptyState(_ message: String) -> some View {
    Text(message)
        .font(.subheadline)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 20)
}
