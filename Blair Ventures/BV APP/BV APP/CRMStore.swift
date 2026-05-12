// CRMStore.swift
// BV APP – CRM AppStore Extension

import Foundation

// MARK: - Business Day Helper

private func addBusinessDays(_ days: Int, to date: Date) -> Date {
    var result = date
    var added = 0
    let calendar = Calendar.current
    while added < days {
        result = calendar.date(byAdding: .day, value: 1, to: result) ?? result
        let weekday = calendar.component(.weekday, from: result)
        if weekday != 1 && weekday != 7 { added += 1 }
    }
    return result
}

// MARK: - CRM Persistence

extension AppStore {

    func loadCRMData() {}   // no-op — CRM data lives in Supabase

    func saveCRMData() {}   // no-op — CRM data lives in Supabase

    // MARK: - Attachment File Storage

    var crmAttachmentsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("CRMAttachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func attachmentFileURL(_ attachment: CRMAttachment) -> URL {
        crmAttachmentsDirectory.appendingPathComponent(attachment.localPath)
    }

    func attachments(for entityID: UUID) -> [CRMAttachment] {
        crmAttachments.filter { $0.entityID == entityID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Saves file data to disk and registers the attachment metadata.
    @discardableResult
    func addCRMAttachment(
        entityID: UUID,
        entityType: CRMEntityType,
        fileName: String,
        fileType: CRMAttachmentFileType,
        data: Data,
        thumbnailData: Data? = nil
    ) -> CRMAttachment? {
        guard requireRole([.officeAdmin, .manager, .executive, .projectManager, .estimator],
                          action: "add_crm_attachment") else { return nil }
        let ext = (fileName as NSString).pathExtension
        let localPath = "\(UUID().uuidString).\(ext.isEmpty ? "bin" : ext)"
        let fileURL = crmAttachmentsDirectory.appendingPathComponent(localPath)
        try? data.write(to: fileURL, options: .atomic)

        var attachment = CRMAttachment(
            entityID: entityID,
            entityType: entityType,
            fileName: fileName,
            fileType: fileType,
            localPath: localPath
        )
        attachment.fileSize = Int64(data.count)
        attachment.thumbnailData = thumbnailData
        if let u = currentUser {
            attachment.createdBy = "\(u.firstName) \(u.lastName)".trimmingCharacters(in: .whitespaces)
        }

        crmAttachments.append(attachment)
        saveCRMData()
        logCRMActivity(
            type: .fileUploaded,
            title: "File attached: \(fileName)",
            notes: "",
            clientID: entityType == .company ? entityID : nil,
            contactID: entityType == .contact ? entityID : nil,
            opportunityID: entityType == .opportunity ? entityID : nil,
            quoteID: nil,
            projectID: nil
        )
        return attachment
    }

    func deleteCRMAttachment(_ attachment: CRMAttachment) {
        guard requireRole([.officeAdmin, .manager, .executive],
                          action: "delete_crm_attachment") else { return }
        // Remove local file immediately (file storage only)
        let fileURL = attachmentFileURL(attachment)
        try? FileManager.default.removeItem(at: fileURL)
        // Soft-delete the record for Supabase sync
        guard let idx = crmAttachments.firstIndex(where: { $0.id == attachment.id }) else { return }
        var deleted = crmAttachments[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        crmAttachments[idx] = deleted
    }

    // MARK: - Contact CRUD

    func upsertCRMContact(_ item: CRMContact) {
        guard requireRole([.officeAdmin, .manager, .executive, .projectManager, .estimator],
                          action: "upsert_crm_contact") else { return }
        var updated = item
        updated.syncStatus  = .pending
        updated.updatedAt   = Date()
        if let idx = crmContacts.firstIndex(where: { $0.id == item.id }) {
            crmContacts[idx] = updated
        } else {
            crmContacts.append(updated)
        }
        saveCRMData()
        Task { await SyncEngine.shared.pushPendingCRMContacts() }
    }

    func deleteCRMContact(_ item: CRMContact) {
        guard requireRole([.manager, .executive],
                          action: "delete_crm_contact") else { return }
        guard let idx = crmContacts.firstIndex(where: { $0.id == item.id }) else { return }
        var deleted = crmContacts[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        crmContacts[idx] = deleted
        Task { await SyncEngine.shared.pushPendingCRMContacts() }
    }

    func contacts(for clientID: UUID) -> [CRMContact] {
        crmContacts.filter { $0.clientID == clientID }
    }

    func primaryContact(for clientID: UUID) -> CRMContact? {
        contacts(for: clientID).first(where: { $0.isPrimary }) ?? contacts(for: clientID).first
    }

    // MARK: - Opportunity CRUD

    func upsertCRMOpportunity(_ item: CRMOpportunity) {
        guard requireRole([.officeAdmin, .manager, .executive, .projectManager, .estimator],
                          action: "upsert_crm_opportunity") else { return }
        var updated = item
        updated.syncStatus = .pending
        updated.updatedAt  = Date()

        if let idx = crmOpportunities.firstIndex(where: { $0.id == item.id }) {
            let existing = crmOpportunities[idx]

            // ── Terminal-stage protection ─────────────────────────────────────
            // Once won or lost, stage/outcome fields are locked from stale writes.
            var protected = updated
            if (existing.stage == .won || existing.stage == .lost),
               item.stage != existing.stage {
                protected.stage       = existing.stage
                protected.probability = existing.probability
                protected.wonAt       = existing.wonAt
                protected.lostAt      = existing.lostAt
                if protected.projectID == nil { protected.projectID = existing.projectID }
            }

            if existing.stage != protected.stage {
                logCRMActivity(
                    type: .stageChanged,
                    title: "Stage changed: \(existing.stage.rawValue) → \(protected.stage.rawValue)",
                    notes: protected.title,
                    clientID: protected.clientID,
                    contactID: protected.contactID,
                    opportunityID: protected.id,
                    quoteID: protected.quoteID,
                    projectID: protected.projectID
                )
            }
            // v1.1 — workType change audit. Routing depends on this
            // field so the change should always be visible in history.
            if existing.workType != protected.workType {
                logCRMActivity(
                    type: .workTypeChanged,
                    title: "Work Type changed: \(existing.workType.displayName) → \(protected.workType.displayName)",
                    notes: protected.workType.routingDescription,
                    clientID: protected.clientID,
                    contactID: protected.contactID,
                    opportunityID: protected.id,
                    quoteID: protected.quoteID,
                    projectID: protected.projectID
                )
            }
            crmOpportunities[idx] = protected
        } else {
            crmOpportunities.append(updated)
        }
        saveCRMData()
        Task { await SyncEngine.shared.pushPendingCRMOpportunities() }
        // Week 4 audit closeout: index the opportunity in Spotlight
        // so admins can search "Smith retrofit" from the Home Screen.
        // Resolve the latest stored value (post protection) so we
        // index the row that actually landed.
        if let stored = crmOpportunities.first(where: { $0.id == item.id }) {
            SpotlightService.shared.upsert(opportunity: stored)
        }
    }

    func deleteCRMOpportunity(_ item: CRMOpportunity) {
        guard requireRole([.manager, .executive],
                          action: "delete_crm_opportunity") else { return }
        guard let idx = crmOpportunities.firstIndex(where: { $0.id == item.id }) else { return }
        var deleted = crmOpportunities[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        crmOpportunities[idx] = deleted
        Task { await SyncEngine.shared.pushPendingCRMOpportunities() }
    }

    func opportunities(for clientID: UUID) -> [CRMOpportunity] {
        crmOpportunities.filter { $0.clientID == clientID }
    }

    var openOpportunities: [CRMOpportunity] {
        crmOpportunities.filter { $0.isActive }
    }

    var pipelineValue: Decimal {
        openOpportunities.reduce(0) { $0 + $1.value }
    }

    /// Open pipeline value for a single client.
    func pipelineValue(for clientID: UUID) -> Decimal {
        crmOpportunities
            .filter { $0.clientID == clientID && $0.isActive && !$0.isDeleted }
            .reduce(0) { $0 + $1.value }
    }

    var weightedPipelineValue: Decimal {
        openOpportunities.reduce(0) { $0 + $1.weightedValue }
    }

    // MARK: - Task CRUD

    func upsertCRMTask(_ item: CRMTask) {
        guard requireRole([.officeAdmin, .manager, .executive, .projectManager, .estimator,
                           .foreman],
                          action: "upsert_crm_task") else { return }
        var updated = item
        updated.syncStatus = .pending
        updated.updatedAt  = Date()

        if let idx = crmTasks.firstIndex(where: { $0.id == item.id }) {
            let existing = crmTasks[idx]
            crmTasks[idx] = updated
            if existing.status != .done && updated.status == .done {
                logCRMActivity(
                    type: .taskCompleted,
                    title: "Task completed: \(updated.title)",
                    notes: updated.description_,
                    clientID: updated.clientID,
                    contactID: updated.contactID,
                    opportunityID: updated.opportunityID,
                    quoteID: updated.quoteID,
                    projectID: updated.projectID
                )
                NotificationManager.shared.runCRMTaskSweep()
            }
        } else {
            crmTasks.append(updated)
            logCRMActivity(
                type: .taskCreated,
                title: "Task created: \(updated.title)",
                notes: updated.description_,
                clientID: updated.clientID,
                contactID: updated.contactID,
                opportunityID: updated.opportunityID,
                quoteID: updated.quoteID,
                projectID: updated.projectID
            )
        }
        saveCRMData()
        Task { await SyncEngine.shared.pushPendingCRMTasks() }
    }

    func deleteCRMTask(_ item: CRMTask) {
        guard requireRole([.officeAdmin, .manager, .executive, .projectManager],
                          action: "delete_crm_task") else { return }
        guard let idx = crmTasks.firstIndex(where: { $0.id == item.id }) else { return }
        var deleted = crmTasks[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        crmTasks[idx] = deleted
        Task { await SyncEngine.shared.pushPendingCRMTasks() }
    }

    func crmTasks(forOpportunity opportunityID: UUID) -> [CRMTask] {
        crmTasks.filter { $0.opportunityID == opportunityID }
    }

    func crmTasks(forClient clientID: UUID) -> [CRMTask] {
        crmTasks.filter { $0.clientID == clientID }
    }

    var overdueCRMTasks: [CRMTask] {
        crmTasks.filter { $0.isOverdue }
    }

    var todayCRMTasks: [CRMTask] {
        let calendar = Calendar.current
        return crmTasks.filter { task in
            guard let due = task.dueDate, task.status != .done else { return false }
            return calendar.isDateInToday(due)
        }
    }

    // MARK: - Activity CRUD

    func logCRMActivity(
        type: CRMActivityType,
        title: String,
        notes: String,
        clientID: UUID?,
        contactID: UUID?,
        opportunityID: UUID?,
        quoteID: UUID?,
        projectID: UUID?
    ) {
        let activity = CRMActivity(
            type: type,
            title: title,
            notes: notes,
            date: Date(),
            userName: currentUser?.fullName ?? "System",
            clientID: clientID,
            contactID: contactID,
            opportunityID: opportunityID,
            quoteID: quoteID,
            projectID: projectID
        )
        crmActivities.insert(activity, at: 0)
        saveCRMData()
    }

    func crmActivities(forClient clientID: UUID) -> [CRMActivity] {
        crmActivities.filter { $0.clientID == clientID }
    }

    func crmActivities(forOpportunity opportunityID: UUID) -> [CRMActivity] {
        crmActivities.filter { $0.opportunityID == opportunityID }
    }

    // MARK: - Lead Intake Automation

    func createLead(company: Client, contact: CRMContact, opportunity: CRMOpportunity) {
        // Upsert client — use upsertClient so it gets .pending syncStatus and triggers a push
        if !clients.contains(where: { $0.id == company.id }) {
            upsertClient(company)
        }

        upsertCRMContact(contact)
        upsertCRMOpportunity(opportunity)

        logCRMActivity(
            type: .leadCreated,
            title: "New lead: \(company.name)",
            notes: opportunity.notes,
            clientID: company.id,
            contactID: contact.id,
            opportunityID: opportunity.id,
            quoteID: nil,
            projectID: nil
        )

        let followUpDue = addBusinessDays(1, to: Date())
        var task = CRMTask()
        task.title = "Call \(company.name) — initial follow-up"
        task.dueDate = followUpDue
        task.priority = .high
        task.clientID = company.id
        task.contactID = contact.id
        task.opportunityID = opportunity.id
        task.assignedToID = currentUser?.id
        task.assignedToName = currentUser?.fullName ?? ""
        upsertCRMTask(task)
    }

    // MARK: - Stage Change Automations

    func advanceOpportunityStage(_ opp: CRMOpportunity) {
        // Use activeStages so we never accidentally advance into .won or .lost
        // via this helper — those transitions must go through markOpportunityWon/Lost.
        let stages = OpportunityStage.activeStages
        guard let currentIdx = stages.firstIndex(of: opp.stage),
              currentIdx + 1 < stages.count else { return }

        var updated = opp
        let nextStage = stages[currentIdx + 1]
        updated.stage = nextStage
        updated.probability = nextStage.defaultProbability
        updated.updatedAt = Date()

        upsertCRMOpportunity(updated)

        if nextStage == .quoteSent {
            let followUpDue = addBusinessDays(2, to: Date())
            var task = CRMTask()
            task.title = "Follow up on quote — \(opp.title)"
            task.dueDate = followUpDue
            task.priority = .high
            task.clientID = opp.clientID
            task.contactID = opp.contactID
            task.opportunityID = opp.id
            task.quoteID = opp.quoteID
            task.assignedToID = opp.assignedToID ?? currentUser?.id
            task.assignedToName = opp.assignedToName.isEmpty ? (currentUser?.fullName ?? "") : opp.assignedToName
            upsertCRMTask(task)
        }

        logCRMActivity(
            type: .stageChanged,
            title: "Advanced to \(nextStage.rawValue)",
            notes: opp.title,
            clientID: opp.clientID,
            contactID: opp.contactID,
            opportunityID: opp.id,
            quoteID: opp.quoteID,
            projectID: opp.projectID
        )
    }

    // MARK: - Quote Won / Lost Automation
    //
    // These are thin wrappers that delegate to resolveOpportunityOutcome() in
    // CRMCommercialBridge.swift — the single source of truth for all win/loss
    // transitions. Do not add outcome logic here; add it to the central handler.

    func markOpportunityWon(_ opp: CRMOpportunity, projectID: UUID? = nil) {
        resolveOpportunityOutcome(
            opportunityID: opp.id,
            outcome:       .won,
            source:        .crm,
            quoteID:       opp.quoteID,
            estimateID:    opp.estimateID,
            projectID:     projectID ?? opp.projectID
        )
    }

    func markOpportunityLost(_ opp: CRMOpportunity, reason: String, competitor: String, notes: String) {
        resolveOpportunityOutcome(
            opportunityID: opp.id,
            outcome:       .lost,
            source:        .crm,
            quoteID:       opp.quoteID,
            estimateID:    opp.estimateID,
            reason:        reason,
            competitor:    competitor,
            notes:         notes
        )
    }

    // MARK: - Handoff Checklist

    func updateHandoffItem(_ item: HandoffChecklistItem) {
        if let idx = handoffChecklists.firstIndex(where: { $0.id == item.id }) {
            handoffChecklists[idx] = item
        } else {
            handoffChecklists.append(item)
        }
        saveCRMData()
    }

    func handoffChecklist(for opportunityID: UUID) -> [HandoffChecklistItem] {
        handoffChecklists.filter { $0.opportunityID == opportunityID }
    }

    // MARK: - Duplicate Detection

    func detectDuplicateCompanies(name: String) -> [Client] {
        let query = name.lowercased()
        return clients.filter { $0.name.lowercased().contains(query) }
    }

    func detectDuplicateContacts(email: String, phone: String) -> [CRMContact] {
        let emailLower = email.lowercased()
        let phoneDigits = phone.filter(\.isNumber)
        return crmContacts.filter { contact in
            (!email.isEmpty && contact.email.lowercased() == emailLower) ||
            (!phoneDigits.isEmpty && contact.phone.filter(\.isNumber) == phoneDigits)
        }
    }

    // MARK: - Dashboard Stats

    /// Groups ACTIVE-only opportunities by stage (used for normal pipeline display).
    var opportunitiesByStage: [OpportunityStage: [CRMOpportunity]] {
        Dictionary(grouping: openOpportunities, by: { $0.stage })
    }

    /// Groups ALL non-deleted opportunities by stage — includes Won and Lost.
    /// Used when the pipeline is in "All Stages" mode.
    var allOpportunitiesByStage: [OpportunityStage: [CRMOpportunity]] {
        let all = crmOpportunities.filter { !$0.isDeleted }
        return Dictionary(grouping: all, by: { $0.stage })
    }

    /// Won deals whose close-date (wonAt, falling back to updatedAt) lands in
    /// this calendar month. The fallback prevents legacy / imported deals
    /// from disappearing from Pipeline-Summary and Win-Rate cards.
    var wonThisMonth: [CRMOpportunity] {
        let calendar = Calendar.current
        let now = Date()
        return crmOpportunities.filter { opp in
            guard opp.stage == .won, !opp.isDeleted else { return false }
            let pinned = opp.wonAt ?? opp.updatedAt
            return calendar.isDate(pinned, equalTo: now, toGranularity: .month)
        }
    }

    var lostThisMonth: [CRMOpportunity] {
        let calendar = Calendar.current
        let now = Date()
        return crmOpportunities.filter { opp in
            guard opp.stage == .lost, !opp.isDeleted else { return false }
            let pinned = opp.lostAt ?? opp.updatedAt
            return calendar.isDate(pinned, equalTo: now, toGranularity: .month)
        }
    }

    var winRate: Double {
        let won = wonThisMonth.count
        let lost = lostThisMonth.count
        let total = won + lost
        guard total > 0 else { return 0 }
        return Double(won) / Double(total)
    }

    // MARK: - Report Computed Vars

    /// Won opportunities filtered by an optional date range.
    ///
    /// Falls back to `updatedAt` when `wonAt` is nil so legacy / imported
    /// deals (which never went through `markOpportunityWon`) still show up
    /// in the Performance Snapshot, Reports, and forecast cards. Without
    /// this fallback the dashboards silently dropped any won deal that
    /// arrived from a CSV import or from older builds that didn't stamp
    /// `wonAt`. Won deals that are soft-deleted are still excluded.
    func wonOpportunities(from start: Date? = nil, to end: Date? = nil) -> [CRMOpportunity] {
        crmOpportunities.filter { opp in
            guard opp.stage == .won, !opp.isDeleted else { return false }
            let pinned = opp.wonAt ?? opp.updatedAt
            if let s = start, pinned < s { return false }
            if let e = end,   pinned > e { return false }
            return true
        }
    }

    /// Lost opportunities, with the same `updatedAt` fallback as
    /// `wonOpportunities` so legacy lost deals still report.
    func lostOpportunities(from start: Date? = nil, to end: Date? = nil) -> [CRMOpportunity] {
        crmOpportunities.filter { opp in
            guard opp.stage == .lost, !opp.isDeleted else { return false }
            let pinned = opp.lostAt ?? opp.updatedAt
            if let s = start, pinned < s { return false }
            if let e = end,   pinned > e { return false }
            return true
        }
    }

    func winRate(from start: Date? = nil, to end: Date? = nil) -> Double {
        let won   = wonOpportunities(from: start, to: end).count
        let lost  = lostOpportunities(from: start, to: end).count
        let total = won + lost
        guard total > 0 else { return 0 }
        return Double(won) / Double(total)
    }

    func totalWonValue(from start: Date? = nil, to end: Date? = nil) -> Decimal {
        wonOpportunities(from: start, to: end).reduce(0) { $0 + $1.value }
    }

    func avgDealSize(from start: Date? = nil, to end: Date? = nil) -> Decimal {
        let opps = wonOpportunities(from: start, to: end)
        guard !opps.isEmpty else { return 0 }
        return opps.reduce(0) { $0 + $1.value } / Decimal(opps.count)
    }

    func avgDaysToClose(from start: Date? = nil, to end: Date? = nil) -> Double {
        let opps = wonOpportunities(from: start, to: end)
        guard !opps.isEmpty else { return 0 }
        // Use wonAt where available, otherwise fall back to updatedAt — same
        // fallback `wonOpportunities` uses so the filter and the average agree.
        let totalDays = opps.reduce(0.0) { sum, opp in
            let closed = opp.wonAt ?? opp.updatedAt
            return sum + closed.timeIntervalSince(opp.createdAt) / 86400
        }
        return totalDays / Double(opps.count)
    }

    func revenueByServiceType(from start: Date? = nil, to end: Date? = nil) -> [(serviceType: String, value: Decimal)] {
        let opps = wonOpportunities(from: start, to: end)
        var map: [String: Decimal] = [:]
        for opp in opps {
            let key = opp.serviceType.isEmpty ? "Other" : opp.serviceType
            map[key, default: 0] += opp.value
        }
        return map.map { (serviceType: $0.key, value: $0.value) }
            .sorted { $0.value > $1.value }
    }

    func lossesByReason(from start: Date? = nil, to end: Date? = nil) -> [(reason: String, count: Int)] {
        let opps = lostOpportunities(from: start, to: end)
        var map: [String: Int] = [:]
        for opp in opps {
            let key = opp.lossReason.isEmpty ? "Unknown" : opp.lossReason
            map[key, default: 0] += 1
        }
        return map.map { (reason: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    func pipelineBySource(from start: Date? = nil, to end: Date? = nil) -> [(source: String, count: Int, value: Decimal)] {
        let opps: [CRMOpportunity]
        if start == nil && end == nil {
            opps = openOpportunities
        } else {
            opps = crmOpportunities.filter { opp in
                if let s = start, opp.createdAt < s { return false }
                if let e = end,   opp.createdAt > e { return false }
                return true
            }
        }
        var map: [String: (count: Int, value: Decimal)] = [:]
        for opp in opps {
            let key = opp.source.rawValue
            let existing = map[key] ?? (count: 0, value: 0)
            map[key] = (count: existing.count + 1, value: existing.value + opp.value)
        }
        return map.map { (source: $0.key, count: $0.value.count, value: $0.value.value) }
            .sorted { $0.value > $1.value }
    }

    func stageFunnelData() -> [(stage: OpportunityStage, count: Int, value: Decimal)] {
        OpportunityStage.activeStages.map { stage in
            let opps = openOpportunities.filter { $0.stage == stage }
            return (stage: stage, count: opps.count, value: opps.reduce(0) { $0 + $1.value })
        }.filter { $0.count > 0 }
    }

    // MARK: - Revenue Forecast

    func forecastForYear(_ year: Int? = nil) -> [ForecastMonth] {
        let cal = Calendar.current
        let now = Date()
        let targetYear = year ?? cal.component(.year, from: now)
        let currentMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let monthFmt: DateFormatter = {
            let f = DateFormatter(); f.dateFormat = "MMM"; return f
        }()

        return (1...12).compactMap { m -> ForecastMonth? in
            var comps = DateComponents()
            comps.year = targetYear; comps.month = m; comps.day = 1
            guard let monthDate = cal.date(from: comps) else { return nil }

            let forecast = openOpportunities
                .filter {
                    guard let s = $0.estimatedStart else { return false }
                    return cal.component(.year,  from: s) == targetYear &&
                           cal.component(.month, from: s) == m
                }
                .reduce(Decimal(0)) { $0 + $1.weightedValue }

            // Same wonAt-or-updatedAt fallback as `wonOpportunities()` —
            // keeps the forecast row in agreement with the Reports / Snapshot
            // cards even for legacy deals that never stamped wonAt.
            let won = crmOpportunities
                .filter {
                    guard $0.stage == .won, !$0.isDeleted else { return false }
                    let w = $0.wonAt ?? $0.updatedAt
                    return cal.component(.year,  from: w) == targetYear &&
                           cal.component(.month, from: w) == m
                }
                .reduce(Decimal(0)) { $0 + $1.value }

            let scheduled = openOpportunities.filter {
                guard let s = $0.estimatedStart else { return false }
                return cal.component(.year,  from: s) == targetYear &&
                       cal.component(.month, from: s) == m
            }.count

            return ForecastMonth(
                month:         monthDate,
                monthLabel:    monthFmt.string(from: monthDate),
                forecast:      forecast,
                won:           won,
                scheduledOpps: scheduled,
                isPast:        monthDate < currentMonthStart
            )
        }
    }

    var unscheduledPipelineValue: Decimal {
        openOpportunities
            .filter { $0.estimatedStart == nil }
            .reduce(0) { $0 + $1.weightedValue }
    }

    var upcomingOpportunities: [CRMOpportunity] {
        let cutoff = Calendar.current.date(byAdding: .day, value: 90, to: Date()) ?? Date()
        return openOpportunities
            .filter { opp in
                guard let start = opp.estimatedStart else { return false }
                return start >= Date() && start <= cutoff
            }
            .sorted { ($0.estimatedStart ?? .distantFuture) < ($1.estimatedStart ?? .distantFuture) }
    }

    // MARK: - Outcome-Timestamp Backfill
    //
    // Older builds (and CSV imports) sometimes saved opportunities with
    // `stage = .won` / `.lost` but never stamped `wonAt` / `lostAt`. The
    // dashboards' Performance Snapshot, Reports, and forecast cards filter
    // by those timestamps, so legacy deals would silently disappear from
    // the metrics. This helper backfills the missing timestamp from
    // `updatedAt` and pushes the corrected rows back to the server.
    //
    // Idempotent — only touches rows where the timestamp is actually nil,
    // and only flips syncStatus to `.pending` when a backfill happens.
    // Safe to call after every pull.
    @discardableResult
    func backfillCRMOutcomeTimestamps() -> Int {
        var fixed = 0
        for i in crmOpportunities.indices {
            var opp = crmOpportunities[i]
            var changed = false
            if opp.stage == .won, opp.wonAt == nil {
                opp.wonAt = opp.updatedAt
                changed = true
            }
            if opp.stage == .lost, opp.lostAt == nil {
                opp.lostAt = opp.updatedAt
                changed = true
            }
            if changed {
                opp.syncStatus = .pending
                crmOpportunities[i] = opp
                fixed += 1
            }
        }
        if fixed > 0 {
            Task { await SyncEngine.shared.pushPendingCRMOpportunities() }
        }
        return fixed
    }
}

// MARK: - Forecast Month Model

struct ForecastMonth: Identifiable {
    let id = UUID()
    let month:         Date
    let monthLabel:    String
    let forecast:      Decimal
    let won:           Decimal
    let scheduledOpps: Int
    let isPast:        Bool
}
