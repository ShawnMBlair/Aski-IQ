// ScheduleConflictService.swift
// Aski IQ – Schedule Conflict Detection

import Foundation

// MARK: - Conflict Model

struct ScheduleConflict: Identifiable {
    let id = UUID()
    let date: Date
    let conflictType: ConflictType
    let description: String
    let affectedEntries: [ScheduleEntry]

    enum ConflictType {
        // Original Phase-0 types (kept for backward compatibility)
        case crewDoubleBooked       // Same crew with overlapping shift times
        case projectOverlap         // Project scheduled during a hold/closure
        case weekendWork            // Entry scheduled on weekend (warning only)

        // Phase 1 upgrades
        /// Same employee on 2+ crews with overlapping shifts the same day.
        case employeeDoubleBooked
        /// Back-to-back shifts for the same crew/employee with less
        /// gap than `AppSettings.travelBufferMinutes`. Covers the
        /// "no time to drive between jobs" risk.
        case travelBuffer
        /// Crew assigned to a shift requiring certs that no member
        /// carries. Driven by `ScheduleEntry.requiredCertifications`
        /// vs `Employee.certifications`.
        case certificationMissing
        /// Sum of weekly hours for a crew or employee exceeds
        /// `AppSettings.overtimeWeeklyThresholdHours`. Notice-level —
        /// surfaces overtime risk; doesn't block.
        case overtimeRisk

        var icon: String {
            switch self {
            case .crewDoubleBooked:    return "person.2.slash"
            case .projectOverlap:      return "calendar.badge.exclamationmark"
            case .weekendWork:         return "exclamationmark.triangle"
            case .employeeDoubleBooked: return "person.crop.circle.badge.exclamationmark"
            case .travelBuffer:        return "car.fill"
            case .certificationMissing: return "checkmark.shield.fill"
            case .overtimeRisk:        return "clock.badge.exclamationmark"
            }
        }

        var color: String {
            switch self {
            case .crewDoubleBooked,
                 .employeeDoubleBooked,
                 .certificationMissing:  return "red"
            case .projectOverlap,
                 .travelBuffer:           return "orange"
            case .weekendWork,
                 .overtimeRisk:           return "yellow"
            }
        }

        var severity: String {
            switch self {
            case .crewDoubleBooked,
                 .employeeDoubleBooked,
                 .certificationMissing:  return "Conflict"
            case .projectOverlap,
                 .travelBuffer:           return "Warning"
            case .weekendWork,
                 .overtimeRisk:           return "Notice"
            }
        }
    }
}

// MARK: - Conflict Service

struct ScheduleConflictService {

    // MARK: - Main Entry Point

    /// Runs all conflict checks over the provided entries.
    /// Pass `projects` to enable project-overlap detection (work scheduled
    /// during a hold/closure). When projects is empty the overlap check is skipped.
    ///
    /// PHASE 1 NOTE: legacy 3-detector signature kept as a thin wrapper
    /// for back-compat. New callers should use `detect(in:projects:crews:
    /// employees:settings:)` to enable the upgraded detection (employee
    /// double-booking, travel buffer, cert mismatch, overtime risk).
    /// Returns deduplicated conflicts sorted by date.
    static func detect(
        in entries: [ScheduleEntry],
        projects: [Project] = [],
        calendar: Calendar = .current
    ) -> [ScheduleConflict] {
        return detect(in: entries,
                      projects: projects,
                      crews: [],
                      employees: [],
                      travelBufferMinutes: 0,
                      overtimeWeeklyThresholdHours: 0,
                      calendar: calendar)
    }

    /// Phase-1 upgraded entry point. All Phase-1 detectors are
    /// no-ops when their respective inputs are missing/disabled,
    /// so callers can opt in incrementally:
    ///   • employee double-book + cert mismatch require `crews` and `employees`
    ///   • travel buffer requires `travelBufferMinutes > 0`
    ///   • overtime risk requires `overtimeWeeklyThresholdHours > 0`
    static func detect(
        in entries: [ScheduleEntry],
        projects: [Project],
        crews: [Crew],
        employees: [Employee],
        travelBufferMinutes: Int,
        overtimeWeeklyThresholdHours: Double,
        calendar: Calendar = .current
    ) -> [ScheduleConflict] {
        var conflicts: [ScheduleConflict] = []

        conflicts += detectCrewDoubleBookings(in: entries, calendar: calendar)
        conflicts += detectWeekendWork(in: entries, calendar: calendar)
        if !projects.isEmpty {
            conflicts += detectProjectOverlaps(in: entries, projects: projects, calendar: calendar)
        }

        // ── Phase 1 detectors ──
        // Phase RA-2: relax the outer guard — direct-worker assignments
        // (custom_crew, individual_worker) don't require a non-empty
        // crews array. The detectors themselves handle missing crew data
        // gracefully via effectiveWorkerIDs. Cert detection still needs
        // the employee directory to resolve certs.
        if !employees.isEmpty {
            conflicts += detectEmployeeDoubleBookings(
                in: entries, crews: crews, calendar: calendar
            )
            conflicts += detectMissingCertifications(
                in: entries, crews: crews, employees: employees
            )
        }
        if travelBufferMinutes > 0 {
            conflicts += detectTravelBufferViolations(
                in: entries,
                bufferMinutes: travelBufferMinutes,
                crews: crews,
                calendar: calendar
            )
        }
        if overtimeWeeklyThresholdHours > 0 {
            conflicts += detectOvertimeRisk(
                in: entries,
                thresholdHours: overtimeWeeklyThresholdHours,
                crews: crews,
                employees: employees,
                calendar: calendar
            )
        }

        return conflicts.sorted { $0.date < $1.date }
    }

    /// Detect conflicts for a specific date range (used in weekly view).
    static func detect(
        in entries: [ScheduleEntry],
        from startDate: Date,
        to endDate: Date,
        projects: [Project] = [],
        calendar: Calendar = .current
    ) -> [ScheduleConflict] {
        let inRange = entries.filter {
            let d = calendar.startOfDay(for: $0.date)
            return d >= calendar.startOfDay(for: startDate) &&
                   d <= calendar.startOfDay(for: endDate)
        }
        return detect(in: inRange, projects: projects, calendar: calendar)
    }

    // MARK: - Crew Double-Booking (time-granular)

    /// Phase 1 refinement: flags the same crew assigned to two
    /// shifts whose times actually overlap (or share a day with no
    /// shift times set). Pre-fix this fired on any same-day pair
    /// across different projects, even non-overlapping morning +
    /// afternoon splits, which produced false positives.
    private static func detectCrewDoubleBookings(
        in entries: [ScheduleEntry],
        calendar: Calendar
    ) -> [ScheduleConflict] {
        var conflicts: [ScheduleConflict] = []

        let crewEntries = entries.filter { $0.crewID != nil && !$0.isDeleted }
        let grouped = Dictionary(grouping: crewEntries) { entry -> String in
            let day = calendar.startOfDay(for: entry.date)
            return "\(entry.crewID!.uuidString)|\(day.timeIntervalSince1970)"
        }

        for (_, group) in grouped where group.count > 1 {
            // Only flag pairs across DIFFERENT projects — same project
            // multiple shifts the same day is intentional split work.
            let projectIDs = Set(group.map { $0.projectID })
            guard projectIDs.count > 1 else { continue }

            // Check time overlap pairwise. If any entry has no shift
            // start/end set we treat it as "all day" (overlaps anything
            // on the same day).
            var overlappingGroup: [ScheduleEntry] = []
            for i in 0..<group.count {
                for j in (i + 1)..<group.count {
                    if shiftsOverlap(group[i], group[j]) {
                        if !overlappingGroup.contains(where: { $0.id == group[i].id }) {
                            overlappingGroup.append(group[i])
                        }
                        if !overlappingGroup.contains(where: { $0.id == group[j].id }) {
                            overlappingGroup.append(group[j])
                        }
                    }
                }
            }
            guard !overlappingGroup.isEmpty else { continue }

            let date = calendar.startOfDay(for: group[0].date)
            let projCount = Set(overlappingGroup.map { $0.projectID }).count
            // Phase 2 hardening: the resolution sheet wants a clear
            // overlap window. Peek at the worst pair (the one with the
            // largest overlap) for the description so the user knows
            // up-front how bad the clash is.
            let worstOverlap = worstOverlapDescription(overlappingGroup)
            conflicts.append(ScheduleConflict(
                date: date,
                conflictType: .crewDoubleBooked,
                description: "Crew double-booked across \(projCount) projects (\(worstOverlap))",
                affectedEntries: overlappingGroup
            ))
        }

        return conflicts
    }

    // MARK: - Phase 1: Employee Double-Booking (across crews)

    /// Same employee on 2+ crews with overlapping shifts the same
    /// day. Looks up crew membership via `Crew.memberIDs` (and
    /// foreman) to expand each entry into the set of employees
    /// affected by it, then flags employees that appear in 2+
    /// time-overlapping shifts.
    private static func detectEmployeeDoubleBookings(
        in entries: [ScheduleEntry],
        crews: [Crew],
        calendar: Calendar
    ) -> [ScheduleConflict] {
        let crewByID = Dictionary(uniqueKeysWithValues: crews.map { ($0.id, $0) })

        // Phase RA-2: expand each shift to its actual worker roster
        // via effectiveWorkerIDs — covers fixed_crew (members + foreman),
        // custom_crew (assignedWorkerIDs + optional foreman), and
        // individual_worker (single assignedWorker). Pre-RA-2 only the
        // fixed-crew case was reachable.

        // (employeeID, day) → all entries that include them
        var empIndex: [String: [ScheduleEntry]] = [:]
        for entry in entries where !entry.isDeleted {
            let workerIDs = effectiveWorkerIDs(for: entry, crewByID: crewByID)
            guard !workerIDs.isEmpty else { continue }
            let day = calendar.startOfDay(for: entry.date)
            for empID in workerIDs {
                let key = "\(empID.uuidString)|\(day.timeIntervalSince1970)"
                empIndex[key, default: []].append(entry)
            }
        }

        var conflicts: [ScheduleConflict] = []
        for (_, group) in empIndex where group.count > 1 {
            // Only flag if the worker appears in 2+ DISTINCT contexts.
            // "Context" = (crewID, projectID) for crew-assigned shifts,
            // or the entry's own id for direct assignments. This preserves
            // the legitimate-split case (same crew + same project, AM
            // and PM shifts — intentional split work, not a double-book)
            // while catching:
            //   • same worker on two crews same day overlapping
            //   • same worker on a crew AND directly-assigned to another
            //     shift overlapping
            //   • two direct shifts overlapping for the same worker
            let contexts = Set(group.map { e -> String in
                if let cid = e.crewID {
                    return "crew:\(cid.uuidString)|proj:\(e.projectID.uuidString)"
                } else {
                    // Each direct (custom_crew or individual_worker)
                    // shift is its own context. Two such shifts for
                    // the same worker overlapping IS a double-book.
                    return "direct:\(e.id.uuidString)"
                }
            })
            guard contexts.count > 1 else { continue }

            // Time-overlap among this employee's shifts
            var overlapping: [ScheduleEntry] = []
            for i in 0..<group.count {
                for j in (i + 1)..<group.count {
                    if shiftsOverlap(group[i], group[j]) {
                        if !overlapping.contains(where: { $0.id == group[i].id }) {
                            overlapping.append(group[i])
                        }
                        if !overlapping.contains(where: { $0.id == group[j].id }) {
                            overlapping.append(group[j])
                        }
                    }
                }
            }
            guard !overlapping.isEmpty else { continue }

            let date = calendar.startOfDay(for: group[0].date)
            let worstOverlap = worstOverlapDescription(overlapping)
            // Phase RA-2: shifts may now be crew-bound, custom-crew, or
            // individual-worker. Describe the clash neutrally — "across
            // N shifts" — instead of crew-count language that broke for
            // direct-worker assignments.
            conflicts.append(ScheduleConflict(
                date: date,
                conflictType: .employeeDoubleBooked,
                description: "Worker on \(overlapping.count) overlapping shifts (\(worstOverlap))",
                affectedEntries: overlapping
            ))
        }
        return conflicts
    }

    // MARK: - Phase 1: Travel / Setup Buffer

    /// Two back-to-back shifts for the same crew where the gap
    /// between shift-end-A and shift-start-B is less than
    /// `bufferMinutes`. Only fires when both shifts have explicit
    /// start/end times (no shift-time = "all day", which is already
    /// covered by the crew-double-book detector).
    private static func detectTravelBufferViolations(
        in entries: [ScheduleEntry],
        bufferMinutes: Int,
        crews: [Crew],
        calendar: Calendar
    ) -> [ScheduleConflict] {
        guard bufferMinutes > 0 else { return [] }
        let buffer = TimeInterval(bufferMinutes * 60)

        var conflicts: [ScheduleConflict] = []
        let crewEntries = entries.filter {
            !$0.isDeleted
            && $0.crewID != nil
            && $0.shiftStart != nil
            && $0.shiftEnd != nil
        }
        let grouped = Dictionary(grouping: crewEntries) { entry -> String in
            let day = calendar.startOfDay(for: entry.date)
            return "\(entry.crewID!.uuidString)|\(day.timeIntervalSince1970)"
        }

        for (_, group) in grouped where group.count > 1 {
            // Sort shifts by start time so we can check adjacent pairs
            let sorted = group.sorted {
                ($0.shiftStart ?? Date.distantFuture) < ($1.shiftStart ?? Date.distantFuture)
            }
            for i in 0..<(sorted.count - 1) {
                let a = sorted[i]
                let b = sorted[i + 1]
                guard let aEnd   = a.shiftEnd,
                      let bStart = b.shiftStart else { continue }
                // Only flag adjacent shifts on different projects
                // (same project = continuation, no travel needed).
                guard a.projectID != b.projectID else { continue }
                let gap = bStart.timeIntervalSince(aEnd)
                if gap >= 0 && gap < buffer {
                    let mins = Int(gap / 60)
                    let date = calendar.startOfDay(for: a.date)
                    conflicts.append(ScheduleConflict(
                        date: date,
                        conflictType: .travelBuffer,
                        description: "Only \(mins) min between back-to-back shifts on different projects (need \(bufferMinutes) min)",
                        affectedEntries: [a, b]
                    ))
                }
            }
        }
        return conflicts
    }

    // MARK: - Phase 1: Certification Mismatch

    /// Flag shifts where `requiredCertifications` is non-empty but
    /// the assigned crew has no member who carries every required
    /// cert. We require at least ONE member to hold ALL the certs
    /// (the simplest mental model: "is there someone here qualified
    /// to do this work?"). Future enhancement could split required
    /// certs across multiple members.
    private static func detectMissingCertifications(
        in entries: [ScheduleEntry],
        crews: [Crew],
        employees: [Employee]
    ) -> [ScheduleConflict] {
        guard !employees.isEmpty else { return [] }
        let crewByID = Dictionary(uniqueKeysWithValues: crews.map { ($0.id, $0) })
        let empByID  = Dictionary(uniqueKeysWithValues: employees.map { ($0.id, $0) })

        var conflicts: [ScheduleConflict] = []
        for entry in entries where !entry.isDeleted {
            let required = Set(entry.requiredCertifications.map { $0.lowercased() })
            guard !required.isEmpty else { continue }

            // Phase RA-2: resolve to the actual worker pool — crew
            // members + foreman for fixed_crew, direct assignments for
            // custom_crew / individual_worker.
            let workerIDs = effectiveWorkerIDs(for: entry, crewByID: crewByID)

            // No workers at all + cert requirement = blocking issue.
            guard !workerIDs.isEmpty else {
                conflicts.append(ScheduleConflict(
                    date: Calendar.current.startOfDay(for: entry.date),
                    conflictType: .certificationMissing,
                    description: "Shift requires \(entry.requiredCertifications.joined(separator: ", ")) but no crew or worker assigned",
                    affectedEntries: [entry]
                ))
                continue
            }

            // Does ANY assigned worker carry all required certs?
            // We require one person to hold the full set — same
            // mental model as pre-RA-2 ("is there someone here who
            // can do this?").
            let qualified = workerIDs.contains { empID in
                guard let emp = empByID[empID], emp.isActive else { return false }
                let held = Set(emp.certifications.map { $0.lowercased() })
                return required.isSubset(of: held)
            }
            if !qualified {
                conflicts.append(ScheduleConflict(
                    date: Calendar.current.startOfDay(for: entry.date),
                    conflictType: .certificationMissing,
                    description: "No assigned worker holds all required certs: \(entry.requiredCertifications.joined(separator: ", "))",
                    affectedEntries: [entry]
                ))
            }
        }
        return conflicts
    }

    // MARK: - Phase 1: Overtime Risk

    /// Sum of weekly hours per crew that exceeds the threshold.
    /// "Week" = ISO week (Mon-start in most locales; we use Calendar.current).
    /// Notice-level — surfaces risk; doesn't block save.
    private static func detectOvertimeRisk(
        in entries: [ScheduleEntry],
        thresholdHours: Double,
        crews: [Crew],
        employees: [Employee] = [],
        calendar: Calendar
    ) -> [ScheduleConflict] {
        guard thresholdHours > 0 else { return [] }
        let crewByID = Dictionary(uniqueKeysWithValues: crews.map { ($0.id, $0) })
        let empByID  = Dictionary(uniqueKeysWithValues: employees.map { ($0.id, $0) })

        // Phase RA-2: aggregate weekly hours PER WORKER, not per crew.
        // The crew-only aggregation was approximately correct when every
        // worker was on exactly one crew, but breaks for custom_crew and
        // individual_worker assignments (a worker could be on Crew A
        // Monday, custom_crew Tuesday, and individual Wednesday — still
        // one human approaching OT).
        //
        // (workerID, ISO week-of-year-string) → entries that include them
        var weekIndex: [String: (entries: [ScheduleEntry], hoursPerEntry: [UUID: Double])] = [:]
        for entry in entries where !entry.isDeleted {
            guard let start = entry.shiftStart,
                  let end   = entry.shiftEnd,
                  end > start else { continue }
            let workerIDs = effectiveWorkerIDs(for: entry, crewByID: crewByID)
            guard !workerIDs.isEmpty else { continue }
            let entryHours = end.timeIntervalSince(start) / 3600.0
            let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: entry.date)
            for empID in workerIDs {
                let weekKey = "\(empID.uuidString)|\(comps.yearForWeekOfYear ?? 0)|\(comps.weekOfYear ?? 0)"
                var bucket = weekIndex[weekKey] ?? (entries: [], hoursPerEntry: [:])
                if !bucket.entries.contains(where: { $0.id == entry.id }) {
                    bucket.entries.append(entry)
                }
                bucket.hoursPerEntry[entry.id] = entryHours
                weekIndex[weekKey] = bucket
            }
        }

        var conflicts: [ScheduleConflict] = []
        var seenSignatures: Set<String> = []
        for (key, bucket) in weekIndex {
            let totalHours = bucket.hoursPerEntry.values.reduce(0, +)
            guard totalHours > thresholdHours else { continue }
            // De-dup by entry-set signature so two workers blowing past
            // the threshold in the same shift group don't fire two
            // identical-looking conflicts.
            let signature = bucket.entries.map { $0.id.uuidString }.sorted().joined(separator: ",")
            guard !seenSignatures.contains(signature) else { continue }
            seenSignatures.insert(signature)

            // Worker label — pull the first worker out of the key,
            // resolve to a name. Falls back to "Worker" if the
            // employee directory isn't loaded.
            let workerIDString = key.split(separator: "|").first.map(String.init) ?? ""
            let workerName: String = {
                guard let uuid = UUID(uuidString: workerIDString),
                      let emp = empByID[uuid] else { return "Worker" }
                return emp.fullName
            }()

            let weekStart = calendar.startOfDay(for: bucket.entries.map { $0.date }.min() ?? Date())
            conflicts.append(ScheduleConflict(
                date: weekStart,
                conflictType: .overtimeRisk,
                description: String(format: "%@ scheduled %.1f h this week (over %.0f h threshold)",
                                    workerName, totalHours, thresholdHours),
                affectedEntries: bucket.entries
            ))
        }
        return conflicts
    }

    // MARK: - Helpers

    /// Phase RA-2 — single source of truth for "which workers does
    /// this shift involve?" Replaces the older crew-only expansion
    /// in employee-double-book / cert / overtime detectors.
    ///
    /// Resolution order:
    ///   • Direct assignment (custom_crew, individual_worker, OR a
    ///     fixed_crew with an explicit roster override): use
    ///     `entry.assignedWorkerIDs`. The override case is RA-3 UI
    ///     work — model-level support lands here.
    ///   • Otherwise (fixed_crew with no override): expand the crew's
    ///     `memberIDs` plus its foreman.
    /// In both cases, `entry.foremanID` (if set) is unioned in so
    /// custom-crew foreman appointments are detected as part of the
    /// roster.
    fileprivate static func effectiveWorkerIDs(
        for entry: ScheduleEntry,
        crewByID: [UUID: Crew]
    ) -> [UUID] {
        var ids: [UUID] = []

        // Direct assignment takes priority over crew expansion. This
        // also gracefully handles the legacy fixed_crew case (empty
        // assignedWorkerIDs) by falling through to crew expansion.
        if !entry.assignedWorkerIDs.isEmpty {
            ids = entry.assignedWorkerIDs
        } else if let crewID = entry.crewID, let crew = crewByID[crewID] {
            ids = crew.memberIDs
            if let f = crew.foremanID, !ids.contains(f) {
                ids.append(f)
            }
        }

        // Per-shift foreman override (custom_crew leadership). Union
        // it in regardless of mode so cert / overtime / double-book
        // detectors all see the foreman as a participant.
        if let f = entry.foremanID, !ids.contains(f) {
            ids.append(f)
        }

        return ids
    }

    /// True when two shifts on the same crew/employee actually share
    /// minutes. If either lacks shift times we treat it as all-day
    /// (overlaps anything on the same calendar day).
    private static func shiftsOverlap(_ a: ScheduleEntry, _ b: ScheduleEntry) -> Bool {
        // Both have explicit times → numeric overlap check
        if let aStart = a.shiftStart, let aEnd = a.shiftEnd,
           let bStart = b.shiftStart, let bEnd = b.shiftEnd {
            return aStart < bEnd && bStart < aEnd
        }
        // At least one is "all day" — same calendar day = overlap
        return Calendar.current.isDate(a.date, inSameDayAs: b.date)
    }

    // MARK: - Phase 2: Overlap reporting helpers
    //
    // Used by the conflict descriptions so a crew double-book reads
    // "(overlap: 1h 15m)" instead of just "with overlapping shifts".
    // Resolution-sheet UX gets clearer the more specific the message is.

    /// Number of minutes of intersection between two shifts. Returns
    /// nil when either side lacks bounds (treat as all-day) or when
    /// the math comes out non-positive.
    private static func overlapMinutes(_ a: ScheduleEntry, _ b: ScheduleEntry) -> Int? {
        guard let aStart = a.shiftStart, let aEnd = a.shiftEnd,
              let bStart = b.shiftStart, let bEnd = b.shiftEnd else { return nil }
        let start = max(aStart, bStart)
        let end   = min(aEnd, bEnd)
        let secs  = end.timeIntervalSince(start)
        guard secs > 0 else { return nil }
        return Int(secs / 60)
    }

    /// Human-readable summary of the worst (largest) overlap among a
    /// group of shifts. Falls back to "all day" when the group has any
    /// untimed shift, and "<1 min" when overlap rounds to zero.
    fileprivate static func worstOverlapDescription(_ entries: [ScheduleEntry]) -> String {
        var worst = 0
        var anyUntimed = false
        for i in 0..<entries.count {
            for j in (i + 1)..<entries.count {
                if let mins = overlapMinutes(entries[i], entries[j]) {
                    if mins > worst { worst = mins }
                } else if Calendar.current.isDate(entries[i].date,
                                                  inSameDayAs: entries[j].date) {
                    anyUntimed = true
                }
            }
        }
        if anyUntimed && worst == 0 { return "all day" }
        if worst <= 0               { return "<1 min" }
        if worst < 60               { return "overlap: \(worst) min" }
        let h = worst / 60, m = worst % 60
        if m == 0                   { return "overlap: \(h)h" }
        return "overlap: \(h)h \(m)m"
    }

    // MARK: - Project Overlap

    /// Flags schedule entries booked for a project that is in a non-active
    /// state (on hold, completed, or cancelled), or that fall outside the
    /// project's start/end date window when those bounds are set.
    private static func detectProjectOverlaps(
        in entries: [ScheduleEntry],
        projects: [Project],
        calendar: Calendar
    ) -> [ScheduleConflict] {
        let projectByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var out: [ScheduleConflict] = []
        for entry in entries {
            guard let project = projectByID[entry.projectID] else { continue }
            let day = calendar.startOfDay(for: entry.date)

            // Status conflicts (project is not currently runnable).
            switch project.status {
            case .onHold:
                out.append(ScheduleConflict(
                    date: day, conflictType: .projectOverlap,
                    description: "Project '\(project.name)' is on hold",
                    affectedEntries: [entry]))
                continue
            case .completed:
                out.append(ScheduleConflict(
                    date: day, conflictType: .projectOverlap,
                    description: "Project '\(project.name)' is marked complete",
                    affectedEntries: [entry]))
                continue
            case .cancelled:
                out.append(ScheduleConflict(
                    date: day, conflictType: .projectOverlap,
                    description: "Project '\(project.name)' is cancelled",
                    affectedEntries: [entry]))
                continue
            default:
                break
            }

            // Date-window conflicts (entry falls outside project bounds).
            if let start = project.startDate, day < calendar.startOfDay(for: start) {
                out.append(ScheduleConflict(
                    date: day, conflictType: .projectOverlap,
                    description: "Shift is before project '\(project.name)' starts",
                    affectedEntries: [entry]))
            }
            if let end = project.endDate, day > calendar.startOfDay(for: end) {
                out.append(ScheduleConflict(
                    date: day, conflictType: .projectOverlap,
                    description: "Shift is after project '\(project.name)' ends",
                    affectedEntries: [entry]))
            }
        }
        return out
    }

    // MARK: - Weekend Work

    /// Flags entries scheduled on Saturday or Sunday as a notice.
    private static func detectWeekendWork(
        in entries: [ScheduleEntry],
        calendar: Calendar
    ) -> [ScheduleConflict] {
        return entries.compactMap { entry in
            let weekday = calendar.component(.weekday, from: entry.date)
            guard weekday == 1 || weekday == 7 else { return nil } // 1 = Sun, 7 = Sat
            return ScheduleConflict(
                date: calendar.startOfDay(for: entry.date),
                conflictType: .weekendWork,
                description: "Shift scheduled on \(weekday == 7 ? "Saturday" : "Sunday")",
                affectedEntries: [entry]
            )
        }
    }
}

// MARK: - AppStore Extension

extension AppStore {

    /// Pre-save check used by `upsertScheduleEntry`. Returns true if writing
    /// `entry` would create a NEW crew double-booking on its date that wasn't
    /// already there. Existing conflicts are not blocking — only new ones.
    /// Weekend-work and project-overlap conflicts are warnings, not blockers.
    func wouldDoubleBookCrew(_ entry: ScheduleEntry) -> ScheduleConflict? {
        guard let crewID = entry.crewID else { return nil }
        let cal = Calendar.current
        let day = cal.startOfDay(for: entry.date)
        // Active entries for this crew on this day, excluding the entry being saved.
        let sameCrewSameDay = scheduleEntries.filter { other in
            guard !other.isDeleted, other.id != entry.id else { return false }
            guard other.crewID == crewID else { return false }
            return cal.isDate(other.date, inSameDayAs: day)
        }
        // Conflict only if at least one existing entry is on a DIFFERENT project.
        guard sameCrewSameDay.contains(where: { $0.projectID != entry.projectID }) else {
            return nil
        }
        let group = sameCrewSameDay + [entry]
        let projectIDs = Set(group.map { $0.projectID })
        return ScheduleConflict(
            date: day,
            conflictType: .crewDoubleBooked,
            description: "Crew already booked on \(projectIDs.count - 1) other project\(projectIDs.count == 2 ? "" : "s") that day",
            affectedEntries: group
        )
    }

    /// Returns all conflicts across the full schedule.
    /// Phase 1 — uses the upgraded detector entry point so all five
    /// new detection types (employee-double-book, travel buffer,
    /// cert mismatch, overtime risk, plus refined crew-double-book
    /// time-overlap) run against the live store.
    var scheduleConflicts: [ScheduleConflict] {
        ScheduleConflictService.detect(
            in: scheduleEntries,
            projects: projects,
            crews: crews,
            employees: employees,
            travelBufferMinutes: AppSettings.shared.travelBufferMinutes,
            overtimeWeeklyThresholdHours: AppSettings.shared.overtimeWeeklyThresholdHours
        )
    }

    /// Returns conflicts at "Conflict" severity (red).
    /// Crew-double-book + employee-double-book + cert-missing all qualify.
    var criticalScheduleConflicts: [ScheduleConflict] {
        scheduleConflicts.filter {
            $0.conflictType == .crewDoubleBooked
            || $0.conflictType == .employeeDoubleBooked
            || $0.conflictType == .certificationMissing
        }
    }

    /// Returns conflicts for a specific day.
    func conflictsOn(date: Date) -> [ScheduleConflict] {
        let cal = Calendar.current
        return scheduleConflicts.filter {
            cal.isDate($0.date, inSameDayAs: date)
        }
    }

    /// Returns conflicts for a date range. Uses the upgraded
    /// detector with full Phase-1 inputs.
    func conflicts(from start: Date, to end: Date) -> [ScheduleConflict] {
        let cal = Calendar.current
        let inRange = scheduleEntries.filter {
            let d = cal.startOfDay(for: $0.date)
            return d >= cal.startOfDay(for: start) && d <= cal.startOfDay(for: end)
        }
        return ScheduleConflictService.detect(
            in: inRange,
            projects: projects,
            crews: crews,
            employees: employees,
            travelBufferMinutes: AppSettings.shared.travelBufferMinutes,
            overtimeWeeklyThresholdHours: AppSettings.shared.overtimeWeeklyThresholdHours
        )
    }
}
