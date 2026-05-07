// LocalPendingStore.swift
// Aski IQ — Phase 1 Step 3
//
// PURPOSE
// Replaces the no-op `AppStore.saveToDisk()` / `loadFromDisk()` stubs with a
// real, tenant-scoped durable cache for pending business mutations. Without
// this, any local edit that hadn't completed `pushPending*` was lost on app
// crash, force-quit, or background termination — silent data loss.
//
// SCOPE — Stage A only
// Persists ONLY the 15 collections confirmed in the Phase 1 v3 plan:
//   clients, crm_contacts, crm_opportunities, estimates, quotes,
//   material_sales, projects, schedule_entries, timesheet_entries,
//   form_submissions, material_requests, change_orders,
//   schedule_recommendations, pending_workflow_alerts, exception_logs
//
// Within each collection, only rows with .syncStatus == .pending or .failed
// are persisted. We are NOT trying to be a full offline cache; the goal is
// "no edit gets lost between save and successful Supabase push."
//
// Stage B/C (full cache, attachments, etc.) is explicitly out of scope.
//
// TENANT ISOLATION
//   • Each tenant gets its own file path:
//       Application Support/AskiIQ/pending/<companyID-uuid>/snapshot.v1.json
//   • `attach(companyID:)` MUST be called after auth resolves and before
//     replay. Calling `replay` without an attached company is a no-op.
//   • Sign-out wipes the file via `wipe()` — but this is belt-and-braces:
//     even if wipe failed, the next sign-in attaches a different path so
//     the prior tenant's bytes can never reach a new session.
//
// SCHEMA VERSIONING
//   • The file carries a `schemaVersion: Int` in its header. If the file's
//     version != the runtime expected version, the file is quarantined
//     (renamed to *.corrupt-<unix-ts>) and the user starts fresh. No
//     migration logic. Bumping the version is the documented escape hatch
//     when the snapshot shape changes.
//
// CORRUPT CACHE RECOVERY
//   • Any JSONDecoder failure → quarantine + start empty.
//   • Any read I/O error other than file-not-found → log + start empty.
//   • Crash on read is impossible by construction.
//
// THREADING
//   • LocalPendingStore is an `actor` so file I/O is serialized and
//     never blocks the main thread.
//   • Snapshot construction reads @Published arrays on the main actor;
//     encode + write happen off-actor inside the LocalPendingStore actor.
//   • Replay returns a snapshot to the caller; the caller (AppStore on
//     the main actor) is responsible for merging it back into @Published
//     arrays.

import Foundation
import os

// MARK: - Persisted snapshot shape

/// On-disk representation of all Stage A pending writes for one tenant.
/// Adding a new collection or changing the shape of an existing one
/// REQUIRES bumping `LocalPendingStore.expectedSchemaVersion`.
struct PersistedPendingSnapshot: Codable {

    /// Bump when the shape of any field below changes incompatibly.
    /// Mismatch on read → quarantine + start fresh. No migration.
    var schemaVersion: Int

    /// The tenant this snapshot belongs to. Cross-checked at replay time
    /// — if the file claims tenant A but the live session is tenant B,
    /// we discard. Defense-in-depth on top of the per-tenant path.
    var companyID: UUID

    /// Wall-clock when the snapshot was written. Informational; not
    /// used for merge decisions.
    var savedAt: Date

    // MARK: Stage A collections (alphabetical by Swift name to keep diffs stable)

    var changeOrders:            [ChangeOrder]
    var clients:                 [Client]
    var crmContacts:             [CRMContact]
    var crmOpportunities:        [CRMOpportunity]
    var estimates:               [Estimate]
    var exceptionLogs:           [ExceptionLog]
    var formSubmissions:         [FormSubmission]
    var materialRequests:        [MaterialRequest]
    var materialSales:           [MaterialSale]
    var pendingWorkflowAlerts:   [WorkflowAlert]
    var projects:                [Project]
    var quotes:                  [Quote]
    var scheduleEntries:         [ScheduleEntry]
    var scheduleRecommendations: [ScheduleRecommendation]
    var timesheetEntries:        [TimesheetEntry]

    /// Total count across all collections. Used for log lines.
    var totalRowCount: Int {
        changeOrders.count + clients.count + crmContacts.count
        + crmOpportunities.count + estimates.count + exceptionLogs.count
        + formSubmissions.count + materialRequests.count + materialSales.count
        + pendingWorkflowAlerts.count + projects.count + quotes.count
        + scheduleEntries.count + scheduleRecommendations.count
        + timesheetEntries.count
    }
}

// MARK: - LocalPendingStore actor

actor LocalPendingStore {

    /// Singleton — there is one backing file per tenant, and the actor
    /// serializes I/O across the whole app.
    static let shared = LocalPendingStore()

    /// Bump when `PersistedPendingSnapshot` shape changes incompatibly.
    static let expectedSchemaVersion: Int = 1

    private let log = Logger(subsystem: "com.aski.iq", category: "LocalPendingStore")

    /// Resolved file URL for the currently-attached tenant.
    /// nil ⇒ no tenant attached → all save/replay operations are no-ops.
    private var fileURL: URL? = nil

    /// Currently-attached tenant. Used to validate snapshots at replay
    /// time AND to ensure save() never writes for the wrong tenant.
    private var attachedCompanyID: UUID? = nil

    /// Pending debounced save task. Coalesces rapid back-to-back save()
    /// calls into one disk write per ~500ms window.
    private var debounceTask: Task<Void, Never>? = nil
    private static let debounceNanos: UInt64 = 500_000_000  // 0.5s

    private init() {}

    // MARK: Attach / detach

    /// Bind the store to a tenant. Creates the per-tenant directory if
    /// missing. Idempotent — re-attaching to the same companyID is a
    /// no-op; attaching to a different one cancels any pending save
    /// for the previous tenant first.
    func attach(companyID: UUID) async {
        if attachedCompanyID == companyID, fileURL != nil {
            return
        }
        // Cancel any pending debounced save for the old tenant — its
        // snapshot was for a different file path.
        debounceTask?.cancel()
        debounceTask = nil

        do {
            let url = try Self.resolveFileURL(for: companyID)
            self.fileURL = url
            self.attachedCompanyID = companyID
            log.info("LocalPendingStore attached: companyID=\(companyID.uuidString, privacy: .public)")
        } catch {
            log.error("LocalPendingStore attach failed: \(error.localizedDescription, privacy: .public)")
            self.fileURL = nil
            self.attachedCompanyID = nil
        }
    }

    /// Wipe the on-disk file for the currently-attached tenant. Called
    /// from sign-out paths AFTER fullSignOutReset has stopped sync.
    /// Failure to wipe is logged but not fatal — the per-tenant path
    /// scheme means the next user lands on a different file anyway.
    func wipe() async {
        debounceTask?.cancel()
        debounceTask = nil

        guard let url = fileURL else {
            attachedCompanyID = nil
            return
        }
        let companyHint = attachedCompanyID?.uuidString ?? "unknown"
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                log.info("LocalPendingStore wiped: companyID=\(companyHint, privacy: .public)")
            }
        } catch {
            log.error("LocalPendingStore wipe failed: \(error.localizedDescription, privacy: .public)")
        }
        self.fileURL = nil
        self.attachedCompanyID = nil
    }

    // MARK: Replay

    /// Read the on-disk snapshot for the attached tenant, if any.
    /// Returns nil when:
    ///   • no tenant attached
    ///   • no file exists (clean install, or just-wiped)
    ///   • schemaVersion mismatch (file is quarantined)
    ///   • companyID mismatch (file is quarantined)
    ///   • JSON decode failure (file is quarantined)
    /// Caller — AppStore — is responsible for merging the returned
    /// snapshot back into @Published arrays.
    func replay() async -> PersistedPendingSnapshot? {
        guard let url = fileURL, let attached = attachedCompanyID else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            log.error("replay read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let snapshot: PersistedPendingSnapshot
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            snapshot = try decoder.decode(PersistedPendingSnapshot.self, from: data)
        } catch {
            log.error("replay decode failed — quarantining: \(error.localizedDescription, privacy: .public)")
            quarantine(url: url, reason: "decode-failure")
            return nil
        }

        if snapshot.schemaVersion != Self.expectedSchemaVersion {
            log.warning("replay schemaVersion mismatch — file=\(snapshot.schemaVersion) expected=\(Self.expectedSchemaVersion) — quarantining")
            quarantine(url: url, reason: "schema-mismatch")
            return nil
        }

        if snapshot.companyID != attached {
            log.error("replay tenant mismatch — file=\(snapshot.companyID.uuidString, privacy: .public) attached=\(attached.uuidString, privacy: .public) — quarantining")
            quarantine(url: url, reason: "tenant-mismatch")
            return nil
        }

        log.info("replay loaded \(snapshot.totalRowCount) pending rows for companyID=\(attached.uuidString, privacy: .public)")
        return snapshot
    }

    // MARK: Save

    /// Schedule a debounced write of `snapshot`. Multiple calls within
    /// `debounceNanos` collapse into one disk write. The most recent
    /// snapshot wins.
    func save(_ snapshot: PersistedPendingSnapshot) async {
        guard let url = fileURL, let attached = attachedCompanyID else {
            return
        }
        guard snapshot.companyID == attached else {
            // Caller built a snapshot for a different tenant. Refuse to
            // write — this is the kind of subtle bug we want to surface
            // rather than silently swallow.
            log.error("save refused — snapshot.companyID=\(snapshot.companyID.uuidString, privacy: .public) attached=\(attached.uuidString, privacy: .public)")
            return
        }

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanos)
            if Task.isCancelled { return }
            await self?.performWrite(snapshot, to: url)
        }
    }

    /// Synchronous write — bypasses debounce. Used for paths that need
    /// to guarantee on-disk durability before returning (sign-out flush,
    /// app-state-background hooks, manual "force save" diagnostics).
    func saveImmediately(_ snapshot: PersistedPendingSnapshot) async {
        guard let url = fileURL, let attached = attachedCompanyID else {
            return
        }
        guard snapshot.companyID == attached else {
            log.error("saveImmediately refused — snapshot.companyID=\(snapshot.companyID.uuidString, privacy: .public) attached=\(attached.uuidString, privacy: .public)")
            return
        }
        debounceTask?.cancel()
        debounceTask = nil
        await performWrite(snapshot, to: url)
    }

    private func performWrite(_ snapshot: PersistedPendingSnapshot, to url: URL) async {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(snapshot)
        } catch {
            log.error("performWrite encode failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Atomic write: write to temp file, then rename. Prevents partial
        // writes from a crash mid-flush from leaving a corrupt JSON behind.
        let tmpURL = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmpURL, options: [.atomic])
            // Replace existing file (rename is atomic on the same volume,
            // which Application Support always is on iOS).
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: url)
            }
            log.debug("performWrite wrote \(snapshot.totalRowCount) rows, \(data.count) bytes")
        } catch {
            log.error("performWrite move failed: \(error.localizedDescription, privacy: .public)")
            // Clean up tmp if it survived the failure
            try? FileManager.default.removeItem(at: tmpURL)
        }
    }

    // MARK: Quarantine + path resolution

    private func quarantine(url: URL, reason: String) {
        let ts = Int(Date().timeIntervalSince1970)
        let target = url.appendingPathExtension("corrupt-\(reason)-\(ts)")
        do {
            try FileManager.default.moveItem(at: url, to: target)
            log.warning("quarantined snapshot: \(target.lastPathComponent, privacy: .public)")
        } catch {
            // If the rename failed, drop the bad file outright — leaving
            // it in place would loop quarantine on every replay.
            log.error("quarantine rename failed (deleting instead): \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Resolve and ensure the per-tenant directory exists. Path:
    /// Application Support/AskiIQ/pending/<uuid>/snapshot.v1.json
    private static func resolveFileURL(for companyID: UUID) throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base
            .appendingPathComponent("AskiIQ", isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent(companyID.uuidString, isDirectory: true)

        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Mark the directory excluded from iCloud backup — pending writes
        // are device-local and per-tenant; backing them up to a different
        // device's iCloud account would break tenant isolation.
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var dirCopy = dir
        try? dirCopy.setResourceValues(excluded)

        return dir.appendingPathComponent("snapshot.v1.json", isDirectory: false)
    }
}

// MARK: - Local persistability protocol
//
// `BaseModel` is a heavier protocol that includes externalID, createdAt,
// updatedAt, lastModifiedBy, lastModifiedAt — required by sync but
// unnecessary for the keep/merge logic in this file. Several Stage A
// collections (Client, CRMContact, CRMOpportunity, MaterialRequest,
// ScheduleRecommendation) intentionally do NOT inherit BaseModel — they
// only declare Identifiable+Codable+Equatable plus their own id and
// syncStatus. To support those types alongside the BaseModel ones in a
// single generic merge helper, we declare a tiny protocol that captures
// just the two requirements LocalPendingStore actually needs.

protocol LocalPendingPersistable: Identifiable, Codable, Equatable
    where Self.ID == UUID
{
    // `id: UUID` is supplied by Identifiable + the `Self.ID == UUID`
    // constraint above. Re-declaring it here would re-state the
    // requirement with the file's actor-isolation context attached,
    // which conflicts with Identifiable's nonisolated declaration.
    var syncStatus: SyncStatus { get set }
}

// Conformance opt-ins for every Stage A model that is NOT covered by an
// existing BaseModel conformance (BaseModel's requirements are a strict
// superset, but Swift requires the conformance declaration to surface).

extension Project:                LocalPendingPersistable {}
extension Estimate:               LocalPendingPersistable {}
extension Quote:                  LocalPendingPersistable {}
extension MaterialSale:           LocalPendingPersistable {}
extension ScheduleEntry:          LocalPendingPersistable {}
extension TimesheetEntry:         LocalPendingPersistable {}
extension FormSubmission:         LocalPendingPersistable {}
extension ChangeOrder:            LocalPendingPersistable {}
extension ExceptionLog:           LocalPendingPersistable {}
// Non-BaseModel types — same shape, declared explicitly:
extension Client:                 LocalPendingPersistable {}
extension CRMContact:             LocalPendingPersistable {}
extension CRMOpportunity:         LocalPendingPersistable {}
extension MaterialRequest:        LocalPendingPersistable {}
extension ScheduleRecommendation: LocalPendingPersistable {}
// WorkflowAlert is intentionally excluded — it has no syncStatus
// (transient runtime fired alert), so it uses the alert-specific
// merge path below.

// MARK: - AppStore integration

extension AppStore {

    /// Build a Stage A snapshot from the live @Published arrays. Filters
    /// each collection to only rows in `.pending` or `.failed` state —
    /// `.synced` and `.local` rows are NOT persisted (they either live
    /// on the server already, or they were never staged for push).
    ///
    /// MUST be called on the main actor (AppStore is @MainActor).
    func buildPendingSnapshot() -> PersistedPendingSnapshot? {
        guard let companyID = currentCompanyID else { return nil }

        func keep<M: LocalPendingPersistable>(_ rows: [M]) -> [M] {
            rows.filter { $0.syncStatus == .pending || $0.syncStatus == .failed }
        }

        return PersistedPendingSnapshot(
            schemaVersion:           LocalPendingStore.expectedSchemaVersion,
            companyID:               companyID,
            savedAt:                 Date(),
            changeOrders:            keep(changeOrders),
            clients:                 keep(clients),
            crmContacts:             keep(crmContacts),
            crmOpportunities:        keep(crmOpportunities),
            estimates:               keep(estimates),
            exceptionLogs:           keep(exceptionLogs),
            formSubmissions:         keep(formSubmissions),
            materialRequests:        keep(materialRequests),
            materialSales:           keep(materialSales),
            // WorkflowAlert has no syncStatus — every live alert is
            // persisted unconditionally so a force-quit doesn't
            // swallow user-visible workflow notifications.
            pendingWorkflowAlerts:   pendingWorkflowAlerts,
            projects:                keep(projects),
            quotes:                  keep(quotes),
            scheduleEntries:         keep(scheduleEntries),
            scheduleRecommendations: keep(scheduleRecommendations),
            timesheetEntries:        keep(timesheetEntries)
        )
    }

    /// Merge a replayed snapshot back into the @Published arrays.
    /// Rule: an in-memory row with `.synced` always wins (server is
    /// fresher); otherwise the snapshot's row replaces the in-memory
    /// copy. Unmatched snapshot rows are appended.
    ///
    /// MUST be called on the main actor.
    func mergePendingSnapshot(_ snap: PersistedPendingSnapshot) {
        Self.merge(into: &changeOrders,            from: snap.changeOrders)
        Self.merge(into: &clients,                 from: snap.clients)
        Self.merge(into: &crmContacts,             from: snap.crmContacts)
        Self.merge(into: &crmOpportunities,        from: snap.crmOpportunities)
        Self.merge(into: &estimates,               from: snap.estimates)
        Self.merge(into: &exceptionLogs,           from: snap.exceptionLogs)
        Self.merge(into: &formSubmissions,         from: snap.formSubmissions)
        Self.merge(into: &materialRequests,        from: snap.materialRequests)
        Self.merge(into: &materialSales,           from: snap.materialSales)
        Self.mergeAlerts(into: &pendingWorkflowAlerts, from: snap.pendingWorkflowAlerts)
        Self.merge(into: &projects,                from: snap.projects)
        Self.merge(into: &quotes,                  from: snap.quotes)
        Self.merge(into: &scheduleEntries,         from: snap.scheduleEntries)
        Self.merge(into: &scheduleRecommendations, from: snap.scheduleRecommendations)
        Self.merge(into: &timesheetEntries,        from: snap.timesheetEntries)
    }

    /// Generic id-based merge for any LocalPendingPersistable array.
    /// Server-synced rows in memory are preserved (we don't trample
    /// fresh data with the older local snapshot); pending/failed rows
    /// are replaced with the disk version (which may have had more
    /// recent edits just before the crash).
    private static func merge<M: LocalPendingPersistable>(
        into live: inout [M],
        from disk: [M]
    ) {
        for row in disk {
            if let i = live.firstIndex(where: { $0.id == row.id }) {
                if live[i].syncStatus == .synced {
                    continue   // server is fresher — drop disk copy
                }
                live[i] = row
            } else {
                live.append(row)
            }
        }
    }

    /// WorkflowAlert is the one Stage A type without `syncStatus`. The
    /// merge path is additive only — never removes alerts, never
    /// replaces an existing live alert with a disk copy.
    private static func mergeAlerts(
        into live: inout [WorkflowAlert],
        from disk: [WorkflowAlert]
    ) {
        let liveIDs = Set(live.map { $0.id })
        for row in disk where !liveIDs.contains(row.id) {
            live.append(row)
        }
    }
}
