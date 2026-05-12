// GanttView.swift
// Aski IQ — Phase 8 / Track 6 / Gantt v1 (read-only)
//
// Horizontal timeline of active projects. Each row shows a bar from
// the project's startDate to endDate; tap navigates into
// ProjectDetailView. Edits are out of scope for v1 — this is purely
// a visual aid for managers + executives planning capacity.
//
// Layout: a single horizontally-scrolling viewport with a vertical
// month axis at top and one project row underneath. The leftmost
// 140pt is reserved for the sticky project label column; the rest
// holds the bars. A vertical "today" line crosses every row so the
// current day is always visible.
//
// Scale: three zoom levels — week, month, quarter. Each picks a
// per-day pixel width tuned so a 6-month project still fits on a
// single iPad-Air screen at month zoom.

import SwiftUI

// MARK: - Public View

struct GanttView: View {
    @EnvironmentObject var store: AppStore
    @State private var scale: GanttScale = .month

    /// Active + on-hold + awarded projects with a valid date range.
    /// Completed/cancelled projects are intentionally excluded — they
    /// don't help anyone planning forward. Sorted by start date so
    /// the visual flows left → right naturally.
    private var visibleProjects: [Project] {
        store.projects
            .filter { !$0.isDeleted }
            .filter {
                $0.status == .active
                    || $0.status == .onHold
                    || $0.status == .awarded
            }
            .filter { $0.startDate != nil && $0.endDate != nil }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }

    /// Min / max date range covered by the visible projects, padded
    /// 1 unit on each side so bars don't kiss the chart edges.
    private var dateRange: ClosedRange<Date> {
        guard let first = visibleProjects.compactMap(\.startDate).min(),
              let last  = visibleProjects.compactMap(\.endDate).max() else {
            // Fallback: today ± 30 days. Keeps the chart drawing
            // even when the user has zero projects with date ranges.
            let cal = Calendar.current
            let lower = cal.date(byAdding: .day, value: -30, to: Date()) ?? Date()
            let upper = cal.date(byAdding: .day, value:  30, to: Date()) ?? Date()
            return lower...upper
        }
        let cal = Calendar.current
        let lower = cal.date(byAdding: scale.padding, value: -1, to: first) ?? first
        let upper = cal.date(byAdding: scale.padding, value:  1, to: last)  ?? last
        return lower...upper
    }

    private var totalDays: Int {
        let start = dateRange.lowerBound
        let end   = dateRange.upperBound
        return Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                scalePicker
                Divider()
                if visibleProjects.isEmpty {
                    emptyState
                } else {
                    chart
                }
            }
            .navigationTitle("Gantt")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Scale picker

    private var scalePicker: some View {
        Picker("Scale", selection: $scale) {
            ForEach(GanttScale.allCases, id: \.self) { s in
                Text(s.displayName).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: Chart

    private var chart: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(spacing: 0) {
                timelineHeader
                ForEach(visibleProjects) { project in
                    projectRow(project)
                    Divider()
                }
            }
            // Width = label column (140) + (days × scale.dayWidth)
            .frame(width: 140 + CGFloat(totalDays) * scale.dayWidth, alignment: .leading)
        }
    }

    private var timelineHeader: some View {
        HStack(spacing: 0) {
            // Spacer for the sticky label column.
            Color(.systemGray6)
                .frame(width: 140, height: 36)
                .overlay(alignment: .leading) {
                    Text("Project")
                        .font(.caption.bold())
                        .padding(.leading, 12)
                        .foregroundColor(.secondary)
                }
            // Timeline ticks — one label per "stride" interval (week
            // / month / quarter) at fixed pixel spacing.
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(.systemGray6))
                ForEach(tickDates, id: \.self) { date in
                    let x = pixelOffset(for: date)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(scale.tickLabel(for: date))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.leading, 4)
                        Spacer()
                        Rectangle()
                            .fill(Color(.systemGray3))
                            .frame(width: 1, height: 6)
                    }
                    .frame(width: scale.dayWidth * CGFloat(scale.daysPerTick), height: 36, alignment: .topLeading)
                    .offset(x: x)
                }
            }
            .frame(height: 36)
        }
    }

    private func projectRow(_ project: Project) -> some View {
        HStack(spacing: 0) {
            // Sticky label column
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                if !project.clientName.isEmpty {
                    Text(project.clientName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 140, height: 48, alignment: .leading)

            // Bar overlay
            ZStack(alignment: .topLeading) {
                Color.clear.frame(height: 48)
                if let s = project.startDate, let e = project.endDate {
                    let startX = pixelOffset(for: s)
                    let width  = max(8, pixelOffset(for: e) - startX)
                    NavigationLink {
                        ProjectDetailView(project: project)
                    } label: {
                        ganttBar(for: project)
                            .frame(width: width, height: 24)
                            .offset(x: startX, y: 12)
                    }
                    .buttonStyle(.plain)
                }
                // Today marker on every row so it stays visible while
                // the user scrolls vertically.
                todayLine
            }
        }
    }

    private func ganttBar(for project: Project) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(barColor(for: project.status))
            .overlay(
                Text(project.name)
                    .font(.caption2.bold())
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 6),
                alignment: .leading
            )
    }

    /// Status-driven bar colors — green for active, orange for hold,
    /// blue for awarded (signed but not yet started). Tracks the
    /// StatusBadge palette used elsewhere.
    private func barColor(for status: ProjectStatus) -> Color {
        switch status {
        case .active:    return .green
        case .onHold:    return .orange
        case .awarded:   return .blue
        case .tendering: return .gray
        case .completed: return .secondary
        case .cancelled: return .red
        }
    }

    private var todayLine: some View {
        Rectangle()
            .fill(Color.red.opacity(0.5))
            .frame(width: 1.5, height: 48)
            .offset(x: pixelOffset(for: Date()))
            .allowsHitTesting(false)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "calendar.day.timeline.left")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No projects on the timeline")
                .font(.headline)
            Text("Active and awarded projects with a start + end date show up here. Add dates from a project's detail screen to plot it.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Math helpers

    /// Days between two dates (no fractional). Negative if reversed.
    private func days(from a: Date, to b: Date) -> Int {
        Calendar.current.dateComponents([.day], from: a, to: b).day ?? 0
    }

    /// X offset for a given date, in points, relative to the bar
    /// region's left edge. The label column occupies the first 140pt
    /// but isn't part of this offset — the chart's HStack already
    /// places the label column to the left of the bar canvas.
    private func pixelOffset(for date: Date) -> CGFloat {
        CGFloat(days(from: dateRange.lowerBound, to: date)) * scale.dayWidth
    }

    /// Tick dates at the scale's interval — every Monday for week,
    /// 1st of each month for month, 1st of each quarter for quarter.
    private var tickDates: [Date] {
        var dates: [Date] = []
        let cal = Calendar.current
        var current = scale.alignedStart(of: dateRange.lowerBound, calendar: cal)
        while current <= dateRange.upperBound {
            dates.append(current)
            guard let next = cal.date(byAdding: scale.tickComponent,
                                      value: scale.tickValue,
                                      to: current) else { break }
            current = next
        }
        return dates
    }
}

// MARK: - Scale

enum GanttScale: CaseIterable, Hashable {
    case week, month, quarter

    var displayName: String {
        switch self {
        case .week:    return "Week"
        case .month:   return "Month"
        case .quarter: return "Quarter"
        }
    }

    /// Pixels per day at this zoom level. Tuned so a typical
    /// 6-month construction project comfortably fits on an iPad Air
    /// at the "month" default.
    var dayWidth: CGFloat {
        switch self {
        case .week:    return 18
        case .month:   return 6
        case .quarter: return 2
        }
    }

    /// How many days each tick on the timeline represents. Used to
    /// stride through the date range when laying out the header.
    var daysPerTick: Int {
        switch self {
        case .week:    return 7
        case .month:   return 30
        case .quarter: return 91
        }
    }

    var tickComponent: Calendar.Component {
        switch self {
        case .week:    return .weekOfYear
        case .month:   return .month
        case .quarter: return .month
        }
    }

    var tickValue: Int {
        switch self {
        case .week:    return 1
        case .month:   return 1
        case .quarter: return 3
        }
    }

    /// Padding component used when expanding `dateRange` so the
    /// chart's first/last bars don't touch the edges.
    var padding: Calendar.Component {
        switch self {
        case .week:    return .day
        case .month:   return .month
        case .quarter: return .month
        }
    }

    /// Snaps a date back to the start of the current tick interval,
    /// so labels align with sensible boundaries (Monday for week,
    /// 1st-of-month for month, etc).
    func alignedStart(of date: Date, calendar: Calendar) -> Date {
        let comps: Set<Calendar.Component>
        switch self {
        case .week:    comps = [.yearForWeekOfYear, .weekOfYear]
        case .month:   comps = [.year, .month]
        case .quarter: comps = [.year, .month]
        }
        return calendar.date(from: calendar.dateComponents(comps, from: date)) ?? date
    }

    func tickLabel(for date: Date) -> String {
        let fmt = DateFormatter()
        switch self {
        case .week:
            fmt.dateFormat = "MMM d"
        case .month:
            fmt.dateFormat = "MMM"
        case .quarter:
            let month = Calendar.current.component(.month, from: date)
            let q = ((month - 1) / 3) + 1
            let year = Calendar.current.component(.year, from: date)
            return "Q\(q) '\(year % 100)"
        }
        return fmt.string(from: date)
    }
}
