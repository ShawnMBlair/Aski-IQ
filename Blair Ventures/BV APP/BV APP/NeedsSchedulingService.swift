// NeedsSchedulingService.swift
// Aski IQ — Phase A Scheduling Command Centre.
//
// PURPOSE
// Derives the "what work needs scheduling?" list from data already in
// the AppStore. No DB tables, no migrations — every item type is
// computed from existing records. Returning a single unified array
// lets the Command Centre's first section render uniformly across
// quotes, projects, material sales, and change orders.
//
// DESIGN RULES
//   • Pure read — never mutates the store.
//   • Cheap — runs on-demand per body recompute. No background work.
//   • Idempotent — same inputs always return the same items in the
//     same order.
//   • Defensive — when source data is incomplete (missing site,
//     missing date, etc.) the item is still returned, but with
//     warnings attached. The Command Centre surfaces the warnings
//     so the user fixes the upstream record before scheduling.
//
// EXTENSION
// To add a new source type later, register a derive method here.
// The compute() pipeline keeps each source independent so a regression
// in one detector can't suppress the others.

import Foundation

// MARK: - Source context (passed forward into ScheduleEntryCreateEditView)

/// Lightweight value type carried from a Command Centre card into the
/// schedule create/edit flow. Lets the entry editor pre-fill known
/// fields from the source record (project, client, site, work type,
/// suggested crew, etc.) so the user doesn't re-type.
///
/// Optional throughout — the editor must tolerate any subset being
/// nil. Phase A ships the type and prefill wiring; the real auto-fill
/// breadth grows as more derive methods land in NeedsSchedulingService.
struct ScheduleSourceContext: Equatable, Identifiable {
    /// `Identifiable` so the SchedulingCommandCentreView can present
    /// the editor via `.sheet(item:)`. We compose the id from
    /// `sourceType + sourceID` rather than just `sourceID` so the same
    /// underlying UUID can never collide across source types (a
    /// project and a quote could in theory share an id; the type
    /// prefix prevents the sheet from getting confused mid-presentation).
    var id: String { "\(sourceType.rawValue).\(sourceID.uuidString)" }
    let sourceID: UUID
    let sourceType: NeedsSchedulingSourceType
    let projectID: UUID?
    let clientName: String?
    let siteName: String?
    let siteAddress: String?
    let workType: String?
    let costCode: String?
    let suggestedDate: Date?
    let suggestedStartTime: Date?
    let suggestedEndTime: Date?
    let suggestedCrewID: UUID?
    let requiredCertifications: [String]
}

// MARK: - Source type

enum NeedsSchedulingSourceType: String, Codable, Equatable {
    case quote          = "quote"
    case project        = "project"
    case materialSale   = "material_sale"
    case rental         = "rental"
    case changeOrder    = "change_order"
    case internalWork   = "internal_work"

    var label: String {
        switch self {
        case .quote:        return "Quote"
        case .project:      return "Project"
        case .materialSale: return "Material Sale"
        case .rental:       return "Rental"
        case .changeOrder:  return "Change Order"
        case .internalWork: return "Internal Work"
        }
    }

    var icon: String {
        switch self {
        case .quote:        return "doc.text.fill"
        case .project:      return "folder.fill"
        case .materialSale: return "shippingbox.fill"
        case .rental:       return "wrench.and.screwdriver.fill"
        case .changeOrder:  return "arrow.left.arrow.right"
        case .internalWork: return "hammer.fill"
        }
    }
}

// MARK: - Warning

/// Non-blocking flags surfaced on a Command Centre card. The user
/// can still tap Schedule — the warnings just feed forward into the
/// editor as pre-flight hints.
enum NeedsSchedulingWarning: String, Equatable {
    case missingSite
    case missingDate
    case missingCrew
    case conflictRisk
    case missingRequiredCertification
    case overtimeRisk

    var label: String {
        switch self {
        case .missingSite:                  return "No site set"
        case .missingDate:                  return "No date suggested"
        case .missingCrew:                  return "No crew suggested"
        case .conflictRisk:                 return "Suggested crew may conflict"
        case .missingRequiredCertification: return "Required cert may be unmet"
        case .overtimeRisk:                 return "Suggested crew nearing OT"
        }
    }

    var icon: String {
        switch self {
        case .missingSite:                  return "mappin.slash"
        case .missingDate:                  return "calendar.badge.exclamationmark"
        case .missingCrew:                  return "person.crop.circle.badge.questionmark"
        case .conflictRisk:                 return "exclamationmark.triangle.fill"
        case .missingRequiredCertification: return "checkmark.shield"
        case .overtimeRisk:                 return "clock.badge.exclamationmark"
        }
    }
}

// MARK: - Item

struct NeedsSchedulingItem: Identifiable, Equatable {
    /// Stable across recomputes — derived from `sourceType + sourceID`
    /// so SwiftUI's ForEach diffs don't reset card state on re-render.
    let id: String
    let sourceID: UUID
    let sourceType: NeedsSchedulingSourceType
    let title: String
    let clientName: String?
    let siteName: String?
    let siteAddress: String?
    let workType: String?
    let suggestedDate: Date?
    let suggestedStartTime: Date?
    let suggestedEndTime: Date?
    let suggestedCrewID: UUID?
    let requiredCertifications: [String]
    let costCode: String?
    let projectID: UUID?
    let warnings: [NeedsSchedulingWarning]
    /// Sort priority: lower = more urgent. Drives the order cards appear.
    let priority: Int

    /// Convert to the context payload that the schedule editor consumes.
    var sourceContext: ScheduleSourceContext {
        ScheduleSourceContext(
            sourceID:               sourceID,
            sourceType:             sourceType,
            projectID:              projectID,
            clientName:             clientName,
            siteName:               siteName,
            siteAddress:            siteAddress,
            workType:               workType,
            costCode:               costCode,
            suggestedDate:          suggestedDate,
            suggestedStartTime:     suggestedStartTime,
            suggestedEndTime:       suggestedEndTime,
            suggestedCrewID:        suggestedCrewID,
            requiredCertifications: requiredCertifications
        )
    }
}

// MARK: - Service

enum NeedsSchedulingService {

    /// Compute the unified worklist. Independent per-source detectors
    /// run sequentially; a regression in one doesn't suppress others.
    /// Returned items are sorted by priority then suggestedDate so the
    /// most urgent work bubbles to the top.
    static func compute(store: AppStore) -> [NeedsSchedulingItem] {
        var items: [NeedsSchedulingItem] = []
        items += deriveFromAcceptedQuotes(store: store)
        items += deriveFromMaterialSales(store: store)
        items += deriveFromApprovedChangeOrders(store: store)
        items += deriveFromActiveProjects(store: store)
        // Sort: urgency first, then earliest suggested date, then title
        // so consecutive renders show a stable order.
        return items.sorted { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            switch (a.suggestedDate, b.suggestedDate) {
            case let (l?, r?): return l < r
            case (nil, _?):    return false
            case (_?, nil):    return true
            case (nil, nil):   return a.title < b.title
            }
        }
    }

    // MARK: - Source: Accepted quotes not yet scheduled

    /// A quote is "needs scheduling" when:
    ///   • status == .accepted
    ///   • not deleted
    ///   • either has a `projectID` AND no future schedule entry on it,
    ///     OR has no `projectID` yet (still needs to be converted —
    ///     surfaces as a warning + lets the user start scheduling
    ///     anyway with whatever they do have).
    private static func deriveFromAcceptedQuotes(store: AppStore) -> [NeedsSchedulingItem] {
        let today = Calendar.current.startOfDay(for: Date())
        let scheduledProjectIDs: Set<UUID> = Set(
            store.scheduleEntries
                .filter { !$0.isDeleted && $0.date >= today }
                .map { $0.projectID }
        )
        return store.quotes.compactMap { quote in
            guard !quote.isDeleted else { return nil }
            guard quote.status == .accepted else { return nil }

            // If the quote IS linked to a project AND that project
            // already has a future shift, consider it handled.
            if let pid = quote.projectID, scheduledProjectIDs.contains(pid) {
                return nil
            }

            var warnings: [NeedsSchedulingWarning] = []
            if quote.siteAddress == nil || quote.siteAddress?.isEmpty == true {
                warnings.append(.missingSite)
            }
            if quote.projectID == nil {
                warnings.append(.missingCrew) // no project = no derivable crew
            }

            // Suggested date: the day after acceptance + 7 (if known),
            // else 7 days out from now. Conservative — gives the office
            // a week of lead time by default.
            let baseDate = quote.acceptedAt ?? Date()
            let suggested = Calendar.current.date(byAdding: .day, value: 7, to: baseDate)

            return NeedsSchedulingItem(
                id:                     "quote.\(quote.id.uuidString)",
                sourceID:               quote.id,
                sourceType:             .quote,
                title:                  quote.jobNumber.isEmpty ? "Quote \(quote.id.uuidString.prefix(8))" : quote.jobNumber,
                clientName:             quote.clientName,
                siteName:               nil,
                siteAddress:            quote.siteAddress,
                workType:               nil,
                suggestedDate:          suggested,
                suggestedStartTime:     nil,
                suggestedEndTime:       nil,
                // SR-1 follow-up: prefer the quote's take-off preference,
                // then fall back to the project's preference (if linked),
                // then last-used crew on the project. The engine treats
                // a preferred-resource match as a signal to extend its
                // availability scan to 60 days.
                suggestedCrewID:        quote.preferredCrewID
                                            ?? suggestCrewID(forProject: quote.projectID, store: store),
                requiredCertifications: [],
                costCode:               nil,
                projectID:              quote.projectID,
                warnings:               warnings,
                priority:               10
            )
        }
    }

    // MARK: - Source: Material sales needing fulfillment

    /// A material sale needs scheduling when:
    ///   • status is active (not paid/cancelled/draft)
    ///   • has a requestedDeliveryDate OR a project link
    ///   • that delivery date isn't already covered by a schedule entry
    private static func deriveFromMaterialSales(store: AppStore) -> [NeedsSchedulingItem] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return store.materialSales.compactMap { sale in
            guard !sale.isDeleted else { return nil }
            // Skip terminal states
            guard sale.status.isActive else { return nil }
            // Only surface sales with at least a delivery date OR a
            // project link to attach a shift against — otherwise we
            // don't have enough to suggest anything.
            guard sale.requestedDeliveryDate != nil || sale.projectID != nil else { return nil }

            // Already covered by a future shift? (matches by project)
            if let pid = sale.projectID,
               store.scheduleEntries.contains(where: {
                   $0.projectID == pid
                   && !$0.isDeleted
                   && $0.date >= today
               }) {
                return nil
            }

            var warnings: [NeedsSchedulingWarning] = []
            if sale.deliveryAddress == nil || sale.deliveryAddress?.isEmpty == true {
                warnings.append(.missingSite)
            }
            if sale.requestedDeliveryDate == nil {
                warnings.append(.missingDate)
            }

            return NeedsSchedulingItem(
                id:                     "msale.\(sale.id.uuidString)",
                sourceID:               sale.id,
                sourceType:             .materialSale,
                title:                  sale.saleNumber.isEmpty ? "Material Sale" : sale.saleNumber,
                clientName:             store.clients.first(where: { $0.id == sale.clientID })?.name,
                siteName:               nil,
                siteAddress:            sale.deliveryAddress,
                workType:               "Delivery",
                suggestedDate:          sale.requestedDeliveryDate,
                suggestedStartTime:     sale.requestedDeliveryDate.flatMap {
                    cal.date(bySettingHour: 8, minute: 0, second: 0, of: $0)
                },
                suggestedEndTime:       sale.requestedDeliveryDate.flatMap {
                    cal.date(bySettingHour: 12, minute: 0, second: 0, of: $0)
                },
                suggestedCrewID:        suggestCrewID(forProject: sale.projectID, store: store),
                requiredCertifications: [],
                costCode:               nil,
                projectID:              sale.projectID,
                warnings:               warnings,
                priority:               sale.requestedDeliveryDate.map { rd in
                    cal.isDateInToday(rd) ? 0 : (rd < Date().addingTimeInterval(86_400 * 3) ? 5 : 20)
                } ?? 25
            )
        }
    }

    // MARK: - Source: Approved change orders adding crew time

    /// A change order needs scheduling when:
    ///   • status == .approved
    ///   • scheduleImpactDays > 0 OR effectiveCostImpact > 0 with crew implied
    ///   • the parent project doesn't already have a future shift that
    ///     would absorb the additional work (heuristic — same project +
    ///     date >= today).
    private static func deriveFromApprovedChangeOrders(store: AppStore) -> [NeedsSchedulingItem] {
        let today = Calendar.current.startOfDay(for: Date())
        return store.changeOrders.compactMap { co in
            guard !co.isDeleted, co.status == .approved else { return nil }
            // Heuristic: only surface when there's an obvious crew time
            // impact. Money-only COs don't need a schedule.
            guard co.scheduleImpactDays > 0 else { return nil }

            // Already covered by a future shift on this project?
            // We don't know which CO a future shift covers, so this
            // is approximate — a project with future shifts is treated
            // as "probably handled." A future field
            // `ScheduleEntry.sourceWorkID` would let us be precise.
            let hasFutureShift = store.scheduleEntries.contains {
                $0.projectID == co.projectID
                && !$0.isDeleted
                && $0.date >= today
            }
            if hasFutureShift { return nil }

            let project = store.projects.first(where: { $0.id == co.projectID })
            return NeedsSchedulingItem(
                id:                     "co.\(co.id.uuidString)",
                sourceID:               co.id,
                sourceType:             .changeOrder,
                title:                  co.title.isEmpty ? co.number : co.title,
                clientName:             project?.clientName,
                siteName:               nil,
                siteAddress:            project?.siteAddress,
                workType:               co.type.displayName,
                suggestedDate:          Calendar.current.date(byAdding: .day, value: 3, to: Date()),
                suggestedStartTime:     nil,
                suggestedEndTime:       nil,
                suggestedCrewID:        suggestCrewID(forProject: co.projectID, store: store),
                requiredCertifications: [],
                costCode:               nil,
                projectID:              co.projectID,
                warnings:               [],
                priority:               15
            )
        }
    }

    // MARK: - Source: Active projects with no upcoming shift

    /// Catches projects that are open and active but have no scheduled
    /// work in the future. Lower priority than the work-derived sources
    /// because it's the most generic — any project will surface here
    /// once it goes a few days without scheduling.
    ///
    /// Excludes projects that are already covered by another item
    /// (quote, material sale, CO) so we don't show the same project
    /// twice on the same load.
    private static func deriveFromActiveProjects(store: AppStore) -> [NeedsSchedulingItem] {
        let today = Calendar.current.startOfDay(for: Date())
        // Build the "already covered" set across the other sources.
        let coveredByQuote = Set(store.quotes
            .filter { !$0.isDeleted && $0.status == .accepted }
            .compactMap { $0.projectID })
        let coveredByMSale = Set(store.materialSales
            .filter { !$0.isDeleted && $0.status.isActive }
            .compactMap { $0.projectID })
        let coveredByCO = Set(store.changeOrders
            .filter { !$0.isDeleted && $0.status == .approved && $0.scheduleImpactDays > 0 }
            .map { $0.projectID })
        let alreadyCovered = coveredByQuote.union(coveredByMSale).union(coveredByCO)

        return store.projects.compactMap { project in
            guard !project.isDeleted else { return nil }
            // `.awarded` is post-acceptance pre-kickoff — the most
            // critical bucket. `.active` is in-flight projects that
            // somehow have no upcoming shift (gap recovery). Both
            // need scheduling attention.
            guard project.status == .active || project.status == .awarded else { return nil }
            // Skip if covered by another source above
            if alreadyCovered.contains(project.id) { return nil }
            // Skip if already has a future shift
            if store.scheduleEntries.contains(where: {
                $0.projectID == project.id
                && !$0.isDeleted
                && $0.date >= today
            }) { return nil }
            // Skip projects with no start date (still in setup)
            // unless they're explicitly active. The status guard above
            // already filters most setup-stage records.
            return NeedsSchedulingItem(
                id:                     "proj.\(project.id.uuidString)",
                sourceID:               project.id,
                sourceType:             .project,
                title:                  project.name,
                clientName:             project.clientName,
                siteName:               nil,
                siteAddress:            project.siteAddress,
                workType:               nil,
                suggestedDate:          project.startDate ?? Calendar.current.date(byAdding: .day, value: 1, to: Date()),
                suggestedStartTime:     nil,
                suggestedEndTime:       nil,
                suggestedCrewID:        suggestCrewID(forProject: project.id, store: store),
                requiredCertifications: [],
                costCode:               nil,
                projectID:              project.id,
                warnings:               project.siteAddress == nil ? [.missingSite] : [],
                // .awarded ranks higher than a generic .active gap —
                // freshly-won work needs a kickoff plan more urgently
                // than an in-flight project that's between shifts.
                priority:               project.status == .awarded ? 12 : 30
            )
        }
    }

    // MARK: - Helper: crew suggestion

    /// Returns the suggested crew for a project. Resolution order:
    ///   1. Project's `preferredCrewID` (SR-1 follow-up — set during
    ///      take-off on the source quote, threaded to project on
    ///      conversion). When present, this is a STRONG preference;
    ///      the recommendation engine will extend its availability
    ///      horizon to 60 days to find a window where this crew has
    ///      gaps.
    ///   2. Most-recently-used crew on this project (historical fit).
    ///   3. nil — engine will pick best available.
    private static func suggestCrewID(forProject projectID: UUID?, store: AppStore) -> UUID? {
        guard let pid = projectID else { return nil }
        // 1. Take-off preference wins.
        if let project = store.projects.first(where: { $0.id == pid }),
           let preferred = project.preferredCrewID {
            return preferred
        }
        // 2. Last-used fallback.
        return store.scheduleEntries
            .filter { !$0.isDeleted && $0.projectID == pid && $0.crewID != nil }
            .sorted { $0.date > $1.date }
            .first?
            .crewID
    }
}

// MARK: - AppStore extension: Section data for Command Centre

extension AppStore {

    /// Convenience used by Command Centre Section 1.
    var needsSchedulingItems: [NeedsSchedulingItem] {
        NeedsSchedulingService.compute(store: self)
    }

    /// Section 2 data: today's assigned shifts, sorted by start time.
    /// Returns assigned only — unassigned shifts surface in Section 3
    /// (Issues) under .missingCrew if they exist for today.
    var todayScheduleEntries: [ScheduleEntry] {
        let cal = Calendar.current
        return scheduleEntries
            .filter { !$0.isDeleted && cal.isDateInToday($0.date) }
            .filter { $0.status != .cancelled && $0.status != .completed }
            .sorted { (a, b) in
                switch (a.shiftStart, b.shiftStart) {
                case let (l?, r?): return l < r
                case (nil, _?):    return true
                case (_?, nil):    return false
                case (nil, nil):   return a.id.uuidString < b.id.uuidString
                }
            }
    }

    /// Section 3 data: live conflicts + missing-data shifts. Phase A
    /// surfaces 4 missing-data classes (no time, no crew where required,
    /// no project — defensive, normally enforced by save). Live
    /// ScheduleConflicts (all 7 detector types) come along for free
    /// from `liveScheduleConflicts`.
    func commandCentreIssues() -> CommandCentreIssues {
        var missing: [MissingDataIssue] = []
        let today = Calendar.current.startOfDay(for: Date())
        for entry in scheduleEntries where !entry.isDeleted {
            // Only surface forward-looking shifts. Past missing-data
            // is a reporting concern, not an action item.
            if entry.date < today { continue }
            if entry.status == .cancelled || entry.status == .completed { continue }
            if entry.crewID == nil {
                missing.append(.init(entry: entry, kind: .missingCrew))
            }
            if entry.shiftStart == nil && entry.shiftEnd == nil {
                missing.append(.init(entry: entry, kind: .missingTime))
            }
        }
        return CommandCentreIssues(
            conflicts: liveScheduleConflicts,
            missing: missing
        )
    }

    /// Section 4 data: per-crew capacity row.
    var crewAvailabilitySnapshot: [CrewAvailabilityRow] {
        let cal = Calendar.current
        let weekStart: Date = {
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
            return cal.date(from: comps) ?? cal.startOfDay(for: Date())
        }()
        let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let threshold = AppSettings.shared.overtimeWeeklyThresholdHours
        // Index live conflicts by crew so each row knows whether the
        // crew is currently in a clash without rerunning the detector.
        let conflictedCrewIDs: Set<UUID> = Set(
            liveScheduleConflicts
                .flatMap { $0.affectedEntries.compactMap { $0.crewID } }
        )

        return crews
            .filter { $0.isActive && !$0.isDeleted }
            .map { crew -> CrewAvailabilityRow in
                let crewShifts = scheduleEntries.filter {
                    !$0.isDeleted
                    && $0.crewID == crew.id
                    && $0.status != .cancelled
                    && $0.date >= weekStart
                    && $0.date <= weekEnd
                }
                let weekHours = crewShifts.reduce(0.0) { acc, e in
                    acc + estimatedHours(for: e)
                }
                let todayHours = crewShifts
                    .filter { cal.isDateInToday($0.date) }
                    .reduce(0.0) { $0 + estimatedHours(for: $1) }

                let bucket: CrewAvailabilityRow.Bucket = {
                    if conflictedCrewIDs.contains(crew.id) { return .atRisk }
                    if threshold > 0 && weekHours >= threshold { return .atRisk }
                    if threshold > 0 && weekHours >= threshold * 0.8 { return .busy }
                    if weekHours > 0 { return .busy }
                    return .available
                }()

                let foreman = crew.foremanID.flatMap { fid in
                    employees.first(where: { $0.id == fid })
                }

                return CrewAvailabilityRow(
                    crewID: crew.id,
                    crewName: crew.name,
                    foremanName: foreman?.fullName,
                    todayHours: todayHours,
                    weekHours: weekHours,
                    weekThreshold: threshold,
                    bucket: bucket,
                    inLiveConflict: conflictedCrewIDs.contains(crew.id)
                )
            }
            .sorted { ($0.bucket.sortOrder, $0.crewName) < ($1.bucket.sortOrder, $1.crewName) }
    }

    /// Estimated hours for a single shift. Falls back to 8h when the
    /// shift has no explicit start/end (full-day default).
    private func estimatedHours(for entry: ScheduleEntry) -> Double {
        guard let s = entry.shiftStart, let e = entry.shiftEnd else { return 8 }
        let secs = e.timeIntervalSince(s)
        return secs > 0 ? secs / 3600 : 8
    }

    // MARK: - RA-4: Individual-worker availability snapshot
    //
    // Parallel to `crewAvailabilitySnapshot`. Pre-RA-4 the Command
    // Centre's "Crew Availability" section only showed crews — fine
    // when every shift was a fixed-crew shift, misleading once
    // custom-crew and individual-worker shifts existed (the workers
    // on those shifts were invisible at the capacity level).
    //
    // SCOPE: only includes workers with at least one DIRECT assignment
    // (custom_crew or individual_worker) this week. Pure crew members
    // are represented through their crew's row — surfacing them
    // separately would double-count and clutter the list. A worker
    // who's on a fixed crew Mon and an individual shift Wed appears
    // in both their crew's row AND their own row (correct: they're
    // contributing to two different load views).

    var workerAvailabilitySnapshot: [WorkerAvailabilityRow] {
        let cal = Calendar.current
        let weekStart: Date = {
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
            return cal.date(from: comps) ?? cal.startOfDay(for: Date())
        }()
        let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let threshold = AppSettings.shared.overtimeWeeklyThresholdHours

        // Workers who have ANY direct assignment this week. We use
        // assignedWorkerIDs (populated for custom_crew + individual_worker
        // and also for any future fixed-crew roster overrides).
        let weekShifts = scheduleEntries.filter {
            !$0.isDeleted
            && $0.status != .cancelled
            && $0.date >= weekStart
            && $0.date <= weekEnd
            && !$0.assignedWorkerIDs.isEmpty
        }
        let directWorkerIDs: Set<UUID> = Set(weekShifts.flatMap { $0.assignedWorkerIDs })
        guard !directWorkerIDs.isEmpty else { return [] }

        // Conflict membership at the worker level.
        let conflictedWorkerIDs: Set<UUID> = {
            var ids: Set<UUID> = []
            for c in liveScheduleConflicts {
                for entry in c.affectedEntries {
                    ids.formUnion(entry.assignedWorkerIDs)
                }
            }
            return ids
        }()

        return directWorkerIDs.compactMap { workerID -> WorkerAvailabilityRow? in
            guard let emp = employees.first(where: { $0.id == workerID && $0.isActive }) else {
                return nil
            }
            let workerShifts = weekShifts.filter { $0.assignedWorkerIDs.contains(workerID) }
            let weekHours = workerShifts.reduce(0.0) { acc, e in
                acc + estimatedHours(for: e)
            }
            let todayHours = workerShifts
                .filter { cal.isDateInToday($0.date) }
                .reduce(0.0) { $0 + estimatedHours(for: $1) }

            let bucket: WorkerAvailabilityRow.Bucket = {
                if conflictedWorkerIDs.contains(workerID) { return .atRisk }
                if threshold > 0 && weekHours >= threshold { return .atRisk }
                if threshold > 0 && weekHours >= threshold * 0.8 { return .busy }
                if weekHours > 0 { return .busy }
                return .available
            }()

            return WorkerAvailabilityRow(
                workerID: workerID,
                workerName: emp.fullName,
                trade: emp.trade,
                todayHours: todayHours,
                weekHours: weekHours,
                weekThreshold: threshold,
                bucket: bucket,
                inLiveConflict: conflictedWorkerIDs.contains(workerID)
            )
        }
        .sorted { ($0.bucket.sortOrder, $0.workerName) < ($1.bucket.sortOrder, $1.workerName) }
    }
}

// MARK: - Section 3 data shapes

struct CommandCentreIssues: Equatable {
    let conflicts: [ScheduleConflict]
    let missing: [MissingDataIssue]

    var totalCount: Int { conflicts.count + missing.count }

    static func == (lhs: CommandCentreIssues, rhs: CommandCentreIssues) -> Bool {
        // ScheduleConflict.id is a fresh UUID per detection pass, so we
        // compare by stable signature. Good enough for SwiftUI diffing —
        // the parent recomputes whenever scheduleEntries changes anyway.
        lhs.conflicts.count == rhs.conflicts.count && lhs.missing == rhs.missing
    }
}

struct MissingDataIssue: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case missingCrew
        case missingTime
        case missingProject

        var label: String {
            switch self {
            case .missingCrew:    return "No crew assigned"
            case .missingTime:    return "No shift times set"
            case .missingProject: return "No project linked"
            }
        }

        var icon: String {
            switch self {
            case .missingCrew:    return "person.crop.circle.badge.questionmark"
            case .missingTime:    return "clock.badge.questionmark"
            case .missingProject: return "folder.badge.questionmark"
            }
        }

        var recommendation: String {
            switch self {
            case .missingCrew:    return "Assign a crew before the shift starts."
            case .missingTime:    return "Set start and end times so the crew knows when to arrive."
            case .missingProject: return "Link the shift to a project so cost coding works."
            }
        }
    }

    let entry: ScheduleEntry
    let kind: Kind

    var id: String { "\(entry.id.uuidString).\(kind.rawValue)" }
}

// MARK: - Section 4 data shape

struct CrewAvailabilityRow: Identifiable, Equatable {
    enum Bucket: Equatable {
        case available
        case busy
        case atRisk
        case notQualified  // Phase A doesn't have qualification scoring yet

        var label: String {
            switch self {
            case .available:    return "Available"
            case .busy:         return "Busy"
            case .atRisk:       return "At Risk"
            case .notQualified: return "Not Qualified"
            }
        }

        var sortOrder: Int {
            switch self {
            case .available:    return 0
            case .busy:         return 1
            case .atRisk:       return 2
            case .notQualified: return 3
            }
        }
    }

    let crewID: UUID
    let crewName: String
    let foremanName: String?
    let todayHours: Double
    let weekHours: Double
    let weekThreshold: Double
    let bucket: Bucket
    let inLiveConflict: Bool

    var id: UUID { crewID }
}

// MARK: - RA-4: Individual-worker availability row
//
// Parallel to CrewAvailabilityRow. Same shape so the Command Centre
// can render both in a unified strip without diverging UI code.
// Re-uses CrewAvailabilityRow.Bucket so the bucket sort/labels stay
// consistent between crews and individuals.

struct WorkerAvailabilityRow: Identifiable, Equatable {
    typealias Bucket = CrewAvailabilityRow.Bucket
    let workerID: UUID
    let workerName: String
    let trade: String?
    let todayHours: Double
    let weekHours: Double
    let weekThreshold: Double
    let bucket: Bucket
    let inLiveConflict: Bool
    var id: UUID { workerID }
}
