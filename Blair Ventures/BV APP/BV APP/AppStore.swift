// AppStore.swift
// AskiCommand – Single Source of Truth
// Session 3: Added auto-push to Supabase after every local write

import Foundation
import Combine

@MainActor
final class AppStore: ObservableObject {

    static let shared = AppStore()

    // MARK: - Published State

    @Published var projects: [Project] = []
    @Published var employees: [Employee] = []
    @Published var crews: [Crew] = []
    @Published var scheduleEntries: [ScheduleEntry] = []
    /// Phase 2 hardening: append-only audit log. New events flow in
    /// from `upsertScheduleEntry` / delete / quick-assign paths, get
    /// pushed by `SyncEngine.pushPendingScheduleAudits()`, and stay
    /// resident only until pushed. No pull side — read history via
    /// direct query when needed.
    @Published var scheduleAuditEvents: [ScheduleAuditEvent] = []
    /// Phase SR-1 Smart Scheduling: AI / rules-based recommendations
    /// awaiting human review. Engine writes here; the Command Centre
    /// review queue surface reads from here. Approving a recommendation
    /// mints real ScheduleEntries via `upsertScheduleEntry` and flips
    /// status to `.applied`.
    @Published var scheduleRecommendations: [ScheduleRecommendation] = []
    @Published var timesheetEntries: [TimesheetEntry] = []
    @Published var exceptionLogs: [ExceptionLog] = []
    @Published var formTemplates: [FormTemplate] = []
    @Published var formSubmissions: [FormSubmission] = []
    @Published var estimates: [Estimate] = []
    @Published var auditSnapshots: [AuditSnapshot] = []
    @Published var equipment:         [Equipment]        = []
    @Published var invoices:          [Invoice]          = []
    @Published var materialRequests:     [MaterialRequest]    = []
    @Published var purchaseOrders:       [PurchaseOrder]      = []
    @Published var suppliers:            [Supplier]           = []
    @Published var workflowRules:        [WorkflowRule]       = []
    @Published var pendingWorkflowAlerts: [WorkflowAlert]     = []
    @Published var workflowLog:          [WorkflowLogEntry]   = []
    @Published var changeOrders:         [ChangeOrder]        = []
    @Published var rfis:                 [RFI]                = []
    @Published var projectBudgets:       [ProjectBudget]      = []
    @Published var subcontractors:       [Subcontractor]      = []
    @Published var subContracts:         [SubContract]        = []
    @Published var incidents:            [Incident]           = []
    @Published var clients:              [Client]             = []
    @Published var companyCostCodes:     [CompanyCostCode]    = []
    @Published var productServices:      [ProductService]     = []
    @Published var clientPricings:       [ClientPricing]      = []
    @Published var importBatches:        [ImportBatch]        = []

    // Phase 8 / Inventory v1 — see InventoryModels.swift + InventoryStore.swift
    @Published var inventoryItems:        [InventoryItem]       = []
    @Published var stockLocations:        [StockLocation]       = []
    @Published var inventoryStockLevels:  [InventoryStockLevel] = []
    @Published var inventoryTransfers:    [InventoryTransfer]   = []

    /// Per-record sync error metadata. Populated by sync push catch
    /// blocks via `recordSyncError(id:error:)`; cleared on successful
    /// retry / discard. In-memory only — failed records reattempt on
    /// the next push cycle, so persisting the error string across app
    /// launches doesn't add value. Surfaced in FailedSyncDetailView so
    /// operators can see the actual reason instead of a generic
    /// "RLS or FK violation."
    @Published var syncErrors: [UUID: SyncErrorInfo] = [:]

    /// Phase 2 stabilization: tracks whether the first full pull has
    /// completed since this device installed the app. Backed by
    /// UserDefaults so a quit-and-relaunch keeps the flag set.
    ///
    /// Used to gate sensitive create flows (MR / PO today; other modules
    /// to follow) so a fresh-install user can't emit a record that
    /// references a project / client / opportunity their local store
    /// hasn't pulled yet — that path produces silent duplicate-number
    /// collisions, FK violations, and the auto-link-trigger NOT NULL
    /// failures we saw on 2026-05-09.
    ///
    /// Set to true in three places:
    ///   • SyncEngine.pullAll on successful completion (the canonical
    ///     "first sync done" signal).
    ///   • AppStore.init when the on-disk store already has data
    ///     (existing users upgrading to this build don't see the gate).
    ///   • Manual override via Admin Panel — escape hatch if a tenant
    ///     hits a bug with the gate logic; never expected in normal use.
    @Published var hasCompletedFirstSync: Bool = {
        UserDefaults.standard.bool(forKey: "bv_has_completed_first_sync")
    }() {
        didSet {
            UserDefaults.standard.set(hasCompletedFirstSync, forKey: "bv_has_completed_first_sync")
        }
    }

    /// Phase 12 follow-up: cache of all profiles in the current tenant
    /// (id + role + email), pulled from the `profiles` table. Used by
    /// QuoteApprovalNotifier to email the actual matching managers /
    /// executives when an approval lands in their queue, instead of
    /// just blasting a shared company inbox. Populated by
    /// SyncEngine.pullCompanyProfiles().
    @Published var tenantProfiles:       [AppUserProfile]     = []
    @Published var quotes:               [Quote]              = []
    @Published var materialSales:        [MaterialSale]       = []
    @Published var contracts:            [Contract]           = []
    @Published var contractClauses:      [ContractClause]     = []
    @Published var contractMilestones:   [ContractMilestone]  = []
    @Published var complianceDocuments:  [ComplianceDocument] = []
    @Published var lienWaivers:          [LienWaiver]         = []

    // Approval limits + workflow permissions per role per company. Populated
    // by SyncEngine.pullWorkflowSettings(); consumed by AppStore helpers in
    // WorkflowSetting.swift to gate Submit/Approve/Send/Receive actions.
    @Published var workflowSettings:     [WorkflowSetting]    = []

    // Read-only audit history for Material Requests. Written server-side by
    // the log_material_request_status_change trigger; pulled by
    // SyncEngine.pullMaterialRequestAudit() and shown in MRDetailView's
    // History section.
    @Published var materialRequestAudits: [MaterialRequestAudit] = []

    // MARK: - CRM State
    @Published var crmContacts:     [CRMContact]     = []
    @Published var crmOpportunities:[CRMOpportunity] = []
    @Published var crmTasks:        [CRMTask]        = []
    @Published var crmActivities:   [CRMActivity]    = []
    @Published var handoffChecklists:[HandoffChecklistItem] = []
    @Published var crmAttachments:   [CRMAttachment]        = []

    // MARK: - Session State

    @Published var currentUser: Employee?
    @Published var currentUserRole: UserRole = .foreman
    @Published var currentCompanyID: UUID?   = nil
    @Published var isOfflineMode: Bool       = false
    @Published var isAuthenticated: Bool     = false

    /// Set by NotificationTapDelegate when the user taps a notification.
    /// RootView observes this and switches tabs to the appropriate destination,
    /// then resets it to nil. Consumers should always reset after handling.
    @Published var pendingDeepLink: NotifRoute? = nil

    /// Set when the user taps an Aski IQ result in the iOS Spotlight search
    /// surface. RootView observes this, switches tabs, and pushes detail.
    /// Reset to nil after handling.
    @Published var pendingSpotlightTarget: SpotlightTarget? = nil

    /// Set when the user taps a result in the in-app universal search sheet.
    /// RootView observes this and routes to the relevant tab / list view.
    /// Reset to nil after handling.
    @Published var pendingOpenRecord: OpenRecordIntent? = nil

    // MARK: - Live Weather (mirrors WeatherService.shared)
    @Published var currentWeather: WeatherData? = nil

    private var weatherCancellable: AnyCancellable?

    private init() {
        // Mirror WeatherService into AppStore so form autoPopulate can read it
        weatherCancellable = WeatherService.shared.$weather
            .receive(on: RunLoop.main)
            .assign(to: \.currentWeather, on: self)
    }

    // MARK: - Persistence
    //
    // Phase 1 Step 3: replaced the no-op stubs with a real, tenant-scoped
    // pending-write cache. ONLY rows in `.syncStatus == .pending` or
    // `.failed` are persisted. `.synced` rows live on the server; persisting
    // them would balloon the cache and re-import stale copies on replay.
    //
    // Stage A scope is locked in `LocalPendingStore.PersistedPendingSnapshot`.
    //
    // Call-site contract (unchanged from the stub era):
    //   • saveToDisk()             — debounced (~500ms). Cheap to call often.
    //   • saveToDiskImmediately()  — synchronous flush. Use before sign-out
    //                                / app termination.
    //   • loadFromDisk()           — KEPT AS NO-OP. Real load happens via
    //                                bindLocalPersistence(...) AFTER auth
    //                                resolves a companyID. Calling load
    //                                before tenant context is known is
    //                                unsafe and we explicitly refuse.

    func saveToDisk() {
        guard currentCompanyID != nil,
              let snapshot = buildPendingSnapshot() else { return }
        Task { await LocalPendingStore.shared.save(snapshot) }
    }

    func saveToDiskImmediately() {
        guard currentCompanyID != nil,
              let snapshot = buildPendingSnapshot() else { return }
        Task { await LocalPendingStore.shared.saveImmediately(snapshot) }
    }

    func loadFromDisk() {
        // Intentionally a no-op. Real load is performed in
        // `bindLocalPersistence(companyID:)` AFTER auth resolves.
        // Loading here would either:
        //   • run with currentCompanyID == nil and replay nothing, or
        //   • leak Tenant A's pending edits into a future Tenant B session
        //     if init() ever runs after a partial sign-out.
    }

    /// Phase 1 Step 3 entry point — call from the auth-completion path
    /// (LoginView, BV_APPApp restoreSession, RootView company-switch)
    /// AFTER `currentCompanyID` is set.
    ///
    /// 1. Attach the local store to the resolved tenant directory.
    /// 2. Replay any pending rows back into @Published arrays.
    /// 3. SyncEngine.pushPending() at the next opportunity will then
    ///    flush the replayed pending rows to Supabase.
    ///
    /// Idempotent — re-attaching to the same companyID is a no-op.
    func bindLocalPersistence(companyID: UUID) {
        Task { [weak self] in
            await LocalPendingStore.shared.attach(companyID: companyID)
            guard let snapshot = await LocalPendingStore.shared.replay() else {
                return
            }
            await MainActor.run {
                guard let self = self else { return }
                // Tenant double-check at the merge boundary — if the
                // user signed out between attach and replay finish, we
                // refuse to merge into a wiped session.
                guard self.currentCompanyID == companyID else {
                    print("⛔ bindLocalPersistence — tenant changed during replay, dropping snapshot")
                    return
                }
                self.mergePendingSnapshot(snapshot)
                print("✅ bindLocalPersistence — merged \(snapshot.totalRowCount) pending rows for companyID=\(companyID)")
            }
        }
    }

    // MARK: - Permission Guard

    /// Returns true if the current role may perform the action.
    /// Prints a violation warning and returns false if not permitted.
    /// Does NOT throw — callers simply return early on false.
    /// Sample-data loading bypasses all guards (no currentUser set yet).
    @discardableResult
    func requireRole(_ allowed: [UserRole], action: String) -> Bool {
        // Bypass during sample data loading (no signed-in user)
        guard currentUser != nil else { return true }
        guard allowed.contains(currentUserRole) else {
            print("⛔ BV Permission denied: [\(currentUserRole.rawValue)] attempted '\(action)'")
            return false
        }
        return true
    }

    // MARK: - Generic CRUD
    // Each upsert saves locally first then pushes to Supabase in background

    func upsertProject(_ item: Project) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "upsert_project") else { return }

        // Phase 1 PMI gate: cannot transition a project to .completed
        // while it has open change orders. Pre-fix the closeout
        // simply moved on, leaving COs in limbo and revised-budget
        // calculations stranded between approved + pending. This
        // catches the transition (not the steady-state) so existing
        // .completed projects with open COs aren't blocked from being
        // saved for unrelated edits.
        let prior = projects.first(where: { $0.id == item.id })
        let isClosingNow = item.status == .completed
            && prior?.status != .completed
        if isClosingNow {
            let openCOs = changeOrders.filter {
                $0.projectID == item.id
                && $0.status.isOpen
                && !$0.isDeleted
            }
            if !openCOs.isEmpty {
                ToastService.shared.error(
                    "Can't close project — \(openCOs.count) change order\(openCOs.count == 1 ? " is" : "s are") still open. Approve or reject \(openCOs.count == 1 ? "it" : "them") first."
                )
                print("⚠️ upsertProject rejected: project \(item.id) has \(openCOs.count) open COs")
                return
            }
        }

        // Stamp the multi-tenant scope here. Without this, the row would
        // either fail RLS WITH CHECK on insert (`company_id = get_my_company_id()`)
        // or land in the DB with a NULL company_id that the next pull would
        // never decode back into the Swift model. Locking it in at the
        // upsert boundary means every UI-driven path (create, edit, restore)
        // is covered by one line.
        var stamped = item
        if stamped.companyID == nil { stamped.companyID = currentCompanyID }
        if let index = projects.firstIndex(where: { $0.id == stamped.id }) {
            projects[index] = stamped
        } else {
            projects.append(stamped)
        }
        saveToDisk()
        Task { await SyncEngine.shared.pushPending() }
        // Reflect into the system Spotlight index so users can find this
        // project from the iOS search surface.
        SpotlightService.shared.upsert(project: stamped)
    }

    func upsertEmployee(_ item: Employee) {
        guard requireRole([.officeAdmin, .manager, .executive],
                          action: "upsert_employee") else { return }
        // Stamp tenant scope so RLS WITH CHECK passes on insert/update and
        // so the next pull decoder finds a value to round-trip back.
        var stamped = item
        if stamped.companyID == nil { stamped.companyID = currentCompanyID }
        if let index = employees.firstIndex(where: { $0.id == stamped.id }) {
            employees[index] = stamped
        } else {
            employees.append(stamped)
        }
        saveToDisk()
        Task { await SyncEngine.shared.pushPending() }
    }

    func upsertCrew(_ item: Crew) {
        guard requireRole([.foreman, .projectManager, .officeAdmin, .manager, .executive],
                          action: "upsert_crew") else { return }
        // Same tenant-stamping contract as upsertEmployee.
        var stamped = item
        if stamped.companyID == nil { stamped.companyID = currentCompanyID }
        if let index = crews.firstIndex(where: { $0.id == stamped.id }) {
            crews[index] = stamped
        } else {
            crews.append(stamped)
        }
        saveToDisk()
        Task { await SyncEngine.shared.pushPending() }
    }

    /// Saves a schedule entry. Detects crew double-booking against existing
    /// entries; returns the conflict so the view can prompt the user. Pass
    /// `force = true` to save anyway (e.g. user accepted the conflict in a
    /// confirmation dialog). Returns nil if no conflict (or if forced).
    /// `auditNote` is an optional human-readable annotation persisted to
    /// the audit trail (e.g. "Quick Assign from Dispatch Board").
    @discardableResult
    func upsertScheduleEntry(_ item: ScheduleEntry,
                             force: Bool = false,
                             auditNote: String? = nil) -> ScheduleConflict? {
        // 2026-04 audit fix: schedule entries had no role gate, so a
        // field worker could in principle reassign their own crew or
        // edit a foreman's plan via direct API. Foreman+ now required.
        // Field workers still SEE the schedule via pull; they just
        // can't mutate it. Server-side RLS layered alongside this in
        // a follow-up migration so direct PostgREST calls also respect
        // the gate.
        // Phase 2 hardening: surface a toast on denial — silent failure
        // is anti-pattern per the enterprise UX rules.
        guard requireRole([.foreman, .projectManager, .officeAdmin, .manager, .executive],
                          action: "upsert_schedule_entry") else {
            ToastService.shared.error("You don't have permission to modify schedules.")
            return nil
        }

        // Phase RA-1: assignment-mode shape validation. Mirrors the
        // server-side CHECK constraint so the iOS app surfaces a clear
        // toast instead of letting a malformed write fail at sync time.
        // Legacy "fixed_crew with no crew yet" (the Unscheduled column
        // case) is allowed — that's the existing draft pattern.
        if let shapeError = assignmentShapeError(for: item) {
            ToastService.shared.error(shapeError)
            return nil
        }

        if !force, let conflict = wouldDoubleBookCrew(item) {
            return conflict
        }
        // Capture pre-state for the audit diff. firstIndex gets the
        // existing snapshot so we can compute crew/date changes.
        let prior = scheduleEntries.first(where: { $0.id == item.id })

        // Stamp tenant scope: prefer the parent project's companyID so a
        // shift inherits its project's tenant, with currentCompanyID as a
        // fallback (project may not be loaded yet on a fresh install).
        var stamped = item
        if stamped.companyID == nil {
            stamped.companyID = project(id: stamped.projectID)?.companyID ?? currentCompanyID
        }
        if let index = scheduleEntries.firstIndex(where: { $0.id == stamped.id }) {
            scheduleEntries[index] = stamped
        } else {
            scheduleEntries.append(stamped)
        }

        // Phase 2 hardening: write an audit row for every save.
        // Computed off the pre/post diff so we don't have to know the
        // user's intent — the data tells us what changed.
        appendScheduleAuditEvent(
            prior: prior,
            updated: stamped,
            forceUsed: force,
            note: auditNote
        )

        // Phase 1 follow-up: keep `Project.assignedCrewIDs` in sync with the
        // schedule. Pre-fix, scheduling a crew on a project never updated
        // the project's crew list, so ProjectDetailView showed shifts but
        // "No crews assigned". Centralizing the linkage here covers every
        // save path (create/edit, force-save, reassign, move) without
        // having to remember it in each call site. ADD-only on purpose —
        // removing a crew from one shift shouldn't strip them from the
        // project (they may still be on other shifts or manually attached).
        syncProjectAssignedCrewFromScheduleEntry(stamped)
        // Phase RA-1: same pattern for direct-worker assignments
        // (custom_crew + individual_worker modes). Workers from a
        // fixed_crew flow through the crew, not this helper.
        syncProjectAssignedWorkersFromScheduleEntry(stamped)

        saveToDisk()
        Task { await SyncEngine.shared.pushPending() }
        return nil
    }

    // MARK: - Phase 2: Permission read-only helpers
    //
    // The existing `requireRole` pattern is "guard inside the mutation"
    // — perfect for safety, but the UI also needs a quiet "can this user
    // even see / tap this action?" check so we hide unreachable buttons
    // instead of letting users tap → toast → confused. These are the
    // visibility predicates the dispatch board / calendar use.

    /// True when the current user can create or edit schedule entries.
    /// Mirrors the role list in `upsertScheduleEntry`'s `requireRole`.
    var canEditSchedule: Bool {
        guard currentUser != nil else { return true }
        return [.foreman, .projectManager, .officeAdmin, .manager, .executive]
            .contains(currentUserRole)
    }

    /// True when the current user can soft-delete a schedule entry.
    /// Tighter than edit — foremen can edit but not delete.
    var canDeleteSchedule: Bool {
        guard currentUser != nil else { return true }
        return [.projectManager, .officeAdmin, .manager, .executive]
            .contains(currentUserRole)
    }

    // MARK: - Phase 2: Audit log appender

    /// Diffs prior vs updated schedule entry and writes the right
    /// audit row. Single chokepoint — every save path runs through
    /// `upsertScheduleEntry`, which calls this once per save.
    /// `forceUsed = true` always tags `overrideUsed`, regardless of
    /// whether a conflict was actually detected (the user clicked
    /// the override button so the intent is recorded).
    fileprivate func appendScheduleAuditEvent(
        prior: ScheduleEntry?,
        updated: ScheduleEntry,
        forceUsed: Bool,
        note: String?
    ) {
        // Determine action — ordered by specificity. We only emit ONE
        // action per save, even if multiple things changed; the row
        // captures the diff for the rest.
        let action: ScheduleAuditAction = {
            if prior == nil { return .created }
            if prior?.isDeleted != updated.isDeleted, updated.isDeleted { return .deleted }
            if prior?.status != updated.status, updated.status == .cancelled { return .cancelled }
            if prior?.status != updated.status, updated.status == .completed { return .completed }
            if prior?.crewID != updated.crewID { return .reassigned }
            if let oldDate = prior?.date,
               !Calendar.current.isDate(oldDate, inSameDayAs: updated.date) {
                return .dateMoved
            }
            return .edited
        }()

        // Capture conflict snapshot at write time. Cheap — the detector
        // already ran during `wouldDoubleBookCrew`'s check; here we just
        // run the full detector once to label what was live.
        let liveConflicts = scheduleConflicts.filter { conflict in
            conflict.affectedEntries.contains(where: { $0.id == updated.id })
        }
        let conflictTypeStrings = liveConflicts.map { String(describing: $0.conflictType) }

        let event = ScheduleAuditEvent(
            companyID:        updated.companyID ?? currentCompanyID ?? UUID(),
            scheduleEntryID:  updated.id,
            projectID:        updated.projectID,
            userID:           currentUser?.id,
            userName:         currentUser?.fullName,
            action:           action,
            oldCrewID:        prior?.crewID,
            newCrewID:        updated.crewID,
            oldDate:          prior?.date,
            newDate:          updated.date,
            conflictDetected: !liveConflicts.isEmpty,
            conflictTypes:    conflictTypeStrings,
            overrideUsed:     forceUsed,
            notes:            note
        )
        scheduleAuditEvents.append(event)
        // Push runs in the same task as the schedule entry's push, so we
        // don't kick a separate Task here.
    }

    // MARK: - Phase SR-1: Schedule Recommendations CRUD + apply
    //
    // Recommendations live in their own table and don't go through
    // upsertScheduleEntry — they're proposals, not commitments.
    // Approving a recommendation calls `applyScheduleRecommendation`
    // which iterates proposed entries and routes each through the
    // chokepoint, so role gates / conflict checks / project linkage /
    // audit logs all run as if the manager had created the shifts
    // by hand.

    /// Save (insert or update) a recommendation. Foreman+ only —
    /// matches the schedule mutation gate. Marks the row pending so
    /// the next sync cycle pushes it.
    func upsertScheduleRecommendation(_ item: ScheduleRecommendation) {
        guard requireRole([.foreman, .projectManager, .officeAdmin, .manager, .executive],
                          action: "upsert_schedule_recommendation") else {
            ToastService.shared.error("You don't have permission to modify schedule recommendations.")
            return
        }
        var stamped = item
        if stamped.companyID == UUID() || stamped.companyID.uuidString == "00000000-0000-0000-0000-000000000000" {
            // Defensive: a freshly-built recommendation may carry a
            // sentinel zero-UUID companyID. Stamp the live one.
            stamped.companyID = currentCompanyID ?? stamped.companyID
        }
        stamped.updatedAt = Date()
        stamped.syncStatus = .pending
        if let idx = scheduleRecommendations.firstIndex(where: { $0.id == stamped.id }) {
            scheduleRecommendations[idx] = stamped
        } else {
            scheduleRecommendations.append(stamped)
        }
        saveToDisk()
        Task { await SyncEngine.shared.pushPending() }
    }

    /// Approve a recommendation and apply its proposed entries to
    /// the live schedule. Each proposed entry routes through
    /// `upsertScheduleEntry` so the existing safety net runs:
    ///   • role gate (will reject if user lacks permission)
    ///   • assignment-mode shape validation
    ///   • conflict gate (returns conflict for "Schedule Anyway" UX)
    ///   • project ↔ crew/worker linkage
    ///   • audit log row per entry
    ///
    /// SR-γ ADDITIONS:
    ///   • High-risk gate: when the plan has any high-severity risks
    ///     (`requiresHighRiskOverride == true`), ONLY manager or
    ///     executive can approve — PM and Office Admin are blocked
    ///     here even though they can normally approve plans.
    ///   • Override reason: when overriding high-risk, a reason is
    ///     mandatory and gets persisted on the recommendation +
    ///     stamped into the audit log via the per-entry auditNote.
    ///
    /// On any per-entry failure, we DON'T roll back already-created
    /// entries — partial application is preferable to losing the
    /// successfully-created ones, and the audit trail records what
    /// actually happened. The recommendation status stays approved
    /// (not applied) so the manager sees there's still work to finish.
    ///
    /// Returns the array of any conflicts that fired during apply
    /// (one per problematic entry); the caller can prompt for
    /// "Schedule Anyway" overrides via the existing flow.
    @discardableResult
    func applyScheduleRecommendation(_ recommendation: ScheduleRecommendation,
                                     editedAndApproved: Bool = false,
                                     overrideReason: String? = nil) -> [ScheduleConflict] {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "apply_schedule_recommendation") else {
            ToastService.shared.error("Only PMs and managers can approve schedule recommendations.")
            return []
        }
        // SR-γ: high-risk gate. Only manager/executive can override
        // a plan with high-severity risks. The reason is mandatory.
        if recommendation.requiresHighRiskOverride {
            guard [.manager, .executive].contains(currentUserRole) else {
                ToastService.shared.error("This plan has high-risk conflicts. Only Manager or Executive can approve it.")
                return []
            }
            let trimmedReason = (overrideReason ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedReason.isEmpty else {
                ToastService.shared.error("Approving a high-risk plan requires an override reason.")
                return []
            }
        }
        var rec = recommendation
        rec.status = editedAndApproved ? .editedAndApproved : .approved
        rec.approvedBy = currentUser?.id
        rec.approvedAt = Date()
        // SR-γ: persist the override reason + approval mode on the
        // recommendation. Both columns already exist from the SR-1
        // migration. Mode answers "why was THIS person allowed to
        // approve this?" — direct vs role-based vs senior override
        // vs conflict override (high-risk approval).
        if let reason = overrideReason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reason.isEmpty {
            rec.overrideReason = reason
        }
        // Approval mode resolution:
        //   • High-risk override (reason supplied) → conflictOverride
        //   • Otherwise the central authority gate computes mode
        //     based on assignee + role hierarchy. Default to
        //     .roleBased when no specific assignee is set.
        if rec.requiresHighRiskOverride && rec.overrideReason != nil {
            rec.approvalMode = .conflictOverride
        } else if let computedMode = approvalMode(
            for: .scheduleRecommendation,
            itemCompanyID: rec.companyID
        ) {
            rec.approvalMode = computedMode
        } else {
            rec.approvalMode = .roleBased
        }

        var createdIDs: [UUID] = []
        var conflicts: [ScheduleConflict] = []
        for proposed in rec.proposedEntries {
            var entry = ScheduleEntry(projectID: proposed.projectID, date: proposed.date)
            entry.id = UUID()
            entry.crewID = proposed.crewID
            entry.assignedWorkerIDs = proposed.assignedWorkerIDs
            entry.foremanID = proposed.foremanID
            entry.assignmentMode = proposed.assignmentMode
            entry.shiftStart = proposed.shiftStart
            entry.shiftEnd = proposed.shiftEnd
            entry.taskDescription = proposed.taskDescription
            entry.costCode = proposed.costCode
            entry.location = proposed.location
            entry.requiredCertifications = proposed.requiredCertifications
            entry.notes = proposed.notes
            entry.status = .scheduled
            let auditNote = "Applied from recommendation \(rec.id.uuidString)"
            // Force=false so the conflict gate fires; caller decides
            // whether to retry with force=true via the existing
            // Schedule Anyway flow on the review screen.
            if let conflict = upsertScheduleEntry(entry, force: false, auditNote: auditNote) {
                conflicts.append(conflict)
                continue
            }
            createdIDs.append(entry.id)
        }

        rec.appliedEntryIDs.append(contentsOf: createdIDs)
        // Only flip to .applied when ALL proposed entries succeeded.
        // Partial applies stay in approved/edited state so the
        // manager can see remaining work.
        if conflicts.isEmpty && createdIDs.count == rec.proposedEntries.count {
            rec.status = .applied
            rec.appliedAt = Date()
        }
        upsertScheduleRecommendation(rec)
        return conflicts
    }

    /// SR-β: Send a recommendation back to the requester with notes
    /// for revision. Distinct from reject — the recommendation stays
    /// in the queue (status `.revisionRequested`) so the requester
    /// can fix what's wrong and resubmit, OR a senior approver can
    /// take over and approve directly per the role hierarchy.
    ///
    /// Notes appear on the recommendation's review screen for the
    /// requester to address, and ride along into any subsequent
    /// approval/audit history.
    func requestScheduleRecommendationRevision(
        _ recommendation: ScheduleRecommendation,
        notes: String
    ) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "request_schedule_recommendation_revision") else {
            ToastService.shared.error("Only PMs and managers can send schedule plans back for revision.")
            return
        }
        var rec = recommendation
        rec.status = .revisionRequested
        // Capture WHO sent it back + WHEN, reusing the rejected_*
        // columns since they serve the same audit purpose ("a senior
        // closed the loop on this attempt"). The status discriminates
        // revision-vs-reject.
        rec.rejectedBy = currentUser?.id
        rec.rejectedAt = Date()
        rec.reviewNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        upsertScheduleRecommendation(rec)
    }

    /// Reject a recommendation with an optional reason. Status flips
    /// to .rejected; no schedule entries are created.
    func rejectScheduleRecommendation(_ recommendation: ScheduleRecommendation,
                                      reason: String? = nil) {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "reject_schedule_recommendation") else {
            ToastService.shared.error("Only PMs and managers can reject schedule recommendations.")
            return
        }
        var rec = recommendation
        rec.status = .rejected
        rec.rejectedBy = currentUser?.id
        rec.rejectedAt = Date()
        rec.rejectionReason = reason
        upsertScheduleRecommendation(rec)
    }

    /// Convenience predicate for the Command Centre queue card: is
    /// this user allowed to approve schedule recommendations at all?
    /// SR-α: now routes through the central `canApproveDomain(_:)`
    /// helper so the role list lives in one place. Per-recommendation
    /// gating (high-risk, override reason) layers on top via
    /// `ApprovalAuthority.canApprove(...)`.
    var canApproveScheduleRecommendation: Bool {
        guard currentUser != nil else { return true }
        return currentUserRole.canApproveDomain(.scheduleRecommendation)
    }

    /// Adds the schedule entry's crew to its project's `assignedCrewIDs`
    /// when not already present. Bypasses the `upsertProject` role gate
    /// because this is a derived assignment, not a user-initiated edit —
    /// foremen can save schedule entries (per `upsert_schedule_entry`)
    /// but can't directly write to projects, and we need the linkage to
    /// land regardless of whose hands triggered the save.
    ///
    /// Idempotent: safe to call repeatedly with the same entry.
    /// No-op when the entry has no crewID, no projectID (defensive),
    /// or when the project can't be found (stale/deleted).
    private func syncProjectAssignedCrewFromScheduleEntry(_ entry: ScheduleEntry) {
        guard let crewID = entry.crewID else { return }
        guard let projIdx = projects.firstIndex(where: { $0.id == entry.projectID }) else { return }
        var project = projects[projIdx]
        guard !project.assignedCrewIDs.contains(crewID) else { return }
        project.assignedCrewIDs.append(crewID)
        project.syncStatus = .pending
        project.lastModifiedAt = Date()
        if project.companyID == nil { project.companyID = currentCompanyID }
        projects[projIdx] = project
    }

    // MARK: - Phase RA-1: Worker linkage + assignment validation

    /// Mirrors `syncProjectAssignedCrewFromScheduleEntry` for direct-
    /// worker assignments. When a shift in `customCrew` or
    /// `individualWorker` mode is saved, the assigned workers get
    /// appended (de-duplicated, additive only) to the project's
    /// `assignedWorkerIDs` array so ProjectDetailView's eventual
    /// "Assigned Workers" section can render them.
    ///
    /// Idempotent. Same role-gate bypass rationale as the crew helper.
    /// No-op for fixedCrew without an explicit roster override (RA-3
    /// will introduce that case) — workers come through the crew link.
    fileprivate func syncProjectAssignedWorkersFromScheduleEntry(_ entry: ScheduleEntry) {
        guard !entry.assignedWorkerIDs.isEmpty else { return }
        guard let projIdx = projects.firstIndex(where: { $0.id == entry.projectID }) else { return }
        var project = projects[projIdx]
        var changed = false
        for worker in entry.assignedWorkerIDs where !project.assignedWorkerIDs.contains(worker) {
            project.assignedWorkerIDs.append(worker)
            changed = true
        }
        guard changed else { return }
        project.syncStatus = .pending
        project.lastModifiedAt = Date()
        if project.companyID == nil { project.companyID = currentCompanyID }
        projects[projIdx] = project
    }

    /// Validates the assignment-mode shape per RA-1 rules. Returns a
    /// human-readable error string when the shape is wrong, or nil
    /// when the entry is structurally valid. Mirrors the server-side
    /// CHECK constraint so the user gets a clear toast at write time.
    ///
    /// Legacy/draft case (fixedCrew, no crew, no workers) is allowed —
    /// matches the Dispatch Board's "Unscheduled" column behavior.
    fileprivate func assignmentShapeError(for entry: ScheduleEntry) -> String? {
        let workerCount = entry.assignedWorkerIDs.count
        switch entry.assignmentMode {
        case .fixedCrew:
            // Must have a crew when assigning workers; allow no-crew /
            // no-worker draft for the Unscheduled column.
            if entry.crewID == nil && workerCount > 0 {
                return "Fixed Crew shift can't have workers without a crew. Pick a crew or switch to Custom Crew."
            }
            // Custom-crew foreman validation: foreman must be in the
            // assigned-worker roster when override is used. Doesn't
            // apply to fixedCrew (foreman comes from Crew.foremanID).
            return nil
        case .customCrew:
            if workerCount < 1 {
                return "Custom Crew needs at least one worker assigned."
            }
            if let f = entry.foremanID, !entry.assignedWorkerIDs.contains(f) {
                return "Foreman must be one of the assigned workers."
            }
            return nil
        case .individualWorker:
            if entry.crewID != nil {
                return "Individual Worker shift can't have a crew. Switch to Custom Crew if you need both."
            }
            if workerCount != 1 {
                return "Individual Worker shift needs exactly one worker."
            }
            // No foreman role on a one-person shift. The single worker
            // IS the worker. If a foreman is required by company policy
            // (future per-tenant setting), promote to customCrew instead.
            if let f = entry.foremanID, f != entry.assignedWorkerIDs.first {
                return "Individual Worker shift can't have a separate foreman. Switch to Custom Crew if you need both roles."
            }
            return nil
        }
    }

    func upsertTimesheetEntry(_ item: TimesheetEntry) {
        // 2026-04 audit fix: timesheets are payroll data — anyone
        // creating/editing a row needs at least field-worker level
        // (workers submit their own; foremen approve). Without this
        // gate a `.client` role could in principle insert payroll
        // entries via the same code path. Field roles can submit
        // their own time, but the server RLS still has to confirm
        // employeeID == auth.uid() for non-foreman submissions.
        guard requireRole([.fieldWorker, .foreman, .safetyAdvisor,
                           .projectManager, .estimator, .officeAdmin,
                           .manager, .executive],
                          action: "upsert_timesheet_entry") else { return }
        let isNewSubmission = item.approvalStatus == .submitted &&
            !timesheetEntries.contains(where: { $0.id == item.id && $0.approvalStatus == .submitted })

        // Stamp tenant scope from the parent project, fallback to currentCompanyID.
        var stamped = item
        if stamped.companyID == nil {
            stamped.companyID = project(id: stamped.projectID)?.companyID ?? currentCompanyID
        }
        if let index = timesheetEntries.firstIndex(where: { $0.id == stamped.id }) {
            timesheetEntries[index] = stamped
        } else {
            timesheetEntries.append(stamped)
        }
        saveToDisk()
        Task { await SyncEngine.shared.pushPending() }

        // Notifications
        let pending = pendingTimesheets().count
        NotificationManager.shared.syncBadge(pendingCount: pending)
        NotificationManager.shared.scheduleDailyApprovalReminder(pendingCount: pending)

        if isNewSubmission {
            let empName  = employee(id: item.employeeID)?.fullName ?? "A worker"
            let projName = project(id: item.projectID)?.name ?? "a project"
            NotificationManager.shared.notifySubmitted(
                employeeName: empName,
                hours:        "\(item.totalHours)",
                projectName:  projName
            )
        }
    }

    func upsertFormTemplate(_ item: FormTemplate) {
        // 2026-04 audit fix: form templates are organization-wide and
        // changing one affects every future submission. Anyone with
        // access to the iOS app could previously mutate templates;
        // now it's office-admin / manager / executive / safety-advisor
        // (the last because safety templates are part of their job).
        guard requireRole([.safetyAdvisor, .officeAdmin, .manager, .executive],
                          action: "upsert_form_template") else { return }
        // Form templates are org-wide — stamp directly from currentCompanyID.
        var stamped = item
        if stamped.companyID == nil { stamped.companyID = currentCompanyID }
        if let index = formTemplates.firstIndex(where: { $0.id == stamped.id }) {
            formTemplates[index] = stamped
        } else {
            formTemplates.append(stamped)
        }
        saveToDisk()
        Task { await SyncEngine.shared.pushPending() }
    }

    func deleteFormTemplate(_ item: FormTemplate) {
        guard let idx = formTemplates.firstIndex(where: { $0.id == item.id }) else { return }
        var deleted = formTemplates[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        formTemplates[idx] = deleted
        Task { await SyncEngine.shared.pushPending() }
    }

    func upsertFormSubmission(_ item: FormSubmission) {
        // Stamp tenant scope from the parent template's companyID, falling
        // back to currentCompanyID if the template isn't in memory.
        var stamped = item
        if stamped.companyID == nil {
            stamped.companyID =
                formTemplates.first(where: { $0.id == stamped.templateID })?.companyID
                ?? currentCompanyID
        }
        if let index = formSubmissions.firstIndex(where: { $0.id == stamped.id }) {
            formSubmissions[index] = stamped
        } else {
            formSubmissions.append(stamped)
        }
        saveToDisk()
        Task { await SyncEngine.shared.pushPending() }
    }

    func deleteFormSubmission(_ item: FormSubmission) {
        guard let idx = formSubmissions.firstIndex(where: { $0.id == item.id }) else { return }
        var deleted = formSubmissions[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        formSubmissions[idx] = deleted
        Task { await SyncEngine.shared.pushPending() }
    }

    /// Returns a short summary of what changed between two Estimate versions
    /// for the revision-history audit trail. Returns nil when nothing material
    /// changed (skip snapshot).
    fileprivate func estimateRevisionSummary(prior: Estimate?, next: Estimate) -> String? {
        guard let prior else { return nil }
        var changes: [String] = []
        if prior.status != next.status {
            changes.append("status: \(prior.status.rawValue) → \(next.status.rawValue)")
        }
        if prior.totalEstimated != next.totalEstimated {
            changes.append("total: \(prior.totalEstimated.currencyString) → \(next.totalEstimated.currencyString)")
        }
        if prior.lineItems.count != next.lineItems.count {
            changes.append("line items: \(prior.lineItems.count) → \(next.lineItems.count)")
        }
        if prior.scopeDescription != next.scopeDescription {
            changes.append("scope edited")
        }
        if prior.profitPercent != next.profitPercent || prior.contingencyPercent != next.contingencyPercent {
            changes.append("markup adjusted")
        }
        return changes.isEmpty ? nil : changes.joined(separator: ", ")
    }

    func upsertEstimate(_ item: Estimate) {
        guard requireRole([.estimator, .projectManager, .officeAdmin, .manager, .executive],
                          action: "upsert_estimate") else { return }
        let isNew     = !estimates.contains(where: { $0.id == item.id })
        let prior     = estimates.first(where: { $0.id == item.id })
        let oldStatus = prior?.status
        let revisionSummary = estimateRevisionSummary(prior: prior, next: item)
        var updated   = item
        updated.syncStatus     = .pending
        updated.updatedAt      = Date()
        updated.lastModifiedAt = Date()
        // Stamp tenant scope. Estimates are typically created from a CRM
        // opportunity which is already tenant-scoped, but fall back to
        // currentCompanyID so a freshly created estimate without a parent
        // opportunity still gets stamped.
        if updated.companyID == nil { updated.companyID = currentCompanyID }

        // CRM bridge: auto-create linked opportunity for new estimates with no prior link.
        // Idempotent — ensureCRMLink checks for existing link before creating anything.
        if isNew && updated.opportunityID == nil {
            ensureCRMLink(for: &updated)
        }

        if let index = estimates.firstIndex(where: { $0.id == item.id }) {
            estimates[index] = updated
        } else {
            estimates.append(updated)
        }
        Task { await SyncEngine.shared.pushPendingEstimates() }

        // Phase 1 PMI fix: estimate total → opportunity value live
        // sync. Pre-fix the linked opportunity's `value` was set
        // only when the CRM link was first created (in
        // ensureCRMLink). Subsequent estimate edits — adding line
        // items, adjusting markup, AI re-extraction — left the
        // opportunity's value stale, so pipeline-by-stage rollups
        // and forecast charts read the wrong number.
        //
        // Skip the sync once the opportunity is .won or .lost —
        // those stages lock the value (won snapshots actual award,
        // lost preserves the bid amount we lost on). Also skip
        // when the estimate is itself .lost / .cancelled / .converted
        // since those are terminal states whose value shouldn't
        // bleed back into the live pipeline.
        if let oppID = updated.opportunityID,
           let oppIdx = crmOpportunities.firstIndex(where: { $0.id == oppID && !$0.isDeleted }),
           crmOpportunities[oppIdx].stage != .won,
           crmOpportunities[oppIdx].stage != .lost,
           !(updated.status == .lost
             || updated.status == .cancelled
             || updated.status == .converted) {
            let newValue = updated.totalEstimated
            if crmOpportunities[oppIdx].value != newValue {
                crmOpportunities[oppIdx].value      = newValue
                crmOpportunities[oppIdx].updatedAt  = Date()
                crmOpportunities[oppIdx].syncStatus = .pending
                Task { await SyncEngine.shared.pushPendingCRMOpportunities() }
            }
        }

        // Auto-advance the linked opportunity stage when the estimate
        // crosses a terminal threshold. Fires once on transition (not on
        // every save while terminal) by gating on `oldStatus != newStatus`.
        // The opportunity is the source of truth for "Won / Lost" once
        // crossed — value gets snapshotted to the awarded amount and the
        // pipeline rollups stop drifting with subsequent estimate edits.
        if let oldStatus, oldStatus != updated.status,
           let oppID = updated.opportunityID,
           let oppIdx = crmOpportunities.firstIndex(where: { $0.id == oppID && !$0.isDeleted }) {
            switch updated.status {
            case .awarded:
                if crmOpportunities[oppIdx].stage != .won {
                    crmOpportunities[oppIdx].stage       = .won
                    crmOpportunities[oppIdx].probability = OpportunityStage.won.defaultProbability
                    crmOpportunities[oppIdx].wonAt       = Date()
                    crmOpportunities[oppIdx].value       = updated.awardedValue ?? updated.totalEstimated
                    crmOpportunities[oppIdx].updatedAt   = Date()
                    crmOpportunities[oppIdx].syncStatus  = .pending
                    Task { await SyncEngine.shared.pushPendingCRMOpportunities() }
                }
            case .lost:
                if crmOpportunities[oppIdx].stage != .lost {
                    crmOpportunities[oppIdx].stage       = .lost
                    crmOpportunities[oppIdx].probability = OpportunityStage.lost.defaultProbability
                    crmOpportunities[oppIdx].lostAt      = Date()
                    crmOpportunities[oppIdx].lossReason     = updated.lossReason?.rawValue ?? crmOpportunities[oppIdx].lossReason
                    crmOpportunities[oppIdx].competitorName = updated.competitorName     ?? crmOpportunities[oppIdx].competitorName
                    crmOpportunities[oppIdx].updatedAt   = Date()
                    crmOpportunities[oppIdx].syncStatus  = .pending
                    Task { await SyncEngine.shared.pushPendingCRMOpportunities() }
                }
            default:
                break
            }
        }

        // Snapshot the prior state on material changes; baseline-snapshot on create.
        if let summary = revisionSummary, let snapshot = prior {
            Task { await RevisionService.shared.snapshotEstimate(snapshot, summary: summary) }
        } else if isNew {
            Task { await RevisionService.shared.snapshotEstimate(item, summary: "Created") }
        }

        if let old = oldStatus, old != updated.status {
            NotificationManager.shared.notifyEstimateStatusChanged(
                estimateName: updated.name,
                status:       updated.status.rawValue
            )
            // 2026-04 audit fix (Phase 9): typed audit row on every
            // estimate status change. Compliance asks "who marked
            // this estimate `awarded` and when?" — pre-fix the
            // revision JSON had it but only as a diff; this row
            // makes it queryable by event_type.
            createAuditSnapshot(
                for:       updated,
                eventType: "status_changed_\(old.rawValue)_to_\(updated.status.rawValue)",
                by:        currentUser?.fullName ?? "system"
            )
        } else if isNew {
            createAuditSnapshot(
                for:       updated,
                eventType: "created",
                by:        currentUser?.fullName ?? "system"
            )
        }
    }

    // MARK: - Deletes

    enum ProjectDeletionError: LocalizedError {
        case notPermitted
        case notFound
        case hasDependents(String)

        var errorDescription: String? {
            switch self {
            case .notPermitted:
                return "You don't have permission to delete this project."
            case .notFound:
                return "Project not found."
            case .hasDependents(let summary):
                return "This project still has \(summary). Archive or move those records before deleting."
            }
        }
    }

    /// Counts active (non-deleted) records that reference a project. Used to
    /// block deletes that would leave orphaned timesheets, invoices, COs, etc.
    private func projectDependents(for projectID: UUID) -> [String] {
        var parts: [String] = []
        let ts = timesheetEntries.filter { $0.projectID == projectID && !$0.isDeleted }.count
        if ts > 0 { parts.append("\(ts) timesheet entr\(ts == 1 ? "y" : "ies")") }
        let inv = invoices.filter { $0.projectID == projectID && !$0.isDeleted }.count
        if inv > 0 { parts.append("\(inv) invoice\(inv == 1 ? "" : "s")") }
        let cos = changeOrders.filter { $0.projectID == projectID && !$0.isDeleted }.count
        if cos > 0 { parts.append("\(cos) change order\(cos == 1 ? "" : "s")") }
        let rfis = self.rfis.filter { $0.projectID == projectID && !$0.isDeleted }.count
        if rfis > 0 { parts.append("\(rfis) RFI\(rfis == 1 ? "" : "s")") }
        let scheds = scheduleEntries.filter { $0.projectID == projectID && !$0.isDeleted }.count
        if scheds > 0 { parts.append("\(scheds) schedule entr\(scheds == 1 ? "y" : "ies")") }
        return parts
    }

    @discardableResult
    func deleteProject(_ item: Project) -> Result<Void, ProjectDeletionError> {
        guard requireRole([.manager, .executive], action: "delete_project") else {
            return .failure(.notPermitted)
        }
        guard let idx = projects.firstIndex(where: { $0.id == item.id }) else {
            return .failure(.notFound)
        }
        let deps = projectDependents(for: item.id)
        if !deps.isEmpty {
            return .failure(.hasDependents(deps.joined(separator: ", ")))
        }
        var deleted = projects[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        projects[idx] = deleted
        Task { await SyncEngine.shared.pushPending() }
        return .success(())
    }

    enum EmployeeDeletionError: LocalizedError {
        case notPermitted
        case notFound
        case hasDependents(String)

        var errorDescription: String? {
            switch self {
            case .notPermitted:
                return "You don't have permission to delete this employee."
            case .notFound:
                return "Employee not found."
            case .hasDependents(let summary):
                return "This employee still has \(summary). Reassign or archive those records before deleting."
            }
        }
    }

    private func employeeDependents(for empID: UUID) -> [String] {
        var parts: [String] = []
        let ts = timesheetEntries.filter { $0.employeeID == empID && !$0.isDeleted }.count
        if ts > 0 { parts.append("\(ts) timesheet entr\(ts == 1 ? "y" : "ies")") }
        let crewsWithEmp = crews.filter { $0.memberIDs.contains(empID) && !$0.isDeleted && $0.isActive }.count
        if crewsWithEmp > 0 { parts.append("\(crewsWithEmp) active crew\(crewsWithEmp == 1 ? "" : "s")") }
        let certs = certificates.filter { $0.employeeID == empID && !$0.isDeleted }.count
        if certs > 0 { parts.append("\(certs) certification\(certs == 1 ? "" : "s")") }
        return parts
    }

    @discardableResult
    func deleteEmployee(_ item: Employee) -> Result<Void, EmployeeDeletionError> {
        guard requireRole([.manager, .executive], action: "delete_employee") else {
            return .failure(.notPermitted)
        }
        guard let idx = employees.firstIndex(where: { $0.id == item.id }) else {
            return .failure(.notFound)
        }
        let deps = employeeDependents(for: item.id)
        if !deps.isEmpty {
            return .failure(.hasDependents(deps.joined(separator: ", ")))
        }
        var deleted = employees[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        employees[idx] = deleted
        Task { await SyncEngine.shared.pushPending() }
        return .success(())
    }

    enum CrewDeletionError: LocalizedError {
        case notPermitted
        case notFound
        case hasDependents(String)

        var errorDescription: String? {
            switch self {
            case .notPermitted:
                return "You don't have permission to delete this crew."
            case .notFound:
                return "Crew not found."
            case .hasDependents(let summary):
                return "This crew still has \(summary). Reassign before deleting."
            }
        }
    }

    private func crewDependents(for crewID: UUID) -> [String] {
        var parts: [String] = []
        let scheds = scheduleEntries.filter { $0.crewID == crewID && !$0.isDeleted }.count
        if scheds > 0 { parts.append("\(scheds) upcoming shift\(scheds == 1 ? "" : "s")") }
        let projAssigned = projects.filter { $0.assignedCrewIDs.contains(crewID) && !$0.isDeleted }.count
        if projAssigned > 0 { parts.append("\(projAssigned) project assignment\(projAssigned == 1 ? "" : "s")") }
        return parts
    }

    @discardableResult
    func deleteCrew(_ item: Crew) -> Result<Void, CrewDeletionError> {
        guard requireRole([.projectManager, .officeAdmin, .manager, .executive],
                          action: "delete_crew") else { return .failure(.notPermitted) }
        guard let idx = crews.firstIndex(where: { $0.id == item.id }) else {
            return .failure(.notFound)
        }
        let deps = crewDependents(for: item.id)
        if !deps.isEmpty {
            return .failure(.hasDependents(deps.joined(separator: ", ")))
        }
        var deleted = crews[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        crews[idx] = deleted
        Task { await SyncEngine.shared.pushPending() }
        return .success(())
    }

    func deleteTimesheetEntry(_ item: TimesheetEntry) {
        guard requireRole([.foreman, .projectManager, .officeAdmin, .manager, .executive],
                          action: "delete_timesheet") else { return }
        guard let idx = timesheetEntries.firstIndex(where: { $0.id == item.id }) else { return }
        var deleted = timesheetEntries[idx]
        deleted.isDeleted  = true
        deleted.deletedAt  = Date()
        deleted.deletedBy  = currentUser?.fullName ?? ""
        deleted.syncStatus = .pending
        timesheetEntries[idx] = deleted
        Task { await SyncEngine.shared.pushPending() }
    }

    // MARK: - Lookup Helpers

    func project(id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    func employee(id: UUID) -> Employee? {
        employees.first { $0.id == id }
    }

    func crew(id: UUID) -> Crew? {
        crews.first { $0.id == id }
    }

    func timesheets(for projectID: UUID) -> [TimesheetEntry] {
        timesheetEntries.filter { $0.projectID == projectID }
    }

    func scheduleEntries(for date: Date) -> [ScheduleEntry] {
        let calendar = Calendar.current
        return scheduleEntries.filter { calendar.isDate($0.date, inSameDayAs: date) }
    }

    func pendingTimesheets() -> [TimesheetEntry] {
        timesheetEntries.filter { $0.approvalStatus == .submitted && !$0.isDeleted }
    }

    // MARK: - Dashboard Helpers
    //
    // Centralized "live" filters so every dashboard / widget agrees on what
    // counts as an active row. Soft-deleted projects were leaking into KPI
    // tiles, the Active Projects card on the Office dashboard, and the
    // Pipeline / Schedule widgets — these helpers prevent that.

    /// Active, non-soft-deleted projects. The single source of truth for
    /// every "Active Projects" KPI / list / chart in the app.
    var liveActiveProjects: [Project] {
        projects.filter { $0.status == .active && !$0.isDeleted }
    }

    /// Live (non-soft-deleted) projects regardless of status.
    var liveProjects: [Project] {
        projects.filter { !$0.isDeleted }
    }

    /// Live (non-soft-deleted) invoices regardless of status.
    var liveInvoices: [Invoice] {
        invoices.filter { !$0.isDeleted }
    }

    /// Live (non-soft-deleted) estimates regardless of status.
    var liveEstimates: [Estimate] {
        estimates.filter { !$0.isDeleted }
    }

    // MARK: - Tenant Scope Backfill
    //
    // The `projects.company_id` column was added to the Supabase schema before
    // the Swift `Project` struct carried the field, so older rows pulled by
    // earlier builds landed with `companyID == nil` locally. This walker
    // stamps the current tenant onto any orphan row and pushes the corrected
    // rows back so the server has them too.
    //
    // Idempotent — only touches rows where `companyID` is genuinely nil, and
    // only when we have a `currentCompanyID` to stamp with. Safe to call
    // after every pull.
    @discardableResult
    func backfillProjectCompanyIDs() -> Int {
        guard let companyID = currentCompanyID else { return 0 }
        var fixed = 0
        for i in projects.indices where projects[i].companyID == nil {
            projects[i].companyID  = companyID
            projects[i].syncStatus = .pending
            fixed += 1
        }
        if fixed > 0 {
            Task { await SyncEngine.shared.pushPending() }
        }
        return fixed
    }

    /// Stamp tenant scope on Employee rows that arrived without it. Same
    /// idempotent walker pattern as `backfillProjectCompanyIDs`. Important
    /// to run before tightening `employees.company_id` to NOT NULL on the
    /// server side because the column is shipped here as PII (payroll).
    @discardableResult
    func backfillEmployeeCompanyIDs() -> Int {
        guard let companyID = currentCompanyID else { return 0 }
        var fixed = 0
        for i in employees.indices where employees[i].companyID == nil {
            employees[i].companyID  = companyID
            employees[i].syncStatus = .pending
            fixed += 1
        }
        if fixed > 0 {
            Task { await SyncEngine.shared.pushPending() }
        }
        return fixed
    }

    /// Stamp tenant scope on Crew rows that arrived without it.
    @discardableResult
    func backfillCrewCompanyIDs() -> Int {
        guard let companyID = currentCompanyID else { return 0 }
        var fixed = 0
        for i in crews.indices where crews[i].companyID == nil {
            crews[i].companyID  = companyID
            crews[i].syncStatus = .pending
            fixed += 1
        }
        if fixed > 0 {
            Task { await SyncEngine.shared.pushPending() }
        }
        return fixed
    }

    /// Stamp tenant scope on the project-derived operational tables that
    /// arrived without it. Each entry inherits its parent project's
    /// `companyID` first; if that lookup fails (parent not yet pulled),
    /// falls back to `currentCompanyID`. Idempotent — only touches rows
    /// where `companyID` is genuinely nil.
    @discardableResult
    func backfillOperationalCompanyIDs() -> Int {
        guard let fallback = currentCompanyID else { return 0 }
        var fixed = 0

        func resolveFromProject(_ projectID: UUID?) -> UUID {
            if let pid = projectID, let p = projects.first(where: { $0.id == pid }),
               let cid = p.companyID { return cid }
            return fallback
        }

        for i in scheduleEntries.indices where scheduleEntries[i].companyID == nil {
            scheduleEntries[i].companyID  = resolveFromProject(scheduleEntries[i].projectID)
            scheduleEntries[i].syncStatus = .pending
            fixed += 1
        }
        for i in timesheetEntries.indices where timesheetEntries[i].companyID == nil {
            timesheetEntries[i].companyID  = resolveFromProject(timesheetEntries[i].projectID)
            timesheetEntries[i].syncStatus = .pending
            fixed += 1
        }
        for i in incidents.indices where incidents[i].companyID == nil {
            incidents[i].companyID  = resolveFromProject(incidents[i].projectID)
            incidents[i].syncStatus = .pending
            fixed += 1
        }
        // Form submissions — derive from parent template; templates are
        // org-wide so fallback is safe.
        for i in formSubmissions.indices where formSubmissions[i].companyID == nil {
            let templateCompany = formTemplates
                .first(where: { $0.id == formSubmissions[i].templateID })?
                .companyID
            formSubmissions[i].companyID  = templateCompany ?? fallback
            formSubmissions[i].syncStatus = .pending
            fixed += 1
        }
        // Org-wide tables: equipment, form templates, product services
        // all map directly to currentCompanyID.
        for i in equipment.indices where equipment[i].companyID == nil {
            equipment[i].companyID  = fallback
            equipment[i].syncStatus = .pending
            fixed += 1
        }
        for i in formTemplates.indices where formTemplates[i].companyID == nil {
            formTemplates[i].companyID  = fallback
            formTemplates[i].syncStatus = .pending
            fixed += 1
        }
        for i in productServices.indices where productServices[i].companyID == nil {
            productServices[i].companyID  = fallback
            productServices[i].syncStatus = .pending
            fixed += 1
        }
        // Certificates live in UserDefaults (computed `certificates` is
        // get-only), so re-encode the array via `saveCertificatesPublic`
        // after stamping. Inherit tenant scope from the owning employee.
        var certs = certificates
        var certsChanged = false
        for i in certs.indices where certs[i].companyID == nil {
            let empCompany = employees
                .first(where: { $0.id == certs[i].employeeID })?
                .companyID
            certs[i].companyID  = empCompany ?? fallback
            certs[i].syncStatus = .pending
            certsChanged = true
            fixed += 1
        }
        if certsChanged {
            saveCertificatesPublic(certs)
        }
        if fixed > 0 {
            Task { await SyncEngine.shared.pushPending() }
        }
        return fixed
    }

    // MARK: - Audit Snapshot

    // MARK: - Pull-to-Refresh

    /// User-triggered pull from any list view's `.refreshable { await store.refreshAll() }`.
    /// No-op if the user is not signed in (avoids errors during sign-out animations).
    @MainActor
    func refreshAll() async {
        guard let user = currentUser else { return }
        await SyncEngine.shared.pullAll(for: user.id, role: currentUserRole)
        // After pulling fresh invoice data, flip any past-due open invoices
        // to .overdue and push the change. Lets server-side reports filter
        // by status = 'overdue' accurately.
        reconcileOverdueInvoices()
        // Stamp wonAt / lostAt on legacy opportunities that arrived without
        // them so the CRM Dashboard's Performance Snapshot, Reports, and
        // forecast cards stop silently dropping those deals. Idempotent.
        backfillCRMOutcomeTimestamps()
        // Stamp companyID on any project that was pulled before the Swift
        // model carried the field. Pre-condition for tightening the DB
        // column to NOT NULL — once this has run on every active client,
        // no new orphan rows should appear.
        backfillProjectCompanyIDs()
        backfillEmployeeCompanyIDs()
        backfillCrewCompanyIDs()
        // Project-derived + org-wide operational tables: schedules,
        // timesheets, incidents, equipment, certs, forms, submissions,
        // product/services. One pass — each entity inherits from its
        // natural parent and falls back to currentCompanyID.
        backfillOperationalCompanyIDs()
        backfillDJRCompanyIDs()
        // Reflect the latest projects + clients into Spotlight after each
        // pull. Replaces stale entries from prior pulls.
        // Week 4 audit closeout: reindex now also covers
        // opportunities, quotes, and invoices so Spotlight surfaces
        // commercial records in addition to the original project +
        // client domains.
        SpotlightService.shared.reindexAll(
            projects:      projects,
            clients:       clients,
            opportunities: crmOpportunities,
            quotes:        quotes,
            invoices:      invoices
        )
    }

    /// Aggregate count of records currently in `.failed` state across the
    /// major synced collections. Drives the FailedSyncBanner visibility.
    /// Note: walks arrays explicitly because not every entity type conforms
    /// to BaseModel — some carry `syncStatus` directly without the protocol.
    var totalFailedSyncCount: Int {
        var n = 0
        n += projects.filter        { $0.syncStatus == .failed }.count
        n += employees.filter       { $0.syncStatus == .failed }.count
        n += crews.filter           { $0.syncStatus == .failed }.count
        n += scheduleEntries.filter { $0.syncStatus == .failed }.count
        n += timesheetEntries.filter{ $0.syncStatus == .failed }.count
        n += formTemplates.filter   { $0.syncStatus == .failed }.count
        n += formSubmissions.filter { $0.syncStatus == .failed }.count
        n += incidents.filter       { $0.syncStatus == .failed }.count
        n += equipment.filter       { $0.syncStatus == .failed }.count
        n += changeOrders.filter    { $0.syncStatus == .failed }.count
        n += rfis.filter            { $0.syncStatus == .failed }.count
        n += projectBudgets.filter  { $0.syncStatus == .failed }.count
        n += subcontractors.filter  { $0.syncStatus == .failed }.count
        n += subContracts.filter    { $0.syncStatus == .failed }.count
        n += invoices.filter        { $0.syncStatus == .failed }.count
        n += materialRequests.filter{ $0.syncStatus == .failed }.count
        n += suppliers.filter       { $0.syncStatus == .failed }.count
        n += purchaseOrders.filter  { $0.syncStatus == .failed }.count
        n += productServices.filter { $0.syncStatus == .failed }.count
        n += estimates.filter       { $0.syncStatus == .failed }.count
        n += materialSales.filter   { $0.syncStatus == .failed }.count
        n += clients.filter         { $0.syncStatus == .failed }.count
        n += crmContacts.filter     { $0.syncStatus == .failed }.count
        n += crmOpportunities.filter{ $0.syncStatus == .failed }.count
        n += crmTasks.filter        { $0.syncStatus == .failed }.count
        n += crmActivities.filter   { $0.syncStatus == .failed }.count
        return n
    }

    /// User-triggered retry of all failed pushes. Flips `.failed` records back
    /// to `.pending` so the standard `pushPending()` machinery picks them up.
    @MainActor
    func retryFailedSyncs() async {
        for i in projects.indices         where projects[i].syncStatus         == .failed { projects[i].syncStatus         = .pending }
        for i in employees.indices        where employees[i].syncStatus        == .failed { employees[i].syncStatus        = .pending }
        for i in crews.indices            where crews[i].syncStatus            == .failed { crews[i].syncStatus            = .pending }
        for i in scheduleEntries.indices  where scheduleEntries[i].syncStatus  == .failed { scheduleEntries[i].syncStatus  = .pending }
        for i in timesheetEntries.indices where timesheetEntries[i].syncStatus == .failed { timesheetEntries[i].syncStatus = .pending }
        for i in formTemplates.indices    where formTemplates[i].syncStatus    == .failed { formTemplates[i].syncStatus    = .pending }
        for i in formSubmissions.indices  where formSubmissions[i].syncStatus  == .failed { formSubmissions[i].syncStatus  = .pending }
        for i in incidents.indices        where incidents[i].syncStatus        == .failed { incidents[i].syncStatus        = .pending }
        for i in equipment.indices        where equipment[i].syncStatus        == .failed { equipment[i].syncStatus        = .pending }
        for i in changeOrders.indices     where changeOrders[i].syncStatus     == .failed { changeOrders[i].syncStatus     = .pending }
        for i in rfis.indices             where rfis[i].syncStatus             == .failed { rfis[i].syncStatus             = .pending }
        for i in projectBudgets.indices   where projectBudgets[i].syncStatus   == .failed { projectBudgets[i].syncStatus   = .pending }
        for i in subcontractors.indices   where subcontractors[i].syncStatus   == .failed { subcontractors[i].syncStatus   = .pending }
        for i in subContracts.indices     where subContracts[i].syncStatus     == .failed { subContracts[i].syncStatus     = .pending }
        for i in invoices.indices         where invoices[i].syncStatus         == .failed { invoices[i].syncStatus         = .pending }
        for i in materialRequests.indices where materialRequests[i].syncStatus == .failed { materialRequests[i].syncStatus = .pending }
        for i in suppliers.indices        where suppliers[i].syncStatus        == .failed { suppliers[i].syncStatus        = .pending }
        for i in purchaseOrders.indices   where purchaseOrders[i].syncStatus   == .failed { purchaseOrders[i].syncStatus   = .pending }
        for i in productServices.indices  where productServices[i].syncStatus  == .failed { productServices[i].syncStatus  = .pending }
        for i in estimates.indices        where estimates[i].syncStatus        == .failed { estimates[i].syncStatus        = .pending }
        for i in materialSales.indices    where materialSales[i].syncStatus    == .failed { materialSales[i].syncStatus    = .pending }
        for i in clients.indices          where clients[i].syncStatus          == .failed { clients[i].syncStatus          = .pending }
        for i in crmContacts.indices      where crmContacts[i].syncStatus      == .failed { crmContacts[i].syncStatus      = .pending }
        for i in crmOpportunities.indices where crmOpportunities[i].syncStatus == .failed { crmOpportunities[i].syncStatus = .pending }
        for i in crmTasks.indices         where crmTasks[i].syncStatus         == .failed { crmTasks[i].syncStatus         = .pending }
        for i in crmActivities.indices    where crmActivities[i].syncStatus    == .failed { crmActivities[i].syncStatus    = .pending }
        await SyncEngine.shared.pushPending()
    }

    /// Hard-deletes every record currently in `.failed` state from the local
    /// store. Used when records are permanently stuck (e.g. they reference
    /// a parent that doesn't exist on the server). Wired to the FailedSyncBanner
    /// "Discard failed items" action, gated by a confirmation alert.
    ///
    /// IMPORTANT: these records are NOT on Supabase — that's why they're failed —
    /// so this is a true delete, not a soft-delete. There is no recovery path.
    @MainActor
    func discardFailedSyncs() {
        projects.removeAll          { $0.syncStatus == .failed }
        employees.removeAll         { $0.syncStatus == .failed }
        crews.removeAll             { $0.syncStatus == .failed }
        scheduleEntries.removeAll   { $0.syncStatus == .failed }
        timesheetEntries.removeAll  { $0.syncStatus == .failed }
        formTemplates.removeAll     { $0.syncStatus == .failed }
        formSubmissions.removeAll   { $0.syncStatus == .failed }
        incidents.removeAll         { $0.syncStatus == .failed }
        equipment.removeAll         { $0.syncStatus == .failed }
        // certificates is a computed property backed by UserDefaults — go
        // through saveCertificatesPublic to persist the filtered list.
        let cleanedCerts = certificates.filter { $0.syncStatus != .failed }
        if cleanedCerts.count != certificates.count {
            saveCertificatesPublic(cleanedCerts)
        }
        changeOrders.removeAll      { $0.syncStatus == .failed }
        rfis.removeAll              { $0.syncStatus == .failed }
        projectBudgets.removeAll    { $0.syncStatus == .failed }
        subcontractors.removeAll    { $0.syncStatus == .failed }
        subContracts.removeAll      { $0.syncStatus == .failed }
        invoices.removeAll          { $0.syncStatus == .failed }
        materialRequests.removeAll  { $0.syncStatus == .failed }
        suppliers.removeAll         { $0.syncStatus == .failed }
        purchaseOrders.removeAll    { $0.syncStatus == .failed }
        productServices.removeAll   { $0.syncStatus == .failed }
        estimates.removeAll         { $0.syncStatus == .failed }
        materialSales.removeAll     { $0.syncStatus == .failed }
        clients.removeAll           { $0.syncStatus == .failed }
        crmContacts.removeAll       { $0.syncStatus == .failed }
        crmOpportunities.removeAll  { $0.syncStatus == .failed }
        crmTasks.removeAll          { $0.syncStatus == .failed }
        crmActivities.removeAll     { $0.syncStatus == .failed }
        objectWillChange.send()
    }

    func createAuditSnapshot(for entity: some BaseModel & Encodable, eventType: String, by user: String) {
        guard let data = try? JSONEncoder().encode(entity) else { return }
        let snapshot = AuditSnapshot(
            id: UUID(),
            entityType: String(describing: type(of: entity)),
            entityID: entity.id,
            eventType: eventType,
            snapshotData: data,
            createdAt: Date(),
            createdBy: user,
            companyID: currentCompanyID,
            syncStatus: .pending
        )
        auditSnapshots.append(snapshot)
        saveToDisk()
        // Push to Supabase so the audit trail survives app reinstall and is
        // queryable from the dashboard for compliance review.
        Task { await SyncEngine.shared.pushPendingAuditSnapshots() }
    }

    // MARK: - Sync Queue

    func pendingSyncItems<T: BaseModel>(in keyPath: KeyPath<AppStore, [T]>) -> [T] {
        self[keyPath: keyPath].filter { $0.syncStatus == .pending || $0.syncStatus == .failed }
    }

    // MARK: - Sign-Out Data Wipe
    // Called on every sign-out. Clears memory AND disk so a subsequent user
    // on the same device cannot read prior company data.
    //
    // ENTRY POINTS
    // - `fullSignOutReset()` — preferred public entry; nukes everything
    //   including UserDefaults. Use this on every sign-out path.
    // - `clearAllData()` — internal building block; clears memory + auth
    //   state but leaves UserDefaults intact. Used by the auth-state
    //   listener as a safety net.

    /// Hard reset called from every sign-out path. Tenant-isolation fix:
    /// pre-fix the home-screen sign-out only reset `currentUser`, leaving
    /// `currentCompanyID` and the SyncEngine state in memory. The next
    /// user's sign-in then briefly read the previous tenant's
    /// `currentCompanyID` before the new profile fetch overwrote it,
    /// causing user A's data to flash in user B's UI.
    ///
    /// Order matters:
    ///   1. Wipe in-memory data + auth state via `clearAllData()`
    ///   2. Reset SyncEngine (stop realtime, clear lastSyncAt)
    ///   3. Wipe persisted tenant data from UserDefaults
    func fullSignOutReset() {
        clearAllData()
        SyncEngine.shared.reset()
        // Wipe the in-memory company settings cache. Server row stays;
        // it'll be re-loaded on next sign-in.
        AppSettings.shared.clearForSignOut()

        // Phase 1 Step 3: wipe the LocalPendingStore file BEFORE wiping
        // UserDefaults so the actor cancels any pending debounced write
        // first. Detach + remove file is idempotent and safe across
        // double sign-out paths.
        Task { await LocalPendingStore.shared.wipe() }

        // Wipe the entire app UserDefaults domain so no tenant-scoped
        // cache key (workflow_log, daily_job_reports, sample_data
        // active-batch tracking, etc.) survives. The legacy-wipe flag
        // and any non-tenant config get wiped too — those are either
        // idempotent (legacy wipe re-runs harmlessly) or non-critical.
        // Note: company settings used to live here; now in
        // company_settings table — see CompanySettingsService.
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            UserDefaults.standard.synchronize()
        }
    }

    func clearAllData() {
        // Tear down realtime subscriptions before wiping state so the next
        // signed-in user does not inherit live channels for the prior company.
        SyncEngine.shared.stopRealtime()
        // Drop everything we put into the system Spotlight index — otherwise
        // a user who shares a device sees the previous user's projects/clients
        // when they search Spotlight.
        SpotlightService.shared.deleteAll()
        // Wipe in-memory state — nothing on disk or UserDefaults to clear
        projects          = []; employees = []; crews = []
        scheduleEntries   = []; timesheetEntries = []; exceptionLogs = []
        formTemplates     = []; formSubmissions = []; estimates = []; auditSnapshots = []
        equipment         = []; invoices = []; materialRequests = []
        purchaseOrders    = []; suppliers = []
        pendingWorkflowAlerts = []; workflowLog = []
        changeOrders      = []; rfis = []; projectBudgets = []
        subcontractors    = []; subContracts = []
        incidents         = []; clients = []; companyCostCodes = []; importBatches = []
        crmContacts       = []; crmOpportunities = []; crmTasks = []
        crmActivities     = []; handoffChecklists = []; crmAttachments = []
        // Wipe session state
        currentUser       = nil
        currentUserRole   = .fieldWorker
        currentCompanyID  = nil
        isAuthenticated   = false
        // Clear crash reporter user context so sign-out is reflected in future events
        CrashReporter.clearUserContext()
    }

}


