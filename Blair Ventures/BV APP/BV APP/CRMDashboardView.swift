// CRMDashboardView.swift
// BV APP – CRM Dashboard Tab

import SwiftUI
import Foundation

// MARK: - CRM Dashboard View

struct CRMDashboardView: View {
    @EnvironmentObject var store: AppStore

    @State private var showLeadIntake = false
    @State private var showTaskCreate = false
    @State private var selectedTask: CRMTask? = nil

    private func currency(_ d: Decimal) -> String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.locale = .current
        return f.string(from: d as NSDecimalNumber) ?? "$0"
    }

    // 2026-04 audit fix (Phase 9): all-time win/loss stats now route
    // through the canonical helpers on AppStore (`allWonOpportunities`,
    // `allLostOpportunities`, `wonValue(in:)`, `lostValue(in:)`,
    // `allTimeWinRate`) so this dashboard, CRMReportsView, and the
    // per-company stats all show the same number for the same metric.
    // Pre-fix each screen filtered crmOpportunities slightly differently.
    private var allWon:      [CRMOpportunity] { store.allWonOpportunities }
    private var allLost:     [CRMOpportunity] { store.allLostOpportunities }
    private var allWonValue: Decimal          { store.wonValue(in: store.crmOpportunities) }
    private var allLostValue: Decimal         { store.lostValue(in: store.crmOpportunities) }
    private var allTimeWinRate: Double        { store.allTimeWinRate }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {

                    // MARK: Overdue Warning Banner
                    if store.overdueCRMTasks.count > 0 {
                        OverdueBanner(count: store.overdueCRMTasks.count)
                    }

                    // MARK: Pipeline Summary
                    PipelineSummaryCard(
                        openCount:    store.openOpportunities.count,
                        pipelineValue: currency(store.pipelineValue),
                        weightedValue: currency(store.weightedPipelineValue),
                        winRate:      store.winRate,
                        wonCount:     store.wonThisMonth.count,
                        wonValue:     currency(store.wonThisMonth.reduce(0) { $0 + $1.value })
                    )

                    // MARK: Won / Lost Summary (all-time)
                    WonLostSummaryCard(
                        wonCount:    allWon.count,
                        wonValue:    currency(allWonValue),
                        lostCount:   allLost.count,
                        lostValue:   currency(allLostValue),
                        winRate:     allTimeWinRate
                    )

                    // MARK: Performance Snapshot
                    PerformanceSnapshotCard(
                        avgDealSize:    store.avgDealSize(),
                        avgDaysToClose: store.avgDaysToClose(),
                        monthForecast:  store.forecastForYear()
                            .first(where: {
                                Calendar.current.isDate($0.month, equalTo: Date(), toGranularity: .month)
                            })?.forecast ?? 0
                    )

                    // MARK: Stage Breakdown
                    VStack(alignment: .leading, spacing: 10) {
                        CRMDashSectionHeader(title: "Deals by Stage")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(OpportunityStage.allCases) { stage in
                                    StageCard(
                                        stage: stage,
                                        // Use allOpportunitiesByStage so Won/Lost cards show real data
                                        opportunities: store.allOpportunitiesByStage[stage] ?? []
                                    ) { currency($0) }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }

                    // MARK: Today's Tasks
                    VStack(alignment: .leading, spacing: 10) {
                        CRMDashSectionHeader(title: "Today's Tasks")

                        if store.todayCRMTasks.isEmpty {
                            EmptyStateCard(message: "No tasks due today")
                        } else {
                            VStack(spacing: 8) {
                                ForEach(store.todayCRMTasks) { task in
                                    TodayTaskRow(task: task, store: store)
                                        .onTapGesture { selectedTask = task }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }

                    // MARK: Recent Activity
                    VStack(alignment: .leading, spacing: 10) {
                        CRMDashSectionHeader(title: "Recent Activity")

                        if store.crmActivities.isEmpty {
                            EmptyStateCard(message: "No recent activity")
                        } else {
                            VStack(spacing: 8) {
                                ForEach(Array(store.crmActivities.prefix(5))) { activity in
                                    ActivityRow(activity: activity)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }

                    // MARK: Quick Actions
                    if store.currentUserRole.canEditCRM {
                        QuickActionsRow(
                            onNewLead: { showLeadIntake = true },
                            onAddTask: { showTaskCreate = true }
                        )
                    }

                    Spacer(minLength: 24)
                }
                .padding(.top, 8)
            }
            .background(Color(.systemGroupedBackground))
            // Pull-to-refresh re-runs the full sync pipeline + the CRM
            // outcome-timestamp backfill so the Performance Snapshot, Won /
            // Lost summaries and forecast cards reflect freshly pulled data.
            .refreshable {
                await store.refreshAll()
            }
            .navigationTitle("CRM Dashboard")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await store.refreshAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh CRM dashboard")
                }
            }
            .sheet(isPresented: $showLeadIntake) {
                LeadIntakeView()
                    .environmentObject(store)
            }
            .sheet(isPresented: $showTaskCreate) {
                CRMTaskCreateSheet(clientID: nil, opportunityID: nil)
                    .environmentObject(store)
            }
            .sheet(item: $selectedTask) { task in
                CRMTaskDetailSheet(task: task)
                    .environmentObject(store)
            }
        }
    }
}

// MARK: - Overdue Banner

private struct OverdueBanner: View {
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.white)
            Text("\(count) task\(count == 1 ? "" : "s") overdue")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.orange)
        .cornerRadius(12)
        .padding(.horizontal, 16)
    }
}

// MARK: - Pipeline Summary Card

private struct PipelineSummaryCard: View {
    let openCount: Int
    let pipelineValue: String
    let weightedValue: String
    let winRate: Double
    let wonCount: Int
    let wonValue: String

    var body: some View {
        VStack(spacing: 0) {
            // Top row: pipeline totals
            HStack(spacing: 0) {
                MetricCell(label: "Open Deals", value: "\(openCount)")
                Divider().frame(height: 50)
                MetricCell(label: "Pipeline", value: pipelineValue)
                Divider().frame(height: 50)
                MetricCell(label: "Weighted", value: weightedValue)
            }
            Divider()
            // Bottom row: won stats
            HStack(spacing: 0) {
                MetricCell(
                    label: "Win Rate (Mo)",
                    value: String(format: "%.0f%%", winRate * 100),
                    valueColor: winRate >= 0.5 ? .green : winRate > 0 ? .orange : .secondary
                )
                Divider().frame(height: 50)
                MetricCell(label: "Won (Mo)", value: "\(wonCount)")
                Divider().frame(height: 50)
                MetricCell(label: "Won Value", value: wonValue, valueColor: .green)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
        .padding(.horizontal, 16)
    }
}

private struct MetricCell: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline)
                .foregroundColor(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

// MARK: - Won / Lost Summary Card

private struct WonLostSummaryCard: View {
    let wonCount:  Int
    let wonValue:  String
    let lostCount: Int
    let lostValue: String
    let winRate:   Double

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "trophy.fill")
                    .foregroundColor(.green)
                Text("All-Time Results")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.0f%% win rate", winRate * 100))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(winRate >= 0.5 ? .green : winRate > 0 ? .orange : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            HStack(spacing: 0) {
                // Won column
                VStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                        Text("Won")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.green)
                    }
                    Text("\(wonCount)")
                        .font(.title2.weight(.bold))
                        .foregroundColor(.primary)
                    Text(wonValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)

                Divider().frame(height: 60)

                // Lost column
                VStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                        Text("Lost")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.red)
                    }
                    Text("\(lostCount)")
                        .font(.title2.weight(.bold))
                        .foregroundColor(.primary)
                    Text(lostValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)

                Divider().frame(height: 60)

                // Closed total
                VStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "archivebox.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Closed")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                    Text("\(wonCount + lostCount)")
                        .font(.title2.weight(.bold))
                        .foregroundColor(.primary)
                    Text("total deals")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
        .padding(.horizontal, 16)
    }
}

// MARK: - Stage Card

private struct StageCard: View {
    let stage: OpportunityStage
    let opportunities: [CRMOpportunity]
    let currency: (Decimal) -> String

    private var totalValue: Decimal {
        opportunities.reduce(0) { $0 + $1.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: stage.icon)
                    .font(.caption)
                    .foregroundColor(stage.color)
                Text(stage.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.primary)
            }
            Text("\(opportunities.count) deal\(opportunities.count == 1 ? "" : "s")")
                .font(.title3.weight(.bold))
                .foregroundColor(.primary)
            Text(currency(totalValue))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(width: 130)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(stage.color.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Today Task Row

private struct TodayTaskRow: View {
    let task: CRMTask
    let store: AppStore

    private var clientName: String {
        guard let cid = task.clientID else { return "" }
        return store.clients.first(where: { $0.id == cid })?.name ?? ""
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: task.priority.icon)
                .font(.subheadline)
                .foregroundColor(task.priority.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if !clientName.isEmpty {
                    Text(clientName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
    }
}

// MARK: - Activity Row

private struct ActivityRow: View {
    let activity: CRMActivity

    private static let relativeFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()

    private var relativeDate: String {
        Self.relativeFmt.localizedString(for: activity.date, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(activity.type.color.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: activity.type.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(activity.type.color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                Text(relativeDate)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
    }
}

// MARK: - Quick Actions Row

private struct QuickActionsRow: View {
    let onNewLead: () -> Void
    let onAddTask: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onNewLead) {
                Label("New Lead", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            Button(action: onAddTask) {
                Label("Add Task", systemImage: "checklist")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(.secondarySystemGroupedBackground))
                    .foregroundStyle(.tint)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - CRM Dashboard Inline View (no NavigationStack — for embedding in WidgetDashboard)

struct CRMDashboardInlineView: View {
    @EnvironmentObject var store: AppStore

    @State private var showLeadIntake = false
    @State private var showTaskCreate = false
    @State private var selectedTask: CRMTask? = nil

    private func currency(_ d: Decimal) -> String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.locale = .current
        return f.string(from: d as NSDecimalNumber) ?? "$0"
    }

    private var allWon:         [CRMOpportunity] { store.crmOpportunities.filter { $0.stage == .won  && !$0.isDeleted } }
    private var allLost:        [CRMOpportunity] { store.crmOpportunities.filter { $0.stage == .lost && !$0.isDeleted } }
    private var allWonValue:    Decimal          { allWon.reduce(0)  { $0 + $1.value } }
    private var allLostValue:   Decimal          { allLost.reduce(0) { $0 + $1.value } }
    private var allTimeWinRate: Double {
        let total = allWon.count + allLost.count
        guard total > 0 else { return 0 }
        return Double(allWon.count) / Double(total)
    }

    var body: some View {
        VStack(spacing: 20) {

            if store.overdueCRMTasks.count > 0 {
                OverdueBanner(count: store.overdueCRMTasks.count)
            }

            PipelineSummaryCard(
                openCount:     store.openOpportunities.count,
                pipelineValue: currency(store.pipelineValue),
                weightedValue: currency(store.weightedPipelineValue),
                winRate:       store.winRate,
                wonCount:      store.wonThisMonth.count,
                wonValue:      currency(store.wonThisMonth.reduce(0) { $0 + $1.value })
            )

            WonLostSummaryCard(
                wonCount:  allWon.count,
                wonValue:  currency(allWonValue),
                lostCount: allLost.count,
                lostValue: currency(allLostValue),
                winRate:   allTimeWinRate
            )

            // MARK: Performance Snapshot — avg deal size, days-to-close, month forecast
            PerformanceSnapshotCard(
                avgDealSize:    store.avgDealSize(),
                avgDaysToClose: store.avgDaysToClose(),
                monthForecast:  store.forecastForYear()
                    .first(where: {
                        Calendar.current.isDate($0.month, equalTo: Date(), toGranularity: .month)
                    })?.forecast ?? 0
            )

            VStack(alignment: .leading, spacing: 10) {
                CRMDashSectionHeader(title: "Deals by Stage")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(OpportunityStage.allCases) { stage in
                            StageCard(
                                stage: stage,
                                opportunities: store.allOpportunitiesByStage[stage] ?? []
                            ) { currency($0) }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                CRMDashSectionHeader(title: "Today's Tasks")
                if store.todayCRMTasks.isEmpty {
                    EmptyStateCard(message: "No tasks due today")
                } else {
                    VStack(spacing: 8) {
                        ForEach(store.todayCRMTasks) { task in
                            TodayTaskRow(task: task, store: store)
                                .onTapGesture { selectedTask = task }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                CRMDashSectionHeader(title: "Recent Activity")
                if store.crmActivities.isEmpty {
                    EmptyStateCard(message: "No recent activity")
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(store.crmActivities.prefix(5))) { activity in
                            ActivityRow(activity: activity)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            if store.currentUserRole.canEditCRM {
                QuickActionsRow(
                    onNewLead: { showLeadIntake = true },
                    onAddTask: { showTaskCreate = true }
                )
            }

            Spacer(minLength: 24)
        }
        .padding(.top, 8)
        .sheet(isPresented: $showLeadIntake) {
            LeadIntakeView().environmentObject(store)
        }
        .sheet(isPresented: $showTaskCreate) {
            CRMTaskCreateSheet(clientID: nil, opportunityID: nil).environmentObject(store)
        }
        .sheet(item: $selectedTask) { task in
            CRMTaskDetailSheet(task: task).environmentObject(store)
        }
    }
}

// MARK: - Reusable Helpers

private struct CRMDashSectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundColor(.primary)
            .padding(.horizontal, 16)
    }
}

private struct EmptyStateCard: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.subheadline)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .padding(.horizontal, 16)
    }
}

// MARK: - Performance Snapshot Card

/// Three-metric KPI strip: average deal size, average days-to-close, this-month forecast.
private struct PerformanceSnapshotCard: View {
    let avgDealSize:    Decimal
    let avgDaysToClose: Double
    let monthForecast:  Decimal

    private func currency(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle       = .currency
        f.maximumFractionDigits = 0
        f.locale            = .current
        return f.string(from: d as NSDecimalNumber) ?? "$0"
    }

    private var avgDaysText: String {
        avgDaysToClose > 0 ? "\(Int(avgDaysToClose))d" : "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Performance Snapshot")
                .font(.headline)
                .padding(.horizontal, 16)

            HStack(spacing: 0) {
                SnapMetric(
                    icon:    "dollarsign.circle.fill",
                    color:   .green,
                    label:   "Avg Deal",
                    value:   avgDealSize > 0 ? currency(avgDealSize) : "—"
                )
                Divider().frame(height: 40)
                SnapMetric(
                    icon:    "clock.fill",
                    color:   .blue,
                    label:   "Avg Close",
                    value:   avgDaysText
                )
                Divider().frame(height: 40)
                SnapMetric(
                    icon:    "chart.line.uptrend.xyaxis",
                    color:   .purple,
                    label:   "Month Fcst",
                    value:   monthForecast > 0 ? currency(monthForecast) : "—"
                )
            }
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .padding(.horizontal, 16)
        }
    }
}

private struct SnapMetric: View {
    let icon:  String
    let color: Color
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(color)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
