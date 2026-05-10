// SyncEngineWorkflow.swift
// Aski IQ — Server sync for the WorkflowAutomation engine.
//
// WHY THIS FILE EXISTS
// `WorkflowAutomation.swift` shipped with UserDefaults-only persistence
// (`saveWorkflowRules` / `loadWorkflowLog`). That meant a manager who
// edited an automation rule on their phone never saw it on the office
// iPad — and the audit log of fires was unrecoverable if a device was
// reset. The 2026-04 audit caught this; here's the server side.
//
// SHAPE
//   * `pullWorkflowRules()` / `pushPendingWorkflowRules()` — full CRUD
//   * `pullWorkflowLog()`   / `pushPendingWorkflowLog()`   — append-only
//
// CALLED FROM
//   `pullAll()` and `pushPending()` in SyncEngine.swift (wired in the
//   same commit so the helpers don't sit dead).
//
// CONFLICT RESOLUTION
// Last-write-wins on rules (matches every other entity in the app). The
// log is append-only so there's no conflict path.

import Foundation
import Combine
import Supabase

extension SyncEngine {

    // ─────────────────────────────────────────────────────────────────
    // MARK: Workflow Rules — Realtime
    // ─────────────────────────────────────────────────────────────────
    //
    // 2026-04 re-audit fix #8: workflow rule edits propagated only on
    // the next manual pull. With realtime, a manager toggling a rule
    // on iPad sees the change reflect on the office iPhone within
    // seconds. Same exponential-backoff reconnect pattern as the
    // timesheet + CRM channels.

    func startRealtimeWorkflow() {
        guard let companyID = store.currentCompanyID else { return }
        // Reuse the `crmRealtimeTask` slot for cancellation hygiene
        // — `stopRealtime()` already cancels it. We don't need a
        // dedicated task handle because workflow + CRM are both low-
        // volume; one channel each is fine.
        Task { [weak self] in
            await self?.realtimeRetryLoop(label: "workflow_rules") { [weak self] in
                guard let self else { return }
                let channel = await supabase.realtimeV2
                    .channel("workflow_rules_\(companyID)")
                let changes = await channel.postgresChange(
                    AnyAction.self,
                    schema: "public",
                    table: SupabaseTable.workflowRules,
                    filter: "company_id=eq.\(companyID)"
                )
                await channel.subscribe()

                for await _ in changes {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        guard !Task.isCancelled, let self else { return }
                        await self.pullWorkflowRules()
                        // Re-evaluate the engine so any new rule that
                        // applies to current state fires immediately.
                        await MainActor.run { self.store.runWorkflowEngine() }
                    }
                }
            }
        }
    }
}

// Continuation of the SyncEngineWorkflow extension follows.
extension SyncEngine {

    // ─────────────────────────────────────────────────────────────────
    // MARK: Workflow Rules — Pull
    // ─────────────────────────────────────────────────────────────────

    func pullWorkflowRules() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id:              String
                let company_id:      String
                let name:            String
                let trigger_kind:    String
                let action_kind:     String
                let is_enabled:      Bool
                let threshold_days:  Int
                let notes:           String
                let last_fired_at:   String?
                let fire_count:      Int
                let is_deleted:      Bool
                let created_at:      String
                let updated_at:      String
            }
            let rows: [Row] = try await client.select(
                Row.self,
                from: SupabaseTable.workflowRules,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ]
            )

            // Preserve any locally-pending edits — don't clobber rows
            // the user just saved that haven't pushed yet.
            let pendingIDs = Set(store.workflowRules
                .filter { $0.syncStatus == .pending || $0.syncStatus == .failed }
                .map { $0.id })

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var merged: [WorkflowRule] = store.workflowRules.filter { pendingIDs.contains($0.id) }

            for row in rows {
                guard let id = UUID(uuidString: row.id),
                      !pendingIDs.contains(id),
                      let trigger = WorkflowTrigger(rawValue: row.trigger_kind),
                      let action  = WorkflowAction(rawValue: row.action_kind),
                      let cid = UUID(uuidString: row.company_id) else { continue }

                var rule = WorkflowRule(name: row.name, trigger: trigger)
                rule.id            = id
                rule.action        = action
                rule.isEnabled     = row.is_enabled
                rule.thresholdDays = row.threshold_days
                rule.notes         = row.notes
                rule.fireCount     = row.fire_count
                rule.lastFiredAt   = row.last_fired_at.flatMap { iso.date(from: $0) }
                rule.companyID     = cid
                rule.syncStatus    = .synced
                rule.isDeleted     = row.is_deleted
                rule.createdAt     = iso.date(from: row.created_at) ?? Date()
                rule.updatedAt     = iso.date(from: row.updated_at) ?? Date()
                merged.append(rule)
            }

            // Seed the default rule set ONLY if the tenant truly has
            // no rules anywhere (not even pending). This stops the
            // "delete a rule, sync, see it come back as a default"
            // bug that a naive merge would create.
            await MainActor.run {
                if merged.isEmpty {
                    store.workflowRules = WorkflowEngine.defaultRules().map {
                        var r = $0
                        r.companyID  = companyID
                        r.syncStatus = .pending  // push these on next loop
                        return r
                    }
                } else {
                    store.workflowRules = merged
                }
                store.saveWorkflowRules()
            }
        } catch {
            print("⚠️ pullWorkflowRules failed: \(error)")
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: Workflow Rules — Push
    // ─────────────────────────────────────────────────────────────────

    func pushPendingWorkflowRules() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.workflowRules.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else { return }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for rule in pending {
            do {
                struct Row: Encodable {
                    let id:              String
                    let company_id:      String
                    let name:            String
                    let trigger_kind:    String
                    let action_kind:     String
                    let is_enabled:      Bool
                    let threshold_days:  Int
                    let notes:           String
                    let last_fired_at:   String?
                    let fire_count:      Int
                    let is_deleted:      Bool
                    let created_at:      String
                    let updated_at:      String
                }
                let row = Row(
                    id:              rule.id.uuidString,
                    company_id:      (rule.companyID ?? companyID).uuidString,
                    name:            rule.name,
                    trigger_kind:    rule.trigger.rawValue,
                    action_kind:     rule.action.rawValue,
                    is_enabled:      rule.isEnabled,
                    threshold_days:  rule.thresholdDays,
                    notes:           rule.notes,
                    last_fired_at:   rule.lastFiredAt.map { iso.string(from: $0) },
                    fire_count:      rule.fireCount,
                    is_deleted:      rule.isDeleted,
                    created_at:      iso.string(from: rule.createdAt),
                    updated_at:      iso.string(from: Date())
                )
                try await client.upsert(row, into: SupabaseTable.workflowRules)

                if let i = store.workflowRules.firstIndex(where: { $0.id == rule.id }) {
                    // Soft-deleted rules disappear from local state
                    // after a successful push so they don't keep
                    // re-firing the engine.
                    if rule.isDeleted {
                        store.workflowRules.remove(at: i)
                    } else {
                        store.workflowRules[i].syncStatus = .synced
                    }
                }
            } catch {
                print("⚠️ pushPendingWorkflowRules failed for \(rule.id): \(error)")
                CrashReporter.capture(error: error,
                                      context: [
                                        "operation": "pushPendingWorkflowRules",
                                        "rule_id":   rule.id.uuidString
                                      ])
                if let i = store.workflowRules.firstIndex(where: { $0.id == rule.id }) {
                    store.workflowRules[i].syncStatus = .failed
                }
            }
        }
        store.objectWillChange.send()
        store.saveWorkflowRules()
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: Workflow Log — Pull
    // ─────────────────────────────────────────────────────────────────

    func pullWorkflowLog() async {
        guard let companyID = store.currentCompanyID else { return }
        do {
            struct Row: Codable {
                let id:         String
                let company_id: String
                let rule_id:    String?
                let rule_name:  String
                let title:      String
                let body:       String
                let fired_at:   String
            }
            // Cap to 500 most recent — matches the in-memory cap so
            // we don't drag down a year's worth of fires on every pull.
            let rows: [Row] = try await client.select(
                Row.self,
                from: SupabaseTable.workflowLog,
                filters: [
                    .eq("company_id", companyID.uuidString),
                    .eq("is_deleted", false)
                ],
                orderBy: "fired_at",
                ascending: false,
                limit: 500
            )

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            // Preserve any locally-pending entries so a flush-in-flight
            // doesn't get overwritten by the pull.
            let pendingIDs = Set(store.workflowLog
                .filter { $0.syncStatus == .pending || $0.syncStatus == .failed }
                .map { $0.id })
            var merged: [WorkflowLogEntry] = store.workflowLog.filter { pendingIDs.contains($0.id) }

            for row in rows {
                guard let id  = UUID(uuidString: row.id),
                      !pendingIDs.contains(id),
                      let cid = UUID(uuidString: row.company_id) else { continue }
                var entry = WorkflowLogEntry(
                    ruleID:   row.rule_id.flatMap { UUID(uuidString: $0) } ?? UUID(),
                    ruleName: row.rule_name,
                    title:    row.title,
                    body:     row.body
                )
                entry.id         = id
                entry.firedAt    = iso.date(from: row.fired_at) ?? Date()
                entry.companyID  = cid
                entry.syncStatus = .synced
                merged.append(entry)
            }
            // Sort newest-first so the UI shows the same order as the
            // in-memory append path.
            merged.sort { $0.firedAt > $1.firedAt }
            await MainActor.run {
                store.workflowLog = Array(merged.prefix(500))
                store.saveWorkflowLog()
            }
        } catch {
            print("⚠️ pullWorkflowLog failed: \(error)")
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // MARK: Workflow Log — Push
    // ─────────────────────────────────────────────────────────────────

    func pushPendingWorkflowLog() async {
        guard let companyID = store.currentCompanyID else { return }
        let pending = store.workflowLog.filter { $0.syncStatus == .pending }
        guard !pending.isEmpty else { return }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for entry in pending {
            do {
                struct Row: Encodable {
                    let id:         String
                    let company_id: String
                    let rule_id:    String?
                    let rule_name:  String
                    let title:      String
                    let body:       String
                    let fired_at:   String
                    let is_deleted: Bool
                }
                let row = Row(
                    id:         entry.id.uuidString,
                    company_id: (entry.companyID ?? companyID).uuidString,
                    rule_id:    entry.ruleID.uuidString,
                    rule_name:  entry.ruleName,
                    title:      entry.title,
                    body:       entry.body,
                    fired_at:   iso.string(from: entry.firedAt),
                    is_deleted: entry.isDeleted
                )
                try await client.upsert(row, into: SupabaseTable.workflowLog)
                if let i = store.workflowLog.firstIndex(where: { $0.id == entry.id }) {
                    store.workflowLog[i].syncStatus = .synced
                }
            } catch {
                print("⚠️ pushPendingWorkflowLog failed for \(entry.id): \(error)")
                CrashReporter.capture(error: error,
                                      context: [
                                        "operation": "pushPendingWorkflowLog",
                                        "log_id":    entry.id.uuidString
                                      ])
                if let i = store.workflowLog.firstIndex(where: { $0.id == entry.id }) {
                    store.workflowLog[i].syncStatus = .failed
                }
            }
        }
        store.objectWillChange.send()
        store.saveWorkflowLog()
    }
}
