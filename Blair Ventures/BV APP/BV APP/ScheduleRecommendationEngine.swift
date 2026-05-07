// ScheduleRecommendationEngine.swift
// Aski IQ — Phase SR-1 Smart Scheduling (gap-aware, RA-1/2/3 aligned).
//
// PURPOSE
// Produces a `ScheduleRecommendation` from a source work item. The
// engine is gap-aware: instead of trusting the source's suggestedDate
// blindly, it scans the next 14 days, builds a per-resource calendar,
// and picks the resource (crew OR individual worker) with the best
// match of free days vs. work to do.
//
// CONTRACT
//   Input:  a ScheduleSourceContext (already produced by Phase A's
//           NeedsSchedulingService)
//   Output: a ScheduleRecommendation with status=.pendingReview,
//           ready to upsert into the queue.
//
// WHAT'S NEW (vs. the v1 SR-1 engine)
//   1. Considers BOTH crews AND individual workers as candidates.
//      For small tasks (1-2 days) an individual worker often fits
//      better than a full crew. The engine emits the right
//      assignmentMode (.fixedCrew or .individualWorker) accordingly.
//
//   2. Looks at GAPS in the schedule. Each candidate gets a 14-day
//      availability map (using RA-2's effectiveWorkerIDs so crew
//      members count their crew shifts AND their direct assignments).
//      The candidate with the most free days starting from the
//      suggested date wins.
//
//   3. Proposed shifts land on the candidate's actually-free days,
//      not on the source's suggestedDate (which may be busy). Falls
//      back to suggestedDate if the candidate has no free days in
//      the window — flagged with high-severity risk.
//
//   4. Reasoning explains the gap analysis: "Crew B is free Tue, Wed,
//      Thu in the next 7 days." Manager sees the calendar context
//      that drove the recommendation.
//
// SCORING
//   +30 — availability covers the requested days exactly
//   +15 — partial availability (covers some days)
//    -25 — no availability in window
//   +30 — last-used on this project (historical fit)
//   +15 — qualified (carries all required certs)
//    -50 — missing required certs (penalty, still scored as fallback)
//   +10 — workload below 50% of OT threshold this week
//    -10 — workload at 80%+
//    -25 — workload over 100%
//   Workers vs. crews: workers eligible only for tasks ≤ 2 days
//   (configurable); for longer work, only crews are scored.

import Foundation

enum ScheduleRecommendationEngine {

    // MARK: - Config

    /// Near-term scan window — used to find ANY available crew or
    /// worker without much waiting. 14 days = 2 weeks of lookahead.
    private static let availabilityWindowDays = 14

    /// Extended scan horizon — used when a SPECIFIC resource is
    /// preferred (last-used on this project, or eventually a
    /// hard-pinned resource from the estimate/quote labor plan)
    /// AND that resource has no free window in the near-term scan.
    /// 60 days lets the engine push proposed dates out to the first
    /// real availability instead of forcing the work onto busy days.
    private static let extendedWindowDays = 60

    /// An individual worker is eligible only for tasks ≤ this many
    /// days. Beyond that, work is large enough that a crew is the
    /// more appropriate unit. Tunable.
    private static let maxWorkerOnlyDays = 2

    // MARK: - Public entry point

    /// Build a recommendation for the given source. Considers both
    /// crews and individual workers with calendar gaps in the
    /// availability window.
    static func recommend(
        for context: ScheduleSourceContext,
        in store: AppStore,
        requestedBy userID: UUID? = nil
    ) -> ScheduleRecommendation? {
        guard let projectID = context.projectID else {
            return nil
        }
        let project = store.project(id: projectID)
        let workType = context.workType ?? "Kickoff"

        // SR-1.4: pull the take-off labor plan from the project (or
        // an empty plan if not specified). The plan declares what
        // the work needs; the engine assembles ANY valid combination
        // of resources to satisfy it — fixed crew, custom crew, or
        // single individual worker.
        let labor = (project?.laborPlan ?? LaborRequirement()).normalized()

        // When a labor plan is set, route through the labor-aware
        // pathway. Empty plans fall through to the legacy "find best
        // resource" logic for back-compat with quotes / projects that
        // pre-date take-off planning.
        if !labor.isEmpty {
            return recommendFromLaborPlan(
                labor: labor,
                context: context,
                project: project,
                projectID: projectID,
                userID: userID,
                workType: workType,
                store: store
            )
        }

        let estimatedDays = estimateDays(for: context, project: project)
        let suggestedStart = context.suggestedStartTime ?? defaultStart(on: context.suggestedDate ?? Date())
        let suggestedEnd   = context.suggestedEndTime   ?? defaultEnd(on: context.suggestedDate ?? Date())
        let baseDate = context.suggestedDate ?? Date()
        let windowStart = Calendar.current.startOfDay(for: baseDate)
        let windowEnd = Calendar.current.date(byAdding: .day, value: availabilityWindowDays - 1, to: windowStart) ?? windowStart

        // Step 1: Build availability maps for every candidate resource
        // (crews AND eligible individual workers).
        let candidates = buildCandidates(
            store: store,
            estimatedDays: estimatedDays,
            requiredCerts: context.requiredCertifications,
            windowStart: windowStart,
            windowEnd: windowEnd
        )

        // Step 2: Score each candidate.
        let scored = candidates.map { c -> ScoredCandidate in
            let score = scoreCandidate(
                c,
                context: context,
                estimatedDays: estimatedDays,
                store: store
            )
            return ScoredCandidate(candidate: c, score: score)
        }
        .sorted { $0.score.total > $1.score.total }

        // Step 3: Pick the winner.
        //
        // SR-1 follow-up: when the source context pins a specific crew
        // (via Quote.preferredCrewID → Project.preferredCrewID set
        // during take-off), force that crew as the winner — even if
        // they don't have the highest pure score. This matches the
        // user's intent: "if specific people or crews are required,
        // push the start date forward, don't substitute a different
        // crew." The extended-horizon window-finder below then
        // searches up to 60 days for a viable date range.
        let pinnedWinner: ScoredCandidate? = {
            guard let suggestedCrewID = context.suggestedCrewID else { return nil }
            return scored.first { sc in
                if case .crew(let c) = sc.candidate.resource, c.id == suggestedCrewID {
                    return true
                }
                return false
            }
        }()
        guard let winner = pinnedWinner ?? scored.first else {
            return blockedRecommendation(
                for: context,
                projectID: projectID,
                userID: userID,
                store: store,
                summary: "No active crews or workers to recommend.",
                reasoning: "Add or activate at least one crew or worker, then regenerate this plan."
            )
        }

        // Step 4: Build proposed entries on the winner's actually-free
        // days. If the winner has fewer free days than estimatedDays
        // in the near-term window AND it's a strongly-preferred
        // resource (last-used on this project / pinned via the
        // source context), expand the horizon and find the first
        // contiguous stretch where they ARE free. The work pushes
        // forward instead of squeezing into busy days.
        let isPreferredResource = winner.score.lastUsed
            || (sourceCrewIDMatches(winner.candidate, context: context))
        let extendedAvail: Availability? = {
            guard isPreferredResource else { return nil }
            guard winner.candidate.availability.availableDays.count < estimatedDays else { return nil }
            let extEnd = Calendar.current.date(
                byAdding: .day,
                value: extendedWindowDays - 1,
                to: windowStart
            ) ?? windowEnd
            return computeAvailability(
                for: winner.candidate.resource,
                store: store,
                windowStart: windowStart,
                windowEnd: extEnd
            )
        }()

        let proposed = buildProposedEntries(
            winner: winner,
            extendedAvail: extendedAvail,
            projectID: projectID,
            estimatedDays: estimatedDays,
            windowStart: windowStart,
            windowEnd: windowEnd,
            workType: workType,
            siteAddress: context.siteAddress,
            costCode: context.costCode,
            requiredCerts: context.requiredCertifications,
            suggestedStart: suggestedStart,
            suggestedEnd: suggestedEnd
        )

        // Step 5: Probe for conflicts (reuse ScheduleConflictService —
        // single source of truth for "would this clash with anything?").
        let probeRisks = probeConflicts(proposed: proposed, store: store)

        // Step 6: Build alternatives — top 2 unwinning candidates.
        let alternatives = scored.dropFirst().prefix(2).compactMap { sc -> ScheduleAlternative? in
            switch sc.candidate.resource {
            case .crew(let crew):
                let freeDays = sc.candidate.availability.availableDays.count
                return ScheduleAlternative(
                    crewID: crew.id,
                    reason: "Crew alt — \(freeDays) free day\(freeDays == 1 ? "" : "s") in next 2 weeks."
                )
            case .worker:
                // Alternatives currently store crew_id only (DB schema).
                // Worker alternatives surface inline in the reasoning
                // instead. SR-2 may extend the alternatives shape.
                return nil
            }
        }

        // Step 7: Confidence + summary + reasoning.
        let confidence = computeConfidence(risks: probeRisks, score: winner.score)
        let summary = buildSummary(
            project: project,
            winner: winner,
            days: estimatedDays,
            risks: probeRisks
        )
        let reasoning = buildReasoning(
            winner: winner,
            estimatedDays: estimatedDays,
            risks: probeRisks,
            scored: scored,
            extendedAvail: extendedAvail,
            proposedDates: proposed.map { $0.date },
            requestedStart: windowStart
        )

        var rec = ScheduleRecommendation(
            id: UUID(),
            companyID: store.currentCompanyID ?? UUID(),
            sourceType: mapSourceType(context.sourceType),
            sourceID: context.sourceID,
            projectID: projectID,
            recommendationType: "project_kickoff_schedule",
            createdByAI: true,
            requestedByUserID: userID,
            status: .pendingReview,
            confidenceScore: confidence,
            summary: summary,
            reasoning: reasoning,
            risks: probeRisks,
            alternatives: Array(alternatives),
            proposedEntries: proposed
        )
        rec.createdAt = Date()
        rec.updatedAt = Date()
        return rec
    }

    // MARK: - Resource model

    /// A schedulable resource — either a standing crew or an individual
    /// worker. The engine treats both uniformly during scoring; the
    /// only branch is at proposed-entry generation, which emits the
    /// right assignmentMode.
    private enum Resource {
        case crew(Crew)
        case worker(Employee)
    }

    /// Daily-hours map + free-day list for one candidate over the
    /// availability window.
    private struct Availability {
        /// startOfDay → total scheduled hours for this resource on that day.
        /// Built from `effectiveWorkerIDs`-aware filtering so a worker
        /// who's on Crew A counts their crew shifts AND any direct
        /// assignments. A crew counts all its shifts.
        let dailyHours: [Date: Double]
        /// Days within the window with zero scheduled hours.
        let availableDays: [Date]
        /// Total scheduled hours in the window (used by scoring).
        let totalScheduledHours: Double
    }

    private struct Candidate {
        let resource: Resource
        let availability: Availability
        let isQualified: Bool
        /// True if this resource is eligible for this assignment shape
        /// (e.g. workers blocked from multi-day if maxWorkerOnlyDays
        /// is exceeded). Filtered out before scoring.
        let isEligible: Bool

        var displayName: String {
            switch resource {
            case .crew(let c):    return c.name
            case .worker(let e):  return e.fullName
            }
        }
    }

    private struct CandidateScore {
        var total: Int
        var availabilityScore: Int
        var lastUsed: Bool
        var qualified: Bool
        var workloadHours: Double
        var workloadPenalty: Int
        /// True when the candidate has at least one free day in the
        /// window — drives confidence.
        var hasAnyFreeDay: Bool
    }

    private struct ScoredCandidate {
        let candidate: Candidate
        let score: CandidateScore
    }

    // MARK: - Candidates

    private static func buildCandidates(
        store: AppStore,
        estimatedDays: Int,
        requiredCerts: [String],
        windowStart: Date,
        windowEnd: Date
    ) -> [Candidate] {
        var out: [Candidate] = []
        let requiredSet = Set(requiredCerts.map { $0.lowercased() })

        // Crews — always eligible.
        let crews = store.crews.filter { $0.isActive && !$0.isDeleted }
        for crew in crews {
            let avail = computeAvailability(
                for: .crew(crew),
                store: store,
                windowStart: windowStart,
                windowEnd: windowEnd
            )
            let qualified = isCrewQualified(crew, requiredCerts: requiredSet, store: store)
            out.append(Candidate(
                resource: .crew(crew),
                availability: avail,
                isQualified: qualified,
                isEligible: true
            ))
        }

        // Individual workers — eligible only for short jobs.
        // For longer jobs, a crew is the right unit; flooding the
        // candidate list with every worker for a 5-day project is
        // noise.
        if estimatedDays <= maxWorkerOnlyDays {
            let employees = store.employees.filter { $0.isActive && !$0.isDeleted }
            for emp in employees {
                let avail = computeAvailability(
                    for: .worker(emp),
                    store: store,
                    windowStart: windowStart,
                    windowEnd: windowEnd
                )
                let qualified = isWorkerQualified(emp, requiredCerts: requiredSet)
                out.append(Candidate(
                    resource: .worker(emp),
                    availability: avail,
                    isQualified: qualified,
                    isEligible: true
                ))
            }
        }

        return out
    }

    /// Compute the per-day scheduled-hours map for a resource over the
    /// window. Reuses the same "is this entry on this resource?" rule
    /// as the conflict detector so what the engine considers "busy"
    /// matches what the conflict detector flags.
    private static func computeAvailability(
        for resource: Resource,
        store: AppStore,
        windowStart: Date,
        windowEnd: Date
    ) -> Availability {
        let cal = Calendar.current
        let crewByID = Dictionary(uniqueKeysWithValues: store.crews.map { ($0.id, $0) })
        var dailyHours: [Date: Double] = [:]

        for entry in store.scheduleEntries {
            guard !entry.isDeleted, entry.status != .cancelled else { continue }
            let day = cal.startOfDay(for: entry.date)
            guard day >= windowStart, day <= windowEnd else { continue }
            // Does this entry involve our resource?
            let workersOnEntry = effectiveWorkerIDs(for: entry, crewByID: crewByID)
            let belongs: Bool
            switch resource {
            case .crew(let c):
                // Resource is the crew — entry counts if it's directly
                // on this crew (fixed_crew with crewID == c.id), OR if
                // any of the crew's members are involved (custom crew
                // pulling members).
                if entry.crewID == c.id { belongs = true }
                else {
                    let members = Set(c.memberIDs + (c.foremanID.map { [$0] } ?? []))
                    belongs = !members.isDisjoint(with: workersOnEntry)
                }
            case .worker(let emp):
                belongs = workersOnEntry.contains(emp.id)
            }
            guard belongs else { continue }
            let hours = estimateEntryHours(entry)
            dailyHours[day, default: 0] += hours
        }

        // Build availableDays — every day in [start, end] with zero hours.
        var available: [Date] = []
        var totalScheduled: Double = 0
        var cursor = windowStart
        while cursor <= windowEnd {
            let scheduled = dailyHours[cursor] ?? 0
            if scheduled <= 0 {
                // Skip Sundays (most common no-work day) unless the user
                // has work on a Sunday already, which signals weekends
                // are fair game.
                let weekday = cal.component(.weekday, from: cursor)
                if weekday != 1 {  // 1 = Sunday
                    available.append(cursor)
                }
            }
            totalScheduled += scheduled
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
        }

        return Availability(
            dailyHours: dailyHours,
            availableDays: available,
            totalScheduledHours: totalScheduled
        )
    }

    /// Mirror of ScheduleConflictService.effectiveWorkerIDs for use
    /// inside the engine. Kept private rather than promoting the
    /// service helper to fileprivate-shared, because the engine and
    /// conflict service have different test surfaces.
    private static func effectiveWorkerIDs(
        for entry: ScheduleEntry,
        crewByID: [UUID: Crew]
    ) -> Set<UUID> {
        var ids: Set<UUID> = Set(entry.assignedWorkerIDs)
        if entry.assignedWorkerIDs.isEmpty,
           let crewID = entry.crewID,
           let crew = crewByID[crewID] {
            ids.formUnion(crew.memberIDs)
            if let f = crew.foremanID { ids.insert(f) }
        }
        if let f = entry.foremanID { ids.insert(f) }
        return ids
    }

    // MARK: - Scoring

    private static func scoreCandidate(
        _ candidate: Candidate,
        context: ScheduleSourceContext,
        estimatedDays: Int,
        store: AppStore
    ) -> CandidateScore {
        var total = 0

        // Availability — the new headline factor.
        let freeDays = candidate.availability.availableDays.count
        let availabilityScore: Int = {
            if freeDays >= estimatedDays { return 30 }   // covers the work
            if freeDays > 0              { return 15 }   // partial
            return -25                                   // none
        }()
        total += availabilityScore

        // Last-used signal. Only meaningful for crews (workers can be
        // "last used" individually but the data signal is noisier).
        var lastUsed = false
        switch candidate.resource {
        case .crew(let crew):
            lastUsed = (context.suggestedCrewID == crew.id)
                || (store.scheduleEntries.contains {
                    !$0.isDeleted
                    && $0.projectID == context.projectID
                    && $0.crewID == crew.id
                })
        case .worker(let emp):
            // For workers: were they on a previous shift on this
            // project (regardless of crew context)?
            let crewByID = Dictionary(uniqueKeysWithValues: store.crews.map { ($0.id, $0) })
            lastUsed = store.scheduleEntries.contains { e in
                !e.isDeleted
                && e.projectID == context.projectID
                && effectiveWorkerIDs(for: e, crewByID: crewByID).contains(emp.id)
            }
        }
        if lastUsed { total += 30 }

        // Cert qualification.
        let required = !context.requiredCertifications.isEmpty
        if required {
            if candidate.isQualified { total += 15 } else { total -= 50 }
        }

        // Workload — sum hours scheduled this week (not the full window).
        let weekStart = startOfCurrentWeek()
        let weekEnd   = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let weekHours = candidate.availability.dailyHours
            .filter { $0.key >= weekStart && $0.key <= weekEnd }
            .reduce(0.0) { $0 + $1.value }

        let threshold = AppSettings.shared.overtimeWeeklyThresholdHours
        var workloadPenalty = 0
        if threshold > 0 {
            if weekHours >= threshold {
                workloadPenalty = -25
            } else if weekHours >= threshold * 0.8 {
                workloadPenalty = -10
            } else if weekHours < threshold * 0.5 {
                workloadPenalty = 10
            }
        }
        total += workloadPenalty

        return CandidateScore(
            total: total,
            availabilityScore: availabilityScore,
            lastUsed: lastUsed,
            qualified: candidate.isQualified || !required,
            workloadHours: weekHours,
            workloadPenalty: workloadPenalty,
            hasAnyFreeDay: freeDays > 0
        )
    }

    /// True when at least one crew member (including foreman) carries
    /// every required cert.
    private static func isCrewQualified(
        _ crew: Crew,
        requiredCerts: Set<String>,
        store: AppStore
    ) -> Bool {
        guard !requiredCerts.isEmpty else { return true }
        var memberIDs = crew.memberIDs
        if let f = crew.foremanID, !memberIDs.contains(f) {
            memberIDs.append(f)
        }
        for empID in memberIDs {
            guard let emp = store.employees.first(where: { $0.id == empID && $0.isActive }) else {
                continue
            }
            let held = Set(emp.certifications.map { $0.lowercased() })
            if requiredCerts.isSubset(of: held) { return true }
        }
        return false
    }

    /// True when the worker carries every required cert.
    private static func isWorkerQualified(_ emp: Employee, requiredCerts: Set<String>) -> Bool {
        guard !requiredCerts.isEmpty else { return true }
        let held = Set(emp.certifications.map { $0.lowercased() })
        return requiredCerts.isSubset(of: held)
    }

    // MARK: - Proposed entries

    /// Build proposed entries on the winner's actually-free days.
    ///
    /// Date-picking strategy:
    ///   1. If `extendedAvail` is provided (preferred-resource case)
    ///      AND it contains a contiguous stretch of `estimatedDays`
    ///      free days, use the FIRST such stretch — pushes the
    ///      proposed start to the first real availability instead
    ///      of forcing the work onto busy days.
    ///   2. Otherwise use the first N free days from the near-term
    ///      window.
    ///   3. If still short, top up with sequential days from the
    ///      window start (conflict probe will flag busy ones).
    private static func buildProposedEntries(
        winner: ScoredCandidate,
        extendedAvail: Availability?,
        projectID: UUID,
        estimatedDays: Int,
        windowStart: Date,
        windowEnd: Date,
        workType: String,
        siteAddress: String?,
        costCode: String?,
        requiredCerts: [String],
        suggestedStart: Date,
        suggestedEnd: Date
    ) -> [ProposedScheduleEntry] {
        let cal = Calendar.current
        var dates: [Date] = []

        // 1. Extended-window first-fit: try to find a contiguous
        // stretch of free days big enough for the whole job. Falls
        // back if no such stretch exists or extendedAvail is nil.
        if let ext = extendedAvail,
           let stretch = firstContiguousStretch(of: estimatedDays,
                                                in: ext.availableDays,
                                                calendar: cal) {
            dates = stretch
        }

        // 2. Near-term free days (limited to estimatedDays). Used
        // when no extended window OR extended search found nothing.
        if dates.isEmpty {
            dates = Array(winner.candidate.availability.availableDays.prefix(estimatedDays))
        }

        // 3. Top up with sequential days if still short. The conflict
        // probe will flag any busy ones.
        if dates.count < estimatedDays {
            var cursor = windowStart
            while dates.count < estimatedDays && cursor <= windowEnd {
                if !dates.contains(cursor) {
                    dates.append(cursor)
                }
                cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
            }
        }
        // Final guard.
        if dates.isEmpty { dates = [windowStart] }

        // Generate entries.
        var out: [ProposedScheduleEntry] = []
        for day in dates {
            let dayStart = applyTimeOfDay(suggestedStart, to: day)
            let dayEnd   = applyTimeOfDay(suggestedEnd, to: day)
            var entry = ProposedScheduleEntry(
                projectID: projectID,
                crewID: nil,
                assignedWorkerIDs: [],
                foremanID: nil,
                assignmentMode: .fixedCrew,
                date: day,
                shiftStart: dayStart,
                shiftEnd: dayEnd,
                taskDescription: workType,
                costCode: costCode,
                location: siteAddress,
                requiredCertifications: requiredCerts,
                estimatedHours: hoursBetween(dayStart, dayEnd) ?? 8,
                notes: nil
            )
            switch winner.candidate.resource {
            case .crew(let crew):
                entry.crewID = crew.id
                entry.assignmentMode = .fixedCrew
            case .worker(let emp):
                entry.crewID = nil
                entry.assignedWorkerIDs = [emp.id]
                entry.assignmentMode = .individualWorker
            }
            out.append(entry)
        }
        return out
    }

    // MARK: - Probe

    private static func probeConflicts(
        proposed: [ProposedScheduleEntry],
        store: AppStore
    ) -> [ScheduleRisk] {
        var phantoms: [ScheduleEntry] = []
        for p in proposed {
            var phantom = ScheduleEntry(projectID: p.projectID, date: p.date)
            phantom.id = p.id
            phantom.crewID = p.crewID
            phantom.assignedWorkerIDs = p.assignedWorkerIDs
            phantom.foremanID = p.foremanID
            phantom.assignmentMode = p.assignmentMode
            phantom.shiftStart = p.shiftStart
            phantom.shiftEnd = p.shiftEnd
            phantom.requiredCertifications = p.requiredCertifications
            phantoms.append(phantom)
        }

        let pool = store.scheduleEntries.filter { !$0.isDeleted } + phantoms
        let conflicts = ScheduleConflictService.detect(
            in: pool,
            projects: store.projects,
            crews: store.crews,
            employees: store.employees,
            travelBufferMinutes: AppSettings.shared.travelBufferMinutes,
            overtimeWeeklyThresholdHours: AppSettings.shared.overtimeWeeklyThresholdHours
        )
        let phantomIDs = Set(phantoms.map { $0.id })
        let relevant = conflicts.filter { c in
            c.affectedEntries.contains { phantomIDs.contains($0.id) }
        }
        return relevant.map { conflict in
            ScheduleRisk(
                type: String(describing: conflict.conflictType),
                severity: severityForConflictType(conflict.conflictType),
                message: conflict.description
            )
        }
    }

    private static func severityForConflictType(_ type: ScheduleConflict.ConflictType) -> ScheduleRisk.Severity {
        switch type {
        case .crewDoubleBooked, .employeeDoubleBooked, .certificationMissing:
            return .high
        case .projectOverlap, .travelBuffer:
            return .medium
        case .weekendWork, .overtimeRisk:
            return .low
        }
    }

    // MARK: - Confidence

    private static func computeConfidence(risks: [ScheduleRisk], score: CandidateScore) -> Double {
        // Risk-driven floor.
        var base: Double
        if risks.contains(where: { $0.severity == .high }) { base = 0.45 }
        else if risks.contains(where: { $0.severity == .medium }) { base = 0.65 }
        else if risks.contains(where: { $0.severity == .low }) { base = 0.85 }
        else { base = 1.0 }
        // Lower confidence if the winning resource had no free days.
        if !score.hasAnyFreeDay { base = min(base, 0.55) }
        return base
    }

    // MARK: - Summary / reasoning

    private static func buildSummary(
        project: Project?,
        winner: ScoredCandidate,
        days: Int,
        risks: [ScheduleRisk]
    ) -> String {
        let projName = project?.name ?? "this project"
        let dayPhrase = days == 1 ? "1 day" : "\(days) days"
        let resourcePhrase: String = {
            switch winner.candidate.resource {
            case .crew(let crew):     return crew.name
            case .worker(let emp):    return "\(emp.fullName) (individual worker)"
            }
        }()
        if risks.isEmpty {
            return "Schedule \(resourcePhrase) on \(projName) for \(dayPhrase). No conflicts detected."
        }
        let severeCount = risks.filter { $0.severity == .high }.count
        if severeCount > 0 {
            return "Schedule \(resourcePhrase) on \(projName) for \(dayPhrase). \(severeCount) hard conflict\(severeCount == 1 ? "" : "s") flagged for review."
        }
        return "Schedule \(resourcePhrase) on \(projName) for \(dayPhrase). \(risks.count) risk\(risks.count == 1 ? "" : "s") flagged."
    }

    private static func buildReasoning(
        winner: ScoredCandidate,
        estimatedDays: Int,
        risks: [ScheduleRisk],
        scored: [ScoredCandidate],
        extendedAvail: Availability?,
        proposedDates: [Date],
        requestedStart: Date
    ) -> String {
        var lines: [String] = []
        let availability = winner.candidate.availability
        let freeDays = availability.availableDays.count

        // Resource & gap analysis — the headline.
        switch winner.candidate.resource {
        case .crew(let crew):
            lines.append("• \(crew.name) has \(freeDays) free day\(freeDays == 1 ? "" : "s") in the next \(availabilityWindowDays) days.")
        case .worker(let emp):
            lines.append("• \(emp.fullName) has \(freeDays) free day\(freeDays == 1 ? "" : "s") in the next \(availabilityWindowDays) days. Individual worker because the task fits in \(estimatedDays) day\(estimatedDays == 1 ? "" : "s").")
        }

        // Preferred-resource pathway: explain that the start date got
        // pushed out to the first real availability so the manager
        // sees the trade-off ("we waited because you wanted Crew X")
        // instead of being surprised by a far-future date.
        if extendedAvail != nil,
           let firstProposed = proposedDates.min(),
           let cal = Optional(Calendar.current),
           let dayDiff = cal.dateComponents([.day], from: cal.startOfDay(for: requestedStart),
                                            to: cal.startOfDay(for: firstProposed)).day,
           dayDiff > 0 {
            let fmt = DateFormatter()
            fmt.dateFormat = "EEE MMM d"
            lines.append("• ⏩ Start pushed to \(fmt.string(from: firstProposed)) (+\(dayDiff) day\(dayDiff == 1 ? "" : "s")) — first window where this preferred resource has \(estimatedDays) free day\(estimatedDays == 1 ? "" : "s") in a row.")
        }

        if winner.score.lastUsed {
            lines.append("• Historical fit — used on this project before.")
        }
        if winner.score.qualified {
            lines.append("• All required certifications covered.")
        } else {
            lines.append("• ⚠ Missing one or more required certifications.")
        }

        let threshold = AppSettings.shared.overtimeWeeklyThresholdHours
        if threshold > 0 {
            let pct = Int((winner.score.workloadHours / threshold) * 100)
            lines.append("• Current workload: \(String(format: "%.1f", winner.score.workloadHours))h this week (\(pct)% of \(Int(threshold))h threshold).")
        }

        // Free-day preview — show up to 5 of the actual free dates.
        let preview = availability.availableDays.prefix(5)
        if !preview.isEmpty {
            let fmt = DateFormatter()
            fmt.dateFormat = "EEE MMM d"
            let dates = preview.map { fmt.string(from: $0) }.joined(separator: ", ")
            lines.append("• Free days: \(dates)\(availability.availableDays.count > 5 ? ", …" : "").")
        }

        // Worker alternatives that didn't make it into the structured
        // alternatives array (which only carries crew_ids in SR-1).
        let workerAlts = scored.dropFirst()
            .compactMap { sc -> String? in
                if case .worker(let emp) = sc.candidate.resource {
                    let f = sc.candidate.availability.availableDays.count
                    return "\(emp.fullName) (\(f) free day\(f == 1 ? "" : "s"))"
                }
                return nil
            }
            .prefix(3)
        if !workerAlts.isEmpty {
            lines.append("")
            lines.append("Other available workers: \(Array(workerAlts).joined(separator: ", "))")
        }

        if !risks.isEmpty {
            lines.append("")
            lines.append("Risks:")
            for r in risks {
                lines.append("  – \(r.severity.rawValue.uppercased()): \(r.message)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func blockedRecommendation(
        for context: ScheduleSourceContext,
        projectID: UUID,
        userID: UUID?,
        store: AppStore,
        summary: String,
        reasoning: String
    ) -> ScheduleRecommendation {
        var rec = ScheduleRecommendation(
            id: UUID(),
            companyID: store.currentCompanyID ?? UUID(),
            sourceType: mapSourceType(context.sourceType),
            sourceID: context.sourceID,
            projectID: projectID,
            recommendationType: "project_kickoff_schedule",
            createdByAI: true,
            requestedByUserID: userID,
            status: .pendingReview,
            confidenceScore: 0,
            summary: summary,
            reasoning: reasoning,
            risks: [
                ScheduleRisk(type: "blocked", severity: .high, message: reasoning)
            ],
            alternatives: [],
            proposedEntries: []
        )
        rec.createdAt = Date()
        rec.updatedAt = Date()
        return rec
    }

    // MARK: - Helpers

    private static func mapSourceType(_ src: NeedsSchedulingSourceType) -> ScheduleRecommendationSourceType {
        switch src {
        case .quote:        return .quote
        case .project:      return .project
        case .materialSale: return .materialSale
        case .changeOrder:  return .changeOrder
        case .rental, .internalWork: return .manual
        }
    }

    private static func estimateDays(for context: ScheduleSourceContext,
                                     project: Project?) -> Int {
        switch context.sourceType {
        case .changeOrder:  return 2
        case .materialSale: return 1
        default:            return 1
        }
    }

    private static func defaultStart(on day: Date) -> Date {
        Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: day) ?? day
    }

    private static func defaultEnd(on day: Date) -> Date {
        Calendar.current.date(bySettingHour: 16, minute: 0, second: 0, of: day) ?? day
    }

    private static func applyTimeOfDay(_ time: Date, to day: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: time)
        return cal.date(bySettingHour: comps.hour ?? 8,
                        minute: comps.minute ?? 0,
                        second: 0,
                        of: day) ?? day
    }

    private static func hoursBetween(_ start: Date?, _ end: Date?) -> Double? {
        guard let s = start, let e = end, e > s else { return nil }
        return e.timeIntervalSince(s) / 3600.0
    }

    private static func startOfCurrentWeek() -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        return cal.date(from: comps) ?? cal.startOfDay(for: Date())
    }

    private static func estimateEntryHours(_ entry: ScheduleEntry) -> Double {
        guard let s = entry.shiftStart, let e = entry.shiftEnd, e > s else { return 8 }
        return e.timeIntervalSince(s) / 3600.0
    }

    /// Find the FIRST contiguous stretch of `n` free days within
    /// `availableDays`. "Contiguous" tolerates weekend gaps — Sunday
    /// is excluded from `availableDays` already, so a Fri-Mon stretch
    /// counts as 2 days adjacent to a 1-day Sunday gap. Returns the
    /// stretch as a list, or nil if no qualifying stretch exists.
    ///
    /// Used by the preferred-resource pathway: when last-used /
    /// pinned crew has no availability in the next 14 days, scan
    /// the 60-day horizon for the earliest window where they are
    /// free for `n` consecutive workdays.
    private static func firstContiguousStretch(
        of n: Int,
        in availableDays: [Date],
        calendar: Calendar
    ) -> [Date]? {
        guard n > 0, availableDays.count >= n else { return nil }
        let sorted = availableDays.sorted()
        var run: [Date] = []
        for day in sorted {
            if let prev = run.last {
                let dayDiff = calendar.dateComponents([.day], from: prev, to: day).day ?? 0
                // Allow same-day, next-day, or weekend-skip (2 or 3
                // days for Fri→Mon — Saturday counted, Sunday skipped).
                if dayDiff >= 1 && dayDiff <= 3 {
                    run.append(day)
                } else {
                    run = [day]
                }
            } else {
                run = [day]
            }
            if run.count >= n {
                return Array(run.prefix(n))
            }
        }
        return nil
    }

    /// True when the source context's `suggestedCrewID` matches the
    /// candidate's resource. Treats this as a "preferred" signal —
    /// extends the availability horizon when the suggested crew has
    /// no near-term gaps. Hard-pinning (Part 2: estimate/quote labor
    /// plan) will use a different field once shipped.
    private static func sourceCrewIDMatches(_ candidate: Candidate,
                                            context: ScheduleSourceContext) -> Bool {
        guard let suggestedID = context.suggestedCrewID else { return false }
        if case .crew(let c) = candidate.resource, c.id == suggestedID {
            return true
        }
        return false
    }

    // MARK: - SR-1.4: Labor-requirement-aware pathway
    //
    // When a labor plan is set on the project (via take-off on the
    // source quote), the engine satisfies the requirement using ANY
    // valid combination of resources rather than pinning a single
    // crew. This eliminates the bottleneck the user flagged: pinning
    // Crew A delays the project even when 3 qualified individual
    // insulators are sitting idle elsewhere.
    //
    // ASSEMBLY PRIORITY
    //   1. Required worker hard pins → exact set, find earliest
    //      simultaneous-free window (top up to count if needed)
    //   2. Preferred crew → if it has enough qualified free members
    //   3. Any fixed crew with enough qualified free members
    //   4. Custom crew assembled from top qualified individual workers
    //   5. Single worker (when count == 1)
    //
    // OUTPUT shape adapts:
    //   • count == 1 + single worker → individualWorker
    //   • crew win (steps 2–3)        → fixedCrew with crewID
    //   • count ≥ 2 + workers picked → customCrew with assignedWorkerIDs
    //   • foreman: first preferred worker, else first assigned

    private static func recommendFromLaborPlan(
        labor: LaborRequirement,
        context: ScheduleSourceContext,
        project: Project?,
        projectID: UUID,
        userID: UUID?,
        workType: String,
        store: AppStore
    ) -> ScheduleRecommendation {
        let cal = Calendar.current
        let baseDate = context.suggestedDate ?? Date()
        let windowStart = cal.startOfDay(for: baseDate)
        let extendedEnd = cal.date(byAdding: .day, value: extendedWindowDays - 1, to: windowStart) ?? windowStart
        let estimatedDays = estimateDays(for: context, project: project)
        let suggestedStart = context.suggestedStartTime ?? defaultStart(on: baseDate)
        let suggestedEnd   = context.suggestedEndTime   ?? defaultEnd(on: baseDate)

        // Build qualified worker pool (matches class + carries all
        // required certs).
        let requiredCertSet = Set(labor.requiredCertifications.map { $0.lowercased() })
        let allWorkers = store.employees.filter { $0.isActive && !$0.isDeleted }
        let qualifiedWorkers = allWorkers.filter { emp in
            workerMatchesClass(emp, class: labor.workerClass)
                && workerCarriesAllCerts(emp, requiredCerts: requiredCertSet)
        }

        // Compute each qualified worker's availability over the full
        // 60-day horizon — we may need it for the assembly step.
        let workerAvail = qualifiedWorkers.map { emp -> (Employee, Availability) in
            let avail = computeAvailability(
                for: .worker(emp),
                store: store,
                windowStart: windowStart,
                windowEnd: extendedEnd
            )
            return (emp, avail)
        }

        // ── Branch A: hard-pinned workers ───────────────────────────
        if !labor.requiredWorkerIDs.isEmpty {
            let pinnedSet = Set(labor.requiredWorkerIDs)
            let pinnedWorkers = workerAvail.filter { pinnedSet.contains($0.0.id) }
            if pinnedWorkers.count >= labor.requiredWorkerIDs.count {
                let window = earliestSimultaneousWindow(
                    workers: pinnedWorkers.map { $0.1 },
                    days: estimatedDays
                )
                if let dates = window {
                    let workers = pinnedWorkers.map { $0.0 }
                    return buildLaborRecommendation(
                        mode: workers.count == 1 ? .individualWorker : .customCrew,
                        crew: nil,
                        workers: workers,
                        foreman: pickForeman(workers: workers, labor: labor),
                        dates: dates,
                        labor: labor,
                        context: context,
                        project: project,
                        projectID: projectID,
                        userID: userID,
                        workType: workType,
                        suggestedStart: suggestedStart,
                        suggestedEnd: suggestedEnd,
                        store: store,
                        rationale: "Required workers — earliest window where all pinned workers are free."
                    )
                }
                // Fall through if pinned workers can't all be free
                // simultaneously in 60 days — surface as a blocked plan.
                return blockedRecommendation(
                    for: context, projectID: projectID, userID: userID, store: store,
                    summary: "Required workers can't all be free in the same \(estimatedDays)-day window.",
                    reasoning: "The plan requires \(pinnedWorkers.count) specific worker(s) to be available simultaneously for \(estimatedDays) day(s). None of them are simultaneously free in the next \(extendedWindowDays) days. Loosen the requirement or extend the lookahead."
                )
            }
            // Pinned workers don't all qualify (missing certs / inactive).
            return blockedRecommendation(
                for: context, projectID: projectID, userID: userID, store: store,
                summary: "Some required workers no longer qualify.",
                reasoning: "The labor plan pins \(labor.requiredWorkerIDs.count) specific worker(s), but only \(pinnedWorkers.count) match the trade and certification requirements. Update the plan or the workers' profiles."
            )
        }

        // ── Branch B/C: try a fixed crew ─────────────────────────────
        if labor.count >= 1 {
            // Order: preferred crew first, then other crews scored by
            // qualified-member count + workload + last-used.
            var crewOrder: [Crew] = []
            if let prefID = labor.preferredCrewID,
               let pref = store.crews.first(where: { $0.id == prefID && $0.isActive }) {
                crewOrder.append(pref)
            }
            let otherCrews = store.crews
                .filter { $0.isActive && !$0.isDeleted && $0.id != labor.preferredCrewID }
                .sorted { a, b in
                    let aq = qualifiedMemberCount(crew: a, requiredCerts: requiredCertSet,
                                                  class: labor.workerClass, store: store)
                    let bq = qualifiedMemberCount(crew: b, requiredCerts: requiredCertSet,
                                                  class: labor.workerClass, store: store)
                    if aq != bq { return aq > bq }
                    return a.name < b.name
                }
            crewOrder.append(contentsOf: otherCrews)

            for crew in crewOrder {
                let qmCount = qualifiedMemberCount(
                    crew: crew, requiredCerts: requiredCertSet,
                    class: labor.workerClass, store: store
                )
                guard qmCount >= labor.count else { continue }
                // Use the crew's standing availability — assume the
                // crew works as a unit on the days the crew is free.
                let crewAvail = computeAvailability(
                    for: .crew(crew),
                    store: store,
                    windowStart: windowStart,
                    windowEnd: extendedEnd
                )
                if let dates = firstContiguousStretch(of: estimatedDays,
                                                     in: crewAvail.availableDays,
                                                     calendar: cal) {
                    return buildLaborRecommendation(
                        mode: .fixedCrew,
                        crew: crew,
                        workers: [],
                        foreman: nil,
                        dates: dates,
                        labor: labor,
                        context: context,
                        project: project,
                        projectID: projectID,
                        userID: userID,
                        workType: workType,
                        suggestedStart: suggestedStart,
                        suggestedEnd: suggestedEnd,
                        store: store,
                        rationale: crew.id == labor.preferredCrewID
                            ? "Preferred crew — \(crew.name) has \(qmCount) qualified members and a free window starting \(dates.first.map { dateLabel($0) } ?? "")."
                            : "\(crew.name) has \(qmCount) qualified members and an open \(estimatedDays)-day window."
                    )
                }
            }
        }

        // ── Branch D: custom crew or individual worker ──────────────
        if labor.count == 1 {
            // Pick the single best qualified worker by availability.
            // Soft preference for preferred workers.
            let preferredSet = Set(labor.preferredWorkerIDs)
            let sorted = workerAvail.sorted { a, b in
                let aPref = preferredSet.contains(a.0.id) ? 1 : 0
                let bPref = preferredSet.contains(b.0.id) ? 1 : 0
                if aPref != bPref { return aPref > bPref }
                if a.1.availableDays.count != b.1.availableDays.count {
                    return a.1.availableDays.count > b.1.availableDays.count
                }
                return a.0.fullName < b.0.fullName
            }
            if let pick = sorted.first,
               let dates = firstContiguousStretch(of: estimatedDays,
                                                  in: pick.1.availableDays,
                                                  calendar: cal) {
                return buildLaborRecommendation(
                    mode: .individualWorker,
                    crew: nil,
                    workers: [pick.0],
                    foreman: nil,
                    dates: dates,
                    labor: labor,
                    context: context,
                    project: project,
                    projectID: projectID,
                    userID: userID,
                    workType: workType,
                    suggestedStart: suggestedStart,
                    suggestedEnd: suggestedEnd,
                    store: store,
                    rationale: "\(pick.0.fullName) is qualified and available — single-worker assignment matches a 1-person job."
                )
            }
        } else {
            // Assemble a custom crew of `count` qualified workers
            // who can all be free in the same window.
            // Strategy: sort workers by availability count desc, then
            // try increasing combinations (top 1, top 2, ... top count)
            // until a window where all are free simultaneously emerges.
            let preferredSet = Set(labor.preferredWorkerIDs)
            let sorted = workerAvail.sorted { a, b in
                let aPref = preferredSet.contains(a.0.id) ? 1 : 0
                let bPref = preferredSet.contains(b.0.id) ? 1 : 0
                if aPref != bPref { return aPref > bPref }
                return a.1.availableDays.count > b.1.availableDays.count
            }
            // Bias the candidate list to reasonable size — top 12
            // qualified workers, then try combinations within that.
            let pool = Array(sorted.prefix(12))
            if pool.count >= labor.count {
                // Greedy: try the top N first. If they can't all align,
                // try the top N-1 + next, etc. For SR-1.4 keep it
                // simple: pick top N and see if they have any
                // simultaneous window. If not, fall back to "top N
                // by availability and let the conflict probe flag it."
                let topN = Array(pool.prefix(labor.count))
                let availList = topN.map { $0.1 }
                if let dates = earliestSimultaneousWindow(
                    workers: availList, days: estimatedDays
                ) {
                    let workers = topN.map { $0.0 }
                    return buildLaborRecommendation(
                        mode: .customCrew,
                        crew: nil,
                        workers: workers,
                        foreman: pickForeman(workers: workers, labor: labor),
                        dates: dates,
                        labor: labor,
                        context: context,
                        project: project,
                        projectID: projectID,
                        userID: userID,
                        workType: workType,
                        suggestedStart: suggestedStart,
                        suggestedEnd: suggestedEnd,
                        store: store,
                        rationale: "Custom crew of \(workers.count) qualified workers with overlapping availability — assembled because no single fixed crew has enough qualified free members."
                    )
                }
                // Couldn't align all N at once — best-effort: each on
                // their own first free day. Conflict probe will flag.
                let workers = topN.map { $0.0 }
                let bestDates = workers.compactMap { worker -> Date? in
                    pool.first(where: { $0.0.id == worker.id })?.1.availableDays.first
                }.sorted().prefix(estimatedDays)
                return buildLaborRecommendation(
                    mode: .customCrew,
                    crew: nil,
                    workers: workers,
                    foreman: pickForeman(workers: workers, labor: labor),
                    dates: Array(bestDates),
                    labor: labor,
                    context: context,
                    project: project,
                    projectID: projectID,
                    userID: userID,
                    workType: workType,
                    suggestedStart: suggestedStart,
                    suggestedEnd: suggestedEnd,
                    store: store,
                    rationale: "Best-effort custom crew — these workers couldn't all be free in the same window. Review the conflict flags."
                )
            }
        }

        // No qualified resources found at all.
        return blockedRecommendation(
            for: context, projectID: projectID, userID: userID, store: store,
            summary: "No qualified resources match this labor plan.",
            reasoning: "Need \(labor.count) worker(s)\(labor.workerClass.map { " of class '\($0)'" } ?? "")\(labor.requiredCertifications.isEmpty ? "" : " with " + labor.requiredCertifications.joined(separator: ", "))). No active crew or worker satisfies the trade + certification requirements. Adjust the plan or onboard qualified people."
        )
    }

    // MARK: - SR-1.4 helpers

    private static func workerMatchesClass(_ emp: Employee, class wantedClass: String?) -> Bool {
        guard let wantedClass = wantedClass, !wantedClass.isEmpty else { return true }
        guard let trade = emp.trade, !trade.isEmpty else { return false }
        return trade.lowercased() == wantedClass.lowercased()
    }

    private static func workerCarriesAllCerts(_ emp: Employee, requiredCerts: Set<String>) -> Bool {
        guard !requiredCerts.isEmpty else { return true }
        let held = Set(emp.certifications.map { $0.lowercased() })
        return requiredCerts.isSubset(of: held)
    }

    private static func qualifiedMemberCount(
        crew: Crew,
        requiredCerts: Set<String>,
        class wantedClass: String?,
        store: AppStore
    ) -> Int {
        var memberIDs = crew.memberIDs
        if let f = crew.foremanID, !memberIDs.contains(f) { memberIDs.append(f) }
        var count = 0
        for empID in memberIDs {
            guard let emp = store.employees.first(where: { $0.id == empID && $0.isActive }) else { continue }
            if workerMatchesClass(emp, class: wantedClass)
                && workerCarriesAllCerts(emp, requiredCerts: requiredCerts) {
                count += 1
            }
        }
        return count
    }

    /// Finds the earliest contiguous N-day window where ALL listed
    /// availabilities have free days. Returns nil if no such window
    /// exists in the union of their schedules.
    private static func earliestSimultaneousWindow(
        workers: [Availability],
        days: Int
    ) -> [Date]? {
        guard !workers.isEmpty, days >= 1 else { return nil }
        // Intersection of available-day sets.
        let perWorkerSets = workers.map { Set($0.availableDays) }
        var common = perWorkerSets[0]
        for s in perWorkerSets.dropFirst() {
            common.formIntersection(s)
            if common.isEmpty { return nil }
        }
        return firstContiguousStretch(of: days,
                                       in: Array(common),
                                       calendar: Calendar.current)
    }

    /// Picks a foreman from the assigned workers — first preferred
    /// worker who's in the assignment, else the first assigned worker
    /// when count > 1, else nil.
    private static func pickForeman(workers: [Employee], labor: LaborRequirement) -> Employee? {
        guard workers.count > 1 else { return nil }
        if let preferredFirst = workers.first(where: { labor.preferredWorkerIDs.contains($0.id) }) {
            return preferredFirst
        }
        return workers.first
    }

    private static func dateLabel(_ d: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE MMM d"
        return fmt.string(from: d)
    }

    /// Build a ScheduleRecommendation from an assembled labor plan.
    /// Handles probing for conflicts, summary, reasoning — single
    /// place that knows how to produce the final payload from any of
    /// the labor-aware branches above.
    private static func buildLaborRecommendation(
        mode: ScheduleAssignmentMode,
        crew: Crew?,
        workers: [Employee],
        foreman: Employee?,
        dates: [Date],
        labor: LaborRequirement,
        context: ScheduleSourceContext,
        project: Project?,
        projectID: UUID,
        userID: UUID?,
        workType: String,
        suggestedStart: Date,
        suggestedEnd: Date,
        store: AppStore,
        rationale: String
    ) -> ScheduleRecommendation {
        let cal = Calendar.current
        var proposed: [ProposedScheduleEntry] = []
        for day in dates {
            let dayStart = applyTimeOfDay(suggestedStart, to: day)
            let dayEnd   = applyTimeOfDay(suggestedEnd, to: day)
            var entry = ProposedScheduleEntry(
                projectID: projectID,
                crewID: crew?.id,
                assignedWorkerIDs: workers.map { $0.id },
                foremanID: foreman?.id,
                assignmentMode: mode,
                date: day,
                shiftStart: dayStart,
                shiftEnd: dayEnd,
                taskDescription: workType,
                costCode: context.costCode,
                location: context.siteAddress,
                requiredCertifications: labor.requiredCertifications,
                estimatedHours: hoursBetween(dayStart, dayEnd) ?? 8,
                notes: nil
            )
            // For fixedCrew mode, leave assignedWorkerIDs empty (model
            // semantics: empty means "use the crew's standing roster").
            if mode == .fixedCrew {
                entry.assignedWorkerIDs = []
                entry.foremanID = nil
            }
            proposed.append(entry)
        }

        let probeRisks = probeConflicts(proposed: proposed, store: store)

        // Summary headline.
        let projName = project?.name ?? "this project"
        let dayPhrase = dates.count == 1 ? "1 day" : "\(dates.count) days"
        let resourceLabel: String = {
            switch mode {
            case .fixedCrew:        return crew?.name ?? "Crew"
            case .customCrew:
                let names = workers.map { $0.fullName }.joined(separator: ", ")
                return names.isEmpty ? "Custom crew" : "Custom crew (\(names))"
            case .individualWorker: return workers.first?.fullName ?? "Worker"
            }
        }()
        let summary: String
        if probeRisks.isEmpty {
            summary = "Schedule \(resourceLabel) on \(projName) for \(dayPhrase). No conflicts detected."
        } else if probeRisks.contains(where: { $0.severity == .high }) {
            let n = probeRisks.filter { $0.severity == .high }.count
            summary = "Schedule \(resourceLabel) on \(projName) for \(dayPhrase). \(n) hard conflict\(n == 1 ? "" : "s") flagged."
        } else {
            summary = "Schedule \(resourceLabel) on \(projName) for \(dayPhrase). \(probeRisks.count) risk\(probeRisks.count == 1 ? "" : "s") flagged."
        }

        // Reasoning.
        var lines: [String] = []
        lines.append("• Labor plan: \(labor.count) \(labor.workerClass ?? "worker")\(labor.count == 1 ? "" : "s")\(labor.requiredCertifications.isEmpty ? "" : " with " + labor.requiredCertifications.joined(separator: ", "))).")
        lines.append("• \(rationale)")
        if let firstDate = dates.first,
           let dayDiff = cal.dateComponents([.day],
                                            from: cal.startOfDay(for: context.suggestedDate ?? Date()),
                                            to: cal.startOfDay(for: firstDate)).day,
           dayDiff > 0 {
            lines.append("• ⏩ Start pushed to \(dateLabel(firstDate)) (+\(dayDiff) day\(dayDiff == 1 ? "" : "s")) — first viable window for the requested labor.")
        }
        if !probeRisks.isEmpty {
            lines.append("")
            lines.append("Risks:")
            for r in probeRisks {
                lines.append("  – \(r.severity.rawValue.uppercased()): \(r.message)")
            }
        }
        let reasoning = lines.joined(separator: "\n")

        // Confidence — same envelope as legacy path.
        let confidence: Double = {
            if probeRisks.contains(where: { $0.severity == .high }) { return 0.45 }
            if probeRisks.contains(where: { $0.severity == .medium }) { return 0.65 }
            if probeRisks.contains(where: { $0.severity == .low }) { return 0.85 }
            return 1.0
        }()

        var rec = ScheduleRecommendation(
            id: UUID(),
            companyID: store.currentCompanyID ?? UUID(),
            sourceType: mapSourceType(context.sourceType),
            sourceID: context.sourceID,
            projectID: projectID,
            recommendationType: "labor_plan_schedule",
            createdByAI: true,
            requestedByUserID: userID,
            status: .pendingReview,
            confidenceScore: confidence,
            summary: summary,
            reasoning: reasoning,
            risks: probeRisks,
            alternatives: [],   // SR-1.4 keeps alternatives lean — improvable in SR-2
            proposedEntries: proposed
        )
        rec.createdAt = Date()
        rec.updatedAt = Date()
        return rec
    }
}
