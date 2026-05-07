// SyncEngineCRM.swift
// BV APP – Supabase Sync for CRM Module
// Covers: Contacts, Opportunities, Tasks, Activities, Checklists

import Foundation
import Supabase

// MARK: - Shared Helpers (file-private)

private let crmIso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let crmDateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

private func crmDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    return crmIso.date(from: s) ?? crmDateFmt.date(from: s)
}

private func crmIsoStr(_ d: Date?) -> String? {
    guard let d else { return nil }
    return crmIso.string(from: d)
}

private func crmDecimal(_ d: Double?) -> Decimal {
    guard let d else { return 0 }
    return Decimal(string: String(d)) ?? 0
}

private func crmDouble(_ d: Decimal) -> Double {
    NSDecimalNumber(decimal: d).doubleValue
}

// MARK: - SyncEngine CRM Extension

extension SyncEngine {

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Realtime — Live CRM Updates
    // ─────────────────────────────────────────────────────────────────────────

    func startRealtimeCRM() {
        guard let companyID = store.currentCompanyID else { return }
        crmRealtimeTask?.cancel()
        // 2026-04 re-audit fix #4: same reconnect loop as the
        // timesheets channel. Without it, a network blip kills CRM
        // realtime until the next pullAll.
        crmRealtimeTask = Task { [weak self] in
            await self?.realtimeRetryLoop(label: "crm") { [weak self] in
                guard let self else { return }
                let channel = await supabase.realtimeV2
                    .channel("crm_changes_\(companyID)")
                let oppChanges = await channel.postgresChange(
                    AnyAction.self,
                    schema: "public",
                    table: SupabaseTable.crmOpportunities,
                    filter: "company_id=eq.\(companyID)"
                )
                await channel.subscribe()

                for await _ in oppChanges {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        guard !Task.isCancelled, let self else { return }
                        await self.pullCRMContacts()
                        await self.pullCRMOpportunities()
                        await self.pullCRMActivities()
                    }
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Pull — Contacts
    // ─────────────────────────────────────────────────────────────────────────

    func pullCRMContacts() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, client_id: String
                let first_name, last_name: String
                let title, phone, email: String?
                let role: String?            // contact role (decision_maker, site_contact, etc.)
                let site_id: String?         // optional site assignment
                let is_primary: Bool?
                let notes: String?
                let created_at: String?
                let sync_status: String?
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.crmContacts)
                .select()
                .eq("company_id", value: companyID.uuidString)
                .eq("is_deleted", value: false)
                .order("last_name")
                .execute()
                .value

            // Preserve .failed records too — otherwise records that hit a transient
            // server-side error get silently dropped on every pullAll, costing the
            // user real data. They get retried via the FailedSyncBanner.
            var merged = store.crmContacts.filter {
                $0.syncStatus == .local || $0.syncStatus == .pending || $0.syncStatus == .failed
            }
            for row in rows {
                guard let id = UUID(uuidString: row.id),
                      let clientID = UUID(uuidString: row.client_id) else { continue }
                var c = CRMContact(clientID: clientID)
                c.id         = id
                c.firstName  = row.first_name
                c.lastName   = row.last_name
                c.title      = row.title ?? ""
                c.phone      = row.phone ?? ""
                c.email      = row.email ?? ""
                c.role       = ContactRole(rawValue: row.role ?? "") ?? .general
                c.siteID     = row.site_id.flatMap { UUID(uuidString: $0) }
                c.isPrimary  = row.is_primary ?? false
                c.notes      = row.notes ?? ""
                c.createdAt  = crmDate(row.created_at) ?? Date()
                c.syncStatus = .synced
                merged.removeAll { $0.id == c.id }
                merged.append(c)
            }
            store.crmContacts = merged
        } catch {
            syncError = "CRM Contacts: \(error.localizedDescription)"
        }
    }

    func pushPendingCRMContacts() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.crmContacts.filter { $0.syncStatus == .pending || $0.syncStatus == .local }
        for c in pending {
            do {
                var payload: [String: AnyJSON] = [
                    "id":         .string(c.id.uuidString),
                    "company_id": .string(companyID.uuidString),
                    "client_id":  .string(c.clientID.uuidString),
                    "first_name": .string(c.firstName),
                    "last_name":  .string(c.lastName),
                    "title":      .string(c.title),
                    "phone":      .string(c.phone),
                    "email":      .string(c.email),
                    "role":       .string(c.role.rawValue),
                    "is_primary": .bool(c.isPrimary),
                    "notes":      .string(c.notes),
                    "created_at": .string(crmIso.string(from: c.createdAt)),
                    "is_deleted": .bool(c.isDeleted)
                ]
                if let siteID = c.siteID {
                    payload["site_id"] = .string(siteID.uuidString)
                }
                if let d = c.deletedAt  { payload["deleted_at"]  = .string(crmIso.string(from: d)) }
                if let s = c.deletedBy  { payload["deleted_by"]  = .string(s) }
                try await supabase.from(SupabaseTable.crmContacts).upsert(payload).execute()
                if let i = store.crmContacts.firstIndex(where: { $0.id == c.id }) {
                    store.crmContacts[i].syncStatus = .synced
                }
                store.crmContacts.removeAll { $0.isDeleted && $0.syncStatus == .synced }
            } catch {
                if let i = store.crmContacts.firstIndex(where: { $0.id == c.id }) {
                    store.crmContacts[i].syncStatus = .failed
                }
            }
        }
        if !pending.isEmpty { store.saveCRMData() }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Pull — Opportunities
    // ─────────────────────────────────────────────────────────────────────────

    func pullCRMOpportunities() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, client_id, title, stage: String
                let value: Double?
                let service_type, site_address, description: String?
                let source, loss_reason, competitor_name: String?
                let probability: Int?
                let assigned_to_name: String?
                let notes: String?
                let contact_id, estimate_id, quote_id, project_id, assigned_to_id: String?
                let estimated_start, created_at, updated_at, won_at, lost_at: String?
                // Sample-data tracking
                let is_sample_data: Bool?
                let sample_data_batch_id: String?
                let sample_data_seed_version: String?
                let sample_data_created_at: String?
                let sample_data_created_by: String?
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.crmOpportunities)
                .select()
                .eq("company_id", value: companyID.uuidString)
                .eq("is_deleted", value: false)
                .order("updated_at", ascending: false)
                .execute()
                .value

            var merged = store.crmOpportunities.filter {
                $0.syncStatus == .local || $0.syncStatus == .pending || $0.syncStatus == .failed
            }
            for row in rows {
                guard let id = UUID(uuidString: row.id),
                      let clientID = UUID(uuidString: row.client_id) else { continue }
                var o = CRMOpportunity(clientID: clientID)
                o.id              = id
                o.title           = row.title
                o.stage           = OpportunityStage(rawValue: row.stage) ?? .newLead
                o.value           = crmDecimal(row.value)
                o.serviceType     = row.service_type ?? ""
                o.siteAddress     = row.site_address ?? ""
                o.description     = row.description ?? ""
                o.source          = LeadSource(rawValue: row.source ?? "") ?? .directInquiry
                o.lossReason      = row.loss_reason ?? ""
                o.competitorName  = row.competitor_name ?? ""
                o.probability     = row.probability ?? 10
                o.assignedToName  = row.assigned_to_name ?? ""
                o.notes           = row.notes ?? ""
                o.contactID       = row.contact_id.flatMap    { UUID(uuidString: $0) }
                o.estimateID      = row.estimate_id.flatMap   { UUID(uuidString: $0) }
                o.quoteID         = row.quote_id.flatMap      { UUID(uuidString: $0) }
                o.projectID       = row.project_id.flatMap    { UUID(uuidString: $0) }
                o.assignedToID    = row.assigned_to_id.flatMap{ UUID(uuidString: $0) }
                o.estimatedStart  = crmDate(row.estimated_start)
                o.createdAt       = crmDate(row.created_at) ?? Date()
                o.updatedAt       = crmDate(row.updated_at) ?? Date()
                o.wonAt           = crmDate(row.won_at)
                o.lostAt          = crmDate(row.lost_at)
                o.syncStatus      = .synced
                o.isSampleData          = row.is_sample_data ?? false
                o.sampleDataBatchID     = row.sample_data_batch_id.flatMap(UUID.init(uuidString:))
                o.sampleDataSeedVersion = row.sample_data_seed_version
                o.sampleDataCreatedAt   = crmDate(row.sample_data_created_at)
                o.sampleDataCreatedBy   = row.sample_data_created_by.flatMap(UUID.init(uuidString:))
                merged.removeAll { $0.id == o.id }
                merged.append(o)
            }
            store.crmOpportunities = merged
        } catch {
            syncError = "CRM Opportunities: \(error.localizedDescription)"
        }
    }

    func pushPendingCRMOpportunities() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.crmOpportunities.filter { $0.syncStatus == .pending || $0.syncStatus == .local }
        for o in pending {
            do {
                var payload: [String: AnyJSON] = [
                    "id":               .string(o.id.uuidString),
                    "company_id":       .string(companyID.uuidString),
                    "client_id":        .string(o.clientID.uuidString),
                    "title":            .string(o.title),
                    "stage":            .string(o.stage.rawValue),
                    "value":            .double(crmDouble(o.value)),
                    "service_type":     .string(o.serviceType),
                    "site_address":     .string(o.siteAddress),
                    "description":      .string(o.description),
                    "source":           .string(o.source.rawValue),
                    "loss_reason":      .string(o.lossReason),
                    "competitor_name":  .string(o.competitorName),
                    "probability":      .integer(o.probability),
                    "assigned_to_name": .string(o.assignedToName),
                    "notes":            .string(o.notes),
                    "created_at":       .string(crmIso.string(from: o.createdAt)),
                    "updated_at":       .string(crmIso.string(from: o.updatedAt)),
                    "is_deleted":       .bool(o.isDeleted)
                ]
                if let id = o.contactID    { payload["contact_id"]    = .string(id.uuidString) }
                if let id = o.estimateID   { payload["estimate_id"]   = .string(id.uuidString) }
                if let id = o.quoteID      { payload["quote_id"]      = .string(id.uuidString) }
                if let id = o.projectID    { payload["project_id"]    = .string(id.uuidString) }
                if let id = o.assignedToID { payload["assigned_to_id"] = .string(id.uuidString) }
                if let d = o.estimatedStart { payload["estimated_start"] = .string(crmIso.string(from: d)) }
                if let d = o.wonAt    { payload["won_at"]    = .string(crmIso.string(from: d)) }
                if let d = o.lostAt   { payload["lost_at"]   = .string(crmIso.string(from: d)) }
                if let d = o.deletedAt { payload["deleted_at"] = .string(crmIso.string(from: d)) }
                if let s = o.deletedBy { payload["deleted_by"] = .string(s) }

                // Sample-data tracking — always included (false on real records)
                payload["is_sample_data"] = .bool(o.isSampleData)
                if let id = o.sampleDataBatchID  { payload["sample_data_batch_id"]     = .string(id.uuidString) }
                if let v  = o.sampleDataSeedVersion { payload["sample_data_seed_version"] = .string(v) }
                if let d  = o.sampleDataCreatedAt   { payload["sample_data_created_at"]   = .string(crmIso.string(from: d)) }
                if let id = o.sampleDataCreatedBy   { payload["sample_data_created_by"]   = .string(id.uuidString) }

                try await supabase.from(SupabaseTable.crmOpportunities).upsert(payload).execute()
                if let i = store.crmOpportunities.firstIndex(where: { $0.id == o.id }) {
                    store.crmOpportunities[i].syncStatus = .synced
                }
                store.crmOpportunities.removeAll { $0.isDeleted && $0.syncStatus == .synced }
            } catch {
                if let i = store.crmOpportunities.firstIndex(where: { $0.id == o.id }) {
                    store.crmOpportunities[i].syncStatus = .failed
                }
            }
        }
        if !pending.isEmpty { store.saveCRMData() }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Pull — Tasks
    // ─────────────────────────────────────────────────────────────────────────

    func pullCRMTasks(role: UserRole) async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, title, priority, status: String
                let description_: String?
                let assigned_to_name: String?
                let due_date, created_at, completed_at: String?
                let client_id, contact_id, opportunity_id, quote_id, project_id, assigned_to_id: String?
                enum CodingKeys: String, CodingKey {
                    case id, title, priority, status
                    case description_    = "description"
                    case assigned_to_name, due_date, created_at, completed_at
                    case client_id, contact_id, opportunity_id, quote_id, project_id, assigned_to_id
                }
            }
            var query = supabase.from(SupabaseTable.crmTasks)
                .select()
                .eq("company_id", value: companyID.uuidString)
            if role.isFieldRole, let userID = store.currentUser?.id {
                query = query.eq("assigned_to_id", value: userID.uuidString)
            }
            let rows: [Row] = try await query
                .eq("is_deleted", value: false)
                .order("created_at", ascending: false)
                .limit(300)
                .execute()
                .value

            var merged = store.crmTasks.filter {
                $0.syncStatus == .local || $0.syncStatus == .pending || $0.syncStatus == .failed
            }
            for row in rows {
                guard let id = UUID(uuidString: row.id) else { continue }
                var t = CRMTask()
                t.id             = id
                t.title          = row.title
                t.description_   = row.description_ ?? ""
                t.priority       = CRMTaskPriority(rawValue: row.priority) ?? .normal
                t.status         = CRMTaskStatus(rawValue: row.status) ?? .open
                t.assignedToName = row.assigned_to_name ?? ""
                t.dueDate        = crmDate(row.due_date)
                t.createdAt      = crmDate(row.created_at) ?? Date()
                t.completedAt    = crmDate(row.completed_at)
                t.clientID       = row.client_id.flatMap      { UUID(uuidString: $0) }
                t.contactID      = row.contact_id.flatMap     { UUID(uuidString: $0) }
                t.opportunityID  = row.opportunity_id.flatMap { UUID(uuidString: $0) }
                t.quoteID        = row.quote_id.flatMap       { UUID(uuidString: $0) }
                t.projectID      = row.project_id.flatMap     { UUID(uuidString: $0) }
                t.assignedToID   = row.assigned_to_id.flatMap { UUID(uuidString: $0) }
                t.syncStatus     = .synced
                merged.removeAll { $0.id == t.id }
                merged.append(t)
            }
            // Fire notification for tasks newly assigned to the current user
            if let userID = store.currentUser?.id {
                let existingIDs = Set(store.crmTasks.filter { $0.assignedToID == userID }.map { $0.id })
                let newlyAssigned = merged.filter {
                    $0.assignedToID == userID && !existingIDs.contains($0.id) && $0.status != .done
                }
                for task in newlyAssigned {
                    NotificationManager.shared.notifyCRMTaskAssigned(
                        taskTitle: task.title,
                        assignedBy: ""
                    )
                }
            }

            store.crmTasks = merged
        } catch {
            syncError = "CRM Tasks: \(error.localizedDescription)"
        }
    }

    func pushPendingCRMTasks() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.crmTasks.filter { $0.syncStatus == .pending || $0.syncStatus == .local }
        for t in pending {
            do {
                var payload: [String: AnyJSON] = [
                    "id":               .string(t.id.uuidString),
                    "company_id":       .string(companyID.uuidString),
                    "title":            .string(t.title),
                    "description":      .string(t.description_),
                    "priority":         .string(t.priority.rawValue),
                    "status":           .string(t.status.rawValue),
                    "assigned_to_name": .string(t.assignedToName),
                    "created_at":       .string(crmIso.string(from: t.createdAt)),
                    "is_deleted":       .bool(t.isDeleted)
                ]
                if let d = t.dueDate      { payload["due_date"]      = .string(crmIso.string(from: d)) }
                if let d = t.completedAt  { payload["completed_at"]  = .string(crmIso.string(from: d)) }
                if let d = t.deletedAt    { payload["deleted_at"]    = .string(crmIso.string(from: d)) }
                if let s = t.deletedBy    { payload["deleted_by"]    = .string(s) }
                if let id = t.clientID     { payload["client_id"]     = .string(id.uuidString) }
                if let id = t.contactID    { payload["contact_id"]    = .string(id.uuidString) }
                if let id = t.opportunityID { payload["opportunity_id"] = .string(id.uuidString) }
                if let id = t.quoteID      { payload["quote_id"]      = .string(id.uuidString) }
                if let id = t.projectID    { payload["project_id"]    = .string(id.uuidString) }
                if let id = t.assignedToID { payload["assigned_to_id"] = .string(id.uuidString) }

                try await supabase.from(SupabaseTable.crmTasks).upsert(payload).execute()
                if let i = store.crmTasks.firstIndex(where: { $0.id == t.id }) {
                    store.crmTasks[i].syncStatus = .synced
                }
                store.crmTasks.removeAll { $0.isDeleted && $0.syncStatus == .synced }
            } catch {
                if let i = store.crmTasks.firstIndex(where: { $0.id == t.id }) {
                    store.crmTasks[i].syncStatus = .failed
                }
            }
        }
        if !pending.isEmpty { store.saveCRMData() }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Pull — Activities (append-only from server)
    // ─────────────────────────────────────────────────────────────────────────

    func pullCRMActivities() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, type_, title: String
                let notes, user_name: String?
                let date: String?
                let client_id, contact_id, opportunity_id, quote_id, project_id: String?
                enum CodingKeys: String, CodingKey {
                    case id, title, notes, date
                    case type_         = "type"
                    case user_name     = "user_name"
                    case client_id, contact_id, opportunity_id, quote_id, project_id
                }
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.crmActivities)
                .select()
                .eq("company_id", value: companyID.uuidString)
                .order("date", ascending: false)
                .limit(200)
                .execute()
                .value

            // Merge server records — keep local ones, add/update server ones
            var merged = store.crmActivities.filter {
                $0.syncStatus == .local || $0.syncStatus == .pending || $0.syncStatus == .failed
            }
            for row in rows {
                guard let id = UUID(uuidString: row.id) else { continue }
                var a = CRMActivity(
                    type: CRMActivityType(rawValue: row.type_) ?? .noteAdded,
                    title: row.title,
                    notes: row.notes ?? "",
                    date: crmDate(row.date) ?? Date(),
                    userName: row.user_name ?? "",
                    clientID: row.client_id.flatMap      { UUID(uuidString: $0) },
                    contactID: row.contact_id.flatMap    { UUID(uuidString: $0) },
                    opportunityID: row.opportunity_id.flatMap { UUID(uuidString: $0) },
                    quoteID: row.quote_id.flatMap        { UUID(uuidString: $0) },
                    projectID: row.project_id.flatMap    { UUID(uuidString: $0) }
                )
                a.id = id
                a.syncStatus = .synced
                merged.removeAll { $0.id == a.id }
                merged.append(a)
            }
            // Re-sort newest first
            store.crmActivities = merged.sorted { $0.date > $1.date }
        } catch {
            syncError = "CRM Activities: \(error.localizedDescription)"
        }
    }

    func pushPendingCRMActivities() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.crmActivities.filter { $0.syncStatus == .pending || $0.syncStatus == .local }
        for a in pending {
            do {
                var payload: [String: AnyJSON] = [
                    "id":         .string(a.id.uuidString),
                    "company_id": .string(companyID.uuidString),
                    "type":       .string(a.type.rawValue),
                    "title":      .string(a.title),
                    "notes":      .string(a.notes),
                    "date":       .string(crmIso.string(from: a.date)),
                    "user_name":  .string(a.userName)
                ]
                if let id = a.clientID      { payload["client_id"]      = .string(id.uuidString) }
                if let id = a.contactID     { payload["contact_id"]     = .string(id.uuidString) }
                if let id = a.opportunityID { payload["opportunity_id"] = .string(id.uuidString) }
                if let id = a.quoteID       { payload["quote_id"]       = .string(id.uuidString) }
                if let id = a.projectID     { payload["project_id"]     = .string(id.uuidString) }

                try await supabase.from(SupabaseTable.crmActivities).upsert(payload).execute()
                if let i = store.crmActivities.firstIndex(where: { $0.id == a.id }) {
                    store.crmActivities[i].syncStatus = .synced
                }
            } catch {
                if let i = store.crmActivities.firstIndex(where: { $0.id == a.id }) {
                    store.crmActivities[i].syncStatus = .failed
                }
            }
        }
        if !pending.isEmpty { store.saveCRMData() }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Pull — Handoff Checklists
    // ─────────────────────────────────────────────────────────────────────────

    func pullCRMChecklists() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id, title: String
                let is_done: Bool?
                let opportunity_id, project_id: String?
            }
            let rows: [Row] = try await supabase
                .from(SupabaseTable.crmChecklists)
                .select()
                .eq("company_id", value: companyID.uuidString)
                .execute()
                .value

            var merged = store.handoffChecklists.filter { _ in false }  // full replace from server
            for row in rows {
                guard let id = UUID(uuidString: row.id) else { continue }
                var item = HandoffChecklistItem(
                    title: row.title,
                    opportunityID: row.opportunity_id.flatMap { UUID(uuidString: $0) },
                    projectID: row.project_id.flatMap     { UUID(uuidString: $0) }
                )
                item.id     = id
                item.isDone = row.is_done ?? false
                merged.append(item)
            }
            // Preserve any purely local items not yet pushed
            let localOnly = store.handoffChecklists.filter { local in
                !merged.contains(where: { $0.id == local.id })
            }
            store.handoffChecklists = merged + localOnly
        } catch {
            syncError = "CRM Checklists: \(error.localizedDescription)"
        }
    }

    func pushPendingCRMChecklists() async {
        guard let companyID = store.currentCompanyID else { return }
        // Push all checklists (upsert is safe — server treats them as idempotent)
        for item in store.handoffChecklists {
            do {
                var payload: [String: AnyJSON] = [
                    "id":         .string(item.id.uuidString),
                    "company_id": .string(companyID.uuidString),
                    "title":      .string(item.title),
                    "is_done":    .bool(item.isDone)
                ]
                if let id = item.opportunityID { payload["opportunity_id"] = .string(id.uuidString) }
                if let id = item.projectID     { payload["project_id"]     = .string(id.uuidString) }
                try await supabase.from(SupabaseTable.crmChecklists).upsert(payload).execute()
            } catch {
                print("⚠️ \(#function) failed: \(error)")
                CrashReporter.capture(error: error, context: ["operation": "\(#function)"])
            }
        }
    }
}

