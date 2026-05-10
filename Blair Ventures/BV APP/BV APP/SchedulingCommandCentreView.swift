// SchedulingCommandCentreView.swift
// Aski IQ — Phase A. Scheduling redesign landing surface.
//
// PURPOSE
// Answer the question "what work needs my attention right now?"
// instead of the old answer ("here is your calendar"). The four
// sections below let an office user, in roughly this order:
//
//   1. See work that needs to be scheduled (Section 1)
//   2. See what's running today (Section 2)
//   3. See what's broken or risky (Section 3)
//   4. See who's available to take new work (Section 4)
//
// SCOPE — PHASE A
//   • Additive — does NOT replace the calendar or dispatch board.
//   • Reachable from a prominent banner card on ScheduleCalendarView.
//   • Reuses NeedsSchedulingService (computed list, no DB changes).
//   • Reuses store.liveScheduleConflicts (existing detector output).
//   • Reuses ScheduleEntryCreateEditView with the new ScheduleSourceContext
//     parameter for one-tap Schedule from any Section 1 card.
//
// NOT PHASE A — DELIBERATELY DEFERRED
//   • Smart crew assignment categorization (Recommended/Available/Busy/
//     Not Qualified) — Phase D.
//   • Calendar-as-default removal — Phase B.
//   • Dispatch board 4-bucket simplification — Phase C.
//   • Field worker landing page — Phase E.

import SwiftUI

struct SchedulingCommandCentreView: View {
    @EnvironmentObject var store: AppStore

    /// Sheet routing for "Schedule" CTAs from Section 1 cards.
    @State private var schedulingTarget: ScheduleSourceContext? = nil
    /// Sheet routing for "edit shift" taps in Section 2.
    @State private var editingEntry: SchedulingEntryPick? = nil
    /// Sheet for resolving a conflict tapped in Section 3.
    @State private var conflictTarget: SchedulingConflictPick? = nil
    /// SR-1: review screen for an AI/rules recommendation.
    @State private var reviewTarget: ScheduleRecommendation? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section1NeedsScheduling
                aiSuggestionsSection
                section2Today
                section3Issues
                section4CrewAvailability
                Spacer(minLength: 32)
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .navigationTitle("Command Centre")
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $schedulingTarget) { ctx in
            // Route into the existing schedule editor with everything
            // we know prefilled. The user reviews and confirms — they
            // never have to retype known data.
            NavigationStack {
                ScheduleEntryCreateEditView(
                    preselectedDate: ctx.suggestedDate ?? Date(),
                    preselectedCrewID: ctx.suggestedCrewID,
                    sourceContext: ctx
                )
                .environmentObject(store)
            }
        }
        .sheet(item: $editingEntry) { pick in
            NavigationStack {
                ScheduleEntryCreateEditView(existing: pick.entry)
                    .environmentObject(store)
            }
        }
        .sheet(item: $conflictTarget) { pick in
            ConflictResolutionSheet(conflict: pick.conflict)
                .environmentObject(store)
        }
        .sheet(item: $reviewTarget) { rec in
            ScheduleRecommendationReviewView(recommendation: rec)
                .environmentObject(store)
        }
    }

    // MARK: - Section 1: Needs Scheduling

    private var section1NeedsScheduling: some View {
        let items = store.needsSchedulingItems
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                title: "Needs Scheduling",
                icon: "tray.full.fill",
                accent: .orange,
                count: items.count,
                hint: "Work that's ready for a schedule decision."
            )
            if items.isEmpty {
                EmptyHint(message: "Nothing waiting. Accepted quotes, active projects, material sales, and approved change orders will appear here when they need scheduling.")
            } else {
                VStack(spacing: 8) {
                    ForEach(items) { item in
                        NeedsSchedulingCard(
                            item: item,
                            onSchedule: {
                                guard store.canEditSchedule else {
                                    ToastService.shared.error("You don't have permission to schedule.")
                                    return
                                }
                                schedulingTarget = item.sourceContext
                            },
                            // SR-1: only project-anchored items get the
                            // "Generate Plan" CTA. Quote-without-project
                            // and rentals fall back to the manual
                            // Schedule path until SR-3 extends the engine.
                            onGeneratePlan: item.projectID != nil
                                ? { generatePlan(for: item) }
                                : nil
                        )
                    }
                }
            }
        }
    }

    // MARK: - SR-1: AI Schedule Suggestions
    //
    // Shows recommendations awaiting review. Hidden when the queue
    // is empty so the Command Centre stays uncluttered for users
    // who haven't generated any plans yet. Each card opens the
    // review screen on tap; only PM+ users get the actionable Approve
    // / Reject buttons inside.

    private var aiSuggestionsSection: some View {
        let pending = store.scheduleRecommendations
            .filter { $0.status.isInQueue }
            .sorted { $0.createdAt > $1.createdAt }
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                title: "AI Schedule Suggestions",
                icon: "sparkles",
                accent: .purple,
                count: pending.count,
                hint: pending.isEmpty
                    ? "Tap the purple Generate Plan button on any project above. The AI scans the next 14 days for free crews and individual workers, then proposes a schedule for your review."
                    : "Generated plans awaiting your review."
            )
            if pending.isEmpty {
                EmptyHint(message: "No pending plans. Generate Plan looks at gaps in your current schedule, finds the best available crew or individual worker, and drafts a plan — it won't go live until a manager approves.")
            } else {
                VStack(spacing: 8) {
                    ForEach(pending) { rec in
                        RecommendationQueueCard(recommendation: rec) {
                            reviewTarget = rec
                        }
                    }
                }
            }
        }
    }

    /// SR-1: invoked by Section 1 cards' "Generate Plan" CTA.
    /// Builds a recommendation via the engine and routes the user
    /// straight into the review screen so they don't have to hunt
    /// for the AI section after generating.
    fileprivate func generatePlan(for item: NeedsSchedulingItem) {
        guard store.canEditSchedule else {
            ToastService.shared.error("You don't have permission to generate schedule plans.")
            return
        }
        guard let rec = ScheduleRecommendationEngine.recommend(
            for: item.sourceContext,
            in: store,
            requestedBy: store.currentUser?.id
        ) else {
            ToastService.shared.warning("Can't generate a plan yet — link this work to a project first.")
            return
        }
        store.upsertScheduleRecommendation(rec)
        // Route to review immediately. The recommendation is also
        // visible in the AI Suggestions section for later access.
        reviewTarget = rec
    }

    // MARK: - Section 2: Scheduled Today

    private var section2Today: some View {
        let entries = store.todayScheduleEntries
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                title: "Scheduled Today",
                icon: "sun.max.fill",
                accent: .blue,
                count: entries.count,
                hint: nil
            )
            if entries.isEmpty {
                EmptyHint(message: "No shifts scheduled for today.")
            } else {
                VStack(spacing: 8) {
                    ForEach(entries) { entry in
                        TodayShiftCard(
                            entry: entry,
                            onTap: {
                                editingEntry = SchedulingEntryPick(id: entry.id, entry: entry)
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Section 3: Conflicts / Risks

    private var section3Issues: some View {
        let issues = store.commandCentreIssues()
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                title: "Conflicts / Risks",
                icon: "exclamationmark.triangle.fill",
                accent: .red,
                count: issues.totalCount,
                hint: nil
            )
            if issues.totalCount == 0 {
                EmptyHint(message: "No live issues. Acknowledged conflicts are hidden.")
            } else {
                VStack(spacing: 8) {
                    ForEach(issues.conflicts) { conflict in
                        ConflictIssueCard(
                            conflict: conflict,
                            onTap: {
                                guard store.canEditSchedule else { return }
                                conflictTarget = SchedulingConflictPick(
                                    id: conflict.stableKey,
                                    conflict: conflict
                                )
                            }
                        )
                    }
                    ForEach(issues.missing) { issue in
                        MissingDataCard(
                            issue: issue,
                            onTap: {
                                guard store.canEditSchedule else { return }
                                editingEntry = SchedulingEntryPick(
                                    id: issue.entry.id,
                                    entry: issue.entry
                                )
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Section 4: Assignment Availability (RA-4)
    //
    // Shows BOTH crews and individually-assigned workers under one
    // section. Crews always show — even at zero workload they answer
    // "who could I assign?" Workers only show when they have at least
    // one direct assignment this week (custom_crew or
    // individual_worker shifts) — pure crew members are represented
    // through their crew's row to avoid double-counting.

    private var section4CrewAvailability: some View {
        let crewRows   = store.crewAvailabilitySnapshot
        let workerRows = store.workerAvailabilitySnapshot
        let total      = crewRows.count + workerRows.count
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                title: "Assignment Availability",
                icon: "person.3.fill",
                accent: .indigo,
                count: total,
                hint: "Who can take work this week."
            )
            if total == 0 {
                EmptyHint(message: "No active crews or workers. Add a crew or assign a worker to see availability.")
            } else {
                VStack(spacing: 8) {
                    if !crewRows.isEmpty {
                        availabilitySubHeader(label: "Crews", count: crewRows.count)
                        VStack(spacing: 6) {
                            ForEach(crewRows) { row in
                                CrewAvailabilityCard(row: row)
                            }
                        }
                    }
                    if !workerRows.isEmpty {
                        availabilitySubHeader(label: "Individual workers", count: workerRows.count)
                        VStack(spacing: 6) {
                            ForEach(workerRows) { row in
                                WorkerAvailabilityCard(row: row)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func availabilitySubHeader(label: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(label.uppercased())
                .font(.caption2.bold())
                .foregroundColor(.secondary)
                .tracking(0.5)
            Text("\(count)")
                .font(.caption2.bold())
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - Section header

    @ViewBuilder
    private func sectionHeader(title: String, icon: String, accent: Color, count: Int, hint: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(accent)
            Text(title)
                .font(.title3.bold())
            Text("\(count)")
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(count > 0 ? accent : Color.secondary)
                .clipShape(Capsule())
            Spacer()
        }
        if let hint {
            Text(hint)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 2)
        }
    }
}

// MARK: - Sheet item wrappers

private struct SchedulingEntryPick: Identifiable {
    let id: UUID
    let entry: ScheduleEntry
}

private struct SchedulingConflictPick: Identifiable {
    let id: String
    let conflict: ScheduleConflict
}

// MARK: - Section 1 card

private struct NeedsSchedulingCard: View {
    let item: NeedsSchedulingItem
    let onSchedule: () -> Void
    /// SR-1: optional "Generate Plan" CTA. Provided only for items
    /// the recommendation engine can act on (project-anchored).
    /// nil for non-project items — they keep the manual Schedule path.
    let onGeneratePlan: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: item.sourceType.icon)
                    .foregroundColor(.blue)
                Text(item.sourceType.label.uppercased())
                    .font(.caption2.bold())
                    .foregroundColor(.blue)
                Spacer()
                if let date = item.suggestedDate {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Text(item.title)
                .font(.subheadline.bold())
                .lineLimit(2)
            VStack(alignment: .leading, spacing: 2) {
                if let client = item.clientName, !client.isEmpty {
                    Label(client, systemImage: "building.2")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let site = item.siteAddress, !site.isEmpty {
                    Label(site, systemImage: "mappin")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if let work = item.workType {
                    Label(work, systemImage: "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if !item.warnings.isEmpty {
                HStack(spacing: 6) {
                    ForEach(item.warnings, id: \.self) { warning in
                        HStack(spacing: 4) {
                            Image(systemName: warning.icon)
                                .font(.caption2)
                            Text(warning.label)
                                .font(.caption2)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .foregroundColor(.orange)
                        .clipShape(Capsule())
                    }
                }
            }
            HStack(spacing: 8) {
                Button(action: onSchedule) {
                    HStack {
                        Image(systemName: "calendar.badge.plus")
                        Text("Schedule")
                            .font(.subheadline.bold())
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                // SR-1: AI route — only shown when the engine can
                // produce a plan from this source. Tap routes through
                // the engine and opens the review screen.
                if let onGeneratePlan {
                    Button(action: onGeneratePlan) {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                            Text("Generate Plan")
                                .font(.subheadline.bold())
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.purple.opacity(0.15))
                        .foregroundColor(.purple)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Generate AI schedule plan")
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
}

// MARK: - Section 2 card

private struct TodayShiftCard: View {
    let entry: ScheduleEntry
    let onTap: () -> Void
    @EnvironmentObject var store: AppStore

    private var project: Project? { store.projects.first(where: { $0.id == entry.projectID }) }
    private var crew: Crew? { entry.crewID.flatMap { cid in store.crews.first(where: { $0.id == cid }) } }
    /// RA-3: foreman comes from the entry directly (custom_crew override)
    /// or the crew (fixed_crew). Individual_worker mode → no foreman.
    private var foreman: Employee? {
        if let f = entry.foremanID {
            return store.employees.first(where: { $0.id == f })
        }
        return crew?.foremanID.flatMap { fid in store.employees.first(where: { $0.id == fid }) }
    }
    private var inLiveConflict: Bool {
        store.liveScheduleConflicts.contains { c in
            c.affectedEntries.contains(where: { $0.id == entry.id })
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                statusStripe
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if inLiveConflict {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        Text(timeRangeLabel)
                            .font(.subheadline.bold())
                        Spacer()
                        Text(entry.status.displayLabel.uppercased())
                            .font(.caption2.bold())
                            .foregroundColor(statusColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(statusColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    Text(project?.name ?? "Unknown Project")
                        .font(.caption.bold())
                        .lineLimit(1)
                    HStack(spacing: 12) {
                        // RA-3: render via assignment helper so custom_crew
                        // and individual_worker shifts show the right label.
                        Label(entry.assignmentLabel(crews: store.crews, employees: store.employees),
                              systemImage: entry.assignmentIconName)
                            .font(.caption2)
                            .foregroundColor(entry.hasNoResources ? .orange : .secondary)
                        if let f = foreman {
                            Label(f.fullName, systemImage: "star.fill")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private var statusStripe: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(statusColor)
            .frame(width: 4)
            .frame(maxHeight: .infinity)
    }

    private var statusColor: Color {
        switch entry.status {
        case .scheduled:   return .blue
        case .inProgress:  return .green
        case .completed:   return .gray
        case .cancelled:   return .red
        case .rescheduled: return .orange
        }
    }

    private var timeRangeLabel: String {
        switch (entry.shiftStart, entry.shiftEnd) {
        case let (s?, e?):
            return "\(s.formatted(date: .omitted, time: .shortened))–\(e.formatted(date: .omitted, time: .shortened))"
        case let (s?, nil):
            return s.formatted(date: .omitted, time: .shortened)
        case (nil, _):
            return "All day"
        }
    }
}

// MARK: - Section 3 cards

private struct ConflictIssueCard: View {
    let conflict: ScheduleConflict
    let onTap: () -> Void
    @EnvironmentObject var store: AppStore

    private var color: Color {
        switch conflict.conflictType {
        case .crewDoubleBooked, .employeeDoubleBooked, .certificationMissing:
            return .red
        case .projectOverlap, .travelBuffer:
            return .orange
        case .weekendWork, .overtimeRisk:
            return .yellow
        }
    }

    private var recommendation: String? {
        // Phase A: a one-line "what to do" summary based on conflict
        // type. Phase D will compute a real "use Crew X instead"
        // recommendation via CrewRecommendationService.
        switch conflict.conflictType {
        case .crewDoubleBooked:
            return "Reassign one shift to a free crew, or move it to a different day."
        case .employeeDoubleBooked:
            return "Move one of the affected shifts to a different day."
        case .travelBuffer:
            return "Shift the second shift's start time to allow travel."
        case .certificationMissing:
            return "Reassign to a crew that holds the required certification, or add the cert to a member."
        case .overtimeRisk:
            return "Spread the work across additional crews to stay under threshold."
        case .projectOverlap:
            return "Confirm the project is available on this date or move the shift."
        case .weekendWork:
            return "Confirm weekend work is approved, or reschedule to a weekday."
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: conflict.conflictType.icon)
                            .foregroundColor(color)
                        Text(conflict.conflictType.severity.uppercased())
                            .font(.caption2.bold())
                            .foregroundColor(color)
                        Spacer()
                        Text(conflict.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text(conflict.description)
                        .font(.subheadline)
                        .lineLimit(3)
                    if let rec = recommendation {
                        Text("Suggested fix: \(rec)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}

private struct MissingDataCard: View {
    let issue: MissingDataIssue
    let onTap: () -> Void
    @EnvironmentObject var store: AppStore

    private var projectName: String {
        store.projects.first(where: { $0.id == issue.entry.projectID })?.name ?? "Unknown Project"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.orange)
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: issue.kind.icon)
                            .foregroundColor(.orange)
                        Text("MISSING DATA")
                            .font(.caption2.bold())
                            .foregroundColor(.orange)
                        Spacer()
                        Text(issue.entry.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text("\(issue.kind.label) — \(projectName)")
                        .font(.subheadline)
                        .lineLimit(2)
                    Text("Suggested fix: \(issue.kind.recommendation)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Section 4 card

// MARK: - RA-4: Individual-worker availability card
//
// Renders the same way as CrewAvailabilityCard for visual consistency.
// Differs only in the secondary line (trade vs. foreman) and the
// leading icon — single person glyph instead of crew glyph.

private struct WorkerAvailabilityCard: View {
    let row: WorkerAvailabilityRow

    private var bucketColor: Color {
        switch row.bucket {
        case .available:    return .green
        case .busy:         return .blue
        case .atRisk:       return .orange
        case .notQualified: return .secondary
        }
    }

    private var loadFraction: Double {
        guard row.weekThreshold > 0 else { return 0 }
        return min(row.weekHours / row.weekThreshold, 1.2)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(bucketColor)
                .frame(width: 4, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "person.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(row.workerName)
                        .font(.subheadline.bold())
                    if row.inLiveConflict {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                }
                if let trade = row.trade, !trade.isEmpty {
                    Text(trade)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.bucket.label)
                    .font(.caption2.bold())
                    .foregroundColor(bucketColor)
                Text("\(String(format: "%.1f", row.weekHours)) / \(String(format: "%.0f", row.weekThreshold))h")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if row.weekThreshold > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.18))
                            Capsule()
                                .fill(bucketColor)
                                .frame(width: geo.size.width * CGFloat(min(loadFraction, 1.0)))
                        }
                    }
                    .frame(width: 80, height: 4)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(10)
    }
}

private struct CrewAvailabilityCard: View {
    let row: CrewAvailabilityRow

    private var bucketColor: Color {
        switch row.bucket {
        case .available:    return .green
        case .busy:         return .blue
        case .atRisk:       return .orange
        case .notQualified: return .secondary
        }
    }

    private var loadFraction: Double {
        guard row.weekThreshold > 0 else { return 0 }
        return min(row.weekHours / row.weekThreshold, 1.2)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(bucketColor)
                .frame(width: 4, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.crewName)
                        .font(.subheadline.bold())
                    if row.inLiveConflict {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                }
                if let f = row.foremanName {
                    Text("Foreman: \(f)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.bucket.label)
                    .font(.caption2.bold())
                    .foregroundColor(bucketColor)
                Text("\(String(format: "%.1f", row.weekHours)) / \(String(format: "%.0f", row.weekThreshold))h")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if let frac = row.weekThreshold > 0 ? Optional(loadFraction) : nil {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.18))
                            Capsule()
                                .fill(bucketColor)
                                .frame(width: geo.size.width * CGFloat(min(frac, 1.0)))
                        }
                    }
                    .frame(width: 80, height: 4)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(10)
    }
}

// MARK: - SR-1: Recommendation queue card

private struct RecommendationQueueCard: View {
    let recommendation: ScheduleRecommendation
    let onTap: () -> Void
    @EnvironmentObject var store: AppStore

    private var projectName: String {
        recommendation.projectID.flatMap { id in
            store.projects.first(where: { $0.id == id })?.name
        } ?? "Project"
    }

    /// Resource label for the recommendation. Handles the three
    /// assignment shapes the engine can produce:
    ///   • fixedCrew → crew name
    ///   • individualWorker → worker name + "(individual)"
    ///   • customCrew → "N workers" (engine doesn't currently emit
    ///     custom crews; included for completeness)
    private var resourceLabel: String {
        guard let first = recommendation.proposedEntries.first else { return "—" }
        switch first.assignmentMode {
        case .fixedCrew:
            return first.crewID
                .flatMap { cid in store.crews.first(where: { $0.id == cid })?.name }
                ?? "—"
        case .individualWorker:
            guard let workerID = first.assignedWorkerIDs.first,
                  let emp = store.employees.first(where: { $0.id == workerID }) else {
                return "—"
            }
            return "\(emp.fullName) (individual)"
        case .customCrew:
            let n = first.assignedWorkerIDs.count
            return "\(n) worker\(n == 1 ? "" : "s")"
        }
    }

    private var resourceIcon: String {
        guard let first = recommendation.proposedEntries.first else { return "person.2.fill" }
        switch first.assignmentMode {
        case .fixedCrew:        return "person.2.fill"
        case .individualWorker: return "person.fill"
        case .customCrew:       return "person.3.sequence.fill"
        }
    }

    private var dayCount: Int { recommendation.proposedEntries.count }

    private var riskColor: Color {
        if recommendation.risks.contains(where: { $0.severity == .high }) { return .red }
        if recommendation.risks.contains(where: { $0.severity == .medium }) { return .orange }
        if !recommendation.risks.isEmpty { return .yellow }
        return .green
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundColor(.purple)
                    Text(projectName)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Spacer()
                    // SR-β: surface "Needs Revision" prominently for
                    // sent-back plans so the requester / senior approver
                    // notices it in the queue. Otherwise show confidence.
                    if recommendation.status == .revisionRequested {
                        Text("NEEDS REVISION")
                            .font(.caption2.bold())
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                    } else {
                        Text("\(Int(recommendation.confidenceScore * 100))%")
                            .font(.caption2.bold())
                            .foregroundColor(.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                Text(recommendation.summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                HStack(spacing: 12) {
                    Label(resourceLabel, systemImage: resourceIcon)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Label("\(dayCount) day\(dayCount == 1 ? "" : "s")",
                          systemImage: "calendar")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Label(recommendation.riskLabel, systemImage: "shield.lefthalf.filled")
                        .font(.caption2.bold())
                        .foregroundColor(riskColor)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SR-1: Recommendation Review Sheet

struct ScheduleRecommendationReviewView: View {
    let recommendation: ScheduleRecommendation
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var rejectionReason: String = ""
    @State private var showRejectAlert = false
    /// SR-β: send-back flow state.
    @State private var revisionNotes: String = ""
    @State private var showSendBackAlert = false
    /// SR-γ: high-risk override flow state.
    @State private var overrideReason: String = ""
    @State private var showHighRiskOverrideAlert = false
    @State private var resultMessage: String? = nil
    @State private var resultIsError = false

    /// SR-γ: only manager / executive can approve a high-risk plan.
    private var canOverrideHighRisk: Bool {
        let role = store.currentUserRole
        return role == .manager || role == .executive
    }

    private var canApprove: Bool {
        store.canPerform(action: .scheduleApproveRecommendation) && recommendation.isActionable
    }

    var body: some View {
        NavigationStack {
            Form {
                summarySection
                // SR-β: surface reviewer's notes prominently when the
                // plan is in revision-requested state. The requester
                // re-opens the plan, sees what the manager flagged,
                // and can revise. Stays visible (read-only) on
                // subsequent approvals so the audit trail is intact.
                if recommendation.status == .revisionRequested,
                   let notes = recommendation.reviewNotes,
                   !notes.isEmpty {
                    revisionNotesCallout(notes: notes)
                }
                proposedShiftsSection
                if !recommendation.risks.isEmpty {
                    risksSection
                }
                if !recommendation.alternatives.isEmpty {
                    alternativesSection
                }
                reasoningSection
                if let msg = resultMessage {
                    Section {
                        Label(msg, systemImage: resultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundColor(resultIsError ? .red : .green)
                    }
                }
                if recommendation.isActionable {
                    actionsSection
                } else {
                    statusSection
                }
            }
            .navigationTitle("Schedule Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.bold()
                }
            }
            .alert("Reject this plan?", isPresented: $showRejectAlert) {
                TextField("Optional reason", text: $rejectionReason)
                Button("Cancel", role: .cancel) { }
                Button("Reject", role: .destructive) {
                    store.rejectScheduleRecommendation(recommendation, reason: rejectionReason.isEmpty ? nil : rejectionReason)
                    resultMessage = "Plan rejected. No schedule entries were created."
                    resultIsError = false
                }
            } message: {
                Text("No schedule entries will be created. The decision is logged.")
            }
            .alert("Override high-risk conflicts?", isPresented: $showHighRiskOverrideAlert) {
                TextField("Reason (required)", text: $overrideReason)
                Button("Cancel", role: .cancel) {
                    overrideReason = ""
                }
                Button("Approve Anyway", role: .destructive) {
                    let trimmed = overrideReason.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        resultMessage = "Override needs a reason. Try again."
                        resultIsError = true
                        return
                    }
                    applyApprove(overrideReason: trimmed)
                    overrideReason = ""
                }
            } message: {
                Text("This plan has \(recommendation.highRiskCount) high-risk conflict\(recommendation.highRiskCount == 1 ? "" : "s"). Your reason is logged to the audit trail.")
            }
            .alert("Send this plan back for revision?", isPresented: $showSendBackAlert) {
                TextField("What needs to change?", text: $revisionNotes)
                Button("Cancel", role: .cancel) { }
                Button("Send Back") {
                    let trimmed = revisionNotes.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        resultMessage = "Send Back needs a note explaining what to change."
                        resultIsError = true
                        return
                    }
                    store.requestScheduleRecommendationRevision(recommendation, notes: trimmed)
                    resultMessage = "Sent back. The requester will see your notes."
                    resultIsError = false
                    revisionNotes = ""
                }
            } message: {
                Text("Adds your notes to the plan so the requester can revise and resubmit.")
            }
        }
        .presentationDetents([.large])
    }

    // MARK: Subsections

    @ViewBuilder
    private func revisionNotesCallout(notes: String) -> some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.title3)
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("REVIEWER REQUESTED CHANGES")
                        .font(.caption2.bold())
                        .foregroundColor(.orange)
                    Text(notes)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    if let when = recommendation.rejectedAt {
                        Text("Sent back \(when.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("Needs Revision")
        }
    }

    private var summarySection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundColor(.purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text(recommendation.summary)
                        .font(.subheadline)
                    HStack(spacing: 12) {
                        Label("\(Int(recommendation.confidenceScore * 100))% confidence",
                              systemImage: "gauge.medium")
                            .font(.caption)
                            .foregroundColor(.purple)
                        Label(recommendation.status.displayLabel,
                              systemImage: "tag")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("AI Recommendation")
        }
    }

    private var proposedShiftsSection: some View {
        Section {
            ForEach(recommendation.proposedEntries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.subheadline.bold())
                        Spacer()
                        if let s = entry.shiftStart, let e = entry.shiftEnd {
                            Text("\(s.formatted(date: .omitted, time: .shortened))–\(e.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    // RA-3 / SR-1 gap-aware: proposed entry can be
                    // fixed_crew (crew name) or individual_worker
                    // (worker name). Show the right label per mode.
                    switch entry.assignmentMode {
                    case .fixedCrew:
                        if let crewID = entry.crewID,
                           let crew = store.crews.first(where: { $0.id == crewID }) {
                            Label(crew.name, systemImage: "person.2.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    case .individualWorker:
                        if let workerID = entry.assignedWorkerIDs.first,
                           let emp = store.employees.first(where: { $0.id == workerID }) {
                            Label(emp.fullName, systemImage: "person.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    case .customCrew:
                        let names = entry.assignedWorkerIDs
                            .compactMap { id in store.employees.first(where: { $0.id == id })?.fullName }
                            .joined(separator: ", ")
                        if !names.isEmpty {
                            Label(names, systemImage: "person.3.sequence.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if let task = entry.taskDescription, !task.isEmpty {
                        Text(task)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if !entry.requiredCertifications.isEmpty {
                        Label(entry.requiredCertifications.joined(separator: " · "),
                              systemImage: "checkmark.shield")
                            .font(.caption2)
                            .foregroundColor(.indigo)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Proposed shifts (\(recommendation.proposedEntries.count))")
        }
    }

    private var risksSection: some View {
        Section {
            ForEach(recommendation.risks) { risk in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: severityIcon(risk.severity))
                        .foregroundColor(severityColor(risk.severity))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(risk.severity.rawValue.uppercased())
                            .font(.caption2.bold())
                            .foregroundColor(severityColor(risk.severity))
                        Text(risk.message)
                            .font(.caption)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Risks (\(recommendation.risks.count))")
        }
    }

    private var alternativesSection: some View {
        Section {
            ForEach(recommendation.alternatives) { alt in
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.swap")
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.crews.first(where: { $0.id == alt.crewID })?.name ?? "Crew")
                            .font(.subheadline)
                        Text(alt.reason)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("Alternative crews")
        } footer: {
            Text("Edit Before Approving lets you swap to one of these.")
                .font(.caption)
        }
    }

    private var reasoningSection: some View {
        Section {
            Text(recommendation.reasoning)
                .font(.caption)
                .foregroundColor(.secondary)
        } header: {
            Text("Why this recommendation")
        }
    }

    private var actionsSection: some View {
        Section {
            // SR-γ: high-risk plans require Manager/Exec + reason.
            // Approve button label adapts so the user knows what's
            // about to happen ("Acknowledge Conflicts & Approve" vs
            // plain "Approve & Publish").
            let isHighRisk = recommendation.requiresHighRiskOverride
            let approveDisabled = !canApprove
                || recommendation.proposedEntries.isEmpty
                || (isHighRisk && !canOverrideHighRisk)
            Button {
                if isHighRisk {
                    showHighRiskOverrideAlert = true
                } else {
                    applyApprove()
                }
            } label: {
                Label(
                    isHighRisk ? "Acknowledge Conflicts & Approve" : "Approve & Publish",
                    systemImage: isHighRisk ? "exclamationmark.shield.fill" : "checkmark.seal.fill"
                )
                .font(.subheadline.bold())
                .foregroundColor(isHighRisk ? .red : .accentColor)
            }
            .disabled(approveDisabled)
            // SR-β: Send Back is the middle ground between approve and
            // reject — keeps the plan in the queue so the requester
            // (or a senior approver) can address the notes and try
            // again, without throwing away the AI's work.
            Button {
                showSendBackAlert = true
            } label: {
                Label("Send Back", systemImage: "arrow.uturn.backward.circle")
                    .font(.subheadline.bold())
            }
            .disabled(!canApprove)
            Button(role: .destructive) {
                showRejectAlert = true
            } label: {
                Label("Reject", systemImage: "xmark.seal")
                    .font(.subheadline.bold())
            }
            .disabled(!canApprove)
        } header: {
            Text("Decide")
        } footer: {
            if !canApprove {
                Text("Only PMs and managers can approve. You can still review the plan.")
                    .font(.caption)
            } else if recommendation.proposedEntries.isEmpty {
                Text("This plan has no proposed shifts. Reject and regenerate after fixing the upstream issue.")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if recommendation.requiresHighRiskOverride && !canOverrideHighRisk {
                // SR-γ: explain why approve is disabled even though
                // the role is normally allowed.
                Text("This plan has \(recommendation.highRiskCount) high-risk conflict\(recommendation.highRiskCount == 1 ? "" : "s"). Only Manager or Executive can approve it. Send Back or Reject is still available.")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if recommendation.requiresHighRiskOverride {
                Text("This plan has high-risk conflicts. Approving requires a written override reason for the audit log.")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else {
                Text("Approving creates real schedule entries. The audit log records who approved and when.")
                    .font(.caption)
            }
        }
    }

    private var statusSection: some View {
        Section {
            HStack {
                Image(systemName: terminalIcon(recommendation.status))
                    .foregroundColor(terminalColor(recommendation.status))
                Text(recommendation.status.displayLabel)
                    .font(.subheadline.bold())
                Spacer()
                if let when = recommendation.approvedAt ?? recommendation.rejectedAt ?? recommendation.appliedAt {
                    Text(when.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if let reason = recommendation.rejectionReason, !reason.isEmpty {
                Text("Reason: \(reason)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            // SR-γ: surface override reason + approval mode for the
            // audit trail. Anyone reading the recommendation post-
            // approval sees who approved AND under what authority.
            if let mode = recommendation.approvalMode {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                        .foregroundColor(.purple)
                        .font(.caption)
                    Text("Approval mode: \(mode.displayLabel)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if let override = recommendation.overrideReason, !override.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("HIGH-RISK OVERRIDE")
                        .font(.caption2.bold())
                        .foregroundColor(.red)
                    Text(override)
                        .font(.caption)
                        .foregroundColor(.primary)
                }
            }
        } header: {
            Text("Status")
        }
    }

    // MARK: Apply

    private func applyApprove(overrideReason: String? = nil) {
        let conflicts = store.applyScheduleRecommendation(
            recommendation,
            overrideReason: overrideReason
        )
        if conflicts.isEmpty {
            resultMessage = "Plan approved. \(recommendation.proposedEntries.count) shift\(recommendation.proposedEntries.count == 1 ? "" : "s") created."
            resultIsError = false
        } else {
            resultMessage = "\(conflicts.count) shift\(conflicts.count == 1 ? "" : "s") flagged conflicts and weren't created. Review and use Schedule Anyway from the Issues section if needed."
            resultIsError = true
        }
    }

    // MARK: Helpers

    private func severityColor(_ s: ScheduleRisk.Severity) -> Color {
        switch s {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .yellow
        }
    }

    private func severityIcon(_ s: ScheduleRisk.Severity) -> String {
        switch s {
        case .high:   return "exclamationmark.triangle.fill"
        case .medium: return "exclamationmark.triangle"
        case .low:    return "info.circle"
        }
    }

    private func terminalIcon(_ status: ScheduleRecommendationStatus) -> String {
        switch status {
        case .approved, .editedAndApproved: return "checkmark.seal.fill"
        case .applied:                       return "checkmark.circle.fill"
        case .rejected:                      return "xmark.seal.fill"
        case .cancelled:                     return "slash.circle"
        default:                             return "tag"
        }
    }

    private func terminalColor(_ status: ScheduleRecommendationStatus) -> Color {
        switch status {
        case .approved, .editedAndApproved, .applied: return .green
        case .rejected, .cancelled:                    return .red
        default:                                        return .secondary
        }
    }
}

// MARK: - Empty hint cell

private struct EmptyHint: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.tertiarySystemGroupedBackground))
            .cornerRadius(10)
    }
}
